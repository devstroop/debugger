const std = @import("std");
const json = std.json;
const dap = @import("dap.zig");
const log_mod = @import("Logger.zig");
const mcp_types = @import("mcp/types.zig");

/// Glue layer between MCP tool calls and DAP operations.
pub const Handler = struct {
    allocator: std.mem.Allocator,
    logger: *const log_mod.Logger,
    adapter_path: []const u8,
    client: ?*dap.DapClient = null,

    pub fn init(allocator: std.mem.Allocator, logger: *const log_mod.Logger, adapter_path: []const u8) Handler {
        return .{ .allocator = allocator, .logger = logger, .adapter_path = adapter_path };
    }

    pub fn deinit(self: *Handler) void {
        self.stopSession();
    }

    fn ensureSession(self: *Handler) !*dap.DapClient {
        if (self.client) |c| return c;
        const c = try self.allocator.create(dap.DapClient);
        c.* = dap.DapClient.init(self.allocator, self.logger, self.adapter_path);
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
        if (self.client) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.client = null;
        }
    }

    fn getClient(self: *Handler) !*dap.DapClient {
        return self.client orelse error.NoActiveSession;
    }
};

// ── Tool handlers ──────────────────────────────────────────────────
// NOTE: `args` is the tool's `arguments` object (already unwrapped by server).

pub fn startDebugging(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    ctx.stopSession();

    const a = args orelse return mcp_types.errorResult(allocator, "Missing arguments");
    const file_path = a.object.get("fileFullPath") orelse return mcp_types.errorResult(allocator, "Missing fileFullPath");
    const wd_arg = a.object.get("workingDirectory");

    const c = try ctx.ensureSession();
    const cwd = if (wd_arg) |wd| wd.string else extractDir(file_path.string);
    try c.launch(file_path.string, cwd);

    return mcp_types.textResult(allocator, "Debug session started (stopped at entry)");
}

pub fn stopDebugging(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    ctx.stopSession();
    return mcp_types.textResult(allocator, "Debug session stopped");
}

pub fn stepOver(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    _ = try c.next(1);
    return mcp_types.textResult(allocator, "Stepped over");
}

pub fn stepInto(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    _ = try c.stepIn(1);
    return mcp_types.textResult(allocator, "Stepped into");
}

pub fn stepOut(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    _ = try c.stepOut(1);
    return mcp_types.textResult(allocator, "Stepped out");
}

pub fn pause(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    _ = try c.pause(1);
    return mcp_types.textResult(allocator, "Paused");
}

pub fn continueExec(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    _ = try c.continueExec(1);
    return mcp_types.textResult(allocator, "Continued");
}

pub fn restartDebugging(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    ctx.stopSession();
    return startDebugging(ctx, allocator, args);
}

pub fn addBreakpoint(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const a = args orelse return mcp_types.errorResult(allocator, "Missing arguments");
    const file_path = a.object.get("fileFullPath") orelse return mcp_types.errorResult(allocator, "Missing fileFullPath");
    const line_val = a.object.get("line") orelse return mcp_types.errorResult(allocator, "Missing line");
    const condition = if (a.object.get("condition")) |c| c.string else null;
    const log_message = if (a.object.get("logMessage")) |lm| lm.string else null;

    const c = try ctx.getClient();
    const line_i64 = jsonToI64(line_val);
    if (line_i64 < 0 or line_i64 > std.math.maxInt(u32)) {
        return mcp_types.errorResult(allocator, "Line number out of range");
    }
    const line: u32 = @intCast(line_i64);

    _ = try c.setBreakpoints(file_path.string, line, condition, log_message);
    return mcp_types.textResult(allocator, "Breakpoint added");
}

pub fn addLogpoint(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    return addBreakpoint(ctx, allocator, args);
}

