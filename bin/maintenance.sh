#!/usr/bin/env bash
#
# Monthly maintenance pass: checks what's outdated (OBS/libobs, CI actions,
# local toolchain) and runs a security audit (CVE lookups for everything
# that ends up in or builds a shipped artifact, static analysis, shellcheck,
# and hardening/import checks on the built binaries). Report-only - it never
# bumps or rewrites anything itself; see .claude/skills/monthly-maintenance
# for the full routine including how to act on what it finds.
#
# Usage: bin/maintenance.sh [all|outdated|audit]   (default: all)
#   all       rebuild every platform this host can build, then outdated + audit
#   outdated  version checks only
#   audit     security checks only, against whatever is already built
#
# Exits non-zero if any check FAILs. WARNs are things to triage, not
# necessarily act on. The full output is also written to
# logs/maintenance-report.txt (build logs next to it).
#
# Env: GITHUB_TOKEN (optional, avoids GitHub's 60 req/h anonymous limit),
#      NVD_API_KEY (optional, lifts NVD's 5 req/30s anonymous limit),
#      MAINT_CVE_DAYS (default 45: how far back counts as a "new" CVE).

# ok/warn/fail/skip always return 0, so `cond && ok ... || fail ...` is a
# safe if/else throughout this file.
# shellcheck disable=SC2015
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PLUGIN_NAME="obs-random-source-visibility"
BUILD_DIR="build"
WIN_BUILD_DIR="$BUILD_DIR/windows"
# Outside build/ since `make rebuild` wipes that (logs/ is gitignored).
OUT_DIR="logs"
REPORT="$OUT_DIR/maintenance-report.txt"
CVE_DAYS="${MAINT_CVE_DAYS:-45}"
UNAME_S="$(uname -s)"

MODE="${1:-all}"
case "$MODE" in
all | outdated | audit) ;;
*)
	echo "usage: $0 [all|outdated|audit]" >&2
	exit 2
	;;
esac

mkdir -p "$OUT_DIR"
exec > >(tee "$REPORT") 2>&1

