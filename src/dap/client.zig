const std = @import("std");
const net = std.net;
const json = std.json;
const log_mod = @import("../logger.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const DapBreakpoint = types.DapBreakpoint;
const Error = types.Error;
const write_json_string = util.write_json_string;
const check_success = util.check_success;
const json_to_i64 = util.json_to_i64;
const find_port_for_pid = util.find_port_for_pid;
const stopped_info_to_json = util.stopped_info_to_json;

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
    pending_stopped_reason: ?[]const u8 = null,
    pending_stopped_description: ?[]const u8 = null,
    pending_stopped_thread: i64 = 0,
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

        const port = self.discover_port(pid) catch |err| {
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

    pub fn initialize(self: *DapClient) !void {
        const resp = try self.send("initialize", "{\"clientID\":\"debugger\",\"adapterID\":\"lldb\"}");
        try check_success(resp);
        self.logger.info("DAP initialized");
    }

    pub fn launch(self: *DapClient, program: []const u8, cwd: []const u8) !void {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.writeAll("{\"program\":\"");
        try write_json_string(w, program);
        try w.writeAll("\",\"cwd\":\"");
        try write_json_string(w, cwd);
        try w.writeAll("\",\"type\":\"lldb\",\"request\":\"launch\",\"stopOnEntry\":false}");

        const seq = self.seq;
        self.seq += 1;
        self.launch_seq = seq;
        try self.write_frame("launch", seq, args.items);

        const start = std.time.milliTimestamp();
        while (true) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            if (elapsed > dap_timeout_ms) return error.Timeout;

            if (self.try_parse_message()) |msg| {
                const root = msg.object;
                if (root.get("request_seq")) |rs_val| {
                    if (self.launch_seq != 0 and json_to_i64(rs_val) == self.launch_seq) {
                        try check_success(msg);
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
                error.NeedMoreData => self.read_more() catch |read_err| {
                    if (read_err == error.Timeout) continue;
                    return read_err;
                },
                else => return err,
            }
        }
    }

    pub fn set_breakpoints(self: *DapClient, file_path: []const u8, breakpoints: []const DapBreakpoint) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);

        try w.writeAll("{\"source\":{\"path\":\"");
        try write_json_string(w, file_path);
        try w.writeAll("\"},\"breakpoints\":[");
        for (breakpoints, 0..) |bp, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"line\":");
            try w.print("{}", .{bp.line});
            if (bp.condition) |c| {
                try w.writeAll(",\"condition\":\"");
                try write_json_string(w, c);
                try w.writeAll("\"");
            }
            if (bp.log_message) |lm| {
                try w.writeAll(",\"logMessage\":\"");
                try write_json_string(w, lm);
                try w.writeAll("\"");
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        return self.send("setBreakpoints", args.items);
    }

    pub fn set_function_breakpoints(self: *DapClient, names: []const []const u8) !json.Value {
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.writeAll("{\"breakpoints\":[");
        for (names, 0..) |name, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":\"");
            try write_json_string(w, name);
            try w.writeAll("\"}");
        }
        try w.writeAll("]}");
        return self.send("setFunctionBreakpoints", args.items);
    }

    pub fn configuration_done(self: *DapClient) !void {
        if (self.started) return;
        const resp = try self.send("configurationDone", "{}");
        try check_success(resp);
        self.started = true;
        self.logger.info("Configuration done, program started");
    }

    fn clear_pending_stopped(self: *DapClient) void {
        if (self.pending_stopped_reason) |r| self.allocator.free(r);
        if (self.pending_stopped_description) |d| self.allocator.free(d);
        self.pending_stopped_reason = null;
        self.pending_stopped_description = null;
        self.pending_stopped_thread = 0;
    }

    pub fn step_next(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("next", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn step_in(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("stepIn", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn step_out(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("stepOut", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn pause_exec(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("pause", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn continue_exec(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (!self.started) {
            try self.configuration_done();
            self.started = true;
            const stopped = try self.wait_for_stopped();
            return stopped_info_to_json(stopped, self.allocator);
        }
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = std.ArrayList(u8){};
        defer args.deinit(self.allocator);
        var w = args.writer(self.allocator);
        try w.print("{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("continue", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn stack_trace(self: *DapClient, start_frame: i64, levels: i64) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
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
        try write_json_string(w, expression);
        try w.writeAll("\",\"context\":\"");
        try write_json_string(w, context);
        try w.writeAll("\"");
        if (frame_id) |fid| {
            try w.writeAll(",\"frameId\":");
            try w.print("{}", .{fid});
        }
        try w.writeAll("}");
        return self.send("evaluate", args.items);
    }

    // ── Low-level protocol ────────────────────────────────────────

    fn discover_port(_: *DapClient, pid: u32) !u16 {
        var elapsed: u64 = 0;
        while (elapsed < dap_timeout_ms) {
            std.Thread.sleep(poll_ms * std.time.ns_per_ms);
            elapsed += poll_ms;
            if (find_port_for_pid(pid)) |port| return port else |_| continue;
        }
        return error.PortDiscoveryFailed;
    }

    pub fn send(self: *DapClient, command: []const u8, args_msg: ?[]const u8) !json.Value {
        _ = self.process_pending_events() catch {};
        const seq = self.seq;
        self.seq += 1;
        const conn = self.conn orelse return error.NotConnected;

        var body = std.ArrayList(u8){};
        defer body.deinit(self.allocator);
        var bw = body.writer(self.allocator);
        try bw.writeAll("{\"seq\":");
        try bw.print("{}", .{seq});
        try bw.writeAll(",\"type\":\"request\",\"command\":\"");
        try write_json_string(bw, command);
        try bw.writeAll("\"");
        if (args_msg) |a| {
            try bw.writeAll(",\"arguments\":");
            try bw.writeAll(a);
        }
        try bw.writeAll("}");

        var frame = std.ArrayList(u8){};
        defer frame.deinit(self.allocator);
        const fw = frame.writer(self.allocator);
        try write_frame_content(fw, body.items);
        try conn.writeAll(frame.items);

        return self.read_response(seq);
    }

    fn write_frame(self: *DapClient, command: []const u8, seq: i64, args_msg: ?[]const u8) !void {
        const conn = self.conn orelse return error.NotConnected;
        var body = std.ArrayList(u8){};
        defer body.deinit(self.allocator);
        var bw = body.writer(self.allocator);
        try bw.writeAll("{\"seq\":");
        try bw.print("{}", .{seq});
        try bw.writeAll(",\"type\":\"request\",\"command\":\"");
        try write_json_string(bw, command);
        try bw.writeAll("\"");
        if (args_msg) |a| {
            try bw.writeAll(",\"arguments\":");
            try bw.writeAll(a);
        }
        try bw.writeAll("}");

        var frame = std.ArrayList(u8){};
        defer frame.deinit(self.allocator);
        const fw = frame.writer(self.allocator);
        try write_frame_content(fw, body.items);
        try conn.writeAll(frame.items);
    }

    fn write_frame_content(fw: anytype, body: []const u8) !void {
        try fw.writeAll("Content-Length: ");
        try fw.print("{}", .{body.len});
        try fw.writeAll("\r\n\r\n");
        try fw.writeAll(body);
    }

    fn read_response(self: *DapClient, expected_seq: i64) !json.Value {
        const start = std.time.milliTimestamp();
        while (true) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            if (elapsed > dap_timeout_ms) return error.Timeout;

            if (self.try_parse_message()) |msg| {
                const root = msg.object;
                self.capture_stopped_thread_id(msg, true);

                if (root.get("request_seq")) |rs_val| {
                    const rs = json_to_i64(rs_val);
                    if (self.launch_seq != 0 and rs == self.launch_seq) {
                        try check_success(msg);
                        self.launch_seq = 0;
                    }
                    if (rs == expected_seq) {
                        try check_success(msg);
                        return msg;
                    }
                }
            } else |err| switch (err) {
                error.ProtocolError => return err,
                error.NeedMoreData => {
                    self.read_more() catch |read_err| {
                        if (read_err == error.Timeout) continue;
                        return read_err;
                    };
                },
                else => return err,
            }
        }
    }

    pub const StoppedInfo = types.StoppedInfo;

    fn wait_for_stopped(self: *DapClient) !StoppedInfo {
        if (self.pending_stopped_reason) |reason| {
            const owned_reason = try self.allocator.dupe(u8, reason);
            const owned_desc = if (self.pending_stopped_description) |d| try self.allocator.dupe(u8, d) else null;
            self.clear_pending_stopped();
            return StoppedInfo{
                .reason = owned_reason,
                .thread_id = self.pending_stopped_thread,
                .description = owned_desc,
            };
        }

        const stop_timeout_ns: u64 = 30_000_000_000;
        var timer = std.time.Timer.start() catch return error.Timeout;
        while (true) {
            if (timer.read() > stop_timeout_ns) return error.Timeout;

            const msg = self.try_parse_message() catch |err| {
                if (err == error.NeedMoreData) {
                    const prev_len = self.read_buf.items.len;
                    self.read_more() catch |read_err| {
                        if (read_err == error.Timeout) {
                            std.Thread.sleep(10 * std.time.ns_per_ms);
                            continue;
                        }
                        return read_err;
                    };
                    if (self.read_buf.items.len == prev_len) {
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                    }
                    continue;
                }
                if (err == error.ProtocolError) {
                    self.read_buf.clearAndFree(self.allocator);
                    continue;
                }
                return err;
            };

            const root = msg.object;

            if (root.get("request_seq") != null) {
                self.logger.fmt(.warn, "wait_for_stopped consumed a response, buffer may be out of sync", .{});
                continue;
            }

            const msg_type_val = root.get("type") orelse continue;
            if (msg_type_val != .string) continue;
            if (!std.mem.eql(u8, msg_type_val.string, "event")) continue;
            const event_val = root.get("event") orelse continue;
            if (event_val != .string) continue;

            if (std.mem.eql(u8, event_val.string, "exited") or
                std.mem.eql(u8, event_val.string, "terminated"))
            {
                self.thread_id = -1;
                return StoppedInfo{ .reason = "exited", .thread_id = 0, .description = null };
            }

            if (!std.mem.eql(u8, event_val.string, "stopped")) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            const body_val = root.get("body") orelse return error.ProtocolError;
            if (body_val != .object) return error.ProtocolError;
            const body = body_val.object;
            const tid_val = body.get("threadId") orelse return error.ProtocolError;
            self.thread_id = json_to_i64(tid_val);

            const reason_val = body.get("reason") orelse return error.ProtocolError;
            if (reason_val != .string) return error.ProtocolError;
            const desc_val = body.get("description");

            return StoppedInfo{
                .reason = reason_val.string,
                .thread_id = self.thread_id,
                .description = if (desc_val) |d| if (d == .string) d.string else null else null,
            };
        }
    }

    fn process_pending_events(self: *DapClient) !void {
        _ = self.read_more() catch {};
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

            const body_slice = data[body_start..total];
            const parsed = json.parseFromSliceLeaky(json.Value, temp_arena.allocator(), body_slice, .{}) catch break;
            const is_response = parsed.object.get("request_seq") != null;
            if (is_response) {
                keep.appendSlice(self.allocator, data[0..total]) catch break;
            } else {
                self.capture_stopped_thread_id(parsed, false);
            }
            data = data[total..];
        }
        const remaining = try self.allocator.dupe(u8, data);
        defer self.allocator.free(remaining);
        self.read_buf.clearRetainingCapacity();
        try self.read_buf.appendSlice(self.allocator, keep.items);
        try self.read_buf.appendSlice(self.allocator, remaining);
    }

    fn capture_stopped_thread_id(self: *DapClient, msg: json.Value, set_pending: bool) void {
        if (msg != .object) return;
        const root = msg.object;
        const msg_type_val = root.get("type") orelse return;
        if (msg_type_val != .string) return;
        if (!std.mem.eql(u8, msg_type_val.string, "event")) return;
        const event_val = root.get("event") orelse return;
        if (event_val != .string) return;

        if (std.mem.eql(u8, event_val.string, "exited") or
            std.mem.eql(u8, event_val.string, "terminated"))
        {
            self.thread_id = -1;
            if (set_pending) {
                self.clear_pending_stopped();
                self.pending_stopped_reason = self.allocator.dupe(u8, event_val.string) catch null;
                self.pending_stopped_description = null;
                self.pending_stopped_thread = 0;
            }
            return;
        }

        if (!std.mem.eql(u8, event_val.string, "stopped")) return;
        const body_val = root.get("body") orelse return;
        if (body_val != .object) return;
        const body = body_val.object;
        const tid_val = body.get("threadId") orelse return;
        self.thread_id = json_to_i64(tid_val);
        if (set_pending) {
            self.clear_pending_stopped();
            if (body.get("reason")) |r_val| {
                if (r_val == .string) {
                    self.pending_stopped_reason = self.allocator.dupe(u8, r_val.string) catch null;
                }
            }
            if (body.get("description")) |d_val| {
                if (d_val == .string) {
                    self.pending_stopped_description = self.allocator.dupe(u8, d_val.string) catch null;
                }
            }
            self.pending_stopped_thread = self.thread_id;
        }
        self.logger.fmt(.debug, "Captured thread_id={}", .{self.thread_id});
    }

    fn try_parse_message(self: *DapClient) !json.Value {
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

        self.parse_arena.deinit();
        self.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        const parsed = json.parseFromSliceLeaky(json.Value, self.parse_arena.allocator(), body, .{}) catch return error.ProtocolError;

        self.read_buf.replaceRange(self.allocator, 0, total, &.{}) catch |e| {
            self.logger.fmt(.err, "replaceRange failed: {s}", .{@errorName(e)});
            return error.ProtocolError;
        };
        return parsed;
    }

    fn read_more(self: *DapClient) !void {
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
