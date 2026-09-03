# Random Source Visibility

[![Release](https://github.com/g33z/obs-random-source-visibility/actions/workflows/release.yml/badge.svg)](https://github.com/g33z/obs-random-source-visibility/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/g33z/obs-random-source-visibility)](https://github.com/g33z/obs-random-source-visibility/releases/latest)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-blue)](#building)

A native OBS Studio filter plugin. Attach it to a **scene** or a **group**.
It shows exactly one direct child source at a time, picking a new one at
random and hiding the previous one on each trigger.

## Behavior

- One child visible per filter instance at a time.
- Trigger hides the previous child, picks a new random child, shows it.
- Avoids repeating the same child twice in a row by default (configurable).
- Only direct children count; nested groups are treated as a single item.

## Triggers

Combine any of the three:

- **Hotkey** - bind one per filter instance under Settings → Hotkeys.
- **Timer** - enable "Automatically re-roll on a timer" and set an interval.
- **Activation** - enable "Re-roll when this scene/group becomes active".

Use "Trigger Now" in the filter properties to test manually.

## Usage in OBS

1. Right-click the scene or group → **Filters**.
2. Under "Effect Filters", click **+** → **Random Source Visibility**.
3. Configure timer/activation/repeat as needed.
4. Optionally bind a hotkey in Settings → Hotkeys.

## Building

A native C plugin built against libobs via CMake, not a script.

### macOS (Apple Silicon)

Links against the libobs bundled inside an installed OBS.app.

```bash
brew install cmake simde
brew install --cask obs   # if OBS isn't already installed

make deps     # fetch libobs headers matching your installed OBS version
make build    # configure + compile
make install  # install into ~/Library/Application Support/obs-studio/plugins/
```

Pass `OBS_APP_BUNDLE=/path/to/OBS.app` to any target if OBS.app isn't at
`/Applications/OBS.app`. Re-run `make deps` after upgrading OBS.

Relaunch OBS and check **Help → Log Files → View Current Log** for
`[obs-random-source-visibility] plugin loaded` to confirm it loaded.

### Linux

```bash
sudo apt install cmake libobs-dev
make build     # or: cmake -B build -S . && cmake --build build
make install   # install into ~/.config/obs-studio/plugins/obs-random-source-visibility/
```

CMake finds libobs via `find_package(libobs)`.

Flatpak OBS isn't supported - OBS 30.2.0+ sandboxes against manually
installed native plugins. Use a system or apt-installed OBS instead.
Ubuntu's own `obs-studio` package is often outdated; prefer the
[official PPA](https://obsproject.com/wiki/install-instructions):

```bash
sudo add-apt-repository ppa:obsproject/obs-studio
sudo apt update
sudo apt install obs-studio
```

### Windows (cross-compiled from Linux/macOS)

There's no local Windows build path. Cross-compile the `.dll` with
mingw-w64 and build the installer with NSIS, both from Linux or macOS.

```bash
# Linux
sudo apt install cmake gcc-mingw-w64-x86-64 nsis
# macOS
brew install cmake mingw-w64 makensis

make deps-windows     # fetch libobs headers, synthesize obs.lib
make build-windows    # cross-compile the .dll
make package-windows  # build the installer .exe into build/dist/
```

Copy the installer onto a Windows machine and run it. There's no
`install-windows` target.

## Packaging

`make package` (macOS/Linux) or `make package-windows` builds a
distributable installer into `build/dist/`: a `.dmg` on macOS, a `.deb`
on Linux, an NSIS `.exe` on Windows.

Install the `.deb` with `apt install ./build/dist/*.deb`, not `dpkg -i` -
apt resolves the `obs-studio` dependency automatically; `dpkg -i` doesn't.

## Releases

Bump the version first: `make version x.y.z`. Then push a tag matching
`vX.Y.Z` (the `v` prefix is required) to trigger
`.github/workflows/release.yml`, which builds all three platforms and
attaches the installers to a new GitHub Release.

Run `make hooks` once per clone to install a pre-push hook that rejects
un-prefixed tags.

## Project layout

```
CMakeLists.txt
Makefile                        build orchestration (native + Windows cross-compile)
deps-windows.sh                 fetches libobs headers, synthesizes obs.lib
cmake/mingw-w64-toolchain.cmake CMake toolchain file for the Windows cross-compile
cmake/installer.nsi             NSIS script for the Windows installer .exe
src/
  plugin-main.c                 module load/unload, source registration
  random-visibility-filter.c/h  the filter implementation
data/
  locale/en-US.ini              UI strings
```

## License

GPLv2, matching OBS Studio's own license and libobs linkage. See
[gnu.de/documents/gpl-2.0.de.html](https://www.gnu.de/documents/gpl-2.0.de.html).
