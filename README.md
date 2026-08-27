# 🎲 Random Source Visibility

[![Latest release](https://img.shields.io/github/v/release/g33z/obs-random-source-visibility?sort=semver&label=release)](https://github.com/g33z/obs-random-source-visibility/releases/latest)
[![Release build](https://img.shields.io/github/actions/workflow/status/g33z/obs-random-source-visibility/release.yml?label=build)](https://github.com/g33z/obs-random-source-visibility/actions/workflows/release.yml)
[![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-informational)](#-building-from-source)
[![OBS Studio](https://img.shields.io/badge/OBS%20Studio-%E2%89%A5%2028.0-8a2be2)](https://obsproject.com)

A native OBS Studio filter plugin. Attach it to a **scene** or a **group**
("folder") and it randomly shows exactly one of that container's direct
child sources at a time — hiding whichever one it last showed before
picking the next one. Think of it as a slideshow with a dice roll instead
of a fixed order.

## ✨ What it does

- Tracks one "currently shown" child source per filter instance.
- On trigger: hides the previously-shown child (if any), picks a new
  random child, shows it. By default it won't pick the same child twice
  in a row (configurable).
- Only touches **direct** children of the scene/group it's attached to —
  nested groups count as a single item and are not recursed into.

## ⏱️ Triggers

Combine any or all of these:

| Trigger | How |
|---|---|
| **Hotkey** | Each filter instance registers its own hotkey under Settings → Hotkeys ("Random Source Visibility: Trigger"), so different scenes/groups can have independent shortcuts. |
| **Timer** | Enable "Automatically re-roll on a timer" in the filter's properties and set an interval. |
| **Scene/group activation** | Enable "Re-roll when this scene/group becomes active" to re-roll whenever OBS switches to the scene (or the group becomes visible). |

There's also a "Trigger Now" button in the filter properties for manual testing.

## 🖱️ Usage in OBS

1. Right-click the scene or group in the Scenes/Sources list → **Filters**.
2. Under "Effect Filters", click **+** → **Random Source Visibility**.
3. Configure timer/activation/repeat options as needed.
4. Optionally bind a hotkey in Settings → Hotkeys.

## 📥 Installing

Grab the latest build for your OS from
[Releases](https://github.com/g33z/obs-random-source-visibility/releases/latest):

- **macOS** — open the `.dmg`, drag the `.plugin` bundle into
  `~/Library/Application Support/obs-studio/plugins/`.
- **Linux** — `sudo apt install ./obs-random-source-visibility_*.deb`
  (requires `obs-studio` installed via apt/PPA — see
  [Linux prerequisites](#linux)).
- **Windows** — run the `.exe` installer. It installs into
  `C:\ProgramData\obs-studio\plugins\` and needs no admin rights.

Restart OBS afterward and check **Help → Log Files → View Current Log**
for `[obs-random-source-visibility] plugin loaded` to confirm it was
picked up.

## 🛠️ Building from source

This is a native plugin (C, built against libobs via CMake) — not a
Lua/Python script. Build instructions differ per OS; jump to yours:
[macOS](#macos-apple-silicon) · [Linux](#linux) · [Windows](#windows-cross-compiled-from-linuxmacos).

### macOS (Apple Silicon)

Links directly against the `libobs` inside an installed OBS.app — no
full obs-studio source build required.

```bash
brew install cmake simde
brew install --cask obs        # skip if OBS is already installed

make deps                      # fetch libobs headers matching your OBS version into .deps/
make build                     # configure + compile
make install                   # install into ~/Library/Application Support/obs-studio/plugins/
```

`make deps` reads your installed OBS.app's version from its Info.plist
and sparse-checks-out just the matching `libobs/` headers from the
obs-studio repo (a few MB, not a full clone) into `.deps/`, plus a
hand-written `obsconfig.h` — the one header CMake would normally generate
during a full obs-studio build. Re-run it after upgrading OBS.

If OBS.app isn't at `/Applications/OBS.app`, pass
`OBS_APP_BUNDLE=/path/to/OBS.app` to any `make` target.

### Linux

Not wired into the Makefile's `deps` target — that's macOS-specific for
locating an installed OBS.app. Install libobs' dev package instead;
`find_package(libobs)` in `CMakeLists.txt` finds it automatically once
it's present.

```bash
sudo apt install cmake libobs-dev

make build                     # or: cmake -B build -S . && cmake --build build
make install                   # install into ~/.config/obs-studio/plugins/obs-random-source-visibility/
```

Skip `libobs-dev` and the build fails at CMake's `find_package(libobs)`
step with "Could not find a package configuration file provided by
libobs".

Ubuntu's own `obs-studio` apt package is often outdated — use the
official PPA for the latest release
([install instructions](https://obsproject.com/wiki/install-instructions)):

```bash
sudo add-apt-repository ppa:obsproject/obs-studio
sudo apt update
sudo apt install obs-studio
```

> [!WARNING]
> **Flatpak OBS is not supported.** Manually-installed native plugins
> were never officially supported in Flatpak, and OBS 30.2.0+ actively
> sandboxes against loading them (fails with
> `libobs-frontend-api.so.0: cannot open shared object file`). The only
> Flathub-endorsed path is publishing as a Flatpak extension of
> `com.obsproject.Studio`, which this project doesn't do. Use a
> system/apt-installed OBS instead.

### Windows (cross-compiled from Linux/macOS)

There's no local Windows build path. Both the plugin `.dll` and the
installer that ships it are built from a Linux or macOS machine, via the
Makefile's `-windows` targets — nothing runs on actual Windows until the
resulting installer is executed there:

- the `.dll` is cross-compiled with [mingw-w64](https://www.mingw-w64.org/)
- the installer `.exe` is built with NSIS's `makensis`, which itself
  cross-builds Windows installers from Linux/macOS

```bash
# Linux
sudo apt install cmake gcc-mingw-w64-x86-64 nsis

# macOS
brew install cmake mingw-w64 makensis
```

```bash
make deps-windows              # fetch libobs headers, synthesize obs.lib into .deps/windows/
make build-windows             # cross-compile obs-random-source-visibility.dll
make package-windows           # build the Windows installer .exe into build/dist/
```

`make deps-windows` (`deps-windows.sh`) targets the latest OBS Studio
release: it sparse-checks-out the matching `libobs/` headers from the
obs-studio repo (same technique as macOS's `make deps`), downloads the
official portable Windows `.zip` release and pulls `obs.dll` out of it,
then synthesizes the `obs.lib` import library that Windows OBS builds
don't ship — by dumping `obs.dll`'s export table (`objdump`) into a
generated `.def` file and feeding it to `dlltool`. That's the standard
way to link against a DLL with no import library of its own.

`make package-windows` feeds `cmake/installer.nsi` to `makensis`, which
packages the staged `.dll` + `data/` tree into an installer that installs
into `C:\ProgramData\obs-studio\plugins\<name>\` — OBS's current
recommended manual-install location — and registers an uninstaller. That
path doesn't need admin rights, unlike `C:\Program Files\...`.

There's no `install-windows` target: copy the `.exe` from `build/dist/`
onto the actual Windows machine and run it.

## 📦 Packaging

`make package` (macOS/Linux) or `make package-windows` (cross-built)
turns whatever was just built into a distributable installer in
`build/dist/`:

| OS | Artifact | Installs to |
|---|---|---|
| macOS | `.dmg` | drag-and-drop `.plugin` bundle |
| Linux | `.deb` | `/usr/lib/x86_64-linux-gnu/obs-plugins/` + `/usr/share/obs/obs-plugins/` (system-wide; requires apt/PPA `obs-studio`, not a portable build) |
| Windows | `.exe` (NSIS) | `C:\ProgramData\obs-studio\plugins\<name>\` |

Install the `.deb` with `sudo apt install ./build/dist/obs-random-source-visibility_*.deb`
so apt resolves its `Depends: obs-studio (>= 28.0.0)` for you —
`dpkg -i` only checks dependencies, it doesn't resolve them, so it'll
report `obs-studio` as missing and leave the package unconfigured even
though the `Depends` line is correct.

## 🚀 Releasing

1. Bump the version: `make version x.y.z`. This rewrites
   `CMakeLists.txt`, the single source of truth `PLUGIN_VERSION` and
   every artifact filename (`.deb`/`.dmg`/`.exe`) are derived from.
2. Tag and push: `git tag vx.y.z && git push --tags`.

Pushing a tag matching `v*` triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml), which
builds macOS and Linux natively and cross-builds Windows (both the
`.dll` and its NSIS installer) on the same Linux runner, then attaches
the resulting `.dmg`/`.deb`/`.exe` to a new GitHub Release. It only runs
on tag pushes — regular commits don't trigger it, so it costs nothing
just by existing.

## 🗂️ Project layout

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
