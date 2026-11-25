const std = @import("std");
const j = @import("json_helpers.zig");
const runtime = @import("runtime.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const Result = union(enum) { ok: u32, err: []const u8 };
const MockHost = struct {
    const Channel = enum { resources, net };
    const Request = struct { id: u32, channel: Channel, kind: []const u8, payload: []const u8 };
    var requests: std.ArrayList(Request) = undefined;
    var next_id: u32 = 0;
    fn init() void {
        requests = std.ArrayList(Request).init(std.testing.allocator);
        next_id = 0;
    }
    fn deinit() void {
        for (requests.items) |r| {
            std.testing.allocator.free(r.kind);
            std.testing.allocator.free(r.payload);
        }
        requests.deinit();
    }
    fn capture(channel: Channel, kind: []const u8, payload: []const u8) Result {
        next_id += 1;
        const k = std.testing.allocator.dupe(u8, kind) catch @panic("test allocator exhausted");
        const p = std.testing.allocator.dupe(u8, payload) catch @panic("test allocator exhausted");
        requests.append(.{ .id = next_id, .channel = channel, .kind = k, .payload = p }) catch @panic("test allocator exhausted");
        return .{ .ok = next_id };
    }
    pub const resources = struct {
        pub fn send(kind: []const u8, payload: []const u8) Result {
            return capture(.resources, kind, payload);
        }
    };
    pub const net = struct {
        pub fn send(kind: []const u8, payload: []const u8) Result {
            return capture(.net, kind, payload);
        }
    };
    fn last() Request {
        return requests.items[requests.items.len - 1];
    }
    fn method(a: A) ![]const u8 {
        const p = try j.parse(a, last().payload);
        const body = try j.parse(a, j.text(j.get(p, "body")) orelse return error.NoHttpBody);
        return j.text(j.get(body, "method")) orelse error.NoRpcMethod;
    }
};
const Engine = runtime.Runtime(MockHost);
fn context(a: A, invocation: []const u8) !V {
    var ctx = try j.parse(a, "{\"server_origin\":\"https://app.test\",\"owner_id\":\"owner\",\"session_id\":\"s\",\"instance_generation\":1,\"history_generation\":1,\"host_time_ms\":1000,\"host_monotonic_ms\":10,\"locale\":\"en\",\"user_action\":true,\"surface\":{\"target\":\"sidebar\"},\"tool_invocation\":{\"session_id\":\"s\",\"parent_session_id\":\"s\",\"call_id\":\"call\",\"catalog_digest\":\"catalog\",\"epoch\":1,\"turn_id\":2,\"round_id\":3,\"deadline_ms\":0,\"artifact\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"generation\":1,\"history_generation\":1}}");
    var identity = j.get(ctx, "tool_invocation");
    try j.set(&identity, "invocation_id", j.string(try a.dupe(u8, invocation)));
    try j.set(&ctx, "tool_invocation", identity);
    return ctx;
}
fn resources(a: A) !V {
    return j.parse(a, "[{\"id\":\"server\",\"endpoint\":\"https://mcp.test/path\",\"origin\":\"https://mcp.test\",\"enabled\":true,\"requires_reenable\":false,\"config_pin\":\"revision\"}]");
}
fn catalog(a: A) !V {
    return j.parse(a, "{\"tools\":[{\"name\":\"run\",\"description\":\"Run\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"x\"],\"additionalProperties\":false,\"properties\":{\"x\":{\"type\":\"integer\"}}}}]}");
}
fn event(a: A, id: u32, value: V) !V {
    var out = j.object(a);
    try j.set(&out, "request_id", .{ .integer = id });
    try j.set(&out, "ok", .{ .bool = true });
    try j.set(&out, "value", value);
    return out;
}
fn deliver(engine: *Engine, a: A, ctx: V, value: V) !V {
    return engine.phase(a, "event-result", try event(a, MockHost.last().id, value), ctx);
}
fn rpcResponse(a: A, result: V) !V {
    const p = try j.parse(a, MockHost.last().payload);
    const body = try j.parse(a, j.text(j.get(p, "body")) orelse return error.NoHttpBody);
    var rpc = j.object(a);
    try j.set(&rpc, "jsonrpc", j.string("2.0"));
    try j.set(&rpc, "id", j.get(body, "id"));
    try j.set(&rpc, "result", result);
    var response = try j.parse(a, "{\"status\":200,\"headers\":{\"content-type\":\"application/json\",\"mcp-session-id\":\"remote-session\"}}");
    try j.set(&response, "body", j.string(try j.stringify(a, rpc)));
    return response;
}
fn toCatalog(engine: *Engine, a: A, ctx: V) !void {
    _ = try deliver(engine, a, ctx, try resources(a));
    try fromInitialize(engine, a, ctx);
}
fn fromInitialize(engine: *Engine, a: A, ctx: V) !void {
    try std.testing.expectEqualStrings("initialize", try MockHost.method(a));
    const initialize = try j.parse(a, MockHost.last().payload);
    const body = try j.parse(a, j.text(j.get(initialize, "body")) orelse return error.NoHttpBody);
    try std.testing.expect(j.is(j.get(j.get(j.get(body, "params"), "clientInfo"), "version"), "0.4.1"));
    _ = try deliver(engine, a, ctx, try rpcResponse(a, try j.parse(a, "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{\"name\":\"test\"}}")));
    try std.testing.expectEqualStrings("notifications/initialized", try MockHost.method(a));
    const notification = try j.parse(a, MockHost.last().payload);
    try std.testing.expect(j.is(j.get(notification, "response_mode"), "discard"));
    try std.testing.expect(j.get(notification, "response_id") == .null);
    _ = try deliver(engine, a, ctx, try j.parse(a, "{\"status\":202,\"headers\":{},\"body\":\"\"}"));
    try std.testing.expectEqualStrings("tools/list", try MockHost.method(a));
}
fn describe(engine: *Engine, a: A, ctx: V) !V {
    const started = try engine.start(a, try j.parse(a, "{\"action\":\"describe\",\"server\":\"server\",\"tool\":\"run\"}"), ctx);
    try std.testing.expect(j.is(j.get(j.get(started, "tool_completion"), "status"), "pending"));
    try toCatalog(engine, a, ctx);
    const result = try deliver(engine, a, ctx, try rpcResponse(a, try catalog(a)));
    const completed = j.get(result, "tool_completion");
    try std.testing.expect(j.is(j.get(completed, "status"), "completed"));
    return j.get(completed, "output");
}
fn pendingCount(engine: *const Engine) usize {
    var count: usize = 0;
    for (engine.slots) |slot| if (slot != null) {
        count += 1;
    };
    return count;
}
test "runtime terminal allocation failures never revisit freed slots" {
    var terminal_failures: usize = 0;
    var size: usize = 0;
    while (size <= 8192) : (size += 128) {
        MockHost.init();
        defer MockHost.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var engine = try Engine.init(std.testing.allocator);
        defer engine.deinit();
        const ctx = try context(a, "terminal-oom");
        _ = try engine.start(a, try j.parse(a, "{\"action\":\"list\"}"), ctx);
        const payload = try event(a, MockHost.last().id, j.array(a));
        var storage: [8192]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(storage[0..size]);
        _ = engine.phase(fixed.allocator(), "event-result", payload, ctx) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (pendingCount(&engine) == 0) {
                terminal_failures += 1;
                try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
            }
            continue;
        };
    }
    try std.testing.expect(terminal_failures > 0);
}

