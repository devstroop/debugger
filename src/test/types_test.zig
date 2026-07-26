const std = @import("std");
const json = std.json;
const types = @import("../mcp/types.zig");

test "textResult returns non-error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try types.textResult(alloc, "hello");
    try std.testing.expect(!result.object.get("isError").?.bool);
    const content = result.object.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), content.items.len);
    const text = content.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("hello", text);
}

test "textResultWithState adds session state fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const state = types.SessionState{
        .active = true,
        .stopped = true,
        .stoppedReason = "breakpoint",
        .threadId = 42,
    };
    const result = try types.textResultWithState(alloc, "paused", state);
    try std.testing.expect(result.object.get("sessionActive").?.bool);
    try std.testing.expect(result.object.get("stopped").?.bool);
    try std.testing.expectEqualStrings("breakpoint", result.object.get("stoppedReason").?.string);
    try std.testing.expectEqual(@as(i64, 42), result.object.get("threadId").?.integer);
}

test "textResultWithState with null state omits fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try types.textResultWithState(alloc, "no state", null);
    try std.testing.expect(result.object.get("sessionActive") == null);
}

test "errorResult returns isError=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try types.errorResult(alloc, "something went wrong");
    try std.testing.expect(result.object.get("isError").?.bool);
    const content = result.object.get("content").?.array;
    const text = content.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("something went wrong", text);
}

test "textContent returns a simple string value" {
    const result = types.textContent("just a string");
    try std.testing.expectEqualStrings("just a string", result.string);
}
