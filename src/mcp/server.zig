const std = @import("std");
const json = std.json;
const log_mod = @import("../logger.zig");

pub fn Server(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        pub const HandlerFn = *const fn (ctx: *Ctx, allocator: std.mem.Allocator, params: ?json.Value) anyerror!json.Value;

        allocator: std.mem.Allocator,
        logger: *const log_mod.Logger,
        ctx: *Ctx,
        handlers: std.StringHashMap(HandlerFn),

        pub fn init(allocator: std.mem.Allocator, logger: *const log_mod.Logger, ctx: *Ctx) Self {
            return .{
                .allocator = allocator,
                .logger = logger,
                .ctx = ctx,
                .handlers = std.StringHashMap(HandlerFn).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.handlers.deinit();
        }

        pub fn registerTool(self: *Self, name: []const u8, handler: HandlerFn) !void {
            try self.handlers.put(name, handler);
        }

        pub fn run(self: *Self) !void {
            const stdin = std.fs.File.stdin();
            const stdout = std.fs.File.stdout();

            var buf: [16384]u8 = undefined;
            var accumulated = std.ArrayList(u8){};
            defer accumulated.deinit(self.allocator);
            const max_message_size: usize = 1024 * 1024; // 1 MB

            while (true) {
                const n = stdin.read(&buf) catch |err| {
                    self.logger.fmt(.err, "stdin read error: {s}", .{@errorName(err)});
                    return err;
                };
                if (n == 0) return;

                var start: usize = 0;
                while (start < n) {
                    if (std.mem.indexOfScalar(u8, buf[start..n], '\n')) |newline_pos| {
                        const abs_pos = start + newline_pos;
                        if (abs_pos > start) {
                            if (accumulated.items.len + (abs_pos - start) > max_message_size) {
                                self.logger.fmt(.err, "message too large", .{});
                                accumulated.clearRetainingCapacity();
                                start = abs_pos + 1;
                                continue;
                            }
                            try accumulated.appendSlice(self.allocator, buf[start..abs_pos]);
                        }
                        const trimmed = std.mem.trim(u8, accumulated.items, " \r");
                        if (trimmed.len > 0) {
                            self.dispatch(trimmed, stdout) catch |err| {
                                self.logger.fmt(.err, "dispatch error: {s}", .{@errorName(err)});
                            };
                        }
                        accumulated.clearRetainingCapacity();
                        start = abs_pos + 1;
                    } else {
                        if (accumulated.items.len + (n - start) > max_message_size) {
                            self.logger.fmt(.err, "message too large", .{});
                            accumulated.clearRetainingCapacity();
                            break;
                        }
                        try accumulated.appendSlice(self.allocator, buf[start..n]);
                        break;
                    }
                }
            }
        }

        fn dispatch(self: *Self, raw: []const u8, out: std.fs.File) !void {
            // Arena for parsing — freed at end of dispatch
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            const parsed = json.parseFromSliceLeaky(json.Value, arena_alloc, raw, .{}) catch |err| {
                self.logger.fmt(.err, "JSON parse error: {s}", .{@errorName(err)});
                const fallback_id = extractId(raw);
                try sendErrorRaw(out, fallback_id, -32700, "Parse error");
                return;
            };
            const root = parsed.object;
            const method = root.get("method") orelse {
                self.logger.warn("message without method");
                try sendErrorRaw(out, root.get("id"), -32600, "Invalid request");
                return;
            };
            const id = root.get("id");
            const params = root.get("params");

            const method_str = method.string;

            if (std.mem.eql(u8, method_str, "initialize")) {
                try self.handleInitialize(id, params, out);
            } else if (std.mem.eql(u8, method_str, "notifications/initialized")) {
                // No response expected
            } else if (std.mem.eql(u8, method_str, "ping")) {
                try sendPong(out, id);
            } else if (std.mem.eql(u8, method_str, "tools/list")) {
                try self.handleToolsList(id, out);
            } else if (std.mem.eql(u8, method_str, "tools/call")) {
                try self.handleToolCall(id, params, out);
            } else if (isNotification(method_str)) {
                // Notifications have no id, they don't expect a response
            } else {
                try sendErrorRaw(out, id, -32601, "Method not found");
            }
        }

        fn handleInitialize(self: *Self, id: ?json.Value, params: ?json.Value, out: std.fs.File) !void {
            // Echo back the protocol version the client proposed
            var protocol_version: []const u8 = "2024-11-05";
            if (params) |p| {
                if (p.object.get("protocolVersion")) |pv| {
                    protocol_version = pv.string;
                }
            }

            var buf = std.ArrayList(u8){};
            defer buf.deinit(self.allocator);
            var w = buf.writer(self.allocator);
            try w.writeAll("{\"result\":{");
            try writeJsonString(w, "protocolVersion"); try w.writeByte(':');
            try writeJsonString(w, protocol_version); try w.writeByte(',');
            try w.writeAll("\"capabilities\":{\"tools\":{\"listChanged\":true}},");
            try w.writeAll("\"serverInfo\":{\"name\":\"debugger\",\"version\":\"0.1.0\"},");
            try w.writeAll("\"instructions\":\"Debug MCP server\"");
            try w.writeAll("},\"jsonrpc\":\"2.0\",\"id\":");
            try writeId(w, id);
            try w.writeAll("}\n");
            try out.writeAll(buf.items);
        }

        fn handleToolsList(self: *Self, id: ?json.Value, out: std.fs.File) !void {
            var buf = std.ArrayList(u8){};
            defer buf.deinit(self.allocator);
            var w = buf.writer(self.allocator);

            try w.writeAll("{\"result\":{\"tools\":[");
            try w.writeAll("{\"name\":\"start_debugging\",\"description\":\"Start a VS Code debug session for a source file. Use when investigating bugs, failing tests, wrong/null variable values, or unexpected runtime behavior.\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"fileFullPath\":{\"type\":\"string\",\"description\":\"Full path to the source code file to debug\"},\"workingDirectory\":{\"type\":\"string\",\"description\":\"Working directory for the debug session\"}},\"required\":[\"fileFullPath\"],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"stop_debugging\",\"description\":\"Stop the current debug session\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"step_over\",\"description\":\"Execute the current line of code without diving into it.\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"step_into\",\"description\":\"Dive into the current line of code.\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"step_out\",\"description\":\"Step out of the current function\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"pause\",\"description\":\"Interrupt a running program and stop at its current location\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"continue_execution\",\"description\":\"Resume program execution until the next breakpoint is hit or the program completes\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"restart_debugging\",\"description\":\"Restart the debug session from the beginning\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"fileFullPath\":{\"type\":\"string\",\"description\":\"Full path to the source code file to debug\"}},\"required\":[\"fileFullPath\"],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"add_breakpoint\",\"description\":\"Set a breakpoint to pause execution at a critical line of code\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"fileFullPath\":{\"type\":\"string\",\"description\":\"Full path to the file\"},\"line\":{\"type\":\"integer\",\"description\":\"Line number (1-based) where the breakpoint should be set\"},\"condition\":{\"type\":\"string\",\"description\":\"Optional condition expression. Execution only pauses if this evaluates to true (e.g. \\\"i == 5\\\")\"}},\"required\":[\"fileFullPath\",\"line\"],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"add_logpoint\",\"description\":\"Add a logpoint that logs a message instead of pausing execution\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"fileFullPath\":{\"type\":\"string\",\"description\":\"Full path to the file\"},\"line\":{\"type\":\"integer\",\"description\":\"Line number (1-based)\"},\"logMessage\":{\"type\":\"string\",\"description\":\"Message to log. Embed expressions in {curly braces} to interpolate runtime values, e.g. \\\"count={items.length}\\\"\"}},\"required\":[\"fileFullPath\",\"line\",\"logMessage\"],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"remove_breakpoint\",\"description\":\"Remove a breakpoint by file and line\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"fileFullPath\":{\"type\":\"string\",\"description\":\"Full path to the file\"},\"line\":{\"type\":\"integer\",\"description\":\"Line number (1-based)\"}},\"required\":[\"fileFullPath\",\"line\"],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"clear_all_breakpoints\",\"description\":\"Remove all breakpoints and logpoints\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"list_breakpoints\",\"description\":\"View all currently set breakpoints across all files\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"get_variables_values\",\"description\":\"Inspect variable values at the current execution point\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"scope\":{\"type\":\"string\",\"description\":\"Variable scope to inspect\",\"enum\":[\"local\",\"global\",\"all\"]}},\"required\":[],\"additionalProperties\":false}},");
            try w.writeAll("{\"name\":\"evaluate_expression\",\"description\":\"Evaluate an expression in the current debug context\",\"inputSchema\":{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\",\"description\":\"Expression to evaluate\"}},\"required\":[\"expression\"],\"additionalProperties\":false}}");
            try w.writeAll("]},\"jsonrpc\":\"2.0\",\"id\":");
            try writeId(w, id);
            try w.writeAll("}\n");
            try out.writeAll(buf.items);
        }

        fn handleToolCall(self: *Self, id: ?json.Value, params: ?json.Value, out: std.fs.File) !void {
            const p = params orelse {
                try sendErrorRaw(out, id, -32602, "Missing params");
                return;
            };
            const name = p.object.get("name") orelse {
                try sendErrorRaw(out, id, -32602, "Missing tool name");
                return;
            };
            const args = p.object.get("arguments");
            const name_str = name.string;

            if (self.handlers.get(name_str)) |handler| {
                // Arena for the handler's response — freed after sending
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const arena_alloc = arena.allocator();

                const result = handler(self.ctx, arena_alloc, args) catch |err| {
                    self.logger.fmt(.err, "Tool '{s}' failed: {s}", .{ name_str, @errorName(err) });
                    try sendErrorRaw(out, id, -32603, "Internal error");
                    return;
                };
                try sendResultRaw(out, id, result);
            } else {
                try sendErrorRaw(out, id, -32601, "Tool not found");
            }
        }
    };
}

