const std = @import("std");
const shared = @import("shared");
const allocator = shared.abi.allocator;

pub const StateManager = struct {
    values_json: []const u8,
    metadata_json: []const u8,
    loading: bool,
    has_snapshot: bool,
    show_invisible: bool,
    error_msg: []const u8,
    locale: []const u8,

    pub var global: StateManager = .{
        .values_json = "{}",
        .metadata_json = "{}",
        .loading = false,
        .has_snapshot = false,
        .show_invisible = false,
        .error_msg = "",
        .locale = "zh-CN",
    };

    pub fn initFromContext(ctx_json: []const u8) !void {
        global.loading = true;
        _ = shared.host.session_state.send("inspect", "{}");
        if (std.mem.indexOf(u8, ctx_json, "\"locale\":\"en")) |_| {
            global.locale = "en-US";
        } else {
            global.locale = "zh-CN";
        }
    }

    pub fn handleAction(action: []const u8, payload_json: []const u8) ![]const u8 {
        if (std.mem.eql(u8, action, "refresh")) {
            global.loading = true;
            _ = shared.host.session_state.send("inspect", "{}");
            return "{\"loading\":true}";
        } else if (std.mem.eql(u8, action, "toggle-invisible")) {
            global.show_invisible = !global.show_invisible;
            return if (global.show_invisible) "{\"show_invisible\":true}" else "{\"show_invisible\":false}";
        } else if (std.mem.eql(u8, action, "save-json")) {
            const res = shared.host.session_state_write.send("mutate", payload_json);
            switch (res) {
                .ok => return "{\"status\":\"saved\"}",
                .err => |msg| {
                    global.error_msg = msg;
                    return "{\"error\":\"save failed\"}";
                },
            }
        }
        return "{}";
    }

    pub fn handlePhase(phase: []const u8, payload_json: []const u8) ![]const u8 {
        if (std.mem.eql(u8, phase, "event-result")) {
            global.loading = false;
            global.has_snapshot = true;
            updateFromInspectPayload(payload_json);
            return "{\"loading\":false,\"has_snapshot\":true}";
        }
        return "{}";
    }

    fn updateFromInspectPayload(payload: []const u8) void {
        if (std.mem.indexOf(u8, payload, "\"values\":")) |pos| {
            const start = pos + 9;
            if (findJsonObjectEnd(payload[start..])) |len| {
                global.values_json = allocator.dupe(u8, payload[start .. start + len]) catch "{}";
            }
        }
        if (std.mem.indexOf(u8, payload, "\"metadata\":")) |pos| {
            const start = pos + 11;
            if (findJsonObjectEnd(payload[start..])) |len| {
                global.metadata_json = allocator.dupe(u8, payload[start .. start + len]) catch "{}";
            }
        }
    }

    fn findJsonObjectEnd(slice: []const u8) ?usize {
        var depth: usize = 0;
        var in_str = false;
        var escape = false;
        var started = false;
        for (slice, 0..) |c, i| {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') {
                in_str = !in_str;
                continue;
            }
            if (!in_str) {
                if (c == '{') {
                    depth += 1;
                    started = true;
                } else if (c == '}') {
                    if (depth > 0) depth -= 1;
                    if (started and depth == 0) return i + 1;
                }
            }
        }
        return null;
    }

    pub fn buildViewStateJson(alloc: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(alloc);
        errdefer list.deinit();

        try list.appendSlice("{\"values\":");
        try list.appendSlice(if (global.values_json.len == 0) "{}" else global.values_json);
        try list.appendSlice(",\"metadata\":");
        try list.appendSlice(if (global.metadata_json.len == 0) "{}" else global.metadata_json);
        try list.appendSlice(",\"loading\":");
        try list.appendSlice(if (global.loading) "true" else "false");
        try list.appendSlice(",\"has_snapshot\":");
        try list.appendSlice(if (global.has_snapshot) "true" else "false");
        try list.appendSlice(",\"show_invisible\":");
        try list.appendSlice(if (global.show_invisible) "true" else "false");
        try list.appendSlice(",\"locale\":");
        try std.json.encodeJsonString(global.locale, .{}, list.writer());
        try list.appendSlice(",\"error\":");
        try std.json.encodeJsonString(global.error_msg, .{}, list.writer());
        try list.appendSlice("}");

        return list.toOwnedSlice();
    }
};
