const std = @import("std");
const json = std.json;

/// Session state for structured tool results
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
    var item = json.ObjectMap.init(allocator);
    try item.put("type", json.Value{ .string = "text" });
    try item.put("text", json.Value{ .string = owned });
    try arr.append(json.Value{ .object = item });
    return json.Value{ .array = arr };
}

fn add_state_to_result(result: *json.ObjectMap, state: ?SessionState) !void {
    const s = state orelse return;
    try result.put("sessionActive", json.Value{ .bool = s.active });
    try result.put("stopped", json.Value{ .bool = s.stopped });
    if (s.stoppedReason) |reason| {
        try result.put("stoppedReason", json.Value{ .string = reason });
    }
    if (s.threadId != 0) {
        try result.put("threadId", json.Value{ .integer = s.threadId });
    }
}

pub fn text_result(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var result = json.ObjectMap.init(allocator);
    try result.put("content", try build_text_content(allocator, text));
    try result.put("isError", json.Value{ .bool = false });
    return json.Value{ .object = result };
}

pub fn text_result_with_state(allocator: std.mem.Allocator, text: []const u8, state: ?SessionState) !json.Value {
    var result = json.ObjectMap.init(allocator);
    try result.put("content", try build_text_content(allocator, text));
    try result.put("isError", json.Value{ .bool = false });
    try add_state_to_result(&result, state);
    return json.Value{ .object = result };
}

pub fn error_result(allocator: std.mem.Allocator, message: []const u8) !json.Value {
    var result = json.ObjectMap.init(allocator);
    try result.put("content", try build_text_content(allocator, message));
    try result.put("isError", json.Value{ .bool = true });
    return json.Value{ .object = result };
}
