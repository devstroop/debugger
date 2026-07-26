const std = @import("std");
const net = std.net;
const json = std.json;
const log_mod = @import("Logger.zig");

const dap_timeout_ms: u64 = 15_000;
const poll_ms: u64 = 300;

pub const DapClient = struct {
    allocator: std.mem.Allocator,
    logger: *const log_mod.Logger,
    adapter_path: []const u8,

    proc: ?std.process.Child = null,
    conn: ?net.Stream = null,
    seq: i64 = 1,
    read_buf: std.ArrayList(u8),
    parse_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, logger: *const log_mod.Logger, adapter_path: []const u8) DapClient {
        return .{
            .allocator = allocator,
            .logger = logger,
            .adapter_path = adapter_path,
            .read_buf = std.ArrayList(u8){},
            .parse_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DapClient) void {
        self.disconnect();
        self.read_buf.deinit(self.allocator);
        self.parse_arena.deinit();
    }

    pub fn connect(self: *DapClient) !void {
        self.logger.info("Spawning adapter...");

        const argv = &.{ self.adapter_path, "--port", "0" };
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        self.proc = child;
        const pid: u32 = @intCast(child.id);

        self.logger.fmt(.info, "Spawned pid={}, discovering port...", .{pid});

        const port = self.discoverPort(pid) catch |err| {
            _ = child.kill() catch unreachable;
            self.proc = null;
            return err;
        };

        self.logger.fmt(.info, "Discovered port {}, connecting...", .{port});

        const conn = net.tcpConnectToHost(self.allocator, "127.0.0.1", port) catch |err| {
            _ = child.kill() catch unreachable;
            self.proc = null;
            return err;
        };
        self.conn = conn;
        self.logger.info("TCP connected");
    }

    pub fn disconnect(self: *DapClient) void {
        if (self.conn) |c| {
            c.close();
            self.conn = null;
        }
        if (self.proc) |*child| {
            _ = child.kill() catch unreachable;
            self.proc = null;
        }
    }

    // ── High-level DAP operations ─────────────────────────────────

    pub fn initialize(self: *DapClient) !void {
        const resp = try self.send("initialize", "{\"clientID\":\"debugger-mcp\",\"adapterID\":\"lldb\"}");
        try checkSuccess(resp);
        self.logger.info("DAP initialized");
    }

    pub fn launch(self: *DapClient, program: []const u8, cwd: []const u8) !void {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.writeAll("{\"program\":\"");
        try writeJsonString(w, program);
        try w.writeAll("\",\"cwd\":\"");
        try writeJsonString(w, cwd);
        try w.writeAll("\",\"type\":\"lldb\",\"request\":\"launch\",\"stopOnEntry\":true}");

        const resp = try self.send("launch", args.items);
        try checkSuccess(resp);
        self.logger.info("Launch sent (stopOnEntry=true)");
    }

    pub fn setBreakpoints(self: *DapClient, file_path: []const u8, line: u32, condition: ?[]const u8, log_message: ?[]const u8) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);

        try w.writeAll("{\"source\":{\"path\":\"");
        try writeJsonString(w, file_path);
        try w.writeAll("\"},\"breakpoints\":[{\"line\":");
        try w.print("{}", .{line});
        if (condition) |c| {
            try w.writeAll(",\"condition\":\"");
            try writeJsonString(w, c);
            try w.writeAll("\"");
        }
        if (log_message) |lm| {
            try w.writeAll(",\"logMessage\":\"");
            try writeJsonString(w, lm);
            try w.writeAll("\"");
        }
        try w.writeAll("}]}");

        return self.send("setBreakpoints", args.items);
    }

    pub fn setFunctionBreakpoints(self: *DapClient, names: []const []const u8) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.writeAll("{\"breakpoints\":[");
        for (names, 0..) |name, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":\"");
            try writeJsonString(w, name);
            try w.writeAll("\"}");
        }
        try w.writeAll("]}");
        return self.send("setFunctionBreakpoints", args.items);
    }

    pub fn configurationDone(self: *DapClient) !void {
        const resp = try self.send("configurationDone", "{}");
        try checkSuccess(resp);
        self.logger.info("Configuration done");
    }

    pub fn next(self: *DapClient, thread_id: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{thread_id});
        return self.send("next", args.items);
    }

    pub fn stepIn(self: *DapClient, thread_id: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{thread_id});
        return self.send("stepIn", args.items);
    }

    pub fn stepOut(self: *DapClient, thread_id: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{thread_id});
        return self.send("stepOut", args.items);
    }

    pub fn pause(self: *DapClient, thread_id: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{thread_id});
        return self.send("pause", args.items);
    }

    pub fn continueExec(self: *DapClient, thread_id: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{thread_id});
        return self.send("continue", args.items);
    }

    pub fn stackTrace(self: *DapClient, thread_id: i64, start_frame: i64, levels: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{},\"startFrame\":{},\"levels\":{}}}", .{ thread_id, start_frame, levels });
        return self.send("stackTrace", args.items);
    }

    pub fn scopes(self: *DapClient, frame_id: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"frameId\":{}}}", .{frame_id});
        return self.send("scopes", args.items);
    }

    pub fn variables(self: *DapClient, var_ref: i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"variablesReference\":{}}}", .{var_ref});
        return self.send("variables", args.items);
    }

    pub fn evaluate(self: *DapClient, expression: []const u8, context: []const u8) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.writeAll("{\"expression\":\"");
        try writeJsonString(w, expression);
        try w.writeAll("\",\"context\":\"");
        try writeJsonString(w, context);
        try w.writeAll("\"}");
        return self.send("evaluate", args.items);
    }

    // ── Low-level protocol ────────────────────────────────────────

    fn discoverPort(_: *DapClient, pid: u32) !u16 {
        var elapsed: u64 = 0;
        while (elapsed < dap_timeout_ms) {
            std.Thread.sleep(poll_ms * std.time.ns_per_ms);
            elapsed += poll_ms;
            if (findPortForPid(pid)) |port| return port else |_| continue;
        }
        return error.PortDiscoveryFailed;
    }

    pub fn send(self: *DapClient, command: []const u8, args_msg: ?[]const u8) !json.Value {
        const seq = self.seq;
        self.seq += 1;
        const conn = self.conn orelse return error.NotConnected;

        var body = std.ArrayList(u8){};
        defer body.deinit(self.allocator);
        var bw = body.writer(self.allocator);
        try bw.writeAll("{\"seq\":");
        try bw.print("{}", .{seq});
        try bw.writeAll(",\"type\":\"request\",\"command\":\"");
        try writeJsonString(bw, command);
        try bw.writeAll("\"");
        if (args_msg) |a| {
            try bw.writeAll(",\"arguments\":");
            try bw.writeAll(a);
        }
        try bw.writeAll("}");

        var frame = std.ArrayList(u8){};
        defer frame.deinit(self.allocator);
        var fw = frame.writer(self.allocator);
        try fw.writeAll("Content-Length: ");
        try fw.print("{}", .{body.items.len});
        try fw.writeAll("\r\n\r\n");
        try fw.writeAll(body.items);
        try conn.writeAll(frame.items);

        return self.readResponse(seq);
    }

    fn readResponse(self: *DapClient, expected_seq: i64) !json.Value {
        const start = std.time.milliTimestamp();
        while (true) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            if (elapsed > dap_timeout_ms) return error.Timeout;

            if (self.tryParseMessage()) |msg| {
                const root = msg.object;
                // DAP responses carry request_seq, not "id"
                if (root.get("request_seq")) |rs_val| {
                    const rs = jsonToI64(rs_val);
                    if (rs == expected_seq) {
                        try checkSuccess(msg);
                        return msg;
                    }
                }
                // Events (type=="event") have no request_seq — skip them
            } else |err| switch (err) {
                error.ProtocolError => return err,
                error.NeedMoreData => {
                    self.readMore() catch |read_err| {
                        if (read_err == error.Timeout) continue;
                        return read_err;
                    };
                },
                else => return err,
            }
        }
    }

    fn tryParseMessage(self: *DapClient) !json.Value {
        const data = self.read_buf.items;
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.NeedMoreData;
        const header = data[0..header_end];

        const cl_marker = "Content-Length: ";
        const cl_pos = std.mem.indexOf(u8, header, cl_marker) orelse return error.ProtocolError;
        const rest = header[cl_pos + cl_marker.len ..];
        const cl_str = std.mem.trim(u8, rest, " \r\n");
        const cl = std.fmt.parseInt(usize, cl_str, 10) catch return error.ProtocolError;

        const body_start = header_end + 4;
        const total = body_start + cl;
        if (data.len < total) return error.NeedMoreData;

        const body = data[body_start..total];

        // Reuse persistent arena — previous response is now invalid
        self.parse_arena.deinit();
        self.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        const parsed = json.parseFromSliceLeaky(json.Value, self.parse_arena.allocator(), body, .{}) catch return error.ProtocolError;

        self.read_buf.replaceRange(self.allocator, 0, total, &.{}) catch |e| {
            self.logger.fmt(.err, "replaceRange failed: {s}", .{@errorName(e)});
            return error.ProtocolError;
        };
        return parsed;
    }

    fn readMore(self: *DapClient) !void {
        const handle = (self.conn orelse return error.NotConnected).handle;
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const rc = std.posix.poll(&poll_fds, 100);
        if (rc catch 0 == 0) return error.Timeout;
        if ((rc catch 0) < 0) return error.ReadError;

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            var buf: [4096]u8 = undefined;
            const conn = &(self.conn orelse return error.NotConnected);
            const n = conn.read(&buf) catch |err| {
                if (err == error.WouldBlock) return error.Timeout;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            try self.read_buf.appendSlice(self.allocator, buf[0..n]);
        } else if (poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
            return error.ConnectionClosed;
        }
    }
};

