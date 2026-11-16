const std = @import("std");
const j = @import("json_helpers.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const limit = 8192;
fn budget(left: *usize, depth: usize) !void {
    if (depth > 32 or left.* == 0) return error.SchemaComplexityExceeded;
    left.* -= 1;
}
const keywords = [_][]const u8{ "$schema", "$id", "$defs", "definitions", "$ref", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "type", "properties", "required", "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minProperties", "maxProperties", "enum", "const", "allOf", "anyOf", "oneOf", "not" };
fn oneOf(s: []const u8, choices: []const []const u8) bool {
    for (choices) |c| if (std.mem.eql(u8, s, c)) return true;
    return false;
}
fn validType(v: V) bool {
    const s = j.text(v) orelse return false;
    return oneOf(s, &.{ "null", "boolean", "number", "integer", "string", "array", "object" });
}
fn supported(s: V, left: *usize, depth: usize) anyerror!void {
    try budget(left, depth);
    if (s == .bool) return;
    if (s != .object) return error.InvalidSchema;
    for (s.object.keys()) |key| if (!oneOf(key, &keywords)) return error.UnsupportedSchemaKeyword;
    if (s.object.get("type")) |t| {
        if (t == .array) {
            if (t.array.items.len == 0) return error.InvalidSchemaType;
            for (t.array.items) |v| if (!validType(v)) return error.InvalidSchemaType;
        } else if (!validType(t)) return error.InvalidSchemaType;
    }
    for ([_][]const u8{ "properties", "$defs", "definitions" }) |key| if (s.object.get(key)) |map| {
        if (map != .object) return error.InvalidSchemaPropertyMap;
        for (map.object.values()) |v| try supported(v, left, depth + 1);
    };
    for ([_][]const u8{ "additionalProperties", "items", "not" }) |key| if (s.object.get(key)) |v| try supported(v, left, depth + 1);
    for ([_][]const u8{ "allOf", "anyOf", "oneOf" }) |key| if (s.object.get(key)) |v| {
        if (v != .array or v.array.items.len == 0) return error.InvalidSchemaAlternatives;
        for (v.array.items) |child| try supported(child, left, depth + 1);
    };
    if (s.object.get("required")) |v| {
        if (v != .array) return error.InvalidRequiredList;
        for (v.array.items) |child| if (child != .string) return error.InvalidRequiredList;
    }
    for ([_][]const u8{ "minItems", "maxItems", "minLength", "maxLength", "minProperties", "maxProperties" }) |key| if (s.object.get(key)) |v| {
        if (j.uint(v) == null) return error.InvalidSchemaSize;
    };
    for ([_][]const u8{ "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf" }) |key| if (s.object.get(key)) |v| {
        const n = j.number(v) orelse return error.InvalidSchemaNumber;
        if (!std.math.isFinite(n)) return error.InvalidSchemaNumber;
    };
    if (s.object.get("uniqueItems")) |v| if (v != .bool) return error.InvalidSchemaUniqueness;
    if (s.object.get("enum")) |v| if (v != .array or v.array.items.len == 0) return error.InvalidSchemaEnum;
    if (s.object.get("$ref")) |v| {
        const ref = j.text(v) orelse return error.UnsupportedSchemaReference;
        if (!std.mem.eql(u8, ref, "#") and !std.mem.startsWith(u8, ref, "#/")) return error.UnsupportedSchemaReference;
    }
}
fn pointer(a: A, root: V, ref: []const u8) !V {
    if (std.mem.eql(u8, ref, "#")) return root;
    var result = root;
    var parts = std.mem.splitScalar(u8, ref[2..], '/');
    while (parts.next()) |part| {
        var decoded = std.ArrayList(u8).init(a);
        defer decoded.deinit();
        var i: usize = 0;
        while (i < part.len) : (i += 1) {
            if (part[i] == '~') {
                i += 1;
                if (i >= part.len) return error.InvalidJsonPointer;
                try decoded.append(switch (part[i]) {
                    '0' => '~',
                    '1' => '/',
                    else => return error.InvalidJsonPointer,
                });
            } else try decoded.append(part[i]);
        }
        if (result == .object) result = result.object.get(decoded.items) orelse return error.MissingSchemaReference else if (result == .array) {
            if (decoded.items.len == 0 or (decoded.items.len > 1 and decoded.items[0] == '0')) return error.MissingSchemaReference;
            const n = std.fmt.parseInt(usize, decoded.items, 10) catch return error.MissingSchemaReference;
            if (n >= result.array.items.len) return error.MissingSchemaReference;
            result = result.array.items[n];
        } else return error.MissingSchemaReference;
    }
    return result;
}
fn typeMatches(v: V, t: V) bool {
    if (j.is(t, "null")) return v == .null;
    if (j.is(t, "boolean")) return v == .bool;
    if (j.is(t, "object")) return v == .object;
    if (j.is(t, "array")) return v == .array;
    if (j.is(t, "string")) return v == .string;
    const n = j.number(v) orelse return false;
    return std.math.isFinite(n) and (j.is(t, "number") or (j.is(t, "integer") and @trunc(n) == n));
}
fn size(s: V, n: usize, min: []const u8, max: []const u8) bool {
    if (j.uint(j.get(s, min))) |m| if (n < m) return false;
    if (j.uint(j.get(s, max))) |m| if (n > m) return false;
    return true;
}
fn matches(a: A, s: V, root: V, v: V, left: *usize, schema_left: *usize, depth: usize) anyerror!bool {
    try budget(left, depth);
    if (s == .bool) return s.bool;
    if (j.text(j.get(s, "$ref"))) |ref| {
        const target = try pointer(a, root, ref);
        // References can enter annotation data that the structural scan did not visit.
        // Validate the target before reading its union fields or enforcing constraints.
        try supported(target, schema_left, depth + 1);
        if (!try matches(a, target, root, v, left, schema_left, depth + 1)) return false;
    }
    if (s.object.get("type")) |t| {
        if (t == .array) {
            var yes = false;
            for (t.array.items) |kind| {
                if (typeMatches(v, kind)) yes = true;
            }
            if (!yes) return false;
        } else if (!typeMatches(v, t)) return false;
    }
    if (s.object.get("const")) |c| if (!try j.equal(a, c, v)) return false;
    if (s.object.get("enum")) |en| {
        var yes = false;
        for (en.array.items) |c| if (try j.equal(a, c, v)) {
            yes = true;
            break;
        };
        if (!yes) return false;
    }
    for ([_][]const u8{ "allOf", "anyOf", "oneOf" }) |key| if (s.object.get(key)) |alts| {
        var count: usize = 0;
        for (alts.array.items) |child| if (try matches(a, child, root, v, left, schema_left, depth + 1)) {
            count += 1;
        };
        if ((std.mem.eql(u8, key, "allOf") and count != alts.array.items.len) or (std.mem.eql(u8, key, "anyOf") and count == 0) or (std.mem.eql(u8, key, "oneOf") and count != 1)) return false;
    };
    if (s.object.get("not")) |child| if (try matches(a, child, root, v, left, schema_left, depth + 1)) return false;
    if (v == .string) {
        const count = std.unicode.utf8CountCodepoints(v.string) catch return error.InvalidUtf8;
        if (!size(s, count, "minLength", "maxLength")) return false;
    }
    if (j.number(v)) |n| {
        if (j.number(j.get(s, "minimum"))) |m| if (n < m) return false;
        if (j.number(j.get(s, "maximum"))) |m| if (n > m) return false;
        if (j.number(j.get(s, "exclusiveMinimum"))) |m| if (n <= m) return false;
        if (j.number(j.get(s, "exclusiveMaximum"))) |m| if (n >= m) return false;
        if (j.number(j.get(s, "multipleOf"))) |m| {
            if (m <= 0) return error.InvalidMultipleOf;
            const q = n / m;
            if (!std.math.isFinite(q) or @abs(q - @round(q)) > 1e-10) return false;
        }
    }
    if (v == .array) {
        if (!size(s, v.array.items.len, "minItems", "maxItems")) return false;
        if (j.truth(j.get(s, "uniqueItems"))) for (v.array.items, 0..) |item, i| {
            for (v.array.items[0..i]) |other| {
                try budget(left, depth);
                if (try j.equal(a, item, other)) return false;
            }
        };
        if (s.object.get("items")) |child| for (v.array.items) |item| {
            if (!try matches(a, child, root, item, left, schema_left, depth + 1)) return false;
        };
    }
    if (v == .object) {
        if (!size(s, v.object.count(), "minProperties", "maxProperties")) return false;
        if (s.object.get("required")) |req| for (req.array.items) |key| {
            if (!v.object.contains(key.string)) return false;
        };
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const properties = j.get(s, "properties");
            const child = if (properties == .object) properties.object.get(entry.key_ptr.*) else null;
            if (child) |c| {
                if (!try matches(a, c, root, entry.value_ptr.*, left, schema_left, depth + 1)) return false;
            } else if (s.object.get("additionalProperties")) |c| {
                if (!try matches(a, c, root, entry.value_ptr.*, left, schema_left, depth + 1)) return false;
            }
        }
    }
    return true;
}
pub fn validate(a: A, schema: V, args: V) !void {
    var sb: usize = limit;
    var eb: usize = limit;
    try supported(schema, &sb, 0);
    if (!try matches(a, schema, schema, args, &eb, &sb, 0)) return error.ArgumentsDoNotMatchSchema;
}
test "local references validate annotation targets before evaluating them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Referencing an annotation must not reinterpret a scalar as an ObjectMap.
    for ([_][]const u8{ "null", "1", "\"text\"", "[]" }) |target| {
        const source = try std.fmt.allocPrint(a, "{{\"$ref\":\"#/default\",\"default\":{s}}}", .{target});
        try std.testing.expectError(error.InvalidSchema, validate(a, try j.parse(a, source), j.object(a)));
    }
    // Referenced annotation objects obey the same fail-closed keyword contract.
    const unsupported = try j.parse(a, "{\"$ref\":\"#/default\",\"default\":{\"pattern\":\"^x$\"}}");
    try std.testing.expectError(error.UnsupportedSchemaKeyword, validate(a, unsupported, j.string("wrong")));
    const valid = try j.parse(a, "{\"$ref\":\"#/default\",\"default\":{\"type\":\"string\",\"minLength\":2}}");
    try validate(a, valid, j.string("ok"));
    try std.testing.expectError(error.ArgumentsDoNotMatchSchema, validate(a, valid, j.string("x")));
}

test "bounded schema validation rejects extras unsupported keywords and recursive refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try j.parse(a, "{\"type\":\"object\",\"required\":[\"name\"],\"additionalProperties\":false,\"properties\":{\"name\":{\"type\":\"string\",\"minLength\":2}}}");
    try validate(a, schema, try j.parse(a, "{\"name\":\"你好\"}"));
    try std.testing.expectError(error.ArgumentsDoNotMatchSchema, validate(a, schema, try j.parse(a, "{\"name\":\"x\"}")));
    try std.testing.expectError(error.UnsupportedSchemaKeyword, validate(a, try j.parse(a, "{\"pattern\":\".*\"}"), .null));
    try std.testing.expectError(error.SchemaComplexityExceeded, validate(a, try j.parse(a, "{\"$ref\":\"#\"}"), .null));
}
