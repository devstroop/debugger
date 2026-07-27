const std = @import("std");
const json = std.json;

pub const SessionState = struct {
    active: bool = false,
    stopped: bool = false,
    stoppedReason: ?[]const u8 = null,
    threadId: i64 = 0,
};

pub fn text_content(text: []const u8) json.Value {
    return json.Value{ .string = text };
}

fn build_text_content(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    const owned = try allocator.dupe(u8, text);
    var arr = json.Array.init(allocator);
    var item = try json.ObjectMap.init(allocator, &.{}, &.{});
    try item.put(allocator, "type", json.Value{ .string = "text" });
    try item.put(allocator, "text", json.Value{ .string = owned });
    try arr.append(json.Value{ .object = item });
    return json.Value{ .array = arr };
}

fn add_state_to_result(result: *json.ObjectMap, allocator: std.mem.Allocator, state: ?SessionState) !void {
    const s = state orelse return;
    try result.put(allocator, "sessionActive", json.Value{ .bool = s.active });
    try result.put(allocator, "stopped", json.Value{ .bool = s.stopped });
    if (s.stoppedReason) |reason| {
        try result.put(allocator, "stoppedReason", json.Value{ .string = reason });
    }
    if (s.threadId != 0) {
        try result.put(allocator, "threadId", json.Value{ .integer = s.threadId });
    }
}

pub fn text_result(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var result = try json.ObjectMap.init(allocator, &.{}, &.{});
    try result.put(allocator, "content", try build_text_content(allocator, text));
    try result.put(allocator, "isError", json.Value{ .bool = false });
    return json.Value{ .object = result };
}

pub fn text_result_with_state(allocator: std.mem.Allocator, text: []const u8, state: ?SessionState) !json.Value {
    var result = try json.ObjectMap.init(allocator, &.{}, &.{});
    try result.put(allocator, "content", try build_text_content(allocator, text));
    try result.put(allocator, "isError", json.Value{ .bool = false });
    try add_state_to_result(&result, allocator, state);
    return json.Value{ .object = result };
}

pub fn error_result(allocator: std.mem.Allocator, message: []const u8) !json.Value {
    var result = try json.ObjectMap.init(allocator, &.{}, &.{});
    try result.put(allocator, "content", try build_text_content(allocator, message));
    try result.put(allocator, "isError", json.Value{ .bool = true });
    return json.Value{ .object = result };
}
