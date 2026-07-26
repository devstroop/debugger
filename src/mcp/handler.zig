const std = @import("std");
const json = std.json;
const DapClient = @import("../dap/client.zig").DapClient;
const DapBreakpoint = @import("../dap/types.zig").DapBreakpoint;
const log_mod = @import("../logger.zig");
const mcp_types = @import("types.zig");

pub const Breakpoint = struct {
    file_path: []const u8,
    line: u32,
    condition: ?[]const u8,
    log_message: ?[]const u8,
};

/// Glue layer between MCP tool calls and DAP operations.
pub const Handler = struct {
    allocator: std.mem.Allocator,
    logger: *const log_mod.Logger,
    adapter_path: []const u8,
    client: ?*DapClient = null,
    breakpoints: std.ArrayList(Breakpoint) = std.ArrayList(Breakpoint){},

    pub fn init(allocator: std.mem.Allocator, logger: *const log_mod.Logger, adapter_path: []const u8) Handler {
        return .{ .allocator = allocator, .logger = logger, .adapter_path = adapter_path };
    }

    pub fn deinit(self: *Handler) void {
        self.stopSession();
        self.breakpoints.deinit(self.allocator);
    }

    fn free_breakpoint(self: *Handler, bp: Breakpoint) void {
        self.allocator.free(bp.file_path);
        if (bp.condition) |c| self.allocator.free(c);
        if (bp.log_message) |lm| self.allocator.free(lm);
    }

    fn free_all_breakpoints(self: *Handler) void {
        for (self.breakpoints.items) |bp| self.free_breakpoint(bp);
        self.breakpoints.clearRetainingCapacity();
    }

    fn ensureSession(self: *Handler) !*DapClient {
        if (self.client) |c| return c;
        const c = try self.allocator.create(DapClient);
        c.* = DapClient.init(self.allocator, self.logger, self.adapter_path);
        errdefer {
            c.deinit();
            self.allocator.destroy(c);
        }
        try c.connect();
        try c.initialize();
        self.logger.info("DAP session initialized");
        self.client = c;
        return c;
    }

    fn stopSession(self: *Handler) void {
        self.free_all_breakpoints();
        if (self.client) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.client = null;
        }
    }

    fn getClient(self: *Handler) !*DapClient {
        return self.client orelse error.NoActiveSession;
    }
};

// ── Tool handlers ──────────────────────────────────────────────────
// NOTE: `args` is the tool's `arguments` object (already unwrapped by server).

pub fn start_debugging(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    ctx.stopSession();

    const a = args orelse return mcp_types.error_result(allocator, "Missing arguments");
    const file_path = a.object.get("fileFullPath") orelse return mcp_types.error_result(allocator, "Missing fileFullPath");
    const wd_arg = a.object.get("workingDirectory");

    const c = try ctx.ensureSession();
    const cwd = if (wd_arg) |wd| wd.string else extract_dir(file_path.string);
    try c.launch(file_path.string, cwd);

    return mcp_types.text_result_with_state(allocator, "Debug session started", .{
        .active = true,
        .stopped = false,
    });
}

pub fn stop_debugging(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    if (ctx.client == null) return mcp_types.error_result(allocator, "No active debug session");
    ctx.stopSession();
    return mcp_types.text_result_with_state(allocator, "Debug session stopped", .{
        .active = false,
        .stopped = false,
    });
}

pub fn step_over(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    if (c.thread_id < 0) return mcp_types.error_result(allocator, "No stopped thread");
    const stopped = try c.step_next();
    return stopped_to_text_result(stopped, allocator);
}

pub fn step_into(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    if (c.thread_id < 0) return mcp_types.error_result(allocator, "No stopped thread");
    const stopped = try c.step_in();
    return stopped_to_text_result(stopped, allocator);
}

pub fn step_out(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    if (c.thread_id < 0) return mcp_types.error_result(allocator, "No stopped thread");
    const stopped = try c.step_out();
    return stopped_to_text_result(stopped, allocator);
}

pub fn pause_exec(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    if (c.thread_id < 0) return mcp_types.error_result(allocator, "No active thread");
    const stopped = try c.pause_exec();
    return stopped_to_text_result(stopped, allocator);
}

pub fn continue_exec(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    const stopped = try c.continue_exec();
    return stopped_to_text_result(stopped, allocator);
}

