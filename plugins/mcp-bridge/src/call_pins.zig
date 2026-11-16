const std = @import("std");
const j = @import("json_helpers.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
pub const capacity = 256;
pub const CallTarget = struct { server: []const u8, tool: []const u8, config_pin: []const u8, schema_pin: []const u8 };
pub fn scope(a: A, identity: V) !V {
    var out = j.object(a);
    const dest = [_][]const u8{ "session", "parent", "artifact", "generation", "history_generation", "epoch", "catalog" };
    const src = [_][]const u8{ "session_id", "parent_session_id", "artifact", "generation", "history_generation", "epoch", "catalog_digest" };
    for (dest, src) |d, s| try j.set(&out, d, try j.clone(a, j.get(identity, s)));
    return out;
}
fn targetClone(a: A, t: CallTarget) !CallTarget {
    return .{ .server = try a.dupe(u8, t.server), .tool = try a.dupe(u8, t.tool), .config_pin = try a.dupe(u8, t.config_pin), .schema_pin = try a.dupe(u8, t.schema_pin) };
}
fn targetEqual(a: CallTarget, b: CallTarget) bool {
    return std.mem.eql(u8, a.server, b.server) and std.mem.eql(u8, a.tool, b.tool) and std.mem.eql(u8, a.config_pin, b.config_pin) and std.mem.eql(u8, a.schema_pin, b.schema_pin);
}
const Entry = struct { arena: std.heap.ArenaAllocator, token: [16]u8, scope_value: V, target: ?CallTarget };
pub const CallPins = struct {
    allocator: A,
    entries: std.ArrayList(Entry),
    pub fn init(a: A) CallPins {
        return .{ .allocator = a, .entries = std.ArrayList(Entry).init(a) };
    }
    pub fn deinit(self: *CallPins) void {
        self.reset();
        self.entries.deinit();
    }
    pub fn reset(self: *CallPins) void {
        for (self.entries.items) |*e| e.arena.deinit();
        self.entries.clearRetainingCapacity();
    }
    pub fn mint(self: *CallPins, identity: V, target: CallTarget) ![]const u8 {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const scoped = try scope(a, identity);
        var data = j.array(a);
        try data.array.append(j.string("microcrab.mcp.call.v1"));
        try data.array.append(scoped);
        for ([_][]const u8{ target.server, target.tool, target.config_pin, target.schema_pin }) |s| try data.array.append(j.string(s));
        const digest = try j.pin(a, data);
        const token = digest[0..16];
        for (self.entries.items) |*e| if (std.mem.eql(u8, &e.token, token)) {
            if (try j.equal(a, e.scope_value, scoped) and e.target != null and targetEqual(e.target.?, target)) return &e.token;
            e.target = null;
            return error.AmbiguousCallPin;
        };
        if (self.entries.items.len >= capacity) {
            var old = self.entries.orderedRemove(0);
            old.arena.deinit();
        }
        var entry = Entry{ .arena = std.heap.ArenaAllocator.init(self.allocator), .token = undefined, .scope_value = .null, .target = null };
        errdefer entry.arena.deinit();
        @memcpy(&entry.token, token);
        entry.scope_value = try j.clone(entry.arena.allocator(), scoped);
        entry.target = try targetClone(entry.arena.allocator(), target);
        try self.entries.append(entry);
        return &self.entries.items[self.entries.items.len - 1].token;
    }
    /// Returned target borrows cache storage until the next mint/reset/deinit.
    pub fn resolve(self: *const CallPins, identity: V, token: []const u8) !CallTarget {
        if (token.len != 16) return error.InvalidCallPin;
        for (token) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidCallPin;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const scoped = try scope(a, identity);
        for (self.entries.items) |e| if (std.mem.eql(u8, &e.token, token)) {
            if (!try j.equal(a, e.scope_value, scoped)) return error.ExpiredCallPin;
            return e.target orelse error.AmbiguousCallPin;
        };
        return error.ExpiredCallPin;
    }
    pub fn expandRequest(self: *const CallPins, identity: V, request: *V) !void {
        if (request.* != .object) return error.InvalidCallRequest;
        var target: ?CallTarget = null;
        if (request.object.get("pin")) |token| {
            for ([_][]const u8{ "server", "tool", "config_pin", "schema_pin" }) |key| if (request.object.contains(key)) return error.ConflictingCallPinFields;
            target = try self.resolve(identity, j.text(token) orelse return error.InvalidCallPin);
        } else {
            const cp = j.text(j.get(request.*, "config_pin")) orelse "";
            const sp = j.text(j.get(request.*, "schema_pin")) orelse "";
            if (cp.len != 16 and sp.len != 16) return;
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const scoped = try scope(a, identity);
            for (self.entries.items) |e| {
                if (!try j.equal(a, e.scope_value, scoped)) continue;
                const t = e.target orelse continue;
                const hash = try j.pin(a, j.string(t.config_pin));
                if (!j.is(j.get(request.*, "server"), t.server) or !j.is(j.get(request.*, "tool"), t.tool) or (!std.mem.eql(u8, cp, t.config_pin) and !std.mem.eql(u8, cp, hash[0..16])) or (!std.mem.eql(u8, sp, t.schema_pin) and !(t.schema_pin.len >= 16 and std.mem.eql(u8, sp, t.schema_pin[0..16])))) continue;
                if (target) |old| {
                    if (!targetEqual(old, t)) return error.AmbiguousLegacyPins;
                } else target = t;
            }
            if (target == null) {
                if (sp.len != 16) return;
                return error.ExpiredCallPin;
            }
        }
        const t = target.?;
        // request allocator owns every expanded string; never borrow evictable cache bytes.
        const a = request.object.allocator;
        try j.set(request, "server", j.string(try a.dupe(u8, t.server)));
        try j.set(request, "tool", j.string(try a.dupe(u8, t.tool)));
        try j.set(request, "config_pin", j.string(try a.dupe(u8, t.config_pin)));
        try j.set(request, "schema_pin", j.string(try a.dupe(u8, t.schema_pin)));
    }
};
test "call pins exact scope conflicts and FIFO eviction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pins = CallPins.init(std.testing.allocator);
    defer pins.deinit();
    const identity = try j.parse(a, "{\"session_id\":\"one\"}");
    const t = CallTarget{ .server = "s", .tool = "t", .config_pin = "revision", .schema_pin = "schema" };
    const token = try a.dupe(u8, try pins.mint(identity, t));
    try std.testing.expectEqualStrings("t", (try pins.resolve(identity, token)).tool);
    try std.testing.expectError(error.ExpiredCallPin, pins.resolve(try j.parse(a, "{\"session_id\":\"two\"}"), token));
    var req = try j.parse(a, "{\"pin\":\"unused\",\"server\":\"s\"}");
    try std.testing.expectError(error.ConflictingCallPinFields, pins.expandRequest(identity, &req));
    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        var other = t;
        other.tool = try std.fmt.allocPrint(a, "tool{d}", .{i});
        _ = try pins.mint(identity, other);
    }
    try std.testing.expectError(error.ExpiredCallPin, pins.resolve(identity, token));
}
