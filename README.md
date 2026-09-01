# Random Source Visibility

An OBS Studio filter plugin. Attach it to a **scene** or a **group**
("folder"), and it randomly shows exactly one of that container's direct
child sources at a time — hiding whichever one it last showed before
picking the next one.

## Behavior

- Maintains one "currently shown" child source per filter instance.
- On trigger: hides the previously-shown child (if any), picks a new
  random child, shows it. By default it avoids picking the same child
  twice in a row (configurable).
- Only affects **direct** children of the scene/group the filter is
  attached to — nested groups are treated as a single item, not
  recursed into.

## Triggers

All three can be combined:

- **Hotkey** — each filter instance registers its own hotkey under
  Settings → Hotkeys ("Random Source Visibility: Trigger"), so different
  scenes/groups can have independent shortcuts.
- **Timer** — enable "Automatically re-roll on a timer" in the filter's
  properties and set an interval.
- **Scene/group activation** — enable "Re-roll when this scene/group
  becomes active" to trigger a re-roll whenever OBS switches to the
  scene (or the group becomes visible).

There's also a "Trigger Now" button in the filter properties for manual
testing.

## Usage in OBS

1. Right-click the scene or group in the Scenes/Sources list → **Filters**.
2. Under "Effect Filters", click **+** → **Random Source Visibility**.
3. Configure timer/activation/repeat options as desired.
4. Optionally bind a hotkey in Settings → Hotkeys.

## Building

This is a native OBS plugin (C, built against libobs via CMake), not a
Lua/Python script.

### macOS (Apple Silicon)

Links directly against the `libobs` shipped inside an installed OBS.app —
no full obs-studio source build required.

Prerequisites:

```bash
brew install cmake simde
brew install --cask obs   # if OBS isn't already installed
```

Then:

```bash
make deps     # fetches libobs headers matching your installed OBS version into .deps/
make build    # configures + compiles
make install  # installs into ~/Library/Application Support/obs-studio/plugins/
```

`make deps` detects your installed OBS.app's version via its Info.plist
and sparse-checks-out just the matching `libobs/` headers from the
obs-studio repo (a few MB, not a full clone) into `.deps/`, plus a
hand-written `obsconfig.h` (the one header CMake would normally generate
during a full obs-studio build). Re-run it if you upgrade OBS.

If OBS.app lives somewhere other than `/Applications/OBS.app`, pass
`OBS_APP_BUNDLE=/path/to/OBS.app` to any `make` target.

Relaunch OBS after `make install` and check **Help → Log Files → View
Current Log** for `[obs-random-source-visibility] plugin loaded` to confirm
it picked it up.

### Linux

Not wired up to the Makefile's `deps` target (that's macOS-specific for
locating an installed OBS.app). Install libobs' dev package instead —
`find_package(libobs)` in CMakeLists.txt finds it automatically once
it's present.

Prerequisites (Ubuntu/Debian-based distros):

```bash
sudo apt install cmake libobs-dev
```

Then:

```bash
make build     # or: cmake -B build -S . && cmake --build build
make install   # installs into ~/.config/obs-studio/plugins/obs-random-source-visibility/
```

If you only install `cmake` and skip `libobs-dev`, `make`/`cmake -B build`
fails at the `find_package(libobs)` step in CMakeLists.txt with "Could not
find a package configuration file provided by libobs".

**Flatpak OBS is not supported.** Manually-installed native plugins were
never officially supported in Flatpak, and OBS 30.2.0+ actively sandboxes
against loading them (fails with `libobs-frontend-api.so.0: cannot open
shared object file`). The only Flathub-endorsed path is publishing as a
Flatpak extension of `com.obsproject.Studio`, which this project doesn't
do. Use a system/apt-installed OBS instead (see below).

