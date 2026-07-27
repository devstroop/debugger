const std = @import("std");

pub const ArrayList = std.array_list.Managed;

pub fn bufPrint(buf: *ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(buf.allocator, fmt, args);
    defer buf.allocator.free(s);
    try buf.appendSlice(s);
}
