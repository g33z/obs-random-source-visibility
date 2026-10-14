#!/usr/bin/env bash
#
# Cuts a release: shows the current version, takes the next one as its first
# argument (`make release 1.3.1`) or prompts for it (default: next patch),
# rewrites CMakeLists.txt's project(... VERSION x.y.z) - the single source of
# truth PLUGIN_VERSION and every artifact filename are derived from - then
# commits that one file and tags the commit vx.y.z. Bump and tag used to be
# two manual steps, which let them drift (CMakeLists.txt reading an old
# version at an already-pushed tag). Does not push - prints the push command.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
	echo "error: working tree is not clean. Commit or stash your changes first," >&2
	echo "       so the version bump is its own commit." >&2
	exit 1
fi

CMAKE_VERSION="$(sed -n -E 's/^project[^V]*VERSION ([0-9.]+).*/\1/p' CMakeLists.txt)"
LAST_TAG="$(git tag --list 'v*' --sort=-v:refname | head -n1)"
echo "Current version: ${CMAKE_VERSION:-unknown} (CMakeLists.txt)"
echo "Last tag:        ${LAST_TAG:-none yet}"
if [[ -n "$LAST_TAG" && "$LAST_TAG" != "v$CMAKE_VERSION" ]]; then
	echo "warning: CMakeLists.txt and the last tag disagree."
fi
echo

SUGGESTED=""
if [[ "$CMAKE_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
	SUGGESTED="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
fi

RAW_VERSION="${1:-}"
if [[ -z "$RAW_VERSION" ]]; then
	read -rp "Next version${SUGGESTED:+ [$SUGGESTED]}: " RAW_VERSION
	RAW_VERSION="${RAW_VERSION:-$SUGGESTED}"
fi
if [[ -z "$RAW_VERSION" ]]; then
	echo "error: no version given." >&2
	exit 1
fi

VERSION="${RAW_VERSION#v}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "error: '$RAW_VERSION' doesn't look like x.y.z." >&2
	exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
	echo "error: tag v$VERSION already exists." >&2
	exit 1
fi

read -rp "Release v$VERSION (${CMAKE_VERSION:-?} -> $VERSION)? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }

# sed -i differs between GNU and BSD/macOS; a temp file works on both.
sed -E "s/^(project[^V]*VERSION )[0-9.]+(.*)/\1$VERSION\2/" CMakeLists.txt > CMakeLists.txt.tmp
mv CMakeLists.txt.tmp CMakeLists.txt

git commit -m "Bump version to $VERSION" -- CMakeLists.txt
git tag "v$VERSION"

echo
echo "Bumped to $VERSION, committed, and tagged v$VERSION. Review with: git show"
echo "Push when ready (pushing the tag is what triggers the release CI job):"
echo "  git push && git push origin v$VERSION"