pub fn removeBreakpoint(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const a = args orelse return mcp_types.errorResult(allocator, "Missing arguments");
    const file_path = a.object.get("fileFullPath") orelse return mcp_types.errorResult(allocator, "Missing fileFullPath");

    const c = try ctx.getClient();
    // Clear all breakpoints on this source file (DAP setBreakpoints replaces)
    var body = std.ArrayList(u8){};
    defer body.deinit(allocator);
    var w = body.writer(allocator);
    try w.writeAll("{\"source\":{\"path\":\"");
    try writeJsonString(w, file_path.string);
    try w.writeAll("\"},\"breakpoints\":[]}");

    _ = try c.send("setBreakpoints", body.items);
    return mcp_types.textResult(allocator, "Breakpoints cleared for file");
}

pub fn clearAllBreakpoints(ctx: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    const c = try ctx.getClient();
    _ = try c.send("setBreakpoints", "{\"source\":{\"path\":\"\"},\"breakpoints\":[]}");
    _ = try c.send("setFunctionBreakpoints", "{\"breakpoints\":[]}");
    return mcp_types.textResult(allocator, "All breakpoints cleared");
}

pub fn listBreakpoints(_: *Handler, allocator: std.mem.Allocator, _: ?json.Value) !json.Value {
    return mcp_types.textResult(allocator, "Breakpoint listing not supported by DAP; breakpoints are tracked server-side by codelldb");
}

pub fn getVariables(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const c = try ctx.getClient();

    const scope_name = if (args) |a| blk: {
        const sn = a.object.get("scope");
        if (sn) |s| break :blk s.string;
        break :blk "local";
    } else "local";

    // Get stack trace to find top frame
    const stack_resp = try c.stackTrace(1, 0, 10);
    const stack_body = stack_resp.object.get("body") orelse return mcp_types.errorResult(allocator, "No stack trace body");
    const stack_frames = stack_body.object.get("stackFrames") orelse return mcp_types.errorResult(allocator, "No stack frames");
    const frames = stack_frames.array.items;
    if (frames.len == 0) return mcp_types.textResult(allocator, "No frames on stack");

    const top_frame = frames[0];
    const frame_id = top_frame.object.get("id") orelse return mcp_types.errorResult(allocator, "No frame id");
    const fid = jsonToI64(frame_id);

    // Get scopes for the top frame
    const scopes_resp = try c.scopes(fid);
    const scopes_body = scopes_resp.object.get("body") orelse return mcp_types.errorResult(allocator, "No scopes body");
    const scopes_arr = scopes_body.object.get("scopes") orelse return mcp_types.errorResult(allocator, "No scopes");
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
    if (target_idx >= scopes.len) return mcp_types.errorResult(allocator, "Scope not found");

    const scope = scopes[target_idx];
    const var_ref = scope.object.get("variablesReference") orelse return mcp_types.errorResult(allocator, "No variablesReference");
    const vref = jsonToI64(var_ref);
    if (vref == 0) return mcp_types.textResult(allocator, "No variables in scope");

    const vars_resp = try c.variables(vref);
    const vars_body = vars_resp.object.get("body") orelse return mcp_types.errorResult(allocator, "No variables body");
    const vars_arr = vars_body.object.get("variables") orelse return mcp_types.errorResult(allocator, "No variables");

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

    if (buf.items.len == 0) return mcp_types.textResult(allocator, "No variables");
    return mcp_types.textResult(allocator, buf.items);
}

pub fn evaluateExpression(ctx: *Handler, allocator: std.mem.Allocator, args: ?json.Value) !json.Value {
    const a = args orelse return mcp_types.errorResult(allocator, "Missing arguments");
    const expr = a.object.get("expression") orelse return mcp_types.errorResult(allocator, "Missing expression");

    const c = try ctx.getClient();
    const resp = try c.evaluate(expr.string, "repl");

    const body = resp.object.get("body") orelse return mcp_types.errorResult(allocator, "No evaluate body");
    const dap_result = body.object.get("result") orelse return mcp_types.textResult(allocator, "(no result)");

    return mcp_types.textResult(allocator, dap_result.string);
}

// ── Helpers ─────────────────────────────────────────────────────────

fn extractDir(path: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        std.mem.lastIndexOfScalar(u8, path, '\\') orelse return ".";
    return path[0..last_slash];
}

fn writeJsonString(w: anytype, s: []const u8) !void {
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

fn jsonToI64(val: json.Value) i64 {
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

pub const Error = error{
    NoActiveSession,
};
