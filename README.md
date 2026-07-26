# debugger-mcp

An MCP (Model Context Protocol) server that bridges MCP tool calls to the Debug Adapter Protocol (DAP) via [codelldb](https://github.com/vadimcn/vscode-lldb). Enables LLM-driven debugging of native code (C, C++, Rust, Zig, etc.) through a debugger.

## Architecture

```
┌──────────────┐   JSON-RPC 2.0     ┌──────────────┐    DAP over TCP    ┌───────────┐
│    VSCode,   │ ◄─── stdio ──────► │ debugger-mcp │ ◄────────────────► │ codelldb  │
│   OpenCode,  │   (NDJSON lines)   │  (Zig)       │  (Content-Length)  │ (LLDB)    │
│  Cline, Roo  │                    └──────┬───────┘                    └───────────┘
│ (MCP client) │                           │
└──────────────┘                     ┌─────┴──────┐
                                     │   stderr   │
                                     │ (logging)  │
                                     └────────────┘
```

- **MCP transport**: stdio (newline-delimited JSON per the MCP spec)
- **DAP transport**: TCP to codelldb (which listens on a random port)
- **Language**: Zig (zero external dependencies — pure `std` library)

## Prerequisites

- **Zig 0.15.2+** (to build)
- **codelldb** — the VS Code LLDB extension adapter
  - Auto-detected at `/tmp/codelldb-extract/extension/adapter/codelldb`
  - Override via `DEBUGGERMCP_ADAPTER` environment variable
- **ss** (from `iproute2`) — used for port discovery on Linux

## OpenCode Configuration

Add to your `opencode.jsonc`:

```jsonc
"mcp": {
  "debugger": {
    "type": "local",
    "command": ["/path/to/debugger-mcp"]
  }
}
```

No additional `env` block is needed (codelldb path defaults to `/tmp/codelldb-extract/extension/adapter/codelldb`).

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

The binary is placed at `zig-out/bin/debugger-mcp`.

## MCP Tools

### Session Management

| Tool | Description | Arguments |
|---|---|---|
| `start_debugging` | Start a debug session | `fileFullPath` (required), `workingDirectory` (optional) |
| `stop_debugging` | Stop the current debug session | — |
| `restart_debugging` | Restart with new target | same as `start_debugging` |

### Execution Control

| Tool | Description |
|---|---|
| `step_over` | Step over current line |
| `step_into` | Step into function |
| `step_out` | Step out of function |
| `pause` | Pause execution |
| `continue_execution` | Resume execution |

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

## Protocol Flow

### Startup
```
OpenCode                  debugger-mcp                 codelldb
   │                          │                          │
   │─── initialize ──────────►│                          │
   │◄── {capabilities} ───────│                          │
   │─── initialized ─────────►│                          │
   │─── tools/list ──────────►│                          │
   │◄── {tools[...]} ─────────│                          │
   │                          │                          │
```

### Debug Session
```
   │─── start_debugging ─────►│                          │
   │                          │──── spawn codelldb ─────►│
   │                          │◄─── port ────────────────│
   │                          │──── TCP connect ────────►│
   │                          │──── DAP initialize ─────►│
   │                          │◄─── {capabilities} ──────│
   │                          │──── DAP launch ─────────►│
   │                          │◄─── {success} ───────────│
   │◄─── "session started" ───│                          │
   │                          │                          │
   │──── step_over ──────────►│                          │
   │                          │──── DAP next ───────────►│
   │                          │◄─── {response} ──────────│
   │◄─── "stepped over" ──────│                          │
```

## DAP Protocol Details

codelldb is spawned with `--port 0` (random port), discovered via `ss -tlnp`, and communicated with over TCP using standard DAP framing (`Content-Length` headers). The server follows codelldb's non-standard initialization order: **launch must happen before `configurationDone`** — codelldb only sends `initialized` as a side effect of receiving the launch request.

## Debugging

The server logs to stderr at the configured log level (default: `info`). Set `DEBUGGERMCP_LOG=debug` environment variable for verbose output.

## Project Structure

```
src/
├── main.zig         # Entry point, tool registration, wiring
├── handler.zig      # MCP tool handlers — translates MCP → DAP
├── dap.zig          # DAP client — spawn, TCP, protocol operations
├── Logger.zig       # Leveled stderr logger
└── mcp/
    ├── server.zig   # Generic MCP stdio JSON-RPC server
    └── types.zig    # MCP result/error builders
```

## Limitations

- **Linux-only** port discovery (uses `ss -tlnp` from `iproute2`)
- **Single session**: only one debug session at a time
- **No DAP event forwarding**: `stopped`, `continued`, etc. are silently discarded (no MCP notifications to the client)
- **Poll-based I/O**: synchronous polling with 100ms intervals — not suitable for high-throughput scenarios
- **codelldb-specific**: initialization order assumes codelldb behavior (`launch` before `configurationDone`)