// ── Free functions ───────────────────────────────────────────────────

fn findPortForPid(pid: u32) !u16 {
    const allocator = std.heap.page_allocator;
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ss", "-tlnp" },
    }) catch return error.SsFailed;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const pid_str = try std.fmt.allocPrint(allocator, "pid={},", .{pid});
    defer allocator.free(pid_str);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, pid_str) == null) continue;
        // Split by whitespace; field 3 (0-indexed) is Local Address:Port
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        var field_idx: usize = 0;
        var local_addr: ?[]const u8 = null;
        while (tokens.next()) |token| : (field_idx += 1) {
            if (field_idx == 3) {
                local_addr = token;
                break;
            }
        }
        const addr = local_addr orelse continue;
        // Find last colon in the local address (port separator)
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse continue;
        const port_str = addr[colon + 1 ..];
        return std.fmt.parseInt(u16, port_str, 10);
    }
    return error.PortNotFound;
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

fn checkSuccess(response: json.Value) !void {
    if (response.object.get("success")) |s| {
        if (!s.bool) return error.DapRequestFailed;
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
    NotConnected,
    PortDiscoveryFailed,
    SsFailed,
    PortNotFound,
    Timeout,
    DapRequestFailed,
    ProtocolError,
    NeedMoreData,
    ConnectionClosed,
    ReadError,
    MissingParams,
};
