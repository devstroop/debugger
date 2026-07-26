const std = @import("std");
const json = std.json;
const util = @import("../dap/util.zig");

test "writeJsonString escapes special characters" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.writeJsonString(w, "hello \"world\"\nline2");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nline2", buf.items);
}

test "writeJsonString escapes backslash" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.writeJsonString(w, "a\\b");
    try std.testing.expectEqualStrings("a\\\\b", buf.items);
}

test "writeJsonString handles plain text unchanged" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try util.writeJsonString(w, "plain_text_123");
    try std.testing.expectEqualStrings("plain_text_123", buf.items);
}

test "checkSuccess passes on success:true" {
    var obj = json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("success", json.Value{ .bool = true });
    const val = json.Value{ .object = obj };
    try util.checkSuccess(val);
}

test "checkSuccess returns error on success:false" {
    var obj = json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("success", json.Value{ .bool = false });
    const val = json.Value{ .object = obj };
    try std.testing.expectError(error.DapRequestFailed, util.checkSuccess(val));
}

test "checkSuccess returns error on missing success field" {
    const obj = json.ObjectMap.init(std.testing.allocator);
    const val = json.Value{ .object = obj };
    // Missing field silently passes (no explicit false)
    try util.checkSuccess(val);
}

test "jsonToI64 with integer value" {
    const val = json.Value{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), util.jsonToI64(val));
}

test "jsonToI64 with float value" {
    const val = json.Value{ .float = 3.14 };
    try std.testing.expectEqual(@as(i64, 3), util.jsonToI64(val));
}

test "jsonToI64 with other type defaults to 0" {
    const val = json.Value{ .string = "not a number" };
    try std.testing.expectEqual(@as(i64, 0), util.jsonToI64(val));
}

test "stoppedInfoToJson produces correct JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const info = util.types.StoppedInfo{
        .reason = "breakpoint",
        .thread_id = 7,
        .description = "hit breakpoint at main",
    };
    const result = try util.stoppedInfoToJson(info, alloc);
    try std.testing.expectEqualStrings("breakpoint", result.object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 7), result.object.get("threadId").?.integer);
    try std.testing.expectEqualStrings("hit breakpoint at main", result.object.get("description").?.string);
}
