const std = @import("std");
const json = std.json;
const types = @import("../mcp/types.zig");
const dap_types = @import("../dap/types.zig");

// ── MCP types tests ──

test "text_result returns non-error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try types.text_result(alloc, "hello");
    try std.testing.expect(!result.object.get("isError").?.bool);
    const content = result.object.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), content.items.len);
    const text = content.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("hello", text);
}

test "text_result_with_state adds session state fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const state = types.SessionState{
        .active = true,
        .stopped = true,
        .stoppedReason = "breakpoint",
        .threadId = 42,
    };
    const result = try types.text_result_with_state(alloc, "paused", state);
    try std.testing.expect(result.object.get("sessionActive").?.bool);
    try std.testing.expect(result.object.get("stopped").?.bool);
    try std.testing.expectEqualStrings("breakpoint", result.object.get("stoppedReason").?.string);
    try std.testing.expectEqual(@as(i64, 42), result.object.get("threadId").?.integer);
}

test "text_result_with_state with null state omits fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try types.text_result_with_state(alloc, "no state", null);
    try std.testing.expect(result.object.get("sessionActive") == null);
}

test "error_result returns isError=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try types.error_result(alloc, "something went wrong");
    try std.testing.expect(result.object.get("isError").?.bool);
    const content = result.object.get("content").?.array;
    const text = content.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("something went wrong", text);
}

test "text_content returns a simple string value" {
    const result = types.text_content("just a string");
    try std.testing.expectEqualStrings("just a string", result.string);
}

// ── DAP types tests ──

test "DapBreakpoint default fields" {
    const bp = dap_types.DapBreakpoint{
        .line = 42,
    };
    try std.testing.expectEqual(@as(u32, 42), bp.line);
    try std.testing.expect(bp.condition == null);
    try std.testing.expect(bp.log_message == null);
}

test "DapBreakpoint with condition and logMessage" {
    const bp = dap_types.DapBreakpoint{
        .line = 10,
        .condition = "i > 5",
        .log_message = "hit line 10",
    };
    try std.testing.expectEqual(@as(u32, 10), bp.line);
    try std.testing.expectEqualStrings("i > 5", bp.condition.?);
    try std.testing.expectEqualStrings("hit line 10", bp.log_message.?);
}

test "StoppedInfo required fields" {
    const info = dap_types.StoppedInfo{
        .reason = "breakpoint",
        .thread_id = 7,
    };
    try std.testing.expectEqualStrings("breakpoint", info.reason);
    try std.testing.expectEqual(@as(i64, 7), info.thread_id);
    try std.testing.expect(info.description == null);
}

test "StoppedInfo with description" {
    const info = dap_types.StoppedInfo{
        .reason = "step",
        .thread_id = 42,
        .description = "step complete",
    };
    try std.testing.expectEqualStrings("step", info.reason);
    try std.testing.expectEqual(@as(i64, 42), info.thread_id);
    try std.testing.expectEqualStrings("step complete", info.description.?);
}

// Error set is implicitly tested by the compiler; no dedicated test needed.
