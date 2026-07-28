const std = @import("std");
const mcp_server = @import("mcp/server.zig");
const handler_mod = @import("mcp/handler.zig");
const log_mod = @import("logger.zig");

// Provide a properly-initialized Threaded Io for process spawning.
// The default debug_io uses Allocator.failing which can't spawn processes.
// We initialise with .init_single_threaded at module scope so the pointer
// exposed via std_options_debug_threaded_io is always valid (comptime
// constants cannot point to undefined memory).  No imported module
// accesses debug_io at comptime or during declaration evaluation — all
// access happens inside function bodies (logger, process spawning) that
// run after main() has upgraded the global to threaded I/O.
var global_threaded: std.Io.Threaded = .init_single_threaded;
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = &global_threaded;

pub fn main() !void {
    // Use a bounded backing buffer so threaded I/O init won't exhaust memory.
    var io_backing: [128 * 1024]u8 = undefined;
    var io_fba = std.heap.FixedBufferAllocator.init(&io_backing);

    // Upgrade the global I/O to threaded BEFORE any debug_io access.
    global_threaded = std.Io.Threaded.init(io_fba.allocator(), .{
        .concurrent_limit = .nothing,
        .async_limit = .nothing,
    });

    const allocator = std.heap.smp_allocator;

    var start_buf: [64]u8 = undefined;
    const start_stderr = std.debug.lockStderr(&start_buf);
    defer std.debug.unlockStderr();
    start_stderr.file_writer.interface.writeAll("debugger: starting\n") catch {};

    var logger = log_mod.Logger.init();
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        if (env_map.get("DEBUGGERMCP_LOG")) |level_str| {
            if (std.ascii.eqlIgnoreCase(level_str, "debug")) logger.min_level = .debug;
            if (std.ascii.eqlIgnoreCase(level_str, "warn")) logger.min_level = .warn;
            if (std.ascii.eqlIgnoreCase(level_str, "error")) logger.min_level = .err;
        }
    }

    const adapter_path = blk: {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        const val = env_map.get("DEBUGGERMCP_ADAPTER");
        if (val) |v| {
            break :blk try allocator.dupe(u8, v);
        }

        // Before falling back to hardcoded paths, try looking up
        // `lldb-dap` via $PATH — this covers user-installed tools,
        // conda environments, Nix, Snap, and custom prefixes.
        // findProgramAbsolute already verifies executability.
        if (std.process.getEnvMap(allocator)) |system_env| {
            defer system_env.deinit();
            if (std.process.findProgramAbsolute("lldb-dap", &system_env)) |found| {
                break :blk try allocator.dupe(u8, found);
            } else |_| {}
        } else |_| {}

        // If $PATH lookup failed, check well-known installation
        // locations.  We verify executability so we don't select a
        // directory or corrupted file that would fail at spawn time.
        const candidates = &.{
            "/usr/lib/llvm-19/bin/lldb-dap",
            "/usr/lib/llvm-18/bin/lldb-dap",
            "/usr/lib/llvm-17/bin/lldb-dap",
            "/usr/bin/lldb-dap",
            "/usr/local/bin/lldb-dap",
            // Homebrew on macOS (Apple Silicon)
            "/opt/homebrew/bin/lldb-dap",
            // Homebrew on macOS (Intel)
            "/usr/local/opt/llvm/bin/lldb-dap",
        };
        for (candidates) |path| {
            if (std.fs.accessAbsolute(path, .{ .execute = true })) |_| {
                break :blk try allocator.dupe(u8, path);
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => logger.warn("accessAbsolute({s}) failed: {}", .{ path, err }),
            }
        }

        // Last resort: let the kernel resolve the name via $PATH.
        // This works when lldb-dap is installed but not at any of the
        // well-known paths above.
        logger.warn("lldb-dap not found via PATH or well-known paths; falling back to bare name", .{});
        break :blk try allocator.dupe(u8, "lldb-dap");
    };

    var handler = handler_mod.Handler.init(allocator, &logger, adapter_path);
    defer handler.deinit();

    var server = mcp_server.Server(handler_mod.Handler).init(allocator, &logger, &handler);
    defer server.deinit();

    try server.registerTool("start_debugging", handler_mod.start_debugging);
    try server.registerTool("stop_debugging", handler_mod.stop_debugging);
    try server.registerTool("step_over", handler_mod.step_over);
    try server.registerTool("step_into", handler_mod.step_into);
    try server.registerTool("step_out", handler_mod.step_out);
    try server.registerTool("pause", handler_mod.pause_exec);
    try server.registerTool("continue_execution", handler_mod.continue_exec);
    try server.registerTool("restart_debugging", handler_mod.restart_debugging);
    try server.registerTool("add_breakpoint", handler_mod.add_breakpoint);
    try server.registerTool("add_logpoint", handler_mod.add_logpoint);
    try server.registerTool("remove_breakpoint", handler_mod.remove_breakpoint);
    try server.registerTool("clear_all_breakpoints", handler_mod.clear_all_breakpoints);
    try server.registerTool("list_breakpoints", handler_mod.list_breakpoints);
    try server.registerTool("get_variables_values", handler_mod.get_variables);
    try server.registerTool("evaluate_expression", handler_mod.evaluate_expression);

    logger.info("Starting MCP stdio server...");
    try server.run();
}
