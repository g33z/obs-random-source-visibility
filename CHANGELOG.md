# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

No changes yet.

## [v1.4.0] - 2026-09-01

First tagged release. Includes everything since the project's inception:

### Added

- Filter plugin that shows exactly one random direct child of a scene
  or group at a time, hiding whichever child it last showed.
- Hotkey, timer, and scene/group activation triggers.
- macOS build via an installed OBS.app's bundled `libobs`, and Linux
  build via `find_package(libobs)`.
- Windows support: cross-compiled `.dll` (via mingw-w64) and an NSIS
  installer `.exe`, built from Linux or macOS.
- `.github/workflows/release.yml`, building macOS, Linux, and Windows
  packages and attaching them to a GitHub Release on every `v*` tag push.
- `make version x.y.z` target to bump the version consistently in
  `CMakeLists.txt` before tagging a release.
- `make hooks` target installing a `pre-push` hook that rejects tags
  without the `v` prefix (the release workflow's `v*` trigger silently
  ignores un-prefixed tags otherwise).

### Changed

- Windows installer now installs to `C:\ProgramData\obs-studio\plugins\<name>\`
  (OBS's current documented manual-install location) instead of the
  per-user `%APPDATA%\obs-studio\plugins\<name>\` path, which OBS 32 no
  longer scans.
- Show/hide order on trigger swapped so the new source is shown before
  the previous one is hidden, avoiding a brief black screen when
  switching visibility.

[v1.4.0]: https://github.com/g33z/obs-random-source-visibility/releases/tag/v1.4.0
