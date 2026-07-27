const std = @import("std");

pub const ArrayList = std.array_list.Managed;

pub fn bufPrint(buf: *ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    var stack_buf: [256]u8 = undefined;
    const written = std.fmt.bufPrint(&stack_buf, fmt, args) catch {
        const s = try std.fmt.allocPrint(buf.allocator, fmt, args);
        defer buf.allocator.free(s);
        try buf.appendSlice(s);
        return;
    };
    try buf.appendSlice(written);
}

pub fn jsonObjectMap(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}
