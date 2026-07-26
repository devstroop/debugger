# debugger-mcp

Zero-dependency Zig binary that bridges MCP (Model Context Protocol) to DAP (Debug Adapter Protocol) via codelldb/LLDB. Enables LLM-driven debugging of native code (C, C++, Rust, Zig, etc.).

## Stack

| Layer | Location | Technology |
|-------|----------|------------|
| **MCP transport** | `src/mcp/server.zig` | Zig — stdio JSON-RPC 2.0 (NDJSON lines) |
| **Tool handlers** | `src/mcp/handler.zig` | Zig — translates MCP tool calls → DAP operations |
| **DAP client** | `src/dap/client.zig` | Zig — spawns codelldb, TCP, protocol operations |
| **DAP wire types** | `src/dap/types.zig` | Zig — DAP data structures (Breakpoint, StoppedInfo, errors) |
| **DAP utilities** | `src/dap/util.zig` | Zig — JSON helpers, port discovery (`ss -tlnp`) |
| **MCP result types** | `src/mcp/types.zig` | Zig — result/error builders with optional session state |
| **Logging** | `src/Logger.zig` | Zig — leveled stderr logger |
| **Entry point** | `src/main.zig` | Zig — wiring, tool registration, env config |
| **Agent skill** | `skills/debug-live/SKILL.md` | Markdown — debugging workflow for LLM agents |

## Architecture

```
src/
├── main.zig              ← Entry point (GPA init, env config, tool registration, run)
│
├── Logger.zig            ← Leveled stderr logger (debug/info/warn/err)
│
├── mcp/                  ← MCP protocol layer
│   ├── server.zig        ← Generic Server(Ctx) — stdio JSON-RPC 2.0 dispatcher
│   ├── handler.zig       ← Tool handler functions + Handler struct (session mgmt)
│   └── types.zig         ← textResult, errorResult, textResultWithState, SessionState
│
├── dap/                  ← DAP protocol layer
│   ├── client.zig        ← DapClient — spawn, TCP connect, protocol ops, event capture
│   ├── types.zig         ← DapBreakpoint, StoppedInfo, Error union
│   └── util.zig          ← writeJsonString, checkSuccess, jsonToI64, findPortForPid, stoppedInfoToJson
│
└── test/                 ← Unit tests
    ├── test.zig           ← Test entry point (re-exports test files)
    ├── types_test.zig     ← Tests for mcp/types.zig
    └── util_test.zig      ← Tests for dap/util.zig (JSON escaping, checkSuccess, etc.)
```

### Responsibility Boundary

| Concern | Location | Notes |
|---------|----------|-------|
| MCP stdio server | `mcp/server.zig` | Generic `Server(Ctx)` — decoupled from handler types |
| Tool handler dispatch | `mcp/handler.zig` | `Handler` struct owns breakpoint list + DapClient lifecycle |
| DAP spawn + TCP | `dap/client.zig` | `DapClient` — spawns codelldb, discovers port, sends/receives frames |
| DAP response correlation | `dap/client.zig` | `send()` → `readResponse()` — matches via `request_seq` |
| Stopped event capture | `dap/client.zig` | `captureStoppedThreadId()` + `waitForStopped()` — synchronous resume model |
| JSON wire formatting | `dap/util.zig` | Content-Length framing, JSON string escaping, `checkSuccess` |
| Port discovery | `dap/util.zig` | `findPortForPid()` — polls `ss -tlnp` for codelldb's random port |
| Result builders | `mcp/types.zig` | `textResult` / `errorResult` / `textResultWithState` + `SessionState` |
| Debugging skill | `skills/debug-live/` | Workflow + root cause analysis framework for LLM agents |

## Tools

### Session Management

| Tool | Description | Arguments |
|---|---|---|
| `start_debugging` | Start a debug session | `fileFullPath` (required), `workingDirectory` (optional) |
| `stop_debugging` | Stop the current debug session | — |
| `restart_debugging` | Restart with new target | same as `start_debugging` |

### Execution Control

| Tool | Description |
|---|---|
| `step_over` | Step over current line — blocks until next `stopped` event |
| `step_into` | Step into function — blocks until next `stopped` event |
| `step_out` | Step out of function — blocks until next `stopped` event |
| `pause` | Pause execution — blocks until `stopped` event |
| `continue_execution` | Resume execution (first call sends `configurationDone` to start the program) |

### Breakpoints

| Tool | Description | Arguments |
|---|---|---|
| `add_breakpoint` | Set a breakpoint | `fileFullPath`, `line` (required), `condition` (optional) |
| `add_logpoint` | Set a logpoint | `fileFullPath`, `line`, `logMessage` (required) |
| `remove_breakpoint` | Remove a breakpoint | `fileFullPath`, `line` (required) |
| `clear_all_breakpoints` | Clear all breakpoints | — |
| `list_breakpoints` | List active breakpoints | — |