fn sidebarPatch(result: V) V {
    return j.get(j.get(result, "vars_patch"), "sidebar");
}
fn expectServiceStatus(view: V, status: []const u8) !void {
    const services = j.get(view, "services");
    try std.testing.expectEqual(@as(usize, 1), services.array.items.len);
    try std.testing.expect(j.is(j.get(services.array.items[0], "id"), "server"));
    try std.testing.expect(j.is(j.get(services.array.items[0], "status"), status));
}

test "runtime sidebar strictly projects enabled services without requiring a session" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var ctx = try context(a, "health");
    try j.set(&ctx, "session_id", .null);
    _ = try engine.initialize(a, ctx);
    const inventory = try j.parse(a,
        \\[{"id":"server","enabled":true,"endpoint":"https://secret.test/path","origin":"https://secret.test",
        \\  "config_pin":"revision","authorization":"secret-auth","headers":{"authorization":"secret-header"}},
        \\ {"id":"disabled","enabled":false}, {"id":"reauthorize","enabled":true,"requires_reenable":true},
        \\ {"id":"not-bool","enabled":"true"}, {"id":42,"enabled":true}]
    );
    const initial = sidebarPatch(try deliver(&engine, a, ctx, inventory));
    try expectServiceStatus(initial, "unchecked");
    try std.testing.expect(!j.truth(j.get(initial, "has_session")));
    try std.testing.expectEqual(@as(usize, 2), j.get(initial, "services").array.items[0].object.count());
    const ha = engine.health_arena.allocator();
    var health = try j.parse(ha,
        \\{"config_pin":"revision","tool_count":3,"checked_at_ms":1234,"private":"provider-message"}
    );
    const cases = [_]struct { raw: []const u8, status: []const u8 }{
        .{ .raw = "pending", .status = "checking" },
        .{ .raw = "checking", .status = "checking" },
        .{ .raw = "online", .status = "connected" },
        .{ .raw = "connected", .status = "connected" },
        .{ .raw = "completed", .status = "connected" },
        .{ .raw = "success", .status = "connected" },
        .{ .raw = "healthy", .status = "connected" },
        .{ .raw = "ok", .status = "connected" },
        .{ .raw = "failed", .status = "unavailable" },
        .{ .raw = "offline", .status = "unavailable" },
        .{ .raw = "error", .status = "unavailable" },
        .{ .raw = "unreachable", .status = "unavailable" },
        .{ .raw = "unrecognized provider data", .status = "unavailable" },
    };
    for (cases) |case| {
        try j.set(&health, "status", j.string(case.raw));
        try j.set(&engine.health, "server", health);
        const view = try engine.projection(a, "sidebar");
        try expectServiceStatus(view, case.status);
        const row = j.get(view, "services").array.items[0];
        try std.testing.expectEqual(@as(usize, 4), row.object.count());
        try std.testing.expectEqual(@as(?f64, 3), j.number(j.get(row, "tool_count")));
        try std.testing.expectEqual(@as(?f64, 1234), j.number(j.get(row, "checked_at_ms")));
        const encoded = try j.stringify(a, view);
        for ([_][]const u8{ "secret", "revision", "provider", "endpoint", "origin", "headers", "authorization" }) |forbidden| {
            try std.testing.expect(std.mem.indexOf(u8, encoded, forbidden) == null);
        }
    }
    try j.set(&health, "tool_count", j.string("3"));
    try j.set(&health, "checked_at_ms", .{ .number_string = "1e9999" });
    try j.set(&engine.health, "server", health);
    const view = try engine.projection(a, "sidebar");
    try expectServiceStatus(view, "unavailable");
    try std.testing.expectEqual(@as(usize, 2), j.get(view, "services").array.items[0].object.count());
    for ([_][]const u8{ "test-connection", "refresh-config", "save-config", "server-toggle", "remove" }) |action_name| {
        _ = try engine.action(a, action_name, try j.parse(a, "{\"id\":\"server\",\"authorization\":\"ignored\"}"), ctx);
    }
    try std.testing.expectEqual(@as(usize, 1), MockHost.requests.items.len);
}

