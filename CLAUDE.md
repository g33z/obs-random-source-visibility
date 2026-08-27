# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native OBS Studio filter plugin (C, built via CMake), not a Lua/Python
script. Attach it to a scene or a group ("folder") and it randomly shows
exactly one of that container's direct child sources at a time, hiding
whichever child it last showed before picking the next one. Triggered by
a hotkey, an optional timer, and/or the scene/group becoming active.

## Commands

macOS (Apple Silicon) is the only platform with a working local build
today, via the `libobs` bundled inside an installed OBS.app — no full
obs-studio source build required.

```bash
brew install cmake simde
brew install --cask obs        # if OBS isn't already installed

make deps                      # fetch libobs headers matching installed OBS version into .deps/
make build                     # configure + compile (default target)
make install                   # install into ~/Library/Application Support/obs-studio/plugins/
make rebuild                   # clean + build
make clean                     # remove build/
```

`make deps` reads the installed OBS.app's version from its Info.plist
and sparse-checks-out just the matching `libobs/` headers from the
obs-studio repo into `.deps/` (gitignored), plus a hand-written
`obsconfig.h` stub for the one header CMake would normally generate
during a full obs-studio build. Re-run `make deps` after upgrading OBS.
If OBS.app isn't at `/Applications/OBS.app`, pass
`OBS_APP_BUNDLE=/path/to/OBS.app` to any `make` target.

There is no test suite — verification is done by installing into OBS
and checking its log (Help → Log Files → View Current Log) for
`[obs-random-source-visibility] plugin loaded`.

Linux is not wired into the Makefile's `deps` target (that's macOS-specific
for locating an installed OBS.app), but `build`/`install`/`package` all
work on Linux via the CMakeLists.txt `find_package(libobs REQUIRED)`
path — install `libobs-dev` via apt first (present in Ubuntu's own
`universe` repo, no PPA needed):

```bash
sudo apt install cmake libobs-dev
```

`cmake` alone is not sufficient — without `libobs-dev`, `find_package(libobs)`
in CMakeLists.txt fails at configure time. Windows is not supported: no
local build path, and deliberately left out of CI too (see Releases below).

## Packaging and releases

`make package` (macOS/Linux only) builds a distributable installer from
whatever `make build` just produced, into `build/dist/`:

- **macOS** — wraps the staged `.plugin` bundle in a `.dmg` via `hdiutil`.
- **Linux** — builds a `.deb` targeting the same system paths OBS's own
  official `.deb` uses (verified by inspecting it directly): the `.so`
  goes to `/usr/lib/x86_64-linux-gnu/obs-plugins/`, data to
  `/usr/share/obs/obs-plugins/<name>/`. This is a different install
  location than `make install`'s per-user
  `~/.config/obs-studio/plugins/<name>/` tree — the `.deb` is meant for
  a system-wide `obs-studio` install (apt/PPA), not a portable OBS build.

`PLUGIN_VERSION` (used in artifact filenames and the `.deb` control
file) is scraped from `CMakeLists.txt`'s `project(... VERSION x.y.z)`
line via `sed`. Note the regex (`^project[^V]*VERSION ...`) deliberately
avoids unescaped `(`/`)` characters — Make's `$(shell ...)` parses
parens naively to find the end of the call, so a literal `\(` from a
sed pattern trips it up even though it's escaped for sed's benefit, not
Make's.

`.github/workflows/release.yml` runs both platforms' `make package` and
publishes the `.dmg`/`.deb` to a GitHub Release whenever a tag matching
`v*` is pushed — it does nothing on regular commits/pushes, so it costs
nothing just by existing. Windows was deliberately dropped from both
local dev and CI: there's no libobs dev package for Windows anywhere,
and getting one requires either building obs-studio's `libobs` from
source (slow, fragile, needs prebuilt Qt/obs-deps and hits an unrelated
mandatory 32-bit sub-build in obs-studio's root `CMakeLists.txt` on
`x64`) or synthesizing an import lib from the official `obs.dll`'s
export table via `dumpbin`/`lib.exe` (works, but untestable outside an
actual Windows CI run and adds real fragility for a plugin this small).
Revisit if Windows support becomes a real requirement.

## Architecture

- `src/plugin-main.c` — module entry point. `obs_module_load` seeds
  `rand()` and registers the filter's `obs_source_info` (from
  `rsv_filter_get_info()`).
- `src/random-visibility-filter.c` / `.h` — the entire filter
  implementation, in one file. Key points:
  - The filter must be attached directly to a scene or group source
    (both resolve via `obs_scene_from_source`); `rsv_trigger()` bails
    out early if not.
  - Only direct children are considered (`obs_scene_enum_items` does
    not recurse into nested groups by design).
  - State is a single `obs_weak_source_t *current_source` tracking
    which child was last shown, so the same instance can hide it on
    the next trigger before picking a new one. Avoiding an immediate
    repeat pick is a settable option (`avoid_repeat`).
  - The three triggers all funnel into `rsv_trigger()`: a
    source-scoped hotkey (`obs_hotkey_register_source`, one per filter
    instance so different scenes/groups can have independent
    shortcuts), a timer accumulated in `video_tick`, and `activate()`
    (fires when the parent scene/group becomes visible).
  - `video_render` is a pure pass-through (`obs_source_skip_video_filter`)
    — this filter never touches pixels, it only flips sibling
    sceneitem visibility.
- `data/locale/en-US.ini` — all `obs_module_text()` UI strings.
- `CMakeLists.txt` — on macOS, builds a `.plugin` bundle and links
  against `OBS_APP_BUNDLE`'s `libobs.framework` directly (an `IMPORTED`
  target `OBS::libobs`, not `find_package`), then a `POST_BUILD` step
  runs `install_name_tool -change` to rewrite the libobs dependency to
  `@executable_path/../Frameworks/libobs.framework/Versions/A/libobs`
  so the plugin resolves it correctly when loaded inside the real OBS
  process. Non-Apple platforms fall back to `find_package(libobs REQUIRED)`.
- `Makefile` — wraps the CMake configure/build/install/clean cycle and
  (on macOS/Linux) copies the installed plugin into the actual
  per-user OBS plugin directory, which differs by OS: a `.plugin`
  bundle under `~/Library/Application Support/obs-studio/plugins/` on
  macOS vs. a `bin/64bit/` + `data/` tree under
  `~/.config/obs-studio/plugins/<name>/` on Linux.
