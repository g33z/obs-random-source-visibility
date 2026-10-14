---
name: monthly-maintenance
description: Monthly upkeep pass for obs-random-source-visibility - OBS/libobs version check, CI action and toolchain updates, and a security audit (NVD CVEs for OBS/NSIS/mingw-w64/SIMDe, GitHub advisories, static analysis, binary hardening checks), driven by `make maintenance`.
---

# Monthly maintenance pass

This is a recurring, low-drama pass over the toolchain, CI and upstream OBS - not a feature
change. Do it roughly once a month, or whenever a new OBS release or a CVE alert prompts it.
The plugin has no package-manager dependencies; what can drift is:

- **OBS / libobs** - the headers and library every platform builds against (macOS: the
  installed OBS.app; Linux: the system `obs-studio`/`libobs-dev` package; Windows:
  `deps-windows.sh` always fetches the *latest* OBS release).
- **CI actions and runner images** in `.github/workflows/release.yml` and
  `.forgejo/workflows/release.yml`.
- **Build tools** - CMake, gcc/clang, mingw-w64, and NSIS's `makensis`, which builds the
  Windows installer `.exe` we ship (so NSIS CVEs land on users' machines).

## 1. Run the pass

```bash
make maintenance        # rebuild everything this host can build, then outdated + audit
# or individually:
make outdated           # version checks only
make audit              # security checks only, against what's already built
```

It's report-only (never bumps anything) and writes the full output to
`logs/maintenance-report.txt` (build logs next to it). It exits non-zero if any check
FAILs. Each line is `[ OK ]`, `[WARN]` (triage it), `[FAIL]` (must be fixed or explicitly
justified before calling the pass done) or `[SKIP]` (a tool is missing - see below).

Set `GITHUB_TOKEN` if GitHub's anonymous rate limit (60 req/h) runs out, and `NVD_API_KEY`
to skip the ~7s pause between NVD queries.

Optional tools it skips without: `cppcheck` and `actionlint`. If they're missing, ask the
user before installing them (`sudo apt install cppcheck` / `brew install cppcheck actionlint`;
actionlint on Linux: `go install github.com/rhysd/actionlint/cmd/actionlint@latest`) -
don't install system packages without asking.

Before attempting any bump, read `UPGRADE.md` at the repo root if it exists - it tracks
bumps that were already attempted and rolled back, with the blocker and what to re-check.
Skip a bump listed there unless its re-check condition now holds.

## 2. OBS / libobs

- **Local OBS behind latest** - upgrade it (`brew upgrade --cask obs` / `sudo apt upgrade
  obs-studio`), then `make deps` on macOS (it caches headers per OBS version).
- **Windows deps** refresh themselves: `deps-windows.sh` targets the latest release and
  re-downloads `obs.dll` when its `.obs-version` stamp doesn't match.
- **Deprecated libobs API**: the audit's "windows build (latest OBS headers)" step compiles
  with `-Wdeprecated-declarations` against the newest release's headers. A deprecation
  warning there is the early warning before an API gets removed - port off it now.
- **New OBS major**: re-check `obsproject.com/kb/plugins-guide` for plugin install-location
  changes (the Windows installer's `InstallDir` and `make install`'s paths - CLAUDE.md
  documents why each one is what it is). OBS moving the Windows path once already failed
  silently, with no log output at all.
- **`.deb` minimum** (`Depends: obs-studio (>= 28.0.0)` in the Makefile): if the code
  started using libobs API newer than that, raise it.

## 3. CI actions and runners

For each `[WARN]` on an action:

- Read the action's release notes/changelog for every major in between - majors usually
  mean a new Node runtime or changed inputs (`download-artifact`'s `merge-multiple`,
  `path` layout, etc.).
- Keep `.github` and `.forgejo` workflows in step for the jobs they share (linux, windows).
- **Forgejo caveat**: bare `actions/...` refs on Forgejo resolve to the
  `data.forgejo.org` mirror, and artifact actions in particular depend on what the Forgejo
  *server* version supports - newer `upload-artifact`/`download-artifact` majors have
  historically lagged on Forgejo. Check the instance's Forgejo version before bumping those
  there; if unsupported, leave them and note it in `UPGRADE.md`.
- An advisory listed against an action matters only if the ref we use can resolve into the
  affected range. A floating `@v4` follows the newest v4.x, but bumping the major still
  removes the doubt.
- A deprecated or removed `runs-on` label (the script checks `actions/runner-images`):
  move to the next image. The macOS job also depends on Homebrew's `obs` cask supporting
  that runner's macOS version.
- **Forgejo runner**: the `.forgejo` workflow runs on `ubuntu-24.04`, mapped on the
  runner to `ghcr.io/catthehacker/ubuntu:act-24.04`. Keep `forgejo-runner` itself current
  (code.forgejo.org/forgejo/runner releases). When GitHub's Ubuntu image moves on, move
  the label mapping with it. Artifact actions there are Forgejo's patched forks
  (`data.forgejo.org/forgejo/*-artifact`), and the script compares them against that
  forge's tags. If a newer fork tag breaks the Forgejo run, fall back to `@v4`, which
  Forgejo's own docs use.

Release workflows only run on `v*` tag pushes, so a CI bump isn't exercised until the next
release. Run `actionlint` locally, then treat the next release's CI run as the real test and
watch it.

## 4. Toolchain

- Apply pending apt/brew upgrades the report lists for build tools.
- **NSIS / makensis**: both CI workflows build the version pinned in
  `bin/install-nsis.sh`. A `[WARN]` that a newer NSIS is out means bump `NSIS_VERSION`
  and both sha256s there, then cross-check the hashes against Homebrew's
  `Formula/m/makensis.rb`; don't trust only what you downloaded. Test with
  `bin/install-nsis.sh /tmp/nsis-test` followed by
  `PATH=/tmp/nsis-test/bin:$PATH make package-windows`. That needs `scons` (apt `scons`,
  or pip in a venv). A `[FAIL]` on the CI pin means a shipped installer is vulnerable, so
  bump it now. A `[FAIL]` on the local makensis only affects installers built by hand:
  `brew upgrade makensis`.
- **CMake**: raising the `...3.29` policy max in `cmake_minimum_required` is optional. Do
  it only after building cleanly on that CMake version on every platform.

## 5. Security triage

Run the audit every pass, even when nothing was outdated - new advisories get published
against versions we already use.

- **CVE `[FAIL]`** (affects a version we build or ship with): fix it now (upgrade the
  tool), or, if no fix is available yet, record why it's not exploitable in our setup (e.g.
  the installer runs with `RequestExecutionLevel user`, never as SYSTEM) in `UPGRADE.md`
  with what to re-check.