test "runtime health is pin scoped and ignores late probes for changed and removed services" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var ctx = try context(a, "health");
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    const payload = try j.parse(a, "{\"id\":\"server\"}");
    const original = try resources(a);
    _ = try engine.initialize(a, ctx);
    try expectServiceStatus(sidebarPatch(try deliver(&engine, a, ctx, original)), "unchecked");

    try expectServiceStatus(sidebarPatch(try engine.action(a, "test-connection", payload, ctx)), "unchecked");
    try toCatalog(&engine, a, ctx);
    const checked = try deliver(&engine, a, ctx, try rpcResponse(a, try catalog(a)));
    try expectServiceStatus(sidebarPatch(checked), "connected");
    const exported = j.get(j.get(j.get(j.get(checked, "vars_patch"), "settings"), "health"), "server");
    try std.testing.expect(j.is(j.get(exported, "status"), "online"));
    try std.testing.expect(!exported.object.contains("config_pin"));
    _ = try engine.action(a, "refresh-config", .null, ctx);
    try expectServiceStatus(sidebarPatch(try deliver(&engine, a, ctx, original)), "connected");

    _ = try engine.action(a, "test-connection", payload, ctx);
    try toCatalog(&engine, a, ctx);
    const old_http = try event(a, MockHost.last().id, try rpcResponse(a, try catalog(a)));
    _ = try engine.action(a, "test-connection", payload, ctx);
    const old_list_id = MockHost.last().id;
    const updated = try resources(a);
    try j.set(&updated.array.items[0], "config_pin", j.string("new-revision"));
    _ = try engine.action(a, "refresh-config", .null, ctx);
    try expectServiceStatus(sidebarPatch(try deliver(&engine, a, ctx, updated)), "unchecked");
    try std.testing.expectEqual(@as(usize, 0), engine.health.object.count());
    const before = MockHost.requests.items.len;
    try expectServiceStatus(sidebarPatch(try engine.phase(a, "event-result", old_http, ctx)), "unchecked");
    try expectServiceStatus(sidebarPatch(try engine.phase(a, "event-result", try event(a, old_list_id, original), ctx)), "unchecked");
    try std.testing.expectEqual(before, MockHost.requests.items.len);

    // A resource-list result can also disagree with the action pin before a
    // configuration response reaches the guest. Do not start HTTP in that case.
    _ = try engine.action(a, "test-connection", payload, ctx);
    const before_list = MockHost.requests.items.len;
    try expectServiceStatus(sidebarPatch(try deliver(&engine, a, ctx, original)), "unchecked");
    try std.testing.expectEqual(before_list, MockHost.requests.items.len);

    _ = try engine.action(a, "test-connection", payload, ctx);
    _ = try deliver(&engine, a, ctx, updated);
    try fromInitialize(&engine, a, ctx);
    try expectServiceStatus(sidebarPatch(try deliver(&engine, a, ctx, try rpcResponse(a, try catalog(a)))), "connected");
    try j.set(&ctx, "session_id", j.string("different-scope"));
    try expectServiceStatus(sidebarPatch(try engine.phase(a, "observe", .null, ctx)), "unchecked");

    _ = try engine.action(a, "test-connection", payload, ctx);
    const removed_list_id = MockHost.last().id;
    _ = try engine.action(a, "remove", payload, ctx);
    _ = try deliver(&engine, a, ctx, j.array(a));
    const removed = try engine.phase(a, "event-result", try event(a, removed_list_id, updated), ctx);
    try std.testing.expectEqual(@as(usize, 0), j.get(sidebarPatch(removed), "services").array.items.len);
    try std.testing.expectEqual(@as(usize, 0), pendingCount(&engine));
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
}
test "runtime projection budgets preserve concrete diagnostics and model completion" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = try context(a, "projection-budget");
    _ = try engine.initialize(a, ctx);
    const inventory = try resources(a);
    const id = try a.alloc(u8, 40 * 1024);
    @memset(id, 'i');
    try j.set(&inventory.array.items[0], "id", j.string(id));
    _ = try deliver(&engine, a, ctx, inventory);
    var request = try j.parse(a, "{\"action\":\"list\"}");
    const tool = try a.alloc(u8, 30 * 1024);
    @memset(tool, 't');
    try j.set(&request, "tool", j.string(tool));
    _ = try engine.start(a, request, ctx);
    const ha = engine.health_arena.allocator();
    var health = try j.parse(ha, "{\"config_pin\":\"revision\"}");
    const oversized = try ha.alloc(u8, 70 * 1024);
    @memset(oversized, 'x');
    try j.set(&health, "status", j.string(oversized));
    try j.set(&engine.health, try ha.dupe(u8, id), health);
    const completion = try j.parse(a, "{\"identity\":{\"invocation_id\":\"completed\"},\"status\":\"completed\",\"output\":{\"content\":[]}}");
    const result = try engine.result(a, completion);
    try std.testing.expect(try j.equal(a, completion, j.get(result, "tool_completion")));
    const settings = j.get(j.get(result, "vars_patch"), "settings");
    try std.testing.expect(j.is(j.get(settings, "error"), "ProjectionByteBudget"));
    try Engine.validateProjection(a, settings);
    const sidebar = sidebarPatch(result);
    try std.testing.expect(j.is(j.get(sidebar, "error"), "ProjectionByteBudget"));
    try std.testing.expectEqual(@as(usize, 0), j.get(sidebar, "services").array.items.len);
    try std.testing.expectEqual(@as(usize, 0), j.get(sidebar, "records").array.items.len);
    try std.testing.expectEqual(@as(usize, 1), engine.records.items.len);
    try Engine.validateProjection(a, sidebar);
    _ = try deliver(&engine, a, ctx, j.array(a));
    _ = try engine.initialize(a, ctx);
    const restored = sidebarPatch(try deliver(&engine, a, ctx, j.array(a)));
    try std.testing.expect(j.is(j.get(restored, "error"), ""));
    try std.testing.expectEqual(@as(usize, 1), j.get(restored, "records").array.items.len);
    var deep: V = .null;
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        var parent = j.array(a);
        try parent.array.append(deep);
        deep = parent;
    }
    try std.testing.expectError(error.ProjectionDepthBudget, Engine.validateProjection(a, deep));
    var wide = j.array(a);
    i = 0;
    while (i < 4096) : (i += 1) try wide.array.append(.null);
    try std.testing.expectError(error.ProjectionNodeBudget, Engine.validateProjection(a, wide));
}

