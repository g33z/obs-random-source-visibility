#!/usr/bin/env bash
#
# Installs a pinned, checksum-verified NSIS (makensis) for building the
# Windows installer, on any Linux box without Homebrew - used by both CI
# workflows. Distro nsis packages lag behind NSIS's security fixes (Ubuntu
# 24.04 ships 3.09, 26.04 ships 3.10), and NSIS CVEs live in the installer
# stub that ends up inside our .exe, so the version matters.
#
# Same recipe as Homebrew's makensis formula: compile only the native
# makensis from source, and take the prebuilt Windows parts (Stubs, Plugins,
# Include, Contrib) from NSIS's official release .zip - so no mingw
# 32-bit toolchain is needed to build the stubs.
#
# Usage: bin/install-nsis.sh [PREFIX]   (default: $HOME/.local/nsis-$NSIS_VERSION)
# Puts makensis at PREFIX/bin/makensis - add that dir to PATH.
# Needs: curl, unzip, scons, a C++ compiler, zlib headers
#   (apt: scons g++ zlib1g-dev unzip).
#
# Bumping: set NSIS_VERSION and both sha256s below. Cross-check the hashes
# against Homebrew's formula (Formula/m/makensis.rb in homebrew-core), not
# just against what you downloaded. `make outdated` flags a newer release.
set -euo pipefail

NSIS_VERSION="3.13"
NSIS_SRC_SHA256="a8ffe024602d46b6d766f9e1ce30c324ad2a24daeacd3efc2642d436a0c157ac"
NSIS_ZIP_SHA256="ba63dffc4410ee89193e1cb5a41989991bd77c61068da17e3156d136b7b0b3d8"

PREFIX="${1:-$HOME/.local/nsis-$NSIS_VERSION}"
BASE_URL="https://downloads.sourceforge.net/project/nsis/NSIS%203/$NSIS_VERSION"

if [ -x "$PREFIX/bin/makensis" ] && "$PREFIX/bin/makensis" -VERSION | grep -qx "v$NSIS_VERSION"; then
	echo "NSIS $NSIS_VERSION already installed at $PREFIX"
	exit 0
fi

for tool in curl unzip scons; do
	command -v "$tool" >/dev/null || {
		echo "$tool not found - install it (apt: scons g++ zlib1g-dev unzip)" >&2
		exit 1
	}
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() {
	local file=$1 sha=$2
	curl -fsSL --retry 3 -o "$WORK/$file" "$BASE_URL/$file"
	echo "$sha  $WORK/$file" | sha256sum -c --quiet - || {
		echo "checksum mismatch for $file - refusing to install" >&2
		exit 1
	}
}
fetch "nsis-$NSIS_VERSION-src.tar.bz2" "$NSIS_SRC_SHA256"
fetch "nsis-$NSIS_VERSION.zip" "$NSIS_ZIP_SHA256"

tar -xjf "$WORK/nsis-$NSIS_VERSION-src.tar.bz2" -C "$WORK"
(
	cd "$WORK/nsis-$NSIS_VERSION-src"
	# makensis bakes PREFIX/share/nsis in as its data path (Stubs/Include/...).
	scons makensis \
		PREFIX="$PREFIX" \
		SKIPMISC=all SKIPPLUGINS=all SKIPSTUBS=all SKIPUTILS=all \
		VERSION="$NSIS_VERSION" \
		-j "$(nproc 2>/dev/null || echo 2)" >/dev/null
)

rm -rf "$PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/share"
install -m 755 "$WORK/nsis-$NSIS_VERSION-src/build/urelease/makensis/makensis" "$PREFIX/bin/makensis"
unzip -q "$WORK/nsis-$NSIS_VERSION.zip" -d "$WORK/zip"
mv "$WORK/zip/nsis-$NSIS_VERSION" "$PREFIX/share/nsis"

"$PREFIX/bin/makensis" -VERSION
echo
echo "Installed NSIS $NSIS_VERSION to $PREFIX - makensis is at $PREFIX/bin/makensis"
