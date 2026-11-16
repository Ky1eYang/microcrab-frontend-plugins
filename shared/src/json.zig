const std = @import("std");

/// Zig 0.13's dynamic Value parser ignores duplicate_field_behavior. Keep one
/// bounded scanner implementation for guests and publication metadata. MCP pins
/// retain numeric lexemes; State and installer request IDs also expose integers.
pub fn UniqueValue(comptime parse_integers: bool) type {
    return struct {
        value: std.json.Value,
        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return .{ .value = try readValue(a, source, options, 0) };
        }
        fn readValue(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions, depth: usize) std.json.ParseError(@TypeOf(source.*))!std.json.Value {
            if (depth > 128) return error.UnexpectedToken;
            const token = try source.nextAllocMax(a, .alloc_always, options.max_value_len.?);
            return switch (token) {
                .null => .null,
                .true => .{ .bool = true },
                .false => .{ .bool = false },
                .allocated_string => |s| .{ .string = s },
                .allocated_number => |s| blk: {
                    if (parse_integers) {
                        if (std.fmt.parseInt(i64, s, 10)) |n| break :blk .{ .integer = n } else |_| {}
                    }
                    break :blk .{ .number_string = s };
                },
                .array_begin => blk: {
                    var items = std.json.Array.init(a);
                    while (try source.peekNextTokenType() != .array_end) try items.append(try readValue(a, source, options, depth + 1));
                    _ = try source.next();
                    break :blk .{ .array = items };
                },
                .object_begin => blk: {
                    var map = std.json.ObjectMap.init(a);
                    while (true) {
                        const next = try source.nextAllocMax(a, .alloc_always, options.max_value_len.?);
                        if (next == .object_end) break;
                        const key = switch (next) {
                            .allocated_string => |s| s,
                            else => return error.UnexpectedToken,
                        };
                        if (map.contains(key)) return error.DuplicateField;
                        try map.put(key, try readValue(a, source, options, depth + 1));
                    }
                    break :blk .{ .object = map };
                },
                else => error.UnexpectedToken,
            };
        }
    };
}

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