test "runtime aggregate isolates failed peers and releases previous large catalogs" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = try context(a, "aggregate");
    _ = try engine.start(a, try j.parse(a, "{\"action\":\"list\",\"limit\":2}"), ctx);
    const inventory = try j.parse(a, "[{\"id\":\"c\",\"enabled\":true,\"config_pin\":\"c-revision\"},{\"id\":\"a\",\"enabled\":true,\"config_pin\":\"a-revision\"},{\"id\":\"b\",\"enabled\":true,\"config_pin\":\"b-revision\"}]");
    _ = try deliver(&engine, a, ctx, inventory);
    try std.testing.expect(j.is(j.get(try j.parse(a, MockHost.last().payload), "resource"), "a"));
    _ = try deliver(&engine, a, ctx, try j.parse(a, "{\"status\":503,\"headers\":{},\"body\":\"private remote error\"}"));
    try std.testing.expect(j.is(j.get(try j.parse(a, MockHost.last().payload), "resource"), "b"));
    try fromInitialize(&engine, a, ctx);
    var large_catalog = try catalog(a);
    const description = try a.alloc(u8, 512 * 1024);
    @memset(description, 'd');
    try j.set(&large_catalog.object.getPtr("tools").?.array.items[0], "description", j.string(description));
    _ = try deliver(&engine, a, ctx, try rpcResponse(a, large_catalog));
    try std.testing.expect(j.is(j.get(try j.parse(a, MockHost.last().payload), "resource"), "c"));
    try std.testing.expect(engine.budget.used < 256 * 1024);
    try fromInitialize(&engine, a, ctx);
    const completed = try deliver(&engine, a, ctx, try rpcResponse(a, try catalog(a)));
    const completion = j.get(completed, "tool_completion");
    try std.testing.expect(j.is(j.get(completion, "status"), "completed"));
    const peers = j.get(j.get(completion, "output"), "servers");
    try std.testing.expectEqual(@as(usize, 3), peers.array.items.len);
    try std.testing.expect(j.get(peers.array.items[0], "error") == .string);
    try std.testing.expectEqual(@as(usize, 0), j.get(peers.array.items[0], "tools").array.items.len);
    try std.testing.expectEqual(@as(usize, 1), j.get(peers.array.items[1], "tools").array.items.len);
    try std.testing.expectEqual(@as(usize, 1), j.get(peers.array.items[2], "tools").array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, try j.stringify(a, completion), "private remote error") == null);
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
}

