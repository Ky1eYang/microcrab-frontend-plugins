const std = @import("std");
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;
pub const max_bytes = 16 * 1024 * 1024;
const Unique = @import("shared").json.UniqueValue(false);
/// Returned trees are owned by the caller allocator (normally an operation arena).
pub fn parse(a: Allocator, source: []const u8) !Value {
    if (source.len > max_bytes) return error.JsonByteBudgetExceeded;
    return (try std.json.parseFromSliceLeaky(Unique, a, source, .{ .allocate = .alloc_always, .max_value_len = max_bytes })).value;
}
pub fn stringify(a: Allocator, value: Value) ![]u8 {
    return std.json.stringifyAlloc(a, value, .{});
}
pub fn clone(a: Allocator, value: Value) !Value {
    return switch (value) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |items| blk: {
            var out = array(a);
            for (items.items) |v| try out.array.append(try clone(a, v));
            break :blk out;
        },
        .object => |map| blk: {
            var out = object(a);
            var it = map.iterator();
            while (it.next()) |entry| try set(&out, try a.dupe(u8, entry.key_ptr.*), try clone(a, entry.value_ptr.*));
            break :blk out;
        },
        else => value,
    };
}
pub fn object(a: Allocator) Value {
    return .{ .object = std.json.ObjectMap.init(a) };
}
pub fn array(a: Allocator) Value {
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
fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
fn serdeFloat(a: Allocator, n: f64) ![]const u8 {
    if (!std.math.isFinite(n)) return error.InvalidJsonNumber;
    // Zig and Rust ryu use the same shortest-roundtrip digits. Match serde_json's
    // decimal/scientific layout, including float .0 and signed zero.
    var buffer: [64]u8 = undefined;
    const scientific = try std.fmt.formatFloat(&buffer, n, .{ .mode = .scientific });
    const marker = std.mem.indexOfScalar(u8, scientific, 'e') orelse return error.InvalidJsonNumber;
    const exponent = try std.fmt.parseInt(i32, scientific[marker + 1 ..], 10);
    if (exponent < -5 or exponent >= 16) return a.dupe(u8, scientific);
    var digits = std.ArrayList(u8).init(a);
    const negative = scientific[0] == '-';
    for (scientific[@intFromBool(negative)..marker]) |c| if (c != '.') {
        try digits.append(c);
    };
    var out = std.ArrayList(u8).init(a);
    if (negative) try out.append('-');
    const point = exponent + 1;
    if (point <= 0) {
        try out.appendSlice("0.");
        var i: i32 = 0;
        while (i < -point) : (i += 1) try out.append('0');
        try out.appendSlice(digits.items);
    } else {
        const p: usize = @intCast(point);
        if (p >= digits.items.len) {
            try out.appendSlice(digits.items);
            var i = digits.items.len;
            while (i < p) : (i += 1) try out.append('0');
            try out.appendSlice(".0");
        } else {
            try out.appendSlice(digits.items[0..p]);
            try out.append('.');
            try out.appendSlice(digits.items[p..]);
        }
    }
    return out.toOwnedSlice();
}
fn sorted(a: Allocator, value: Value, depth: usize) !Value {
    if (depth > 128) return error.JsonDepthExceeded;
    if (value == .object) {
        var keys = try a.alloc([]const u8, value.object.count());
        for (value.object.keys(), 0..) |key, i| keys[i] = key;
        std.mem.sort([]const u8, keys, {}, less);
        var out = object(a);
        for (keys) |key| try set(&out, key, try sorted(a, value.object.get(key).?, depth + 1));
        return out;
    }
    if (value == .array) {
        var out = array(a);
        for (value.array.items) |v| try out.array.append(try sorted(a, v, depth + 1));
        return out;
    }
    if (value == .number_string) {
        if (!std.mem.eql(u8, value.number_string, "-0")) {
            if (std.fmt.parseInt(i64, value.number_string, 10)) |n| return .{ .integer = n } else |_| {}
            if (std.fmt.parseInt(u64, value.number_string, 10)) |n| return .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{n}) } else |_| {}
        }
        const n = try std.fmt.parseFloat(f64, value.number_string);
        return .{ .number_string = try serdeFloat(a, n) };
    }
    if (value == .float) return .{ .number_string = try serdeFloat(a, value.float) };
    return value;
}
pub fn canonical(a: Allocator, value: Value) ![]u8 {
    return stringify(a, try sorted(a, value, 0));
}
pub fn pin(a: Allocator, value: Value) ![64]u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const bytes = try canonical(scratch.allocator(), value);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn equal(a: Allocator, x: Value, y: Value) !bool {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return std.mem.eql(u8, try canonical(scratch.allocator(), x), try canonical(scratch.allocator(), y));
}
test "canonical float formatting follows serde ryu boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[1.0,0.00001,1e-6,1000000000000000.0,1e16,-0.0,18446744073709551615]", try canonical(a, try parse(a, "[1.0,1e-5,1e-6,1e15,1e16,-0,18446744073709551615]")));
}
test "duplicate decoded keys reject and canonical ordering preserves serialization lexemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"x\":1,\"x\":2}"));
    const v = try parse(a, "{\"z\":1e0,\"a\":2}");
    try std.testing.expectEqualStrings("{\"z\":1e0,\"a\":2}", try stringify(a, v));
    const p = try pin(a, try parse(a, "{\"b\":2,\"a\":1}"));
    const q = try pin(a, try parse(a, "{\"a\":1,\"b\":2}"));
    try std.testing.expectEqualStrings(&p, &q);
}
