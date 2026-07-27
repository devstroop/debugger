const std = @import("std");
const json = std.json;
const builtin = @import("builtin");
const compat = @import("../compat.zig");
pub const types = @import("types.zig");

pub fn stopped_info_to_json(info: types.StoppedInfo, allocator: std.mem.Allocator) !json.Value {
    var obj = try compat.jsonObjectMap(allocator);
    try obj.put(allocator, "reason", json.Value{ .string = try allocator.dupe(u8, info.reason) });
    try obj.put(allocator, "threadId", json.Value{ .integer = info.thread_id });
    if (info.description) |d| {
        try obj.put(allocator, "description", json.Value{ .string = try allocator.dupe(u8, d) });
    }
    return json.Value{ .object = obj };
}

pub fn find_port_for_pid(pid: u32) !u16 {
    const allocator = std.heap.page_allocator;

    // macOS uses `lsof`, Linux uses `ss`.
    const argv = if (comptime builtin.target.os.tag == .macos)
        &.{ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pfn" }
    else
        &.{ "ss", "-tlnp" };

    const io = std.Options.debug_io;
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch {
        if (comptime builtin.target.os.tag == .macos) return error.LsofFailed;
        return error.SsFailed;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (comptime builtin.target.os.tag == .macos) {
        return find_port_macos(result.stdout, pid);
    } else {
        return find_port_linux(result.stdout, pid);
    }
}

fn find_port_linux(stdout: []const u8, pid: u32) !u16 {
    const pid_str = try std.fmt.allocPrint(std.heap.page_allocator, "pid={},", .{pid});
    defer std.heap.page_allocator.free(pid_str);

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, pid_str) == null) continue;
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
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse continue;
        const port_str = addr[colon + 1 ..];
        return std.fmt.parseInt(u16, port_str, 10);
    }
    return error.PortNotFound;
}

fn find_port_macos(stdout: []const u8, pid: u32) !u16 {
    const pid_str = try std.fmt.allocPrint(std.heap.page_allocator, "{}", .{pid});
    defer std.heap.page_allocator.free(pid_str);

    // lsof -F output: pPID\nfFD\nnADDRESS\n  e.g. p12345\nf26\nn127.0.0.1:8080\n
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var found_pid = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == 'p' and std.mem.eql(u8, line[1..], pid_str)) {
            found_pid = true;
            continue;
        }
        if (found_pid and line.len > 1 and line[0] == 'n') {
            const addr = line[1..];
            const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse continue;
            const port_str = addr[colon + 1 ..];
            if (port_str.len > 0 and port_str[0] != '*') {
                return std.fmt.parseInt(u16, port_str, 10);
            }
        }
    }
    return error.PortNotFound;
}

pub fn write_json_string(w: anytype, s: []const u8) !void {
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

pub fn check_success(response: json.Value) !void {
    if (response.object.get("success")) |s| {
        if (!s.bool) return error.DapRequestFailed;
    }
}

pub fn json_to_i64(val: json.Value) i64 {
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}
