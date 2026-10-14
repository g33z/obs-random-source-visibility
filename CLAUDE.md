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
in CMakeLists.txt fails at configure time. If `obs-studio` comes from
obsproject's PPA instead (it ships its own libobs CMake config), that
config also requires SIMDe headers: `sudo apt install libsimde-dev`.

Windows is cross-compiled from Linux or macOS via mingw-w64 — nothing is
built on actual Windows, and there's no local build path on Windows
itself. Driven by the same Makefile, via `-windows`-suffixed targets:

```bash
sudo apt install cmake gcc-mingw-w64-x86-64        # Linux; macOS: brew install mingw-w64 makensis
brew install makensis                              # Linux too (linuxbrew) - not apt's nsis, see below

make deps-windows      # fetch libobs headers + synthesize obs.lib into .deps/windows/
make build-windows     # cross-compile obs-random-source-visibility.dll
make package-windows   # build a Windows installer .exe into build/dist/ via makensis
```

makensis has to be NSIS >= 3.12: the installer stub it embeds in our
`.exe` is where NSIS CVEs live (CVE-2025-43715, fixed 3.11;
CVE-2026-42171, fixed 3.12), and Ubuntu's `nsis` package is behind (3.09
on 24.04, 3.10 on 26.04). Locally, Homebrew's `makensis` is current on both macOS
and Linux. CI (GitHub and Forgejo, which has no Homebrew) runs
`bin/install-nsis.sh` instead. It installs a pinned, sha256-verified NSIS the
same way Homebrew's formula does: it compiles only the native `makensis` with
scons, and takes the prebuilt Stubs/Plugins/Include from NSIS's official
release `.zip`. `make outdated` warns when a newer NSIS than the pin is out.
`make audit` FAILs on a vulnerable pin or local makensis.

There's no `install-windows` — copy the installer `.exe` onto an actual
Windows machine and run it. See Packaging and releases below for how
`deps-windows.sh` synthesizes `obs.lib`, how `cmake/installer.nsi` builds
the installer, and why a native Windows build was ruled out for both.

## Monthly maintenance

`make maintenance` (`bin/maintenance.sh all`) is the monthly upkeep pass, and
the `monthly-maintenance` skill (`.claude/skills/monthly-maintenance/`) is
the full routine around it (what to bump, how to triage, how to record
it). The script only reports, it never changes anything. It rebuilds every platform
this host can build, then:

- `make outdated` — local OBS and `.deps/windows` vs. the latest OBS
  release, CI action refs (GitHub actions against GitHub, `.forgejo` ones
  against the `data.forgejo.org` mirror Forgejo actually resolves them
  from), and pending apt/brew upgrades for build tools.
- `make audit` — NVD CVEs for OBS, NSIS, mingw-w64 and SIMDe (CPE range match
  plus a "before X"/"up to X" parse of the description, plus anything
  new in the last `MAINT_CVE_DAYS`). NSIS hits FAIL, since makensis builds the
  installer we ship. Also: GitHub advisories for obs-studio and every action used,
  gcc `-fanalyzer`/clang `--analyze` replayed from each build dir's
  `compile_commands.json` (so the windows build dir also checks for
  deprecated API against the *latest* OBS headers), cppcheck/shellcheck/
  actionlint when installed, and hardening/import/export checks on the
  built `.so`/`.dll`/`.plugin`.

Output (`maintenance-report.txt` plus build logs) goes to the gitignored
`logs/` rather than `build/`, because `make rebuild` wipes `build/` mid-run.

## Packaging and releases

`make package` (macOS/Linux) or `make package-windows` (cross-compiled)
builds a distributable installer from whatever was just built, into
`build/dist/`:

- **macOS** — wraps the staged `.plugin` bundle in a `.dmg` via `hdiutil`.
- **Linux** — builds a `.deb` targeting the same system paths OBS's own
  official `.deb` uses (verified by inspecting it directly): the `.so`
  goes to `/usr/lib/x86_64-linux-gnu/obs-plugins/`, data to
  `/usr/share/obs/obs-plugins/<name>/`. This is a different install
  location than `make install`'s per-user
  `~/.config/obs-studio/plugins/<name>/` tree — the `.deb` is meant for
  a system-wide `obs-studio` install (apt/PPA), not a portable OBS build.
