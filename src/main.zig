const std = @import("std");
const mcp_server = @import("mcp/server.zig");
const handler_mod = @import("mcp/handler.zig");
const log_mod = @import("logger.zig");

pub fn main() !void {
    // Write startup marker to stderr so opencode can confirm the binary launched
    const stderr_file = std.fs.File.stderr();
    stderr_file.writeAll("debugger: starting\n") catch {};

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var logger = log_mod.Logger.init();
    if (std.process.getEnvVarOwned(allocator, "DEBUGGERMCP_LOG")) |level_str| {
        defer allocator.free(level_str);
        if (std.ascii.eqlIgnoreCase(level_str, "debug")) logger.min_level = .debug;
        if (std.ascii.eqlIgnoreCase(level_str, "warn")) logger.min_level = .warn;
        if (std.ascii.eqlIgnoreCase(level_str, "error")) logger.min_level = .err;
    } else |_| {}

    const adapter_path = std.process.getEnvVarOwned(allocator, "DEBUGGERMCP_ADAPTER") catch
        "/tmp/codelldb-extract/extension/adapter/codelldb";

    var handler = handler_mod.Handler.init(allocator, &logger, adapter_path);
    defer handler.deinit();

    var server = mcp_server.Server(handler_mod.Handler).init(allocator, &logger, &handler);
    defer server.deinit();

    // Register tools — each handler is a free function that takes *Handler as first arg
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