fn stopped_to_text_result(stopped: json.Value, allocator: std.mem.Allocator) !json.Value {
    const reason = stopped.object.get("reason") orelse return mcp_types.text_result(allocator, "");
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);
    try w.writeAll("Stopped: ");
    try w.writeAll(reason.string);
    if (stopped.object.get("description")) |d| {
        try w.writeAll(" (");
        try w.writeAll(d.string);
        try w.writeByte(')');
    }
    const tid = if (stopped.object.get("threadId")) |t| t.integer else 0;
    const is_exit = std.mem.eql(u8, reason.string, "exited") or std.mem.eql(u8, reason.string, "terminated");
    return mcp_types.text_result_with_state(allocator, buf.items, .{
        .active = !is_exit,
        .stopped = !is_exit,
        .stoppedReason = reason.string,
        .threadId = tid,
    });
}

pub fn restart_debugging(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    ctx.stopSession();
    return start_debugging(ctx, allocator, args);
}

pub fn add_breakpoint(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const a = args orelse return mcp_types.error_result(allocator, "Missing arguments");
    const file_path = a.object.get("fileFullPath") orelse return mcp_types.error_result(allocator, "Missing fileFullPath");
    const line_val = a.object.get("line") orelse return mcp_types.error_result(allocator, "Missing line");
    const condition = if (a.object.get("condition")) |c| c.string else null;
    const log_message = if (a.object.get("logMessage")) |lm| lm.string else null;

    _ = try ctx.getClient();
    const line_i64 = json_to_i64(line_val);
    if (line_i64 < 0 or line_i64 > std.math.maxInt(u32)) {
        return mcp_types.error_result(allocator, "Line number out of range");
    }
    const line: u32 = @intCast(line_i64);

    // Allocate owned strings (free on any failure to prevent leaks)
    const owned_path = ctx.allocator.dupe(u8, file_path.string) catch |err| return err;
    const owned_cond = if (condition) |c| (ctx.allocator.dupe(u8, c) catch |err| {
        ctx.allocator.free(owned_path);
        return err;
    }) else null;
    const owned_msg = if (log_message) |lm| (ctx.allocator.dupe(u8, lm) catch |err| {
        ctx.allocator.free(owned_path);
        if (owned_cond) |c| ctx.allocator.free(c);
        return err;
    }) else null;

    // Free owned strings on any subsequent error to prevent leaks
    {
        const bp = Breakpoint{
            .file_path = owned_path,
            .line = line,
            .condition = owned_cond,
            .log_message = owned_msg,
        };
        ctx.breakpoints.append(ctx.allocator, bp) catch |err| {
            ctx.free_breakpoint(bp);
            return err;
        };
    }

    // Sync with remote; rollback local list on failure
    sync_breakpoints(ctx) catch |err| {
        // Remove the last appended breakpoint and free its strings
        if (ctx.breakpoints.items.len > 0) {
            const last = ctx.breakpoints.items.len - 1;
            ctx.free_breakpoint(ctx.breakpoints.items[last]);
            _ = ctx.breakpoints.orderedRemove(last);
        }
        return err;
    };
    return mcp_types.text_result(allocator, "Breakpoint added");
}

pub fn add_logpoint(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    return add_breakpoint(ctx, allocator, args);
}

pub fn remove_breakpoint(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const a = args orelse return mcp_types.error_result(allocator, "Missing arguments");
    const file_path = a.object.get("fileFullPath") orelse return mcp_types.error_result(allocator, "Missing fileFullPath");
    const line_val = a.object.get("line");

    const client = try ctx.getClient();
    const line: u32 = if (line_val) |lv| blk: {
        const lv_i64 = json_to_i64(lv);
        if (lv_i64 < 0 or lv_i64 > std.math.maxInt(u32)) return mcp_types.error_result(allocator, "Line number out of range");
        break :blk @intCast(lv_i64);
    } else return mcp_types.error_result(allocator, "Missing required parameter: line");

    // Build the filtered DAP breakpoint list (everything except matches)
    var dap_bps = std.ArrayList(DapBreakpoint){};
    defer dap_bps.deinit(ctx.allocator);
    for (ctx.breakpoints.items) |bp| {
        const is_match = std.mem.eql(u8, bp.file_path, file_path.string) and bp.line == line;
        if (!is_match and std.mem.eql(u8, bp.file_path, file_path.string)) {
            try dap_bps.append(ctx.allocator, .{
                .line = bp.line,
                .condition = bp.condition,
                .log_message = bp.log_message,
            });
        }
    }

    // Send filtered list to remote first (so local is unchanged on failure)
    const resp = try client.set_breakpoints(file_path.string, dap_bps.items);
    const success = resp.object.get("success") orelse return mcp_types.error_result(allocator, "Remote breakpoint removal failed");
    if (!success.bool) return mcp_types.error_result(allocator, "Remote breakpoint removal failed");

    // Remote succeeded — now update local list
    var removed: usize = 0;
    var i: usize = ctx.breakpoints.items.len;
    while (i > 0) {
        i -= 1;
        const bp = ctx.breakpoints.items[i];
        if (std.mem.eql(u8, bp.file_path, file_path.string) and bp.line == line) {
            ctx.free_breakpoint(bp);
            _ = ctx.breakpoints.orderedRemove(i);
            removed += 1;
        }
    }
    if (removed == 0) return mcp_types.text_result(allocator, "Breakpoint not found");
    return mcp_types.text_result(allocator, "Breakpoint removed");
}