// ── Free-standing JSON response helpers (no self needed) ──────────

fn sendResultRaw(out: std.fs.File, id: ?json.Value, result: json.Value) !void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.heap.page_allocator);
    var w = buf.writer(std.heap.page_allocator);
    try w.writeAll("{\"result\":");
    try writeJsonValue(w, result);
    try w.writeAll(",\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll("}\n");
    try out.writeAll(buf.items);
}

fn sendErrorRaw(out: std.fs.File, id: ?json.Value, code: i32, msg: []const u8) !void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.heap.page_allocator);
    var w = buf.writer(std.heap.page_allocator);
    try w.writeAll("{\"error\":{\"code\":");
    try w.print("{}", .{code});
    try w.writeAll(",\"message\":");
    try writeJsonString(w, msg);
    try w.writeAll("},\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll("}\n");
    try out.writeAll(buf.items);
}

fn writeId(w: anytype, id_val: ?json.Value) !void {
    if (id_val) |id| {
        switch (id) {
            .integer => |n| try w.print("{}", .{n}),
            .float => |f| try w.print("{}", .{@as(i64, @intFromFloat(f))}),
            .string => |s| {
                try w.writeByte('"');
                try w.writeAll(s);
                try w.writeByte('"');
            },
            else => try w.writeAll("null"),
        }
    } else {
        try w.writeAll("null");
    }
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
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
    try w.writeByte('"');
}

