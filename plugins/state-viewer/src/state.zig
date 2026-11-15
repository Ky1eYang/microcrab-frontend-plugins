const std = @import("std");
const shared = @import("shared");
const allocator = shared.abi.allocator;

pub const StateManager = struct {
    values_json: []const u8,
    metadata_json: []const u8,
    witness: []const u8,
    invocation_id: []const u8,
    loading: bool,
    has_snapshot: bool,
    show_invisible: bool,
    error_msg: []const u8,
    locale: []const u8,

    pub var global: StateManager = .{
        .values_json = "{}",
        .metadata_json = "{}",
        .witness = "",
        .invocation_id = "op-init",
        .loading = false,
        .has_snapshot = false,
        .show_invisible = false,
        .error_msg = "",
        .locale = "zh-CN",
    };

    pub fn initFromContext(ctx_json: []const u8) !void {
        global.loading = true;
        _ = shared.host.session_state.send("state-inspection", "{}");

        if (std.mem.indexOf(u8, ctx_json, "\"locale\":\"en")) |_| {
            global.locale = "en-US";
        } else {
            global.locale = "zh-CN";
        }

        if (extractJsonFieldString(ctx_json, "invocation_id", allocator)) |inv_id| {
            if (inv_id.len > 0) {
                global.invocation_id = inv_id;
            }
        }
    }

    pub fn handleAction(action: []const u8, payload_json: []const u8) ![]const u8 {
        if (std.mem.eql(u8, action, "refresh")) {
            global.loading = true;
            _ = shared.host.session_state.send("state-inspection", "{}");
            return "{\"loading\":true}";
        } else if (std.mem.eql(u8, action, "toggle-invisible")) {
            global.show_invisible = !global.show_invisible;
            return if (global.show_invisible) "{\"show_invisible\":true}" else "{\"show_invisible\":false}";
        } else if (std.mem.eql(u8, action, "save-json")) {
            return try executeSaveJson(payload_json);
        } else if (std.mem.eql(u8, action, "delete-field")) {
            return try executeDeleteField(payload_json);
        }
        return "{}";
    }

    var op_seq: u32 = 1;

    fn getNextOpId(buf: []u8) []const u8 {
        op_seq += 1;
        return std.fmt.bufPrint(buf, "op-{d}", .{op_seq}) catch "op-gen";
    }

    fn executeSaveJson(payload_json: []const u8) ![]const u8 {
        // Extract key, is_new
        const key = extractJsonFieldString(payload_json, "key", allocator) orelse return "{\"error\":\"Missing key\"}";
        const is_new = std.mem.indexOf(u8, payload_json, "\"is_new\":true") != null;

        // Extract value: could be an object, array, or primitive
        const val_str = extractRawValue(payload_json, "value") orelse "null";

        // Generate operation_id
        var op_id_buf: [64]u8 = undefined;
        const op_id = if (global.invocation_id.len > 0 and !std.mem.eql(u8, global.invocation_id, "op-init"))
            global.invocation_id
        else
            getNextOpId(&op_id_buf);

        // Assemble change object
        var change_buf = std.ArrayList(u8).init(allocator);
        defer change_buf.deinit();

        if (is_new) {
            try change_buf.appendSlice("{\"scoped_set\":[{\"name\":");
            try std.json.encodeJsonString(key, .{}, change_buf.writer());
            try change_buf.appendSlice(",\"value\":");
            try change_buf.appendSlice(val_str);
            try change_buf.appendSlice(",\"visibility\":\"visible\",\"persistence\":\"persisted\",\"editors\":[\"agent\",\"client\",\"runtime\"]}]}");
        } else {
            try change_buf.appendSlice("{\"set\":{");
            try std.json.encodeJsonString(key, .{}, change_buf.writer());
            try change_buf.appendSlice(":");
            try change_buf.appendSlice(val_str);
            try change_buf.appendSlice("}}");
        }

        // Assemble exact 3-field state-change payload: operation_id, expected, change
        var req_buf = std.ArrayList(u8).init(allocator);
        defer req_buf.deinit();

        try req_buf.appendSlice("{\"operation_id\":");
        try std.json.encodeJsonString(op_id, .{}, req_buf.writer());
        try req_buf.appendSlice(",\"expected\":");
        try std.json.encodeJsonString(global.witness, .{}, req_buf.writer());
        try req_buf.appendSlice(",\"change\":");
        try req_buf.appendSlice(change_buf.items);
        try req_buf.appendSlice("}");

        const res = shared.host.session_state_write.send("state-change", req_buf.items);
        switch (res) {
            .ok => {
                global.error_msg = "";
                return "{\"status\":\"saved\"}";
            },
            .err => |msg| {
                global.error_msg = allocator.dupe(u8, msg) catch "save failed";
                return "{\"error\":\"save failed\"}";
            },
        }
    }

    fn executeDeleteField(payload_json: []const u8) ![]const u8 {
        const key = extractJsonFieldString(payload_json, "key", allocator) orelse return "{\"error\":\"Missing key\"}";

        var op_id_buf: [64]u8 = undefined;
        const op_id = if (global.invocation_id.len > 0 and !std.mem.eql(u8, global.invocation_id, "op-init"))
            global.invocation_id
        else
            getNextOpId(&op_id_buf);

        var change_buf = std.ArrayList(u8).init(allocator);
        defer change_buf.deinit();

        try change_buf.appendSlice("{\"remove\":[");
        try std.json.encodeJsonString(key, .{}, change_buf.writer());
        try change_buf.appendSlice("]}");

        var req_buf = std.ArrayList(u8).init(allocator);
        defer req_buf.deinit();

        try req_buf.appendSlice("{\"operation_id\":");
        try std.json.encodeJsonString(op_id, .{}, req_buf.writer());
        try req_buf.appendSlice(",\"expected\":");
        try std.json.encodeJsonString(global.witness, .{}, req_buf.writer());
        try req_buf.appendSlice(",\"change\":");
        try req_buf.appendSlice(change_buf.items);
        try req_buf.appendSlice("}");

        const res = shared.host.session_state_write.send("state-change", req_buf.items);
        switch (res) {
            .ok => {
                global.error_msg = "";
                return "{\"status\":\"deleted\"}";
            },
            .err => |msg| {
                global.error_msg = allocator.dupe(u8, msg) catch "delete failed";
                return "{\"error\":\"delete failed\"}";
            },
        }
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
        if (extractJsonFieldString(payload, "witness", allocator)) |w| {
            global.witness = w;
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

fn extractJsonFieldString(json_text: []const u8, field_name: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{field_name}) catch return null;
    const pos = std.mem.indexOf(u8, json_text, pattern) orelse return null;
    var start = pos + pattern.len;
    while (start < json_text.len and (json_text[start] == ' ' or json_text[start] == '\t' or json_text[start] == '\n' or json_text[start] == '\r')) : (start += 1) {}
    if (start >= json_text.len) return null;

    if (json_text[start] == '"') {
        start += 1;
        var end = start;
        var escape = false;
        while (end < json_text.len) : (end += 1) {
            if (escape) {
                escape = false;
                continue;
            }
            if (json_text[end] == '\\') {
                escape = true;
                continue;
            }
            if (json_text[end] == '"') {
                return alloc.dupe(u8, json_text[start..end]) catch null;
            }
        }
    } else {
        var end = start;
        while (end < json_text.len and json_text[end] != ',' and json_text[end] != '}' and json_text[end] != ']') : (end += 1) {}
        return alloc.dupe(u8, std.mem.trim(u8, json_text[start..end], " \t\r\n")) catch null;
    }
    return null;
}

fn extractRawValue(json_text: []const u8, field_name: []const u8) ?[]const u8 {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{field_name}) catch return null;
    const pos = std.mem.indexOf(u8, json_text, pattern) orelse return null;
    var start = pos + pattern.len;
    while (start < json_text.len and (json_text[start] == ' ' or json_text[start] == '\t' or json_text[start] == '\n' or json_text[start] == '\r')) : (start += 1) {}
    if (start >= json_text.len) return null;

    if (json_text[start] == '{') {
        var depth: usize = 0;
        var in_str = false;
        var escape = false;
        for (json_text[start..], 0..) |c, i| {
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
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) return json_text[start .. start + i + 1];
                }
            }
        }
    } else if (json_text[start] == '[') {
        var depth: usize = 0;
        var in_str = false;
        var escape = false;
        for (json_text[start..], 0..) |c, i| {
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
                if (c == '[') depth += 1;
                if (c == ']') {
                    depth -= 1;
                    if (depth == 0) return json_text[start .. start + i + 1];
                }
            }
        }
    } else if (json_text[start] == '"') {
        var end = start + 1;
        var escape = false;
        while (end < json_text.len) : (end += 1) {
            if (escape) {
                escape = false;
                continue;
            }
            if (json_text[end] == '\\') {
                escape = true;
                continue;
            }
            if (json_text[end] == '"') {
                return json_text[start .. end + 1];
            }
        }
    } else {
        var end = start;
        while (end < json_text.len and json_text[end] != ',' and json_text[end] != '}' and json_text[end] != ']') : (end += 1) {}
        return std.mem.trim(u8, json_text[start..end], " \t\r\n");
    }
    return null;
}
