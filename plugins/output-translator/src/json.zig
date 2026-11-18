const std = @import("std");
pub const Value = std.json.Value;
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Value {
    if (bytes.len > 768 * 1024) return error.JsonByteBudgetExceeded;
    return (try std.json.parseFromSliceLeaky(@import("shared").json.UniqueValue(true), a, bytes, .{ .allocate = .alloc_always, .max_value_len = 768 * 1024 })).value;
}
pub fn object(a: std.mem.Allocator) Value {
    return .{ .object = std.json.ObjectMap.init(a) };
}
pub fn array(a: std.mem.Allocator) Value {
    return .{ .array = std.json.Array.init(a) };
}
pub fn set(v: *Value, key: []const u8, value: Value) !void {
    try v.object.put(key, value);
}
pub fn string(s: []const u8) Value {
    return .{ .string = s };
}
pub fn get(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn text(v: Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}
pub fn is(v: Value, s: []const u8) bool {
    return if (text(v)) |t| std.mem.eql(u8, t, s) else false;
}
pub fn truth(v: Value) bool {
    return v == .bool and v.bool;
}
pub fn uint(v: Value) ?u64 {
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .number_string => |n| std.fmt.parseInt(u64, n, 10) catch null,
        else => null,
    };
}
pub fn number(v: Value) ?f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |n| std.fmt.parseFloat(f64, n) catch null,
        else => null,
    };
}
pub fn stringify(a: std.mem.Allocator, v: Value) ![]u8 {
    return std.json.stringifyAlloc(a, v, .{});
}