test "runtime initialization handshake describe pinned call and schema failure without dispatch" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = try context(a, "describe");
    _ = try engine.initialize(a, ctx);
    try std.testing.expectEqualStrings("resource-list", MockHost.last().kind);
    _ = try deliver(&engine, a, ctx, try resources(a));
    const described = try describe(&engine, a, ctx);
    const pin = j.get(described, "call_pin");
    try std.testing.expect(j.text(pin).?.len == 16);
    const call_ctx = try context(a, "call");
    var request = try j.parse(a, "{\"action\":\"call\",\"arguments\":{\"x\":1}}");
    try j.set(&request, "pin", pin);
    _ = try engine.start(a, request, call_ctx);
    try toCatalog(&engine, a, call_ctx);
    _ = try deliver(&engine, a, call_ctx, try rpcResponse(a, try catalog(a)));
    try std.testing.expectEqualStrings("tools/call", try MockHost.method(a));
    var finished_ctx = try j.clone(a, call_ctx);
    try j.set(&finished_ctx, "host_monotonic_ms", .{ .integer = 35 });
    const completed = try deliver(&engine, a, finished_ctx, try rpcResponse(a, try j.parse(a, "{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}")));
    try std.testing.expect(j.is(j.get(j.get(completed, "tool_completion"), "status"), "completed"));
    const observed = j.get(try engine.projection(a, "sidebar"), "records").array.items[0];
    try std.testing.expectEqual(@as(f64, 25), j.number(j.get(observed, "duration_ms")).?);
    try std.testing.expectEqual(@as(usize, 0), pendingCount(&engine));
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
    const bad_ctx = try context(a, "bad");
    try j.set(&request, "arguments", try j.parse(a, "{\"x\":\"wrong\"}"));
    _ = try engine.start(a, request, bad_ctx);
    try toCatalog(&engine, a, bad_ctx);
    const before = MockHost.requests.items.len;
    const failed = try deliver(&engine, a, bad_ctx, try rpcResponse(a, try catalog(a)));
    const failure = j.get(failed, "tool_completion");
    try std.testing.expect(j.is(j.get(failure, "status"), "failed"));
    try std.testing.expect(!j.truth(j.get(failure, "outcome_unknown")));
    try std.testing.expectEqual(before, MockHost.requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
}
test "runtime complete identity cancellation cleanup and late response fencing" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = try context(a, "describe");
    const described = try describe(&engine, a, ctx);
    const call_ctx = try context(a, "call");
    var request = try j.parse(a, "{\"action\":\"call\",\"arguments\":{\"x\":1}}");
    try j.set(&request, "pin", j.get(described, "call_pin"));
    _ = try engine.start(a, request, call_ctx);
    try toCatalog(&engine, a, call_ctx);
    _ = try deliver(&engine, a, call_ctx, try rpcResponse(a, try catalog(a)));
    const call_id = MockHost.last().id;
    const call_payload = try j.parse(a, MockHost.last().payload);
    const rpc = try j.parse(a, j.text(j.get(call_payload, "body")).?);
    const wrong = try context(a, "other");
    const before = MockHost.requests.items.len;
    _ = try engine.cancel(a, wrong);
    try std.testing.expectEqual(@as(usize, 1), pendingCount(&engine));
    try std.testing.expectEqual(before, MockHost.requests.items.len);
    const cancelled = try engine.cancel(a, call_ctx);
    try std.testing.expect(j.get(cancelled, "tool_completion") == .null);
    try std.testing.expectEqualStrings("notifications/cancelled", try MockHost.method(a));
    const cleanup = try j.parse(a, MockHost.last().payload);
    try std.testing.expect(j.is(j.get(cleanup, "response_mode"), "discard"));
    const cleanup_body = try j.parse(a, j.text(j.get(cleanup, "body")).?);
    try std.testing.expect(try j.equal(a, j.get(j.get(cleanup_body, "params"), "requestId"), j.get(rpc, "id")));
    try std.testing.expectEqual(@as(usize, 0), pendingCount(&engine));
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
    const sidebar = try engine.projection(a, "sidebar");
    const rows = j.get(sidebar, "records");
    try std.testing.expect(j.is(j.get(rows.array.items[0], "status"), "cancelled"));
    try std.testing.expect(j.truth(j.get(rows.array.items[0], "outcome_unknown")));
    const late = try engine.phase(a, "event-result", try event(a, call_id, .null), call_ctx);
    try std.testing.expect(j.get(late, "tool_completion") == .null);
}
test "runtime dispatched transport failure is unknown and never replays" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const described = try describe(&engine, a, try context(a, "describe"));
    const ctx = try context(a, "uncertain");
    var request = try j.parse(a, "{\"action\":\"call\",\"arguments\":{\"x\":1}}");
    try j.set(&request, "pin", j.get(described, "call_pin"));
    _ = try engine.start(a, request, ctx);
    try toCatalog(&engine, a, ctx);
    _ = try deliver(&engine, a, ctx, try rpcResponse(a, try catalog(a)));
    const dispatched = MockHost.requests.items.len;
    var failed_event = j.object(a);
    try j.set(&failed_event, "request_id", .{ .integer = MockHost.last().id });
    try j.set(&failed_event, "ok", .{ .bool = false });
    try j.set(&failed_event, "error", j.string("connection lost"));
    const failed = try engine.phase(a, "event-result", failed_event, ctx);
    const completion = j.get(failed, "tool_completion");
    try std.testing.expect(j.is(j.get(completion, "status"), "failed"));
    try std.testing.expect(j.truth(j.get(completion, "outcome_unknown")));
    try std.testing.expectEqual(dispatched, MockHost.requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), pendingCount(&engine));
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
    const late = try engine.phase(a, "event-result", failed_event, ctx);
    try std.testing.expect(j.get(late, "tool_completion") == .null);
    try std.testing.expectEqual(dispatched, MockHost.requests.items.len);
}