pub fn clear_all_breakpoints(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    // Send empty set_breakpoints for each tracked file BEFORE freeing
    const c = try ctx.getClient();

    // Collect unique file paths into owned strings first
    var files = std.ArrayList([]const u8){};
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    for (ctx.breakpoints.items) |bp| {
        var found = false;
        for (files.items) |f| {
            if (std.mem.eql(u8, f, bp.file_path)) { found = true; break; }
        }
        if (!found) try files.append(allocator, try allocator.dupe(u8, bp.file_path));
    }

    // Clear remote first, then local (on error, local list is preserved)
    for (files.items) |file| {
        const resp = try c.set_breakpoints(file, &.{});
        const bp_success = resp.object.get("success") orelse {
            ctx.logger.fmt(.warn, "clear_all_breakpoints: missing success field for {s}", .{file});
            return mcp_types.error_result(allocator, "Failed to clear breakpoints remotely");
        };
        if (!bp_success.bool) {
            ctx.logger.fmt(.warn, "clear_all_breakpoints: set_breakpoints failed for {s}", .{file});
            return mcp_types.error_result(allocator, "Failed to clear breakpoints remotely");
        }
    }
    // Also clear any function breakpoints
    _ = try c.set_function_breakpoints(&.{});

    ctx.free_all_breakpoints();
    return mcp_types.text_result(allocator, "All breakpoints cleared");
}

pub fn list_breakpoints(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    if (ctx.breakpoints.items.len == 0) return mcp_types.text_result(allocator, "No breakpoints set");

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);
    for (ctx.breakpoints.items, 0..) |bp, i| {
        if (i > 0) try w.writeByte('\n');
        try w.writeAll(if (bp.log_message != null) "Logpoint" else "Breakpoint");
        try w.writeAll(": ");
        try w.writeAll(bp.file_path);
        try w.writeAll(":");
        try w.print("{}", .{bp.line});
        if (bp.condition) |c| {
            try w.writeAll(" (condition: ");
            try w.writeAll(c);
            try w.writeByte(')');
        }
    }
    return mcp_types.text_result(allocator, buf.items);
}

pub fn get_variables(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const c = try ctx.getClient();

    const scope_name = if (args) |a| blk: {
        const sn = a.object.get("scope");
        if (sn) |s| break :blk s.string;
        break :blk "local";
    } else "local";

    // Get stack trace to find top frame
    const stack_resp = try c.stack_trace(0, 10);
    const stack_body = stack_resp.object.get("body") orelse return mcp_types.error_result(allocator, "No stack trace body");
    const stack_frames = stack_body.object.get("stackFrames") orelse return mcp_types.error_result(allocator, "No stack frames");
    const frames = stack_frames.array.items;
    if (frames.len == 0) return mcp_types.text_result(allocator, "No frames on stack");

    const top_frame = frames[0];
    const frame_id = top_frame.object.get("id") orelse return mcp_types.error_result(allocator, "No frame id");
    const fid = json_to_i64(frame_id);

    // Get scopes for the top frame
    const scopes_resp = try c.scopes(fid);
    const scopes_body = scopes_resp.object.get("body") orelse return mcp_types.error_result(allocator, "No scopes body");
    const scopes_arr = scopes_body.object.get("scopes") orelse return mcp_types.error_result(allocator, "No scopes");
    const scopes = scopes_arr.array.items;

    // Find target scope
    var target_idx: usize = 0;
    for (scopes, 0..) |scope, i| {
        const name = scope.object.get("name") orelse continue;
        if (std.ascii.eqlIgnoreCase(name.string, scope_name)) {
            target_idx = i;
            break;
        }
    }
    if (target_idx >= scopes.len) return mcp_types.error_result(allocator, "Scope not found");

    const scope = scopes[target_idx];
    const var_ref = scope.object.get("variablesReference") orelse return mcp_types.error_result(allocator, "No variablesReference");
    const vref = json_to_i64(var_ref);
    if (vref == 0) return mcp_types.text_result(allocator, "No variables in scope");

    const vars_resp = try c.variables(vref);
    const vars_body = vars_resp.object.get("body") orelse return mcp_types.error_result(allocator, "No variables body");
    const vars_arr = vars_body.object.get("variables") orelse return mcp_types.error_result(allocator, "No variables");

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    for (vars_arr.array.items, 0..) |v, i| {
        if (i > 0) try w.writeAll("\n");
        const name = v.object.get("name") orelse continue;
        const value = v.object.get("value") orelse continue;
        try w.writeAll(name.string);
        try w.writeAll(" = ");
        try w.writeAll(value.string);
    }

    if (buf.items.len == 0) return mcp_types.text_result(allocator, "No variables");
    return mcp_types.text_result(allocator, buf.items);
}

