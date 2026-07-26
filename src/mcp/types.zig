const std = @import("std");
const json = std.json;

pub fn textContent(text: []const u8) json.Value {
    return json.Value{ .string = text };
}

pub fn textResult(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    // Build proper MCP result: {"content":[{"type":"text","text":"..."}],"isError":false}
    var content_arr = json.Array.init(allocator);
    var item = json.ObjectMap.init(allocator);
    try item.put("type", json.Value{ .string = "text" });
    try item.put("text", json.Value{ .string = text });
    try content_arr.append(json.Value{ .object = item });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", json.Value{ .array = content_arr });
    try result.put("isError", json.Value{ .bool = false });
    return json.Value{ .object = result };
}

pub fn errorResult(allocator: std.mem.Allocator, message: []const u8) !json.Value {
    var content_arr = json.Array.init(allocator);
    var item = json.ObjectMap.init(allocator);
    try item.put("type", json.Value{ .string = "text" });
    try item.put("text", json.Value{ .string = message });
    try content_arr.append(json.Value{ .object = item });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", json.Value{ .array = content_arr });
    try result.put("isError", json.Value{ .bool = true });
    return json.Value{ .object = result };
}