N_OK=0 N_WARN=0 N_FAIL=0 N_SKIP=0
ok() { N_OK=$((N_OK + 1)); printf '  [ OK ] %s\n' "$*"; }
warn() { N_WARN=$((N_WARN + 1)); printf '  [WARN] %s\n' "$*"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '  [FAIL] %s\n' "$*"; }
skip() { N_SKIP=$((N_SKIP + 1)); printf '  [SKIP] %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# version_lt a b: true if version a sorts strictly before version b.
version_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

days_ago() {
	date -u -d "-$1 days" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d
}
SINCE="$(days_ago "$CVE_DAYS")"

gh_api() {
	local auth=()
	[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL --max-time 30 "${auth[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

NVD_LAST_CALL=0
nvd_api() {
	local auth=() now
	if [ -n "${NVD_API_KEY:-}" ]; then
		auth=(-H "apiKey: $NVD_API_KEY")
	else
		# Anonymous limit is 5 requests per rolling 30s.
		now=$(date +%s)
		[ $((now - NVD_LAST_CALL)) -lt 7 ] && sleep $((7 - (now - NVD_LAST_CALL)))
		NVD_LAST_CALL=$(date +%s)
	fi
	curl -fsSL --max-time 60 "${auth[@]}" "https://services.nvd.nist.gov/rest/json/cves/2.0?$1"
}

# ---------------------------------------------------------------- versions

latest_obs_tag() { gh_api repos/obsproject/obs-studio/releases/latest | jq -r .tag_name; }

installed_obs_version() {
	case "$UNAME_S" in
	Darwin)
		/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
			"${OBS_APP_BUNDLE:-/Applications/OBS.app}/Contents/Info.plist" 2>/dev/null || true
		;;
	Linux)
		# obs-studio (obsproject PPA) ships its own headers; libobs-dev is
		# Ubuntu's separate package - whichever is installed is what we build
		# against.
		local v
		v=$(dpkg-query -W -f='${Version}' obs-studio 2>/dev/null ||
			dpkg-query -W -f='${Version}' libobs-dev 2>/dev/null || true)
		printf '%s' "${v%%[-+~]*}"
		;;
	esac
}

nsis_pinned_version() { sed -n 's/^NSIS_VERSION="\(.*\)"/\1/p' bin/install-nsis.sh; }

makensis_version() { have makensis && makensis -VERSION 2>/dev/null | sed 's/^v//; s/-.*//'; }

# ------------------------------------------------------------------ builds

run_builds() {
	section "Rebuild (fresh deps + build for every platform this host supports)"
	if make rebuild >"$OUT_DIR/maintenance-build-host.log" 2>&1; then
		ok "host build ($UNAME_S)"
	else
		fail "host build ($UNAME_S) failed - see $OUT_DIR/maintenance-build-host.log"
		tail -n 15 "$OUT_DIR/maintenance-build-host.log" | sed 's/^/         | /' || true
		grep -q 'Could NOT find SIMDe' "$OUT_DIR/maintenance-build-host.log" &&
			info "hint: obsproject's PPA libobs needs SIMDe headers - sudo apt install libsimde-dev"
	fi

	if have x86_64-w64-mingw32-gcc; then
		if make clean-windows build-windows >"$OUT_DIR/maintenance-build-windows.log" 2>&1; then
			ok "windows cross-build (against latest OBS release, via deps-windows.sh)"
		else
			fail "windows cross-build failed - see $OUT_DIR/maintenance-build-windows.log"
			tail -n 15 "$OUT_DIR/maintenance-build-windows.log" | sed 's/^/         | /' || true
		fi
	else
		skip "windows cross-build: x86_64-w64-mingw32-gcc not installed"
	fi
}

# ---------------------------------------------------------------- outdated

check_obs() {
	section "OBS Studio / libobs"
	local latest installed cached
	if ! latest=$(latest_obs_tag) || [ -z "$latest" ]; then
		warn "couldn't query latest OBS release from GitHub"
		return
	fi
	info "latest OBS release: $latest"

	installed=$(installed_obs_version)
	if [ -z "$installed" ]; then
		skip "no local OBS install found to compare against"
	elif version_lt "$installed" "$latest"; then
		warn "local OBS is $installed, latest is $latest - upgrade it (then 'make deps' on macOS)"
	else
		ok "local OBS $installed is current"
	fi

	if [ -L .deps/windows/libobs-headers ]; then
		cached=$(readlink .deps/windows/libobs-headers | sed -n 's|obs-studio-\([^/]*\)/libobs|\1|p')
		if [ "$cached" = "$latest" ]; then
			ok "windows deps (.deps/windows) are on $latest"
		else
			warn "windows deps are on $cached, latest is $latest - 'make deps-windows' refreshes them"
		fi
	fi
	if [ "$UNAME_S" = Darwin ] && [ -L .deps/libobs-headers ]; then
		cached=$(readlink .deps/libobs-headers | sed -n 's|obs-studio-\([^/]*\)/libobs|\1|p')
		[ "$cached" = "$installed" ] && ok "macOS deps match installed OBS $installed" ||
			warn "macOS deps are on $cached but OBS.app is $installed - run 'make deps'"
	fi

	local min
	min=$(sed -n "s/.*'Depends: obs-studio (>= \([0-9.]*\))'.*/\1/p" Makefile)
	info ".deb declares Depends: obs-studio (>= $min) - re-check this still holds if"
	info "the code started using newer libobs API (see skill step 2)"
}

check_actions() {
	section "CI actions (.github / .forgejo workflows)"
	local file line action ref latest api_base
	for file in .github/workflows/*.yml .forgejo/workflows/*.yml; do
		[ -f "$file" ] || continue
		while IFS= read -r line; do
			action=${line%@*}
			ref=${line#*@}
			if [[ "$action" == https://* ]] || [[ "$file" == .forgejo/* ]]; then
				# A full URL names its forge directly (e.g. Forgejo's patched
				# artifact forks on data.forgejo.org); Forgejo resolves bare
				# "actions/..." against its DEFAULT_ACTIONS_URL (data.forgejo.org),
				# which mirrors GitHub's actions on its own schedule - so compare
				# against that forge's tags, not GitHub.
				api_base=data.forgejo.org
				if [[ "$action" == https://* ]]; then
					api_base=${action#https://}
					api_base=${api_base%%/*}
					action=${action#https://"$api_base"/}
				fi
				latest=$(curl -fsSL --max-time 30 \
					"https://$api_base/api/v1/repos/$action/tags?limit=50" 2>/dev/null |
					jq -r '.[].name' | grep -E '^v[0-9]+(\.[0-9]+)*$' | sort -V | tail -1) || latest=""
			else
				latest=$(gh_api "repos/$action/releases/latest" 2>/dev/null | jq -r .tag_name) || latest=""
				api_base="github.com"
			fi
			if [ -z "$latest" ] || [ "$latest" = null ]; then
				warn "$file: $action@$ref - couldn't look up latest on $api_base"
				continue
			fi
			# A floating major tag (v4) is current as long as the major matches.
			if [[ "$ref" =~ ^v[0-9]+$ ]]; then
				if [ "$ref" = "${latest%%.*}" ]; then
					ok "$file: $action@$ref (latest $latest)"
				else
					warn "$file: $action@$ref - latest is $latest (major bump, read its changelog)"
				fi
			elif [ "$ref" = "$latest" ]; then
				ok "$file: $action@$ref"
			else
				warn "$file: $action@$ref - latest is $latest"
			fi
		done < <(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$file" | sort -u)

		[[ "$file" == .github/* ]] || continue
		local images runner row
		images=$(curl -fsSL --max-time 30 \
			https://raw.githubusercontent.com/actions/runner-images/main/README.md 2>/dev/null) || images=""
		while read -r runner; do
			if [ -z "$images" ]; then
				warn "$file: runs-on $runner - couldn't fetch actions/runner-images to check it"
				continue
			fi
			# Each image is one table row listing its labels in backticks; a
			# deprecated one carries a "deprecated" badge in the same row.
			row=$(grep -F "\`$runner\`" <<<"$images" | head -1)
			if [ -z "$row" ]; then
				warn "$file: runs-on $runner - not listed in actions/runner-images (removed?)"
			elif grep -qi deprecated <<<"$row"; then
				warn "$file: runs-on $runner - deprecated in actions/runner-images, move to a newer image"
			else
				ok "$file: runs-on $runner"
			fi
		done < <(sed -n 's/^[[:space:]]*runs-on:[[:space:]]*\(.*\)/\1/p' "$file" | sort -u)
	done
}

check_toolchain() {
	section "Local toolchain"
	have cmake && info "cmake $(cmake --version | head -1 | awk '{print $3}')"
	have cc && info "cc: $(cc --version | head -1)"
	have x86_64-w64-mingw32-gcc && info "mingw: $(x86_64-w64-mingw32-gcc --version | head -1)"
	have makensis && info "makensis $(makensis_version)"

	# CI builds NSIS from source at the version pinned in bin/install-nsis.sh;
	# Homebrew's formula tracks upstream releases closely, so it doubles as
	# the "latest NSIS" source.
	local nsis_pin nsis_latest
	nsis_pin=$(nsis_pinned_version)
	if nsis_latest=$(curl -fsSL --max-time 30 https://formulae.brew.sh/api/formula/makensis.json |
		jq -r .versions.stable) && [ -n "$nsis_latest" ]; then
		version_lt "$nsis_pin" "$nsis_latest" &&
			warn "bin/install-nsis.sh pins NSIS $nsis_pin, latest is $nsis_latest - bump it (see the script's header)" ||
			ok "bin/install-nsis.sh pins NSIS $nsis_pin (latest)"
	else
		warn "couldn't look up the latest NSIS release"
	fi

	local cmake_latest cmake_max
	cmake_max=$(sed -n 's/^cmake_minimum_required(VERSION [0-9.]*\.\.\.\([0-9.]*\)).*/\1/p' CMakeLists.txt)
	if cmake_latest=$(gh_api repos/Kitware/CMake/releases/latest | jq -r .tag_name | sed 's/^v//') &&
		[ -n "$cmake_max" ] && version_lt "$cmake_max" "$(echo "$cmake_latest" | cut -d. -f1,2)"; then
		info "CMake $cmake_latest is out; cmake_minimum_required's policy max is $cmake_max"
		info "(optional bump - raise it only after building cleanly with that CMake)"
	fi

	case "$UNAME_S" in
	Linux)
		local pending
		pending=$(apt list --upgradable 2>/dev/null |
			grep -E '^(cmake|gcc|binutils|gcc-mingw-w64|mingw-w64|binutils-mingw-w64|nsis|libobs|obs-studio|libsimde|shellcheck|cppcheck|clang)' || true)
		if [ -n "$pending" ]; then
			warn "apt has upgrades pending for build tools (run 'sudo apt update' first for fresh data):"
			printf '%s\n' "$pending" | sed 's/^/         | /'
		else
			ok "no pending apt upgrades for build tools (as of the last 'apt update')"
		fi
		;;
	Darwin)
		if have brew; then
			local pending
			pending=$(brew outdated cmake simde mingw-w64 makensis shellcheck cppcheck jq 2>/dev/null || true)
			pending+=$(brew outdated --cask obs 2>/dev/null || true)
			[ -n "$pending" ] && { warn "brew has upgrades pending:"; printf '%s\n' "$pending" | sed 's/^/         | /'; } ||
				ok "no pending brew upgrades for build tools"
		fi
		;;
	esac
}