### Inspection

| Tool | Description | Arguments |
|---|---|---|
| `get_variables_values` | Inspect variables in current scope | `scope` (optional — filter by scope name) |
| `evaluate_expression` | Evaluate an expression in the debuggee | `expression` (required) |

## Commands

```bash
zig build                              # Build CLI (debug)
zig build -Doptimize=ReleaseSafe       # Build CLI (release)
zig build test                         # Run unit tests (src/test/)
zig run                                # Build and run (requires codelldb in PATH or DEBUGGERMCP_ADAPTER)

# Environment
DEBUGGERMCP_LOG=debug ./zig-out/bin/debugger-mcp           # Verbose stderr logging
DEBUGGERMCP_ADAPTER=/path/to/codelldb ./zig-out/bin/debugger-mcp  # Custom adapter path
```

## Key Patterns

### Generic MCP Server — `Server(Ctx)`

Uses Zig's comptime generics to decouple protocol handling from application logic:

```zig
pub fn Server(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        handlers: std.StringHashMap(HandlerFn),
        // ...
    };
}
```

`HandlerFn` = `*const fn (ctx: *Ctx, allocator: std.mem.Allocator, params: ?json.Value) anyerror!json.Value`

- **Compile-time dispatch** — no vtable, no interface overhead
- **Type safety** — handler context type checked at compile time
- **Reusability** — server can be instantiated with any context type

### DAP Client Design

```
DapClient.init() → connect() → initialize() → launch() → step/continue/breakpoint ops → deinit()
```

Key design choices:
- **codelldb spawned with `--port 0`** — random port discovered via `ss -tlnp`
- **TCP transport** — DAP frames are Content-Length framed over TCP
- **Synchronous + polling** — all I/O is blocking with `poll()` timeouts
- **Launch response captured lazily** — codelldb sends `initialized` event before launch response; `launch_seq` field tracks the pending response for later verification
- **Stopped event capture** — `processPendingEvents()` and `waitForStopped()` extract `threadId` and reason from DAP `stopped` events
- **Breakpoint state tracked locally** — `Handler.breakpoints` is synced with codelldb via `setBreakpoints` on every add/remove/clear

### Allocator Strategy

| Scope | Mechanism |
|-------|-----------|
| Per-request | `ArrayList(u8)` body — deferred `deinit` after `writeAll` |
| Persistent parse | `parse_arena` — reset before each `tryParseMessage()` |
| Handler response | Arena from MCP server `dispatch()` — freed after response sent |
| Logger | `std.heap.page_allocator` — simple alloc/dealloc per line |

### Port Discovery

```zig
fn findPortForPid(pid: u32) !u16
```

Runs `ss -tlnp` every 300ms (15s timeout), searches output for `pid=N,`, extracts port from the local address field (field 3), returns the port number. Linux-only.

### Session Lifecycle

`Handler.ensureSession()` implements lazy singleton initialization:
1. Checks `self.client` — returns existing session if present
2. Allocates `DapClient` on the heap
3. Calls `connect()` → `initialize()`
4. Uses `errdefer` to clean up on any failure
5. Stores pointer in `self.client`

`stopSession()` reverses this: deinit, destroy, set null. Breakpoints list is freed on stop.

### Tool Handler Pattern

Each handler is a free function:

```zig
fn handler(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value
```

1. Extract arguments via `args.object.get("key") orelse return mcp_types.errorResult(...)`
2. Call DAP methods on `ctx.getClient()`
3. Return `mcp_types.textResult(...)` / `textResultWithState(...)` on success, or `errorResult(...)` on failure

Results include optional `SessionState` (active, stopped, stoppedReason, threadId) so the MCP client can infer whether a tool call left the debuggee paused or running.

## Skill

The `debug-live` Agent Skill at `skills/debug-live/SKILL.md` teaches an LLM a complete debugging workflow: when to invoke debugging, root cause analysis framework, breakpoint strategy, tool-call patterns, and things to avoid. Install it into your agent's skills directory to enable automatic skill discovery.

## Limitations

- **Linux-only** port discovery (uses `ss -tlnp` from `iproute2`)
- **Single session**: only one debug session at a time
- **No DAP event forwarding**: `stopped`, `continued`, etc. are consumed internally (no MCP notifications to the client)
- **Poll-based I/O**: synchronous polling with 100ms intervals — not suitable for high-throughput scenarios
- **codelldb-specific**: initialization order assumes codelldb behaviour (`launch` before `configurationDone`)
