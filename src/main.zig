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
    // The env_map is now loaded separately (see client.zig connect()), so this
    // only covers per-spawn overhead (argv, pipes, internal structures) — < 1KB.
    // 256KB provides a generous margin for concurrent spawns.
    var io_backing: [256 * 1024]u8 = undefined;
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
        logger.warn("lldb-dap not found via env; falling back to PATH lookup");
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