# ------------------------------------------------------------------- audit

# cve_check LABEL KEYWORD VERSION SEVERITY [CPE] [REPORT_RECENT=1]
# Flags CVEs that affect VERSION (via NVD's CPE range matching when a CPE
# is given, else by parsing "before X"/"up to X" out of the description) as
# SEVERITY (fail|warn), and anything else published/updated in the last
# CVE_DAYS as a WARN to triage by hand (NVD often takes weeks to attach
# CPE data to a new CVE, so the range match alone misses fresh ones).
cve_check() {
	local label=$1 keyword=$2 version=$3 severity=$4 cpe=${5:-} report_recent=${6:-1}
	local json matched="" id desc pub mod bound
	if ! json=$(nvd_api "keywordSearch=$(jq -rn --arg k "$keyword" '$k|@uri')"); then
		warn "$label: NVD query failed"
		return
	fi
	if [ -n "$cpe" ] && [ -n "$version" ]; then
		local cpe_json
		if cpe_json=$(nvd_api "virtualMatchString=$cpe:$version"); then
			matched=$(printf '%s' "$cpe_json" | jq -r '.vulnerabilities[].cve.id')
			# Keyword search misses some CVEs the CPE match finds (and vice
			# versa), so walk the union of both.
			json=$(jq -s '{vulnerabilities: ([.[].vulnerabilities[]] | unique_by(.cve.id))}' \
				<(printf '%s' "$json") <(printf '%s' "$cpe_json"))
		else
			warn "$label: NVD CPE query failed"
		fi
	fi

	local hits=0
	while IFS=$'\t' read -r id pub mod desc; do
		[ -n "$id" ] || continue
		# The description's "before X"/"up to X" wins over NVD's CPE range
		# when both exist: NVD's ranges are sometimes off by one release.
		local affected="" desc_verdict=""
		if [ -n "$version" ]; then
			bound=$(printf '%s' "$desc" | sed -n 's/.*[Bb]efore \([0-9][0-9.]*[0-9]\).*/\1/p' | head -1)
			if [ -n "$bound" ]; then
				version_lt "$version" "$bound" && desc_verdict="$version is before fixed $bound" ||
					desc_verdict=no
			fi
			bound=$(printf '%s' "$desc" | sed -n 's/.*up to \([0-9][0-9.]*[0-9]\).*/\1/p' | head -1)
			if [ -n "$bound" ] && [ -z "$desc_verdict" ]; then
				version_lt "$bound" "$version" && desc_verdict=no ||
					desc_verdict="$version is within 'up to $bound'"
			fi
		fi
		if [ -n "$desc_verdict" ] && [ "$desc_verdict" != no ]; then
			affected="$desc_verdict (from description)"
		elif printf '%s\n' "$matched" | grep -qx "$id"; then
			if [ "$desc_verdict" = no ]; then
				hits=$((hits + 1))
				warn "$label: $id - NVD's CPE range includes $version but the description says it's fixed; verify"
				info "${desc:0:200}"
				continue
			fi
			affected="matches $version by NVD CPE range"
		fi
		if [ -n "$affected" ]; then
			hits=$((hits + 1))
			"$severity" "$label: $id affects us - $affected"
			info "${desc:0:200}"
		elif [ "$report_recent" = 1 ] && [[ "$pub" > "$SINCE" || "$mod" > "$SINCE" ]]; then
			hits=$((hits + 1))
			warn "$label: $id new/updated since $SINCE - triage by hand"
			info "${desc:0:200}"
		fi
	done < <(printf '%s' "$json" | jq -r '.vulnerabilities[].cve |
		[.id, .published[:10], .lastModified[:10],
		 ((.descriptions[] | select(.lang=="en") | .value) // "" | gsub("[\t\n]"; " "))] | @tsv')
	[ "$hits" -eq 0 ] && ok "$label${version:+ $version}: no known or recent CVEs"
	return 0
}

# action_ref_in_range REF RANGE: true if an action ref can resolve into an
# advisory's range (e.g. ">= 4.0.0, < 4.1.3"). A floating major tag (v4)
# follows that major's newest release, so it's treated as v4.<max>: it only
# counts as affected if the whole major is (no fixed release within it).
action_ref_in_range() {
	local ref=${1#v} range=$2 part op ver
	[[ "$ref" =~ ^[0-9]+$ ]] && ref="$ref.99999.99999"
	[[ "$ref" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1 # a SHA or branch: can't tell
	IFS=',' read -ra parts <<<"$range"
	for part in "${parts[@]}"; do
		read -r op ver <<<"$part"
		case "$op" in
		'>=') version_lt "$ref" "$ver" && return 1 ;;
		'>') { version_lt "$ref" "$ver" || [ "$ref" = "$ver" ]; } && return 1 ;;
		'<') version_lt "$ref" "$ver" || return 1 ;;
		'<=') { version_lt "$ref" "$ver" || [ "$ref" = "$ver" ]; } || return 1 ;;
		'=') [ "$ref" = "$ver" ] || return 1 ;;
		*) return 1 ;;
		esac
	done
	return 0
}

