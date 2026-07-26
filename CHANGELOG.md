# Changelog

All notable changes to debugger-mcp are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once
1.0 ships.

## [Unreleased]

### Added

- **Community-standard files:** `LICENSE` (Apache-2.0), `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`, `SUPPORT.md`.
- **GitHub templates:** Issue templates (bug report, feature request) and
  pull request template.
- **CI workflow:** `zig build` on push/PR for Linux (x86_64).
- **Test suite:** Unit tests for `mcp/types.zig` and `dap/util.zig`;
  `zig build test` target wired into the build system.

### Changed

- **`src/mcp/types.zig`:** `buildTextContent` no longer duplicates input
  strings with `allocator.dupe` — the caller's arena already keeps the text
  live for the lifetime of the response. Fixes a latent memory leak.
- **`skills/debug-live/SKILL.md`:** Updated to reflect that `stopOnEntry` is
  `false`; the debugger does not pause at the program entry by default.

### Fixed

- **`src/Logger.zig`:** Replaced `std.debug.print` (which holds a global
  mutex and can panic) with direct stderr writes via `std.os.write`.
