# Contributing to debugger-mcp

Thanks for your interest. This document is short on purpose — read it before opening an issue or pull request.

## What this repo is

debugger-mcp is a zero-dependency Zig binary that bridges MCP (Model Context Protocol) to DAP (Debug Adapter Protocol) via codelldb/LLDB. It enables LLM-driven debugging of native code.

## What this repo is not

- **Not a general-purpose DAP client.** Only the subset needed for codelldb debugging is implemented.
- **Not an MCP framework.** The generic `Server(Ctx)` pattern could be extracted, but that is out of scope here.
- **Not a debug adapter.** The actual debugging is done by codelldb; this server translates MCP tool calls into DAP requests.

## Reporting issues

Issues without the information below get closed with a label, not a discussion.

**Required for every bug report:**

1. **Zig version** (`zig version`)
2. **Target platform** (e.g. Linux x86_64, macOS arm64)
3. **Build command** you used (`zig build`, `zig build -Doptimize=ReleaseSafe`)
4. **Debug adapter** (codelldb version, path, how it was installed)
5. **MCP client** (OpenCode, Cline, Roo, etc.) and version
6. **Steps to reproduce.** Include the exact sequence of tool calls.
7. **What you expected vs. what happened**

**Bug reports that won't be triaged:**

- "Doesn't connect" with no logs, no adapter path, and no `--verbose` output
- "Crashes" with no logs or reproduction path
- Anything that doesn't include a reproduction path
- Feature requests filed as bugs

**Feature requests** are welcome — please open a discussion or a clearly-labelled `enhancement` issue *first*. Most large patches that arrive without a prior conversation get closed.

## Security

**Do not file security issues on the public tracker.** See `SECURITY.md` for the disclosure channel.

## Pull requests

**Talk first, code second.** Open an issue describing the change before writing more than ~50 lines of code. PRs without a prior discussion are reviewed last.

**What we accept:**

- Bug fixes with a regression test
- Platform support fixes (especially Linux distro variants)
- New tests for existing untested code paths
- Documentation improvements
- Protocol-correctness fixes against real adapter behaviour

**What we don't accept without prior agreement:**

- Refactors for the sake of refactoring
- New abstractions ("I extracted a `Transport` trait")
- Style-only changes
- Adding dependencies (zero-dependency is a project goal)
- Changes that break the MCP tool API without a migration plan

**PR requirements:**

- `zig build test` passes locally
- New code has tests
- No `unreachable` or panic paths on user input — return errors
- Commits are signed (`git commit -S`) if possible

**Review process:**

- Solo maintainer, best-effort, no SLA. Plan on weeks, not days.
- The maintainer reserves the right to say no without elaborate justification.

**Contributor licensing:** By opening a PR you agree your contribution is licensed under Apache-2.0, per Section 5 of the license. No separate CLA is required.