audit_cves() {
	section "CVEs (NVD) - things that build or ship in a release artifact"
	have jq || { skip "jq not installed - CVE checks need it"; return; }
	local obs_latest obs_local nsis
	obs_latest=$(latest_obs_tag 2>/dev/null) || obs_latest=""
	obs_local=$(installed_obs_version)
	# OBS itself isn't shipped by us, so it's a WARN - it matters for the
	# OBS you run and the minimum version the plugin claims to support.
	cve_check "OBS Studio (local)" "OBS Studio" "$obs_local" warn
	[ -n "$obs_latest" ] && [ "$obs_latest" != "$obs_local" ] &&
		cve_check "OBS Studio (latest)" "OBS Studio" "$obs_latest" warn "" 0
	# makensis builds the Windows installer we ship, and NSIS CVEs are
	# about the generated installer itself - a vulnerable makensis means a
	# vulnerable .exe on users' machines, so this one FAILs.
	# The CI pin is what actually ships in a release; the local one matters
	# for installers built by hand.
	cve_check "NSIS (CI pin, bin/install-nsis.sh)" "Nullsoft Scriptable Install System" \
		"$(nsis_pinned_version)" fail "cpe:2.3:a:nullsoft:nullsoft_scriptable_install_system"
	nsis=$(makensis_version || true)
	if [ -z "$nsis" ]; then
		info "makensis not installed locally"
	elif [ "$nsis" != "$(nsis_pinned_version)" ]; then
		cve_check "NSIS (local makensis)" "Nullsoft Scriptable Install System" "$nsis" fail \
			"cpe:2.3:a:nullsoft:nullsoft_scriptable_install_system" 0
	fi
	cve_check "mingw-w64" "mingw-w64" "" warn
	cve_check "SIMDe" "SIMD Everywhere" "" warn

	section "Security advisories (GitHub Advisory Database)"
	local ghsa
	if ghsa=$(gh_api "repos/obsproject/obs-studio/security-advisories?per_page=100" 2>/dev/null); then
		local recent
		recent=$(printf '%s' "$ghsa" | jq -r --arg s "$SINCE" '.[] | select(.published_at >= $s) | "\(.ghsa_id) \(.severity) \(.summary)"')
		[ -n "$recent" ] && { warn "obs-studio advisories since $SINCE:"; printf '%s\n' "$recent" | sed 's/^/         | /'; } ||
			ok "obs-studio: no repository advisories since $SINCE"
	else
		warn "couldn't query obs-studio's security advisories"
	fi

	local uses action ref adv id sev range summary
	while read -r uses; do
		action=${uses%@*}
		ref=${uses#*@}
		# Advisories are keyed by GitHub owner/repo; a URL-form fork (e.g.
		# data.forgejo.org/forgejo/upload-artifact) is looked up by its path.
		action=${action#https://*/}
		if ! adv=$(gh_api "advisories?ecosystem=actions&affects=$action&per_page=100" 2>/dev/null); then
			warn "$action@$ref: advisory lookup failed (GitHub rate limit? set GITHUB_TOKEN)"
			continue
		fi
		local hit=0
		while IFS=$'\t' read -r id sev range summary; do
			[ -n "$id" ] || continue
			if action_ref_in_range "$ref" "$range"; then
				hit=1
				fail "$action@$ref is in the affected range of $id ($sev, $range): $summary"
			fi
		done < <(printf '%s' "$adv" | jq -r '.[] | .ghsa_id as $id | .severity as $s | .summary as $sum |
			.vulnerabilities[] | [$id, $s, .vulnerable_version_range, $sum] | @tsv')
		[ "$hit" -eq 0 ] && ok "$action@$ref: no advisories affecting this ref"
	done < <(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*\([^[:space:]#]*@[^[:space:]#]*\).*/\1/p' \
		.github/workflows/*.yml .forgejo/workflows/*.yml 2>/dev/null | sort -u)
}

# Re-runs each translation unit from a build dir's compile_commands.json
# through the compiler's static analyzer with extra warnings on, so the
# analysis sees exactly the flags/headers the real build used - and for the
# windows build dir that's the latest OBS release's headers, so this also
# catches newly deprecated libobs API before it gets removed.
analyze_build_dir() {
	local dir=$1 label=$2
	local db="$dir/compile_commands.json"
	if [ ! -f "$db" ]; then
		skip "$label: no $db (build it first, or run '$0 all')"
		return
	fi
	local n out cc cmd extra all_out=""
	for n in $(jq -r 'keys[]' "$db"); do
		cmd=$(jq -r ".[$n].command" "$db" | sed 's/ -o [^ ]*/ -o \/dev\/null/')
		cc=${cmd%% *}
		extra="-Wall -Wextra -Wformat=2 -Wformat-security -Wshadow -Wnull-dereference -Wdeprecated-declarations"
		if "$cc" --version 2>/dev/null | grep -q 'Free Software Foundation'; then
			extra+=" -fanalyzer"
		elif "$cc" --version 2>/dev/null | grep -q clang; then
			extra+=" --analyze"
		fi
		# shellcheck disable=SC2086 # cmd is a compile command line, word-splitting intended
		out=$(cd "$(jq -r ".[$n].directory" "$db")" && eval "$cmd $extra" 2>&1) || true
		all_out+=$(printf '%s' "$out" | grep -E 'warning:|error:' || true)
	done
	if [ -n "$all_out" ]; then
		fail "$label: compiler/analyzer findings:"
		printf '%s\n' "$all_out" | sed 's/^/         | /'
	else
		ok "$label: clean (-Wall -Wextra + static analyzer)"
	fi
}

audit_static() {
	section "Static analysis"
	have jq || { skip "jq not installed - needed to read compile_commands.json"; return; }
	analyze_build_dir "$BUILD_DIR" "host build ($UNAME_S)"
	analyze_build_dir "$WIN_BUILD_DIR" "windows build (latest OBS headers)"

	if have cppcheck; then
		local out
		out=$(cppcheck --enable=warning,performance,portability --inline-suppr --quiet \
			--suppress=missingIncludeSystem --suppress=missingInclude --suppress=unknownMacro \
			-D__GNUC__ src/ 2>&1) || true
		[ -n "$out" ] && { fail "cppcheck:"; printf '%s\n' "$out" | sed 's/^/         | /'; } || ok "cppcheck: clean"
	else
		skip "cppcheck not installed (apt install cppcheck / brew install cppcheck)"
	fi

	if have shellcheck; then
		local out
		out=$(shellcheck ./*.sh bin/*.sh 2>&1) || true
		[ -n "$out" ] && { fail "shellcheck:"; printf '%s\n' "$out" | sed 's/^/         | /'; } || ok "shellcheck: clean"
	else
		skip "shellcheck not installed (apt install shellcheck / brew install shellcheck)"
	fi

	if have actionlint; then
		local out
		out=$(actionlint .github/workflows/*.yml 2>&1) || true
		[ -n "$out" ] && { fail "actionlint:"; printf '%s\n' "$out" | sed 's/^/         | /'; } || ok "actionlint: clean (.github)"
	else
		skip "actionlint not installed (go install github.com/rhysd/actionlint/cmd/actionlint@latest / brew install actionlint)"
	fi
}

audit_artifacts() {
	section "Built artifacts (hardening, imports, exports)"
	local so="$BUILD_DIR/$PLUGIN_NAME.so"
	if [ "$UNAME_S" = Linux ] && [ -f "$so" ] && have readelf; then
		local ph dyn needed
		ph=$(readelf -lW "$so")
		dyn=$(readelf -dW "$so")
		grep -q GNU_RELRO <<<"$ph" && ok ".so: RELRO" || fail ".so: no RELRO"
		grep -qE 'BIND_NOW|FLAGS_1.*NOW' <<<"$dyn" && ok ".so: BIND_NOW (full RELRO)" ||
			fail ".so: no BIND_NOW - only partial RELRO"
		grep -E 'GNU_STACK' <<<"$ph" | grep -q 'RWE' && fail ".so: executable stack" || ok ".so: non-executable stack"
		grep -q TEXTREL <<<"$dyn" && fail ".so: has text relocations" || ok ".so: no text relocations"
		needed=$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn" | grep -vE '^(libobs\.so|libc\.so|libm\.so|libpthread\.so)' || true)
		[ -z "$needed" ] && ok ".so: links only libobs + libc" || warn ".so: unexpected NEEDED libs: $needed"
		nm -D --defined-only "$so" | grep -q ' obs_module_load$' && ok ".so: exports obs_module_load" ||
			fail ".so: obs_module_load not exported - OBS won't load it"
	elif [ "$UNAME_S" = Darwin ] && [ -d "$BUILD_DIR/$PLUGIN_NAME.plugin" ]; then
		local bin="$BUILD_DIR/$PLUGIN_NAME.plugin/Contents/MacOS/$PLUGIN_NAME"
		otool -L "$bin" | grep -q '@executable_path/../Frameworks/libobs.framework' &&
			ok ".plugin: libobs path rewritten for loading inside OBS.app" ||
			fail ".plugin: libobs install name not rewritten (install_name_tool step)"
		otool -L "$bin" | tail -n +2 | grep -vE 'libobs|/usr/lib/|/System/' | sed 's/^/         | unexpected: /' || true
	else
		skip "host artifact: not built"
	fi

	local dll="$WIN_BUILD_DIR/$PLUGIN_NAME.dll"
	local objdump=x86_64-w64-mingw32-objdump
	if [ -f "$dll" ] && have "$objdump"; then
		local pe flag imports
		pe=$("$objdump" -p "$dll")
		for flag in DYNAMIC_BASE NX_COMPAT HIGH_ENTROPY_VA; do
			grep -qw "$flag" <<<"$pe" && ok ".dll: $flag" || fail ".dll: missing $flag"
		done
		# Anything beyond obs.dll and the OS/CRT DLLs (e.g. libgcc_s_seh-1.dll,
		# libwinpthread-1.dll) won't exist on a user's machine and makes OBS
		# fail to load the plugin.
		imports=$(sed -n 's/.*DLL Name: //p' <<<"$pe" |
			grep -viE '^(obs\.dll|kernel32\.dll|msvcrt\.dll|ucrtbase\.dll|api-ms-win-.*\.dll|user32\.dll|advapi32\.dll)$' || true)
		[ -z "$imports" ] && ok ".dll: imports only obs.dll + system DLLs" ||
			fail ".dll: imports DLLs users won't have: $imports"
		grep -qE '\] obs_module_load$' <<<"$pe" && ok ".dll: exports obs_module_load" ||
			fail ".dll: obs_module_load not exported - OBS won't load it"
	else
		skip "windows artifact: not built"
	fi
}

# -------------------------------------------------------------------- main

echo "bin/maintenance.sh $MODE - $(date -u +%Y-%m-%dT%H:%MZ) - $UNAME_S - CVE window since $SINCE"
for tool in curl jq; do have "$tool" || echo "warning: $tool not installed - network/JSON checks will be skipped or fail"; done

[ "$MODE" = all ] && run_builds
if [ "$MODE" = all ] || [ "$MODE" = outdated ]; then
	check_obs
	check_actions
	check_toolchain
fi
if [ "$MODE" = all ] || [ "$MODE" = audit ]; then
	audit_cves
	audit_static
	audit_artifacts
fi

section "Summary"
echo "  $N_OK ok, $N_WARN warn, $N_FAIL fail, $N_SKIP skipped - report: $REPORT"
[ "$N_FAIL" -eq 0 ]
