#!/usr/bin/env bash
#
# Fetches libobs headers and synthesizes an obs.lib import library for
# cross-compiling this plugin to Windows from Linux/macOS via mingw-w64.
# Windows OBS builds ship obs.dll but no import library to link against, so
# this dumps its export table (objdump) into a generated .def file and feeds
# that to dlltool to produce one - the standard way to link against a DLL
# that doesn't ship its own import library. See CLAUDE.md for background.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_DIR="$REPO_ROOT/.deps/windows"
GENERATED_DIR="$DEPS_DIR/generated"

OBJDUMP="${MINGW_OBJDUMP:-x86_64-w64-mingw32-objdump}"
DLLTOOL="${MINGW_DLLTOOL:-x86_64-w64-mingw32-dlltool}"

command -v "$OBJDUMP" >/dev/null || {
	echo "$OBJDUMP not found - install gcc-mingw-w64-x86-64 (apt) or mingw-w64 (brew)" >&2
	exit 1
}
command -v "$DLLTOOL" >/dev/null || {
	echo "$DLLTOOL not found - install gcc-mingw-w64-x86-64 (apt) or mingw-w64 (brew)" >&2
	exit 1
}

mkdir -p "$GENERATED_DIR"

OBS_TAG=$(curl -fsSL https://api.github.com/repos/obsproject/obs-studio/releases/latest |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
if [ -z "$OBS_TAG" ]; then
	echo "couldn't determine latest obs-studio release tag from the GitHub API" >&2
	exit 1
fi
echo "Targeting OBS Studio $OBS_TAG"

SRC_DIR="$DEPS_DIR/obs-studio-$OBS_TAG"
if [ ! -f "$SRC_DIR/libobs/obs.h" ]; then
	rm -rf "$DEPS_DIR"/obs-studio-*
	git clone --filter=blob:none --sparse --depth 1 --branch "$OBS_TAG" \
		https://github.com/obsproject/obs-studio.git "$SRC_DIR"
	git -C "$SRC_DIR" sparse-checkout set libobs
fi
ln -sfn "obs-studio-$OBS_TAG/libobs" "$DEPS_DIR/libobs-headers"

OBS_ROOT="$DEPS_DIR/obs-root"
OBS_DLL="$OBS_ROOT/bin/64bit/obs.dll"
if [ ! -f "$OBS_DLL" ]; then
	ZIP_URL="https://github.com/obsproject/obs-studio/releases/download/$OBS_TAG/OBS-Studio-$OBS_TAG-Windows-x64.zip"
	TMP_ZIP=$(mktemp)
	trap 'rm -f "$TMP_ZIP"' EXIT
	curl -fsSL -o "$TMP_ZIP" "$ZIP_URL"
	rm -rf "$OBS_ROOT"
	mkdir -p "$OBS_ROOT"
	unzip -q "$TMP_ZIP" "bin/64bit/obs.dll" -d "$OBS_ROOT"
fi

# obs.dll's C API symbols are undecorated on x64 (no name-mangling), so the
# export table's names are usable in a .def file as-is.
DEF_FILE="$GENERATED_DIR/obs.def"
{
	echo "EXPORTS"
	# Keeps reading to EOF instead of exiting once the export table ends -
	# an early exit would close the pipe while objdump is still writing the
	# rest of the file's dump, killing it with SIGPIPE under `pipefail`.
	"$OBJDUMP" -p "$OBS_DLL" | awk '
		/\[Ordinal\/Name Pointer\] Table/ { found=1; next }
		found && /^\t\[[ 0-9]+\] / { sub(/^\t\[[ 0-9]+\] /, ""); print; next }
		{ found=0 }
	'
} >"$DEF_FILE"

if [ "$(wc -l <"$DEF_FILE")" -lt 2 ]; then
	echo "no exports parsed from $OBS_DLL - obs.dll's export table format may have changed" >&2
	exit 1
fi

"$DLLTOOL" -d "$DEF_FILE" -D obs.dll -l "$GENERATED_DIR/obs.lib"

cat >"$GENERATED_DIR/obsconfig.h" <<'EOF'
#pragma once
/* #undef OBS_DATA_PATH */
/* #undef OBS_PLUGIN_PATH */
/* #undef OBS_PLUGIN_DESTINATION */
/* #undef GIO_FOUND */
/* #undef PULSEAUDIO_FOUND */
/* #undef XCB_XINPUT_FOUND */
/* #undef ENABLE_WAYLAND */
#define OBS_RELEASE_CANDIDATE 0
#define OBS_BETA 0
EOF

echo "Fetched libobs $OBS_TAG headers and synthesized obs.lib into $DEPS_DIR"
