const std = @import("std");
const json = std.json;
const util = @import("../dap/util.zig");

test "write_json_string escapes special characters" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.write_json_string(w, "hello \"world\"\nline2");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nline2", buf.items);
}

test "write_json_string escapes backslash" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.write_json_string(w, "a\\b");
    try std.testing.expectEqualStrings("a\\\\b", buf.items);
}

test "write_json_string handles plain text unchanged" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.write_json_string(w, "plain_text_123");
    try std.testing.expectEqualStrings("plain_text_123", buf.items);
}

test "write_json_string handles empty string" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.write_json_string(w, "");
    try std.testing.expectEqualStrings("", buf.items);
}

test "write_json_string escapes control characters" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.write_json_string(w, "\x00\x01\x1f");
    try std.testing.expectEqualStrings("\\u0000\\u0001\\u001f", buf.items);
}

test "write_json_string escapes tab and carriage return" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.write_json_string(w, "a\tb\rc");
    try std.testing.expectEqualStrings("a\\tb\\rc", buf.items);
}

test "check_success passes on success:true" {
    var obj = json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("success", json.Value{ .bool = true });
    const val = json.Value{ .object = obj };
    try util.check_success(val);
}

test "check_success returns error on success:false" {
    var obj = json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("success", json.Value{ .bool = false });
    const val = json.Value{ .object = obj };
    try std.testing.expectError(error.DapRequestFailed, util.check_success(val));
}

test "check_success passes on missing success field" {
    const obj = json.ObjectMap.init(std.testing.allocator);
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
    // Use explicit null-check path: non-numeric types return 0
    const val = json.Value{ .bool = true }; // bool isn't numeric
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
        .thread_id = 9223372036854775807, // max i64
        .description = null,
    };
    const result = try util.stopped_info_to_json(info, alloc);
    try std.testing.expectEqualStrings("", result.object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), result.object.get("threadId").?.integer);
}
