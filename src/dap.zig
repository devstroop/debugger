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
    launch_seq: i64 = 0,
    thread_id: i64 = -1,
    started: bool = false,
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

        // codelldb defers the launch response until after configurationDone.
        // It sends `initialized` event immediately after launch, then waits.
        // We send the request and wait for `initialized`; the launch response
        // will be captured and validated by readResponse on a subsequent call.
        const seq = self.seq;
        self.seq += 1;
        self.launch_seq = seq;
        try self.writeFrame("launch", seq, args.items);

        const start = std.time.milliTimestamp();
        while (true) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            if (elapsed > dap_timeout_ms) return error.Timeout;

            if (self.tryParseMessage()) |msg| {
                const root = msg.object;
                // Capture launch response if it arrives before initialized
                if (root.get("request_seq")) |rs_val| {
                    if (self.launch_seq != 0 and jsonToI64(rs_val) == self.launch_seq) {
                        try checkSuccess(msg);
                        self.launch_seq = 0;
                    }
                }
                if (root.get("type")) |t| {
                    if (std.mem.eql(u8, t.string, "event")) {
                        if (root.get("event")) |e| {
                            if (std.mem.eql(u8, e.string, "initialized")) {
                                self.logger.info("Launch sent and initialized received (adapter ready)");
                                return;
                            }
                        }
                    }
                }
            } else |err| switch (err) {
                error.NeedMoreData => self.readMore() catch |read_err| {
                    if (read_err == error.Timeout) continue;
                    return read_err;
                },
                else => return err,
            }
        }
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
        if (self.started) return;
        const resp = try self.send("configurationDone", "{}");
        try checkSuccess(resp);
        self.started = true;
        self.logger.info("Configuration done, program started");
    }

    pub fn next(self: *DapClient) !json.Value {
        _ = self.processPendingEvents() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        return self.send("next", args.items);
    }

    pub fn stepIn(self: *DapClient) !json.Value {
        _ = self.processPendingEvents() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        return self.send("stepIn", args.items);
    }

    pub fn stepOut(self: *DapClient) !json.Value {
        _ = self.processPendingEvents() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        return self.send("stepOut", args.items);
    }

    pub fn pause(self: *DapClient) !json.Value {
        _ = self.processPendingEvents() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        return self.send("pause", args.items);
    }

    pub fn continueExec(self: *DapClient) !json.Value {
        // Allow configurationDone to start the program even without a stopped thread
        if (!self.started) {
            try self.configurationDone();
            // After configDone, program runs and may stop at a breakpoint.
            return json.Value{ .string = "" };
        }
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        return self.send("continue", args.items);
    }

    pub fn stackTrace(self: *DapClient, start_frame: i64, levels: i64) !json.Value {
        _ = self.processPendingEvents() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{},\"startFrame\":{},\"levels\":{}}}", .{ self.thread_id, start_frame, levels });
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

    pub fn evaluate(self: *DapClient, expression: []const u8, context: []const u8, frame_id: ?i64) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.writeAll("{\"expression\":\"");
        try writeJsonString(w, expression);
        try w.writeAll("\",\"context\":\"");
        try writeJsonString(w, context);
        try w.writeAll("\"");
        if (frame_id) |fid| {
            try w.writeAll(",\"frameId\":");
            try w.print("{}", .{fid});
        }
        try w.writeAll("}");
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
        // Process pending events (e.g. stopped) to update state before building request
        _ = self.processPendingEvents() catch {};
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
        const fw = frame.writer(self.allocator);
        try writeFrameContent(fw, body.items);
        try conn.writeAll(frame.items);

        return self.readResponse(seq);
    }

    fn writeFrame(self: *DapClient, command: []const u8, seq: i64, args_msg: ?[]const u8) !void {
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
        const fw = frame.writer(self.allocator);
        try writeFrameContent(fw, body.items);
        try conn.writeAll(frame.items);
    }

    fn writeFrameContent(fw: anytype, body: []const u8) !void {
        try fw.writeAll("Content-Length: ");
        try fw.print("{}", .{body.len});
        try fw.writeAll("\r\n\r\n");
        try fw.writeAll(body);
    }

    fn readResponse(self: *DapClient, expected_seq: i64) !json.Value {
        const start = std.time.milliTimestamp();
        while (true) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            if (elapsed > dap_timeout_ms) return error.Timeout;

            if (self.tryParseMessage()) |msg| {
                const root = msg.object;
                // Capture thread ID from stopped events
                self.captureStoppedThreadId(msg);

                if (root.get("request_seq")) |rs_val| {
                    const rs = jsonToI64(rs_val);
                    // Capture pending launch response and verify it
                    if (self.launch_seq != 0 and rs == self.launch_seq) {
                        try checkSuccess(msg);
                        self.launch_seq = 0;
                    }
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

    fn processPendingEvents(self: *DapClient) !void {
        // Read available data without blocking
        _ = self.readMore() catch {};
        // Scan the buffer: remove events (capturing state), keep responses
        // We work byte-level: find Content-Length header, parse JSON body
        var keep = std.ArrayList(u8){};
        var temp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer {
            temp_arena.deinit();
            keep.deinit(self.allocator);
        }
        var data = self.read_buf.items;
        while (true) {
            const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse break;
            const cl_marker = "Content-Length: ";
            const cl_pos = std.mem.indexOf(u8, data[0..header_end], cl_marker) orelse break;
            const rest = data[cl_pos + cl_marker.len .. header_end];
            const cl = std.fmt.parseInt(usize, std.mem.trim(u8, rest, " \r\n"), 10) catch break;
            const body_start = header_end + 4;
            const total = body_start + cl;
            if (data.len < total) break;

            // Peek at the message type without consuming
            const body_slice = data[body_start..total];
            const parsed = json.parseFromSliceLeaky(json.Value, temp_arena.allocator(), body_slice, .{}) catch break;
            const is_response = parsed.object.get("request_seq") != null;
            if (is_response) {
                // Keep response in the buffer — append to keep list
                keep.appendSlice(self.allocator, data[0..total]) catch break;
            } else {
                // Event — process it (capture thread_id), discard from buffer
                self.captureStoppedThreadId(parsed);
            }
            data = data[total..];
        }
        // Copy remaining unprocessed data before clearing buffer
        const remaining = try self.allocator.dupe(u8, data);
        defer self.allocator.free(remaining);
        self.read_buf.clearRetainingCapacity();
        self.read_buf.appendSlice(self.allocator, keep.items) catch {};
        self.read_buf.appendSlice(self.allocator, remaining) catch {};
    }

    fn captureStoppedThreadId(self: *DapClient, msg: json.Value) void {
        const root = msg.object;
        const msg_type = root.get("type") orelse return;
        if (!std.mem.eql(u8, msg_type.string, "event")) return;
        const event = root.get("event") orelse return;
        if (!std.mem.eql(u8, event.string, "stopped")) return;
        const body = root.get("body") orelse return;
        const tid = body.object.get("threadId") orelse return;
        self.thread_id = jsonToI64(tid);
        self.logger.fmt(.debug, "Captured thread_id={}", .{self.thread_id});
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
