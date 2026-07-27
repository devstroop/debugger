const std = @import("std");
const compat = @import("../compat.zig");
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

const dap_timeout_ms: u64 = 15_000; // timeout in ms (converted to ns at nanosecond call sites)
const poll_ms: u64 = 300; // poll interval in ms

const ManagedWriter = struct {
    buf: *compat.ArrayList(u8),
    pub fn writeAll(self: @This(), data: []const u8) !void {
        try self.buf.appendSlice(data);
    }
    pub fn writeByte(self: @This(), byte: u8) !void {
        try self.buf.append(byte);
    }
    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        try compat.bufPrint(self.buf, fmt, args);
    }
};

pub const DapClient = struct {
    allocator: std.mem.Allocator,
    logger: *const log_mod.Logger,
    adapter_path: []const u8,
    io: std.Io,

    proc: ?std.process.Child = null,
    conn: ?std.Io.net.Stream = null,
    seq: i64 = 1,
    launch_seq: i64 = 0,
    thread_id: i64 = -1,
    started: bool = false,
    pending_stopped_reason: ?[]const u8 = null,
    pending_stopped_description: ?[]const u8 = null,
    pending_stopped_thread: i64 = 0,
    read_buf: compat.ArrayList(u8),
    parse_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, logger: *const log_mod.Logger, adapter_path: []const u8) DapClient {
        return .{
            .allocator = allocator,
            .logger = logger,
            .adapter_path = adapter_path,
            .io = std.Options.debug_io,
            .read_buf = compat.ArrayList(u8).init(allocator),
            .parse_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DapClient) void {
        self.disconnect();
        self.read_buf.deinit();
        self.parse_arena.deinit();
    }

    pub fn connect(self: *DapClient) !void {
        self.logger.info("Spawning adapter...");

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ self.adapter_path, "--port", "0" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        const pid: u32 = @intCast(child.id orelse {
            child.kill(self.io);
            return error.InvalidSpawn;
        });
        self.proc = child;

        self.logger.fmt(.info, "Spawned pid={}, discovering port...", .{pid});

        const port = self.discover_port(pid) catch |err| {
            if (self.proc) |*p| p.kill(self.io);
            self.proc = null;
            return err;
        };

        self.logger.fmt(.info, "Discovered port {}, connecting...", .{port});

        var addr_buf: [32]u8 = undefined;
        const addr_str = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});
        const address = try std.Io.net.IpAddress.parseLiteral(addr_str);
        const conn = std.Io.net.IpAddress.connect(&address, self.io, .{ .mode = .stream }) catch |err| {
            if (self.proc) |*p| p.kill(self.io);
            self.proc = null;
            return err;
        };
        self.conn = conn;
        self.logger.info("TCP connected");
    }

    pub fn disconnect(self: *DapClient) void {
        if (self.conn) |c| {
            c.close(self.io);
            self.conn = null;
        }
        if (self.proc) |*child| {
            child.kill(self.io);
            self.proc = null;
        }
    }

    pub fn initialize(self: *DapClient) !void {
        const resp = try self.send("initialize", "{\"clientID\":\"debugger\",\"adapterID\":\"lldb\"}");
        try check_success(resp);
        self.logger.info("DAP initialized");
    }

    pub fn launch(self: *DapClient, program: []const u8, cwd: []const u8) !void {
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try args.appendSlice("{\"program\":\"");
        try write_json_string(ManagedWriter{ .buf = &args }, program);
        try args.appendSlice("\",\"cwd\":\"");
        try write_json_string(ManagedWriter{ .buf = &args }, cwd);
        try args.appendSlice("\",\"type\":\"lldb\",\"request\":\"launch\",\"stopOnEntry\":false}");

        const seq = self.seq;
        self.seq += 1;
        self.launch_seq = seq;
        try self.write_frame("launch", seq, args.items);

        const start = std.Io.Clock.Timestamp.now(self.io, .awake);
        while (true) {
            const now = std.Io.Clock.Timestamp.now(self.io, .awake);
            const elapsed = start.durationTo(now).raw.nanoseconds;
            if (elapsed > dap_timeout_ms * std.time.ns_per_ms) return error.Timeout;

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
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try args.appendSlice("{\"source\":{\"path\":\"");
        try write_json_string(ManagedWriter{ .buf = &args }, file_path);
        try args.appendSlice("\"},\"breakpoints\":[");
        for (breakpoints, 0..) |bp, i| {
            if (i > 0) try args.append(',');
            try args.appendSlice("{\"line\":");
            try compat.bufPrint(&args, "{}", .{bp.line});
            if (bp.condition) |c| {
                try args.appendSlice(",\"condition\":\"");
                try write_json_string(ManagedWriter{ .buf = &args }, c);
                try args.appendSlice("\"");
            }
            if (bp.log_message) |lm| {
                try args.appendSlice(",\"logMessage\":\"");
                try write_json_string(ManagedWriter{ .buf = &args }, lm);
                try args.appendSlice("\"");
            }
            try args.appendSlice("}");
        }
        try args.appendSlice("]}");
        return self.send("setBreakpoints", args.items);
    }

    pub fn set_function_breakpoints(self: *DapClient, names: []const []const u8) !json.Value {
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try args.appendSlice("{\"breakpoints\":[");
        for (names, 0..) |name, i| {
            if (i > 0) try args.append(',');
            try args.appendSlice("{\"name\":\"");
            try write_json_string(ManagedWriter{ .buf = &args }, name);
            try args.appendSlice("\"}");
        }
        try args.appendSlice("]}");
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
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("next", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn step_in(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("stepIn", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn step_out(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("stepOut", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn pause_exec(self: *DapClient) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"threadId\":{}}}", .{self.thread_id});
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
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"threadId\":{}}}", .{self.thread_id});
        const resp = try self.send("continue", args.items);
        try check_success(resp);
        const stopped = try self.wait_for_stopped();
        return stopped_info_to_json(stopped, self.allocator);
    }

    pub fn stack_trace(self: *DapClient, start_frame: i64, levels: i64) !json.Value {
        self.clear_pending_stopped();
        _ = self.process_pending_events() catch {};
        if (self.thread_id < 0) return error.InvalidThreadId;
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"threadId\":{},\"startFrame\":{},\"levels\":{}}}", .{ self.thread_id, start_frame, levels });
        return self.send("stackTrace", args.items);
    }

    pub fn scopes(self: *DapClient, frame_id: i64) !json.Value {
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"frameId\":{}}}", .{frame_id});
        return self.send("scopes", args.items);
    }

    pub fn variables(self: *DapClient, var_ref: i64) !json.Value {
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try compat.bufPrint(&args, "{{\"variablesReference\":{}}}", .{var_ref});
        return self.send("variables", args.items);
    }

    pub fn evaluate(self: *DapClient, expression: []const u8, context: []const u8, frame_id: ?i64) !json.Value {
        var args = compat.ArrayList(u8).init(self.allocator);
        defer args.deinit();
        try args.appendSlice("{\"expression\":\"");
        try write_json_string(ManagedWriter{ .buf = &args }, expression);
        try args.appendSlice("\",\"context\":\"");
        try write_json_string(ManagedWriter{ .buf = &args }, context);
        try args.appendSlice("\"");
        if (frame_id) |fid| {
            try args.appendSlice(",\"frameId\":");
            try compat.bufPrint(&args, "{}", .{fid});
        }
        try args.appendSlice("}");
        return self.send("evaluate", args.items);
    }

    // ── Low-level protocol ────────────────────────────────────────

    fn discover_port(self: *DapClient, pid: u32) !u16 {
        var elapsed: u64 = 0;
        while (elapsed < dap_timeout_ms) {
            std.Io.sleep(self.io, .{ .nanoseconds = poll_ms * std.time.ns_per_ms }, .awake) catch |err| {
                self.logger.fmt(.debug, "sleep failed: {s}", .{@errorName(err)});
            };
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

        var body = compat.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        try body.appendSlice("{\"seq\":");
        try compat.bufPrint(&body, "{}", .{seq});
        try body.appendSlice(",\"type\":\"request\",\"command\":\"");
        try write_json_string(ManagedWriter{ .buf = &body }, command);
        try body.appendSlice("\"");
        if (args_msg) |a| {
            try body.appendSlice(",\"arguments\":");
            try body.appendSlice(a);
        }
        try body.appendSlice("}");

        var frame = compat.ArrayList(u8).init(self.allocator);
        defer frame.deinit();
        try write_frame_content(&frame, body.items);

        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(self.io, &wbuf);
        try writer.interface.writeAll(frame.items);

        return self.read_response(seq);
    }

    fn write_frame(self: *DapClient, command: []const u8, seq: i64, args_msg: ?[]const u8) !void {
        const conn = self.conn orelse return error.NotConnected;
        var body = compat.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        try body.appendSlice("{\"seq\":");
        try compat.bufPrint(&body, "{}", .{seq});
        try body.appendSlice(",\"type\":\"request\",\"command\":\"");
        try write_json_string(ManagedWriter{ .buf = &body }, command);
        try body.appendSlice("\"");
        if (args_msg) |a| {
            try body.appendSlice(",\"arguments\":");
            try body.appendSlice(a);
        }
        try body.appendSlice("}");

        var frame = compat.ArrayList(u8).init(self.allocator);
        defer frame.deinit();
        try write_frame_content(&frame, body.items);

        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(self.io, &wbuf);
        try writer.interface.writeAll(frame.items);
    }

    fn write_frame_content(fw: *compat.ArrayList(u8), body: []const u8) !void {
        try fw.appendSlice("Content-Length: ");
        try compat.bufPrint(fw, "{}", .{body.len});
        try fw.appendSlice("\r\n\r\n");
        try fw.appendSlice(body);
    }

    fn read_response(self: *DapClient, expected_seq: i64) !json.Value {
        const start = std.Io.Clock.Timestamp.now(self.io, .awake);
        while (true) {
            const now = std.Io.Clock.Timestamp.now(self.io, .awake);
            const elapsed = start.durationTo(now).raw.nanoseconds;
            if (elapsed > dap_timeout_ms * std.time.ns_per_ms) return error.Timeout;

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
        const start = std.Io.Clock.Timestamp.now(self.io, .awake);
        while (true) {
            const now = std.Io.Clock.Timestamp.now(self.io, .awake);
            if (start.durationTo(now).raw.nanoseconds > stop_timeout_ns) return error.Timeout;

            const msg = self.try_parse_message() catch |err| {
                if (err == error.NeedMoreData) {
                    const prev_len = self.read_buf.items.len;
                    self.read_more() catch |read_err| {
                        if (read_err == error.Timeout) {
                            std.Io.sleep(self.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch |e| {
                                self.logger.fmt(.debug, "sleep failed: {s}", .{@errorName(e)});
                            };
                            continue;
                        }
                        return read_err;
                    };
                    if (self.read_buf.items.len == prev_len) {
                        std.Io.sleep(self.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch |e| {
                            self.logger.fmt(.debug, "sleep failed: {s}", .{@errorName(e)});
                        };
                    }
                    continue;
                }
                if (err == error.ProtocolError) {
                    self.read_buf.clearAndFree();
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
                std.Io.sleep(self.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch |e| {
                    self.logger.fmt(.debug, "sleep failed: {s}", .{@errorName(e)});
                };
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
        var keep = compat.ArrayList(u8).init(self.allocator);
        var temp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer {
            temp_arena.deinit();
            keep.deinit();
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
                keep.appendSlice(data[0..total]) catch break;
            } else {
                self.capture_stopped_thread_id(parsed, false);
            }
            data = data[total..];
        }
        const remaining = try self.allocator.dupe(u8, data);
        defer self.allocator.free(remaining);
        self.read_buf.clearRetainingCapacity();
        try self.read_buf.appendSlice(keep.items);
        try self.read_buf.appendSlice(remaining);
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

        self.read_buf.replaceRange(0, total, &.{}) catch |e| {
            self.logger.fmt(.err, "replaceRange failed: {s}", .{@errorName(e)});
            return error.ProtocolError;
        };
        return parsed;
    }

    fn read_more(self: *DapClient) !void {
        const handle = (self.conn orelse return error.NotConnected).socket.handle;
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const rc = std.posix.poll(&poll_fds, 100);
        if (rc catch 0 == 0) return error.Timeout;
        if ((rc catch 0) < 0) return error.ReadError;

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            var buf: [4096]u8 = undefined;
            const conn = &(self.conn orelse return error.NotConnected);
            const n = std.posix.read(conn.socket.handle, &buf) catch |err| {
                if (err == error.WouldBlock) return error.Timeout;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            try self.read_buf.appendSlice(buf[0..n]);
        } else if (poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
            return error.ConnectionClosed;
        }
    }
};
