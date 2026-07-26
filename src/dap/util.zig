const std = @import("std");
const json = std.json;
pub const types = @import("types.zig");

pub fn stoppedInfoToJson(info: types.StoppedInfo, allocator: std.mem.Allocator) !json.Value {
    var obj = json.ObjectMap.init(allocator);
    try obj.put("reason", json.Value{ .string = try allocator.dupe(u8, info.reason) });
    try obj.put("threadId", json.Value{ .integer = info.thread_id });
    if (info.description) |d| {
        try obj.put("description", json.Value{ .string = try allocator.dupe(u8, d) });
    }
    return json.Value{ .object = obj };
}

pub fn findPortForPid(pid: u32) !u16 {
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

pub fn writeJsonString(w: anytype, s: []const u8) !void {
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

pub fn checkSuccess(response: json.Value) !void {
    if (response.object.get("success")) |s| {
        if (!s.bool) return error.DapRequestFailed;
    }
}

pub fn jsonToI64(val: json.Value) i64 {
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}