fn writeJsonValue(w: anytype, val: json.Value) !void {
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{}", .{n}),
        .float => |f| try w.print("{}", .{f}),
        .number_string => |s| try writeJsonString(w, s),
        .string => |s| try writeJsonString(w, s),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try writeJsonString(w, entry.key_ptr.*);
                try w.writeByte(':');
                try writeJsonValue(w, entry.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

fn sendPong(out: std.fs.File, id: ?json.Value) !void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.heap.page_allocator);
    var w = buf.writer(std.heap.page_allocator);
    try w.writeAll("{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll("}\n");
    try out.writeAll(buf.items);
}

fn isNotification(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "notifications/") or
        std.mem.startsWith(u8, method, "$/");
}

fn extractId(raw: []const u8) ?json.Value {
    if (std.mem.indexOf(u8, raw, "\"id\"")) |id_pos| {
        const rest = raw[id_pos + 4 ..];
        const trimmed = std.mem.trimLeft(u8, rest, " \t:");
        if (trimmed.len > 0) {
            if (trimmed[0] == '"') {
                const end = std.mem.indexOfScalar(u8, trimmed[1..], '"') orelse return null;
                return json.Value{ .string = trimmed[1 .. 1 + end] };
            }
            if (trimmed[0] >= '0' and trimmed[0] <= '9') {
                const end = std.mem.indexOfAny(u8, trimmed, ",} \t\n") orelse trimmed.len;
                const num = std.fmt.parseInt(i64, trimmed[0..end], 10) catch return null;
                return json.Value{ .integer = num };
            }
        }
    }
    return null;
}