- **CVE `[WARN]` new/updated in the window**: read it. It needs action only if it's about
  a component we use (VDO.Ninja-style "works with OBS" CVEs usually aren't). Warnings
  about OBS itself affect the user's own OBS install, not the plugin binary - tell the user
  if their installed version is affected.
- **Static analysis `[FAIL]`**: fix the code. The plugin is ~300 lines of C; treat every
  analyzer finding as real until proven otherwise.
- **Artifact `[FAIL]`**: missing hardening (RELRO/BIND_NOW, DYNAMIC_BASE/NX), an
  unexpected DLL import (e.g. `libgcc_s_seh-1.dll` - a user won't have it, and OBS silently
  fails to load the plugin), or a missing `obs_module_load` export. Fix it in
  `CMakeLists.txt` / the toolchain file.

## 6. Verify

```bash
make maintenance                 # zero FAIL
make package                     # .deb on Linux / .dmg on macOS
make package-windows             # Windows installer
make install                     # then start OBS
```

Check OBS's log (Help → Log Files → View Current Log) for
`[obs-random-source-visibility] plugin loaded`, and that the filter still works on a scene.

## 7. Record it

There's no CHANGELOG: release notes come from the commit messages
(`generate_release_notes: true`). So commit the pass as its own commit, e.g.
`Monthly maintenance 2026-10: bump CI actions, ...`, listing what moved and any CVE
closed. Commit only when the user asks.

If anything that ends up in a shipped artifact changed (build flags, toolchain, NSIS, OBS
headers), cut a patch release with `make release` once it's verified. A CI-only or
docs-only change doesn't need one.

If this pass attempted and rolled back a bump, add (or update) its entry in `UPGRADE.md`:
what broke, why it's not routine, and what to re-check before retrying. If it resolved a
bump `UPGRADE.md` listed as blocked, remove that entry.