Ubuntu's own `obs-studio` apt package is often outdated. For the newest
release, use the official PPA instead ([install instructions](https://obsproject.com/wiki/install-instructions)):

```bash
sudo add-apt-repository ppa:obsproject/obs-studio
sudo apt update
sudo apt install obs-studio
```

### Windows (cross-compiled from Linux/macOS)

There's no local Windows build path — the Windows `.dll`, and the
installer that ships it, are both built from a Linux or macOS machine,
via the Makefile's `-windows` targets: the `.dll` is cross-compiled with
[mingw-w64](https://www.mingw-w64.org/), and the installer `.exe` is
built with NSIS's `makensis`, which itself cross-builds Windows
installers from Linux/macOS — nothing runs on actual Windows until the
resulting installer is executed there.

Prerequisites:

```bash
# Linux
sudo apt install cmake gcc-mingw-w64-x86-64 nsis

# macOS
brew install cmake mingw-w64 makensis
```

Then:

```bash
make deps-windows     # fetches libobs headers and synthesizes obs.lib into .deps/windows/
make build-windows    # cross-compiles obs-random-source-visibility.dll
make package-windows  # builds a Windows installer .exe into build/dist/
```

`make deps-windows` (`deps-windows.sh`) targets the latest OBS Studio
release: it sparse-checks-out the matching `libobs/` headers from the
obs-studio repo (same technique as macOS's `make deps`), downloads the
official portable Windows `.zip` release and pulls `obs.dll` out of it,
then synthesizes the `obs.lib` import library Windows OBS builds don't
ship by dumping that DLL's export table (`objdump`) into a generated
`.def` file and feeding it through `dlltool` — the standard way to link
against a DLL that doesn't ship its own import library.

`make package-windows` feeds `cmake/installer.nsi` to `makensis`, which
packages the staged `.dll` + `data/` tree into a self-contained installer
that, when run on Windows, installs into
`C:\ProgramData\obs-studio\plugins\<name>\` — OBS's current recommended
manual-install location — and registers an uninstaller. That path doesn't
require admin rights to write to, unlike `C:\Program Files\...`. There's
no `install-windows` target — copy the `.exe` from `build/dist/` onto the
actual Windows machine and run it.

## Packaging

`make package` (macOS/Linux) or `make package-windows` (cross-built)
builds a distributable installer from whatever was just built: a `.dmg`
on macOS, a `.deb` on Linux (installs system-wide, to
`/usr/lib/x86_64-linux-gnu/obs-plugins/` + `/usr/share/obs/obs-plugins/`,
requires `obs-studio` installed via apt/PPA rather than a portable OBS
build), an NSIS-built `.exe` installer for Windows (installs into
`C:\ProgramData\obs-studio\plugins\<name>\`). Output lands in `build/dist/`.

The `.deb` declares `Depends: obs-studio (>= 28.0.0)`. Install it with
`sudo apt install ./build/dist/obs-random-source-visibility_*.deb` so apt
resolves that dependency automatically — `dpkg -i` doesn't resolve
dependencies at all, it only checks them, so it'll report `obs-studio`
as missing (and leave the package unconfigured) even though the
`Depends` line is correct.

## Releases

Bump the version with `make version x.y.z` (rewrites
`CMakeLists.txt`, the single source of truth that `PLUGIN_VERSION` and
`.deb`/`.dmg`/`.zip` filenames are derived from) before tagging.

Pushing a tag matching `v*` (e.g. `v1.0.0`) triggers
`.github/workflows/release.yml`, which builds macOS and Linux natively
and cross-builds Windows (both the `.dll` and its NSIS installer) on the
same Linux runner (`make package` / `make package-windows`), attaching
the resulting `.dmg`/`.deb`/`.exe` to a new GitHub Release. It only runs
on tag pushes — regular commits don't trigger it.

Tags **must** be `vX.Y.Z` (e.g. `v1.3.1`), not `X.Y.Z` — the release
workflow's `v*` trigger silently does nothing for an un-prefixed tag,
which just looks like a hung release. Run `make hooks` once per clone
to install a `pre-push` hook (versioned in `.githooks/`, wired up via
`core.hooksPath`) that rejects pushing a tag without the `v` prefix.

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