- **Windows** — builds a real installer `.exe` via NSIS's `makensis`
  (`cmake/installer.nsi`), which — like the mingw-w64 compiler — itself
  cross-builds from Linux/macOS; nothing runs on actual Windows until the
  resulting installer is executed there. The installer installs into
  `C:\ProgramData\obs-studio\plugins\<name>\` — OBS's current documented
  manual-install location (obsproject.com/kb/plugins-guide) as of OBS 32.
  The older `%APPDATA%\obs-studio\plugins\<name>\` per-user convention
  this project originally used is no longer scanned, and fails silently:
  no log output at all, not even a load failure (confirmed against a real
  OBS 32.2.2 install). `C:\ProgramData` still doesn't require admin
  rights to write to (unlike `C:\Program Files\...`), so
  `RequestExecutionLevel user` still applies; the uninstaller registers under
  `HKCU\...\Uninstall\<name>` (there's no `install-windows` target since
  there's nowhere to install to from a non-Windows host).

`PLUGIN_VERSION` (used in artifact filenames and the `.deb` control
file) is scraped from `CMakeLists.txt`'s `project(... VERSION x.y.z)`
line via `sed`. Note the regex (`^project[^V]*VERSION ...`) deliberately
avoids unescaped `(`/`)` characters — Make's `$(shell ...)` parses
parens naively to find the end of the call, so a literal `\(` from a
sed pattern trips it up even though it's escaped for sed's benefit, not
Make's.

`.github/workflows/release.yml` runs all three platforms' package step
and publishes the `.dmg`/`.deb`/`.exe` to a GitHub Release whenever a tag
matching `v*` is pushed (the `windows` job runs on the same
`ubuntu-24.04` runner as `linux`, just with `gcc-mingw-w64-x86-64` and
`bin/install-nsis.sh`'s makensis installed too) — it does nothing on regular commits/pushes, so it
costs nothing just by existing.

Windows was previously left out entirely (no local build path, dropped
from CI) on the assumption that linking against libobs on Windows would
need either building obs-studio's `libobs` from source (slow, fragile,
needs prebuilt Qt/obs-deps and an unrelated mandatory 32-bit sub-build in
obs-studio's root `CMakeLists.txt` on `x64`) or a native Windows build to
synthesize an import lib via MSVC's `dumpbin`/`lib.exe` — the latter
noted at the time as "works, but untestable outside an actual Windows CI
run." Both assumptions turned out to be avoidable: `deps-windows.sh`
downloads OBS's official portable Windows `.zip` release (no installer,
no Windows machine needed to obtain `obs.dll`), dumps its export table
via `x86_64-w64-mingw32-objdump` into a generated `.def`, and feeds that
to `x86_64-w64-mingw32-dlltool` to produce `obs.lib` — the same
dumpbin/lib.exe technique, just with mingw-w64's cross binutils instead
of MSVC, so it runs on Linux/macOS. libobs headers are sparse-checked-out
from the obs-studio repo the same way macOS's `deps` does. This
deliberately avoids obs-studio's root `CMakeLists.txt` (and its 32-bit
sub-build) entirely by never building libobs from source, only linking
against the already-built `obs.dll` OBS's own release ships. Verified for
real in this repo's history: a full cross-compile (`x86_64-w64-mingw32-gcc`)
producing a valid PE32+ DLL whose imports (`objdump -p`) correctly
resolve to `obs.dll`'s exported functions, before any of this was wired
into the Makefile/CI.

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
- `CMakeLists.txt` — `project(... LANGUAGES C)` deliberately excludes
  CXX: the plugin is pure C, and requesting C++ made CMake probe for a
  host C++ compiler even though nothing used it, which broke the mingw-w64
  cross-compile (CMake picked the *host's* `c++`, not
  `x86_64-w64-mingw32-g++`, and the resulting object/link mismatch failed
  the compiler-works check). On macOS, builds a `.plugin` bundle and links
  against `OBS_APP_BUNDLE`'s `libobs.framework` directly (an `IMPORTED`
  target `OBS::libobs`, not `find_package`), then a `POST_BUILD` step
  runs `install_name_tool -change` to rewrite the libobs dependency to
  `@executable_path/../Frameworks/libobs.framework/Versions/A/libobs`
  so the plugin resolves it correctly when loaded inside the real OBS
  process. Linux falls back to `find_package(libobs REQUIRED)`. Windows
  links an `IMPORTED` `OBS::libobs` target against `OBS_STUDIO_DIR`'s
  `obs.dll` via the `obs.lib` import lib `deps-windows.sh` synthesizes
  (`.deps/windows/generated/obs.lib`) — same shape as the macOS branch,
  just without the `install_name_tool` step (Windows resolves the DLL
  dependency by name, no path rewrite needed since it's on OBS's own
  plugin search path). `install(TARGETS ...)` sets both `LIBRARY` and
  `RUNTIME` `DESTINATION` to the same computed path (`obs-plugins/64bit`
  on Windows, `obs-plugins` elsewhere) because a `MODULE` library's
  install artifact type on a mingw-w64 cross-compiled Windows target
  turned out to be `LIBRARY`, not `RUNTIME` as CMake's docs would suggest
  — confirmed empirically, not assumed, after a first attempt (setting
  only `RUNTIME DESTINATION`) silently installed the `.dll` to the wrong
  path.
- `Makefile` — wraps the CMake configure/build/install/clean cycle and
  (on macOS/Linux) copies the installed plugin into the actual
  per-user OBS plugin directory, which differs by OS: a `.plugin`
  bundle under `~/Library/Application Support/obs-studio/plugins/` on
  macOS vs. a `bin/64bit/` + `data/` tree under
  `~/.config/obs-studio/plugins/<name>/` on Linux. The `-windows`-suffixed
  targets (`deps-windows`/`configure-windows`/`build-windows`/
  `stage-windows`/`package-windows`/`clean-windows`) cross-compile instead,
  driven by `cmake/mingw-w64-toolchain.cmake`; there's no `install-windows`
  since there's nowhere on a Linux/macOS host to install a Windows plugin
  to.
- `deps-windows.sh` — fetches libobs headers and synthesizes `obs.lib` for
  the Windows cross-compile (see Packaging and releases above). Uses
  `set -euo pipefail`; the `objdump -p obs.dll | awk ...` pipeline
  deliberately avoids an early `exit` in the `awk` script once it's past
  the export-name table — exiting early would close the pipe while
  `objdump` is still writing the rest of its dump, killing it with
  `SIGPIPE` and failing the whole script under `pipefail`. Drains to EOF
  instead. `obs.dll` lives in an unversioned `.deps/windows/obs-root/`
  (CMakeLists.txt points at it directly), so a `.obs-version` stamp there
  makes a new OBS release re-download it. Without the stamp, a new release
  would update the headers but keep linking the old dll.
- `bin/install-nsis.sh` — installs the pinned NSIS used by both CI workflows'
  windows jobs (see Windows above for why not apt/Homebrew). Bumping it
  means updating `NSIS_VERSION` plus both sha256s. Cross-check the hashes
  against Homebrew's `makensis` formula.
- `.forgejo/workflows/release.yml` — Forgejo mirror of the GitHub release
  workflow (linux + windows, no macOS). `runs-on: ubuntu-24.04` needs a
  runner label mapped to a GitHub-like image with sudo, apt and Node 24
  (`ghcr.io/catthehacker/ubuntu:act-24.04`). Artifacts go through Forgejo's
  patched `forgejo/upload-artifact`/`download-artifact` forks (full
  `https://data.forgejo.org/...` URLs), because GitHub's own
  `actions/*-artifact@v4+` don't work against Forgejo.
- `bin/release.sh` — behind `make release`: shows the current version and
  last tag, prompts for the next version (or takes `make release x.y.z`),
  bumps `CMakeLists.txt`'s `project(... VERSION)`, commits that one file and
  tags `vx.y.z`. Refuses on a dirty tree or an existing tag; never pushes.
- `bin/maintenance.sh` — the monthly maintenance/security pass (see Monthly
  maintenance above). Exits non-zero if any check FAILs.
- `cmake/installer.nsi` — NSIS script `make package-windows` feeds to
  `makensis` to build the Windows installer `.exe`. Reads directly from
  `stage-windows`'s output (`obs-plugins/64bit/<name>.dll` and
  `data/obs-plugins/<name>/`) via `-D` command-line defines
  (`PLUGIN_NAME`/`PLUGIN_VERSION`/`STAGE_DIR`/`OUT_FILE`) passed in by
  the Makefile, so the script has no version string or path of its own
  to keep in sync. `InstallDir` points at `$COMMONPROGRAMDATA` (see
  Packaging and releases above for why); `RequestExecutionLevel user`
  still applies since that path, unlike `$ProgramFiles`, doesn't need a
  UAC prompt to write to.
