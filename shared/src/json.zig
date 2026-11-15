const std = @import("std");

pub fn createEnvelope(allocator: std.mem.Allocator, html: []const u8, view_state_json: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try list.appendSlice("{\"html\":");
    try std.json.encodeJsonString(html, .{}, list.writer());
    try list.appendSlice(",\"view_state\":");
    if (view_state_json.len == 0) {
        try list.appendSlice("null");
    } else {
        try list.appendSlice(view_state_json);
    }
    try list.appendSlice("}");
    return list.toOwnedSlice();
}