test "runtime pending admission history clearing and reset release exact owned memory" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const initial = try context(a, "history-inventory");
    _ = try engine.initialize(a, initial);
    _ = try deliver(&engine, a, initial, try resources(a));
    const request = try j.parse(a, "{\"action\":\"list\"}");
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const ctx = try context(a, try std.fmt.allocPrint(a, "i{d}", .{i}));
        _ = try engine.start(a, request, ctx);
    }
    try std.testing.expectEqual(@as(usize, 32), pendingCount(&engine));
    const before = MockHost.requests.items.len;
    const ctx = try context(a, "overflow");
    const denied = try engine.start(a, request, ctx);
    try std.testing.expect(j.is(j.get(j.get(denied, "tool_completion"), "status"), "failed"));
    try std.testing.expectEqual(before, MockHost.requests.items.len);
    _ = try engine.action(a, "clear-history", .null, ctx);
    try std.testing.expectEqual(@as(usize, 0), engine.records.items.len);
    try std.testing.expectEqual(@as(usize, 32), pendingCount(&engine));
    _ = try engine.phase(a, "history-reset", .null, ctx);
    try std.testing.expectEqual(@as(usize, 0), pendingCount(&engine));
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
    const kept_ctx = try context(a, "kept-pending");
    _ = try engine.start(a, request, kept_ctx);
    const kept_id = engine.records.items[0].id;
    i = 0;
    while (i < 140) : (i += 1) {
        const next_ctx = try context(a, try std.fmt.allocPrint(a, "history{d}", .{i}));
        _ = try engine.start(a, request, next_ctx);
        _ = try deliver(&engine, a, next_ctx, try j.parse(a, "[]"));
    }
    try std.testing.expectEqual(@as(usize, 128), engine.records.items.len);
    try std.testing.expect(engine.history_bytes <= 2 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), pendingCount(&engine));
    try std.testing.expectEqual(kept_id, engine.records.items[0].id);
    try std.testing.expectEqualStrings("pending", engine.records.items[0].status);
    try expectServiceStatus(sidebarPatch(try engine.phase(a, "observe", .null, kept_ctx)), "unchecked");
    const paged = sidebarPatch(try engine.action(a, "history-page", try j.parse(a, "{\"page\":1}"), kept_ctx));
    try expectServiceStatus(paged, "unchecked");
    try std.testing.expectEqual(@as(?u64, 1), j.uint(j.get(paged, "page")));
    try std.testing.expectEqual(@as(?u64, 10), j.uint(j.get(paged, "page_size")));
    try std.testing.expectEqual(@as(?u64, 128), j.uint(j.get(paged, "total_records")));
    try std.testing.expectEqual(@as(?u64, 128), j.uint(j.get(j.get(paged, "metrics"), "total")));
    try std.testing.expectEqual(@as(usize, 10), j.get(paged, "records").array.items.len);
    try std.testing.expect(j.get(paged, "detail") == .null);
    try std.testing.expect(j.get(paged, "selected_id") == .null);
    var changed = try context(a, "changed");
    try j.set(&changed, "history_generation", .{ .integer = 2 });
    try engine.updateContext(a, changed);
    try std.testing.expectEqual(@as(usize, 0), engine.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.history_bytes);
}
test "runtime large completed results evict history by bytes and keep projections bounded" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const described = try describe(&engine, a, try context(a, "describe"));
    var request = try j.parse(a, "{\"action\":\"call\",\"arguments\":{\"x\":1}}");
    try j.set(&request, "pin", j.get(described, "call_pin"));
    var output = try j.parse(a, "{\"content\":[{\"type\":\"text\"}]}");
    const text = try a.alloc(u8, 58 * 1024);
    @memset(text, 'x');
    try j.set(&output.object.getPtr("content").?.array.items[0], "text", j.string(text));
    var i: usize = 0;
    while (i < 36) : (i += 1) {
        const ctx = try context(a, try std.fmt.allocPrint(a, "large{d}", .{i}));
        _ = try engine.start(a, request, ctx);
        try toCatalog(&engine, a, ctx);
        _ = try deliver(&engine, a, ctx, try rpcResponse(a, try catalog(a)));
        const done = try deliver(&engine, a, ctx, try rpcResponse(a, output));
        try std.testing.expect(j.is(j.get(j.get(done, "tool_completion"), "status"), "completed"));
    }
    try std.testing.expect(engine.records.items.len < 36);
    try std.testing.expect(engine.records.items.len > 0);
    try std.testing.expect(engine.history_bytes <= 2 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used);
    const view = try engine.projection(a, "sidebar");
    try std.testing.expect(j.get(view, "records").array.items.len <= 10);
    try std.testing.expect((try j.stringify(a, view)).len < 64 * 1024);
    const id = engine.records.items[engine.records.items.len - 1].id;
    var inspect = j.object(a);
    try j.set(&inspect, "id", .{ .integer = @intCast(id) });
    _ = try engine.action(a, "inspect-history", inspect, try context(a, "inspect"));
    const detail = j.get(try engine.projection(a, "sidebar"), "detail");
    try std.testing.expect(j.truth(j.get(detail, "omitted")));
    try std.testing.expect(j.text(j.get(detail, "source")).?.len <= 4096);
    try std.testing.expect(j.uint(j.get(detail, "total_bytes")).? > 4096);
}

