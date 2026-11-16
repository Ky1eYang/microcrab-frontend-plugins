const std = @import("std");
const j = @import("json_helpers.zig");
const cp = @import("call_pins.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
pub fn short(a: A, value: V) ![16]u8 {
    const digest = try j.pin(a, value);
    return digest[0..16].*;
}
pub fn limit(request: V) usize {
    return @intCast(@min(32, @max(1, j.uint(j.get(request, "limit")) orelse 20)));
}
pub fn summary(a: A, tool: V) !V {
    var out = j.object(a);
    try j.set(&out, "name", try j.clone(a, j.get(tool, "name")));
    const description = j.text(j.get(tool, "description")) orelse "";
    var view = try std.unicode.Utf8View.init(description);
    var iter = view.iterator();
    var end: usize = 0;
    var count: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        if (count == 512) break;
        end += slice.len;
        count += 1;
    }
    try j.set(&out, "description", j.string(try a.dupe(u8, description[0..end])));
    return out;
}
pub fn inventory(a: A, resources: []const V) ![64]u8 {
    var values = j.array(a);
    for (resources) |r| {
        var item = j.array(a);
        try item.array.append(j.get(r, "id"));
        try item.array.append(j.get(r, "config_pin"));
        try values.array.append(item);
    }
    return j.pin(a, values);
}
const Position = struct { scope_value: V, inventory: []const u8, catalog: []const u8, offset: usize };
const Entry = struct { arena: std.heap.ArenaAllocator, token: [16]u8, position: ?Position };
pub const Cursors = struct {
    allocator: A,
    entries: std.ArrayList(Entry),
    pub fn init(a: A) Cursors {
        return .{ .allocator = a, .entries = std.ArrayList(Entry).init(a) };
    }
    pub fn reset(self: *Cursors) void {
        for (self.entries.items) |*e| e.arena.deinit();
        self.entries.clearRetainingCapacity();
    }
    pub fn deinit(self: *Cursors) void {
        self.reset();
        self.entries.deinit();
    }
    fn find(self: *const Cursors, identity: V, token: []const u8, inv: []const u8) !Position {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const scoped = try cp.scope(a, identity);
        for (self.entries.items) |e| if (std.mem.eql(u8, &e.token, token)) {
            const p = e.position orelse return error.StaleDiscoveryCursor;
            if (!std.mem.eql(u8, p.inventory, inv) or !try j.equal(a, p.scope_value, scoped)) return error.StaleDiscoveryCursor;
            return p;
        };
        return error.StaleDiscoveryCursor;
    }
    pub fn start(self: *const Cursors, identity: V, request: V, inv: []const u8) !usize {
        if (request != .object) return error.InvalidDiscoveryRequest;
        const token = request.object.get("cursor") orelse return 0;
        return (try self.find(identity, j.text(token) orelse return error.StaleDiscoveryCursor, inv)).offset;
    }
    fn offset(self: *const Cursors, identity: V, request: V, inv: []const u8, catalog: []const u8) !usize {
        if (request != .object) return error.InvalidDiscoveryRequest;
        const token = request.object.get("cursor") orelse return 0;
        const p = try self.find(identity, j.text(token) orelse return error.StaleDiscoveryCursor, inv);
        if (!std.mem.eql(u8, p.catalog, catalog)) return error.StaleDiscoveryCursor;
        return p.offset;
    }
    fn mint(self: *Cursors, a: A, identity: V, inv: []const u8, catalog: []const u8, off: usize) !V {
        const scoped = try cp.scope(a, identity);
        var data = j.array(a);
        try data.array.append(j.string("microcrab.mcp.discovery.v1"));
        try data.array.append(scoped);
        try data.array.append(j.string(inv));
        try data.array.append(j.string(catalog));
        try data.array.append(.{ .integer = @intCast(off) });
        const token = try short(a, data);
        for (self.entries.items) |*e| if (std.mem.eql(u8, &e.token, &token)) {
            if (e.position) |p| {
                if (p.offset == off and std.mem.eql(u8, p.inventory, inv) and std.mem.eql(u8, p.catalog, catalog) and try j.equal(a, p.scope_value, scoped)) return j.string(try a.dupe(u8, &token));
            }
            e.position = null;
            return error.AmbiguousDiscoveryCursor;
        };
        if (self.entries.items.len >= 256) {
            var old = self.entries.orderedRemove(0);
            old.arena.deinit();
        }
        var entry = Entry{ .arena = std.heap.ArenaAllocator.init(self.allocator), .token = token, .position = null };
        errdefer entry.arena.deinit();
        const ea = entry.arena.allocator();
        entry.position = .{ .scope_value = try j.clone(ea, scoped), .inventory = try ea.dupe(u8, inv), .catalog = try ea.dupe(u8, catalog), .offset = off };
        try self.entries.append(entry);
        return j.string(try a.dupe(u8, &token));
    }
    pub fn server(self: *Cursors, a: A, identity: V, request: V, resource: V, tools: []const V) !V {
        const inv = try inventory(a, &.{resource});
        var catalog_data = j.array(a);
        try catalog_data.array.append(j.string("server"));
        var tool_values = j.array(a);
        for (tools) |t| try tool_values.array.append(t);
        try catalog_data.array.append(tool_values);
        const catalog = try j.pin(a, catalog_data);
        const off = try self.offset(identity, request, &inv, &catalog);
        if (off > tools.len) return error.StaleDiscoveryCursor;
        var page = j.array(a);
        for (tools[off..@min(tools.len, off + limit(request))]) |t| try page.array.append(try summary(a, t));
        const next = off + page.array.items.len;
        const cursor = if (next < tools.len) try self.mint(a, identity, &inv, &catalog, next) else V.null;
        var out = j.object(a);
        try j.set(&out, "server", try j.clone(a, j.get(resource, "id")));
        const config = try short(a, j.get(resource, "config_pin"));
        try j.set(&out, "config_pin", j.string(try a.dupe(u8, &config)));
        try j.set(&out, "catalog_pin", j.string(try a.dupe(u8, catalog[0..16])));
        try j.set(&out, "tools", page);
        try j.set(&out, "next_cursor", cursor);
        try j.set(&out, "usage_hint", j.string("Use describe with server and tool to inspect parameters and obtain call_pin; then call with pin and arguments."));
        return out;
    }
    pub fn aggregate(self: *Cursors, a: A, identity: V, request: V, resources: []const V, servers: []const V) !V {
        if (resources.len > 32 or servers.len > 32) return error.ResourceLimitExceeded;
        const inv = try inventory(a, resources);
        var fingerprints = j.array(a);
        var total: usize = 0;
        for (servers) |s| {
            var fp = j.array(a);
            for ([_][]const u8{ "id", "config_pin", "catalog_pin", "tool_count", "error" }) |key| try fp.array.append(j.get(s, key));
            try fingerprints.array.append(fp);
            const count = j.uint(j.get(s, "tool_count")) orelse 0;
            if (count > 1000) return error.InvalidRetainedDiscovery;
            total += @intCast(@max(1, count));
        }
        var data = j.array(a);
        try data.array.append(j.string("aggregate"));
        try data.array.append(fingerprints);
        const catalog = try j.pin(a, data);
        const off = try self.offset(identity, request, &inv, &catalog);
        if (off > total) return error.StaleDiscoveryCursor;
        var pos: usize = 0;
        var count: usize = 0;
        var next = off;
        var page = j.array(a);
        for (servers) |s| {
            const tools = j.get(s, "tools");
            if (tools != .array) return error.InvalidRetainedDiscovery;
            const n: usize = @intCast(j.uint(j.get(s, "tool_count")) orelse 0);
            const width = @max(1, n);
            if (pos + width <= off) {
                pos += width;
                continue;
            }
            if (count >= limit(request)) break;
            const start_at = off -| pos;
            const take = tools.array.items.len;
            if (take > limit(request) - count) return error.DiscoverySummaryBudgetExceeded;
            var entry = j.object(a);
            try j.set(&entry, "id", try j.clone(a, j.get(s, "id")));
            const config = try short(a, j.get(s, "config_pin"));
            try j.set(&entry, "config_pin", j.string(try a.dupe(u8, &config)));
            try j.set(&entry, "tools", try j.clone(a, tools));
            if (s == .object) if (s.object.get("error")) |e| try j.set(&entry, "error", try j.clone(a, e));
            try page.array.append(entry);
            count += take;
            next = pos + (if (n == 0) @as(usize, 1) else start_at + take);
            pos += width;
        }
        var out = j.object(a);
        try j.set(&out, "servers", page);
        try j.set(&out, "next_cursor", if (next < total) try self.mint(a, identity, &inv, &catalog, next) else .null);
        return out;
    }
};
test "discovery pages bind catalog and scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cursors = Cursors.init(std.testing.allocator);
    defer cursors.deinit();
    const identity = try j.parse(a, "{\"session_id\":\"s\"}");
    const resource = try j.parse(a, "{\"id\":\"server\",\"config_pin\":\"revision\"}");
    const tools = try j.parse(a, "[{\"name\":\"a\"},{\"name\":\"b\"}]");
    const req = try j.parse(a, "{\"limit\":1}");
    const first = try cursors.server(a, identity, req, resource, tools.array.items);
    var second = try j.clone(a, req);
    try j.set(&second, "cursor", j.get(first, "next_cursor"));
    const page = try cursors.server(a, identity, second, resource, tools.array.items);
    try std.testing.expect(j.is(j.get(j.get(page, "tools").array.items[0], "name"), "b"));
    try std.testing.expectError(error.StaleDiscoveryCursor, cursors.server(a, identity, second, resource, tools.array.items[0..1]));
}
