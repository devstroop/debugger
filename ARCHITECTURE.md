# Architecture

## Overview

`debugger-mcp` is a zero-dependency Zig binary that acts as a protocol bridge between MCP (Model Context Protocol) and DAP (Debug Adapter Protocol). It allows LLM-based tools like OpenCode to drive native code debugging through codelldb/LLDB.

## Module Dependencies

```mermaid
graph TD
    main[main.zig] --> Logger[Logger.zig]
    main --> handler[handler.zig]
    main --> server[mcp/server.zig]

    handler --> dap[dap.zig]
    handler --> types[mcp/types.zig]
    handler --> Logger

    dap --> Logger
    dap --> stdlib[std.posix / std.net / std.process]

    types --> stdjson[std.json]

    server --> types
    server --> Logger
```

## Generic Server Pattern `Server(Ctx)`

The MCP server uses Zig's comptime generics to decouple protocol handling from application logic:

```zig
pub fn Server(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        handlers: std.StringHashMap(HandlerFn),
        // ...
    };
}
```

`HandlerFn` is a function pointer type: `*const fn (ctx: *Ctx, allocator: std.mem.Allocator, params: ?json.Value) anyerror!json.Value`

```mermaid
flowchart LR
    subgraph CompileTime["Compile Time"]
        CtxType["Ctx type parameter"] --> ServerGen["Server(Ctx) generated<br/>with HandlerFn(Ctx)"]
    end

    subgraph Runtime["Run Time"]
        ServerGen --> Register["registerTool(name, handlerFn)"]
        Register --> Dispatch["dispatch(method, params)"]
        Dispatch --> Lookup{"handlers.get(method)"}
        Lookup -->|Found| Call["handler(ctx, arena_alloc, params)"]
        Lookup -->|Not found| Error["send -32601<br/>Method not found"]
        Call --> Arena["arena.deinit()<br/>(response sent)"]
    end
```

This pattern enables:
- **Compile-time dispatch** — no vtable, no interface overhead
- **Type safety** — the handler context type is checked at compile time
- **Reusability** — the server could be instantiated with any context type

## DAP Client Design

### Connection Lifecycle

```mermaid
flowchart TD
    A["DapClient.init(allocator, logger, adapter_path)"]
    A --> B["connect()"]
    B --> B1["spawn codelldb --port 0"]
    B1 --> B2["discoverPort(pid)"]
    B2 --> B3["tcpConnectToHost(127.0.0.1, port)"]
    B3 --> C["initialize()"]
    C --> C1["send('initialize', {clientID, adapterID})"]
    C1 --> D["launch(program, cwd)"]
    D --> D1["send('launch', {program, cwd, …})"]
    D1 --> E["…debug operations…"]
    E --> F["DapClient.deinit()"]
    F --> F1["conn.close()"]
    F --> F2["proc.kill()"]
    F --> F3["read_buf.deinit()"]
    F --> F4["parse_arena.deinit()"]
```

### Request-Response Correlation

DAP uses a monotonic `seq` counter for requests. Responses carry a `request_seq` field matching the request's `seq`. The `send()` method orchestrates this flow:

```mermaid
sequenceDiagram
    participant Client as DapClient
    participant Adapter as codelldb

    Note over Client: self.seq += 1 → N
    Client->>Adapter: send(seq=N, command, args)
    activate Adapter
    Adapter-->>Client: event (type="event", no request_seq)
    Note over Client: readResponse() — silently skipped
    Adapter-->>Client: response (request_seq=N)
    deactivate Adapter
    Note over Client: readResponse() — matched,<br/>checkSuccess(), return
```

### Memory Strategy

Two allocation patterns coexist:

```mermaid
flowchart LR
    subgraph PerRequest["Per-request (send / writeFrame)"]
        Build["ArrayList(u8) body"] --> Write["writeAll to TCP"]
        Write --> Free["defer body.deinit()"]
    end

    subgraph Persistent["Persistent (readResponse)"]
        Parse["tryParseMessage"] --> Reset["parse_arena.deinit()<br/>parse_arena.init()"]
        Reset --> JSON["json.parseFromSliceLeaky(arena)"]
    end
```

- **Per-request arenas**: `send()` creates a temporary `ArrayList(u8)` to build the JSON body, freed after `writeAll`
- **Persistent parse arena**: `parse_arena` is reused across all response reads — deinitialized and re-created before each new parse

