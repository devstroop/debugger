const std = @import("std");
const json = std.json;
const util = @import("../dap/util.zig");
const compat = @import("../compat.zig");

const TestWriter = struct {
    buf: *compat.ArrayList(u8),
    pub fn writeAll(self: TestWriter, data: []const u8) !void { try self.buf.appendSlice(data); }
    pub fn writeByte(self: TestWriter, byte: u8) !void { try self.buf.append(byte); }
    pub fn print(self: TestWriter, comptime fmt: []const u8, args: anytype) !void {
        try compat.bufPrint(self.buf, fmt, args);
    }
};

fn testWriteJsonString(input: []const u8, expected: []const u8) !void {
    var buf = compat.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try util.write_json_string(TestWriter{ .buf = &buf }, input);
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "write_json_string escapes special characters" {
    try testWriteJsonString("hello \"world\"\nline2", "hello \\\"world\\\"\\nline2");
}

test "write_json_string escapes backslash" {
    try testWriteJsonString("a\\b", "a\\\\b");
}

test "write_json_string handles plain text unchanged" {
    try testWriteJsonString("plain_text_123", "plain_text_123");
}

test "write_json_string handles empty string" {
    try testWriteJsonString("", "");
}

test "write_json_string escapes control characters" {
    try testWriteJsonString("\x00\x01\x1f", "\\u0000\\u0001\\u001f");
}

test "write_json_string escapes tab and carriage return" {
    try testWriteJsonString("a\tb\rc", "a\\tb\\rc");
}

fn makeObj() !json.ObjectMap {
    return try compat.jsonObjectMap(std.testing.allocator);
}

fn putObj(obj: *json.ObjectMap, key: []const u8, val: json.Value) !void {
    try obj.put(std.testing.allocator, key, val);
}

test "check_success passes on success:true" {
    var obj = try makeObj();
    defer obj.deinit(std.testing.allocator);
    try putObj(&obj, "success", json.Value{ .bool = true });
    const val = json.Value{ .object = obj };
    try util.check_success(val);
}

test "check_success returns error on success:false" {
    var obj = try makeObj();
    defer obj.deinit(std.testing.allocator);
    try putObj(&obj, "success", json.Value{ .bool = false });
    const val = json.Value{ .object = obj };
    try std.testing.expectError(error.DapRequestFailed, util.check_success(val));
}

test "check_success passes on missing success field" {
    var obj = try compat.jsonObjectMap(std.testing.allocator);
    defer obj.deinit(std.testing.allocator);
    const val = json.Value{ .object = obj };
    try util.check_success(val);
}

test "json_to_i64 with integer value" {
    const val = json.Value{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), util.json_to_i64(val));
}

test "json_to_i64 with float value" {
    const val = json.Value{ .float = 3.14 };
    try std.testing.expectEqual(@as(i64, 3), util.json_to_i64(val));
}

test "json_to_i64 with negative integer" {
    const val = json.Value{ .integer = -10 };
    try std.testing.expectEqual(@as(i64, -10), util.json_to_i64(val));
}

test "json_to_i64 with other type defaults to 0" {
    const val = json.Value{ .string = "not a number" };
    try std.testing.expectEqual(@as(i64, 0), util.json_to_i64(val));
}

test "json_to_i64 with null defaults to 0" {
    const val = json.Value{ .bool = true };
    try std.testing.expectEqual(@as(i64, 0), util.json_to_i64(val));
}

test "stopped_info_to_json produces correct JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const info = util.types.StoppedInfo{
        .reason = "breakpoint",
        .thread_id = 7,
        .description = "hit breakpoint at main",
    };
    const result = try util.stopped_info_to_json(info, alloc);
    try std.testing.expectEqualStrings("breakpoint", result.object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 7), result.object.get("threadId").?.integer);
    try std.testing.expectEqualStrings("hit breakpoint at main", result.object.get("description").?.string);
}

test "stopped_info_to_json handles null description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const info = util.types.StoppedInfo{
        .reason = "step",
        .thread_id = 0,
        .description = null,
    };
    const result = try util.stopped_info_to_json(info, alloc);
    try std.testing.expectEqualStrings("step", result.object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 0), result.object.get("threadId").?.integer);
    try std.testing.expect(result.object.get("description") == null);
}

test "stopped_info_to_json handles empty reason and large threadId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const info = util.types.StoppedInfo{
        .reason = "",
        .thread_id = 9223372036854775807,
        .description = null,
    };
    const result = try util.stopped_info_to_json(info, alloc);
    try std.testing.expectEqualStrings("", result.object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), result.object.get("threadId").?.integer);
}
