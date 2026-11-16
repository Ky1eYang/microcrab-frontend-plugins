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

test "runtime health follows live configuration and ignores removed service completion" {
    MockHost.init();
    defer MockHost.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var ctx = try context(a, "health");
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    _ = try engine.initialize(a, ctx);
    var inventory = j.array(a);
    const ha = engine.health_arena.allocator();
    engine.health = j.object(ha);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const id = try std.fmt.allocPrint(a, "server{d}", .{i});
        var row = try resources(a);
        try j.set(&row.array.items[0], "id", j.string(id));
        if (i < 32) try inventory.array.append(row.array.items[0]);
        try j.set(&engine.health, try ha.dupe(u8, id), try j.parse(ha, "{\"status\":\"online\",\"tool_count\":1}"));
    }
    _ = try deliver(&engine, a, ctx, inventory);
    try std.testing.expectEqual(@as(usize, 32), engine.health.object.count());
    try std.testing.expect(j.get(engine.health, "server39") == .null);
    _ = try engine.action(a, "test-connection", try j.parse(a, "{\"id\":\"server0\"}"), ctx);
    const test_id = MockHost.last().id;
    _ = try engine.action(a, "refresh-config", .null, ctx);
    _ = try deliver(&engine, a, ctx, j.array(a));
    try std.testing.expectEqual(@as(usize, 0), engine.health.object.count());
    _ = try engine.phase(a, "event-result", try event(a, test_id, inventory), ctx);
    try fromInitialize(&engine, a, ctx);
    _ = try deliver(&engine, a, ctx, try rpcResponse(a, try catalog(a)));
    try std.testing.expectEqual(@as(usize, 0), engine.health.object.count());
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
    const ha = engine.health_arena.allocator();
    engine.health = j.object(ha);
    const oversized = try ha.alloc(u8, 70 * 1024);
    @memset(oversized, 'x');
    try j.set(&engine.health, "oversized", j.string(oversized));
    const completion = try j.parse(a, "{\"identity\":{\"invocation_id\":\"completed\"},\"status\":\"completed\",\"output\":{\"content\":[]}}");
    const result = try engine.result(a, completion);
    try std.testing.expect(try j.equal(a, completion, j.get(result, "tool_completion")));
    const settings = j.get(j.get(result, "vars_patch"), "settings");
    try std.testing.expect(j.is(j.get(settings, "error"), "ProjectionByteBudget"));
    try Engine.validateProjection(a, settings);
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