test "runtime detail chunks normalize arbitrary UTF8 offsets" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = try context(a, "utf8");
    const request = try j.parse(a, "{\"action\":\"list\",\"arguments\":{\"x\":\"你好世界\"}}");
    _ = try engine.start(a, request, ctx);
    const record = engine.records.items[0];
    const position = std.mem.indexOf(u8, record.arguments, "你").?;
    var inspect = try j.parse(a, "{\"field\":\"arguments\"}");
    try j.set(&inspect, "id", .{ .integer = @intCast(record.id) });
    try j.set(&inspect, "offset", .{ .integer = @intCast(position + 1) });
    _ = try engine.action(a, "inspect-history", inspect, ctx);
    const detail = j.get(try engine.projection(a, "sidebar"), "detail");
    try std.testing.expect(std.unicode.utf8ValidateSlice(j.text(j.get(detail, "source")).?));
    try std.testing.expectEqual(@as(u64, @intCast(position)), j.uint(j.get(detail, "offset")).?);
}

test "runtime configuration credentials remain transient and are absent from projections" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var ctx = try context(a, "settings");
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    const config = try j.parse(a, "{\"id\":\"server\",\"endpoint\":\"https://mcp.test/path\",\"enabled\":true,\"authorization\":\"Bearer secret-never-project\"}");
    const reply = try engine.action(a, "save-config", config, ctx);
    try std.testing.expectEqualStrings("resource-configure", MockHost.last().kind);
    try std.testing.expect(std.mem.indexOf(u8, MockHost.last().payload, "secret-never-project") != null);
    try std.testing.expect(std.mem.indexOf(u8, try j.stringify(a, reply), "secret-never-project") == null);
    var inventory = try resources(a);
    try j.set(&inventory.array.items[0], "authorization", j.string("Bearer host-readback-forbidden"));
    _ = try deliver(&engine, a, ctx, inventory);
    const projection = try j.stringify(a, try engine.projection(a, "setting-page"));
    try std.testing.expect(std.mem.indexOf(u8, projection, "secret-never-project") == null);
    try std.testing.expect(std.mem.indexOf(u8, projection, "host-readback-forbidden") == null);
    try std.testing.expectEqual(@as(usize, 0), engine.records.items.len);
    try j.set(&ctx, "user_action", .{ .bool = false });
    const before = MockHost.requests.items.len;
    _ = try engine.action(a, "save-config", config, ctx);
    try std.testing.expectEqual(before, MockHost.requests.items.len);
}