## Tool Handler Pattern

Each handler is a free function with the signature:

```zig
fn handler(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value
```

```mermaid
flowchart TD
    Call["handler(ctx, allocator, args)"]
    Call --> Extract["extract arguments<br/>args.object.get('key') orelse …"]
    Extract --> Success{"all required<br/>args present?"}
    Success -->|No| ErrorResult["return errorResult(…)"]
    Success -->|Yes| GetClient["ctx.getClient()"]
    GetClient --> DAP["call DAP method<br/>(launch / setBreakpoints / …)"]
    DAP --> Done{"DAP call<br/>succeeded?"}
    Done -->|Yes| TextResult["return textResult(…)"]
    Done -->|No| Propagate["return error"]
```

### Session Lifecycle

`Handler.ensureSession()` implements lazy singleton initialization:

```mermaid
flowchart TD
    ES["ensureSession()"] --> Check{"self.client<br/>already set?"}
    Check -->|Yes| Return["return existing client"]
    Check -->|No| Alloc["alloc DapClient on heap"]
    Alloc --> Init["init()"]
    Init --> Conn["connect()"]
    Conn --> InitDAP["initialize()"]
    InitDAP --> Store["store in self.client"]
    Store --> Return

    Init -->|errdefer| Cleanup["c.deinit()<br/>self.allocator.destroy(c)"]

    SS["stopSession()"] --> HasClient{"self.client<br/>!= null?"}
    HasClient -->|Yes| Deinit["c.deinit()"]
    Deinit --> Destroy["self.allocator.destroy(c)"]
    Destroy --> Null["self.client = null"]
    HasClient -->|No| Done["(no-op)"]
```

`stopSession()` reverses this: deinit, destroy, set null.

## Port Discovery

```mermaid
flowchart TD
    Start["findPortForPid(pid)"]
    Start --> SS["run 'ss -tlnp'"]
    SS --> Search["search output for 'pid=N,'"]
    Search --> Found{"found?"}
    Found -->|No| Sleep["sleep 300ms"]
    Sleep --> Timeout{"15s elapsed?"}
    Timeout -->|No| SS
    Timeout -->|Yes| Fail["return error.PortDiscoveryFailed"]
    Found -->|Yes| Tokenize["tokenize line by whitespace"]
    Tokenize --> Extract["take field 3<br/>(local address:port)"]
    Extract --> Parse["extract port<br/>after last colon"]
    Parse --> Success["return port"]
```

## Error Handling Strategy

| Layer | Approach |
|---|---|
| MCP parse errors | Send JSON-RPC `-32700` error |
| Unknown methods | Send `-32601` Method not found |
| Missing params | Send `-32602` Invalid params |
| Handler failures | Send `-32603` Internal error with message |
| DAP protocol errors | Convert to error results or propagate |
| Stdin read errors | Fatal — `server.run()` returns |
| Dispatch errors | Logged, server continues |

## Key Design Decisions

1. **Inline tool schemas**: The `tools/list` response is a hardcoded JSON string. This is simple but requires manual updates when tools change. (An alternative would be building it programmatically from registered handler metadata.)

2. **TCP over stdio for DAP**: codelldb is spawned with `--port 0` rather than using stdin/stdout for DAP. This adds port discovery complexity but matches codelldb's recommended usage pattern.

3. **No DAP event processing**: DAP events (stopped, continued, breakpoint) are discarded. The server does not push MCP notifications. This means the LLM client must poll for state changes rather than being notified.

4. **Single-threaded synchronous**: All I/O is blocking with polling timeouts. No async runtime, no threads. This keeps the code simple but limits concurrency.

5. **Zero dependencies**: The entire project uses only Zig's standard library. No JSON library, no HTTP library, no MCP or DAP SDK.

## Debug Logging

The `Logger` module writes structured log lines to stderr:

```mermaid
flowchart LR
    App["Application code"] --> LogCall["logger.info / .fmt / .err"]
    LogCall --> Format["format: [timestamp] [LEVEL] message"]
    Format --> Stderr["stderr"]
```

Default level is `info`. Change at initialization in `main.zig`:
```zig
var logger = log_mod.Logger.init();
logger.min_level = .debug;
```