pub fn evaluate_expression(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const a = args orelse return mcp_types.error_result(allocator, "Missing arguments");
    const expr = a.object.get("expression") orelse return mcp_types.error_result(allocator, "Missing expression");

    const c = try ctx.getClient();

    // Get top frame ID for context
    var frame_id: ?i64 = null;
    if (c.stack_trace(0, 5)) |stack_resp| {
        if (stack_resp.object.get("body")) |body| {
            if (body.object.get("stackFrames")) |frames| {
                if (frames.array.items.len > 0) {
                    if (frames.array.items[0].object.get("id")) |fid| {
                        frame_id = switch (fid) {
                            .integer => |n| n,
                            .float => |f| @intFromFloat(f),
                            else => null,
                        };
                    }
                }
            }
        }
    } else |_| {}

    const resp = try c.evaluate(expr.string, "watch", frame_id);

    const body = resp.object.get("body") orelse return mcp_types.error_result(allocator, "No evaluate body");
    const dap_result = body.object.get("result") orelse return mcp_types.text_result(allocator, "(no result)");

    return mcp_types.text_result(allocator, dap_result.string);
}

// ── Helpers ─────────────────────────────────────────────────────────

fn extract_dir(path: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        std.mem.lastIndexOfScalar(u8, path, '\\') orelse return ".";
    return path[0..last_slash];
}

fn write_json_string(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...7, 0xb, 0xc, 0xe...0x1f => {
                try w.writeAll("\\u00");
                try w.print("{x:0>2}", .{@as(u8, c)});
            },
            else => try w.writeByte(c),
        }
    }
}

fn json_to_i64(val: json.Value) i64 {
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn sync_breakpoints(ctx: *Handler) !void {
    const c = ctx.client orelse return;
    const all_bps = ctx.breakpoints.items;

    // Collect unique file paths
    var files = std.ArrayList([]const u8){};
    defer files.deinit(ctx.allocator);
    for (all_bps) |bp| {
        var found = false;
        for (files.items) |f| {
            if (std.mem.eql(u8, f, bp.file_path)) { found = true; break; }
        }
        if (!found) try files.append(ctx.allocator, bp.file_path);
    }

    // For each unique file, send all breakpoints for that file
    for (files.items) |file| {
        var count: usize = 0;
        for (all_bps) |bp| {
            if (std.mem.eql(u8, bp.file_path, file)) count += 1;
        }
        var dap_bps = try ctx.allocator.alloc(DapBreakpoint, count);
        defer ctx.allocator.free(dap_bps);
        var idx: usize = 0;
        for (all_bps) |bp| {
            if (std.mem.eql(u8, bp.file_path, file)) {
                dap_bps[idx] = .{
                    .line = bp.line,
                    .condition = bp.condition,
                    .log_message = bp.log_message,
                };
                idx += 1;
            }
        }
        const resp = try c.set_breakpoints(file, dap_bps);
        // Check that the DAP call succeeded (response has success: true)
        const success = resp.object.get("success") orelse {
            ctx.logger.fmt(.warn, "set_breakpoints response missing success for {s}", .{file});
            return error.DapRequestFailed;
        };
        if (!success.bool) {
            ctx.logger.fmt(.warn, "set_breakpoints failed for {s}", .{file});
            return error.DapRequestFailed;
        }
    }
}

pub const Error = error{
    NoActiveSession,
};
