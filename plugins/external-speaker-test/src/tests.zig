const std = @import("std");
const origin = @import("origin.zig");
const request = @import("request.zig");
const runtime = @import("runtime.zig");
const Budget = @import("budget.zig").Budget;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const allocator = std.testing.allocator;
const site = "http://127.0.0.1:18765";
const uuid = "12345678-1234-4234-9234-123456789abc";
const other_uuid = "12345678-1234-4234-9234-123456789abd";
const token = "fixture_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

const Host = struct {
    var count: u32 = 0;
    var bytes: [1024]u8 = undefined;
    var len: usize = 0;
    var fail: bool = false;
    var resource_count: u32 = 0;
    var resource_kind: []const u8 = "";
    var resource_wire: [1024]u8 = undefined;
    var resource_len: usize = 0;

    pub fn resources(kind: []const u8, wire: []const u8) ?u32 {
        resource_count += 1;
        resource_kind = kind;
        @memcpy(resource_wire[0..wire.len], wire);
        resource_len = wire.len;
        return 100;
    }

    pub fn net(wire: []const u8) ?u32 {
        count += 1;
        @memcpy(bytes[0..wire.len], wire);
        len = wire.len;
        return if (fail) null else 99;
    }
};

const ctx_json =
    \\{"server_origin":"http://127.0.0.1:18765","session_id":"session-1","user_action":true,
    \\"surface":{"target":"sidebar","surface_id":"mount-a"},"target_visible":true,
    \\"surface_generation":1,"history_generation":2}
;
const payload_json =
    \\{"session":"session-1","action_id":7,"message":"A 'quote'\nand \"line\"","operation":"
++ uuid ++ "\"}";

fn context(a: std.mem.Allocator) !std.json.Value {
    return runtime.parse(a, ctx_json, runtime.max_context);
}

const active_endpoint = site ++ "/api/v1/sessions/session-1/inbox";
const external_endpoint = "https://speaker.example.test:8443/api/v1/sessions/remote-23/inbox";
const active_id = "speaker-yzcTPiWlkiYBIZ55G4fA3jfswAiV_WfVcAonGny0UcI";
const external_id = "speaker-LJ6S__RbvRb1EtIfexL8KI19HHmDX9MYJqNA6wqC0k8";
const pin = "fixture-config-pin";

fn grantCompletion(a: std.mem.Allocator, id: []const u8, endpoint: []const u8, enabled: bool) !std.json.Value {
    const raw = try std.json.stringifyAlloc(a, .{
        .request_id = 100,
        .ok = true,
        .value = .{.{ .id = id, .endpoint = endpoint, .config_pin = pin, .enabled = enabled, .methods = .{"POST"} }},
    }, .{});
    return runtime.parse(a, raw, runtime.max_completion);
}

fn listAction(a: std.mem.Allocator) !std.json.Value {
    return runtime.parse(a, "{\"action_id\":8}", runtime.max_action);
}

fn objectSet(v: *std.json.Value, name: []const u8, value: std.json.Value) void {
    v.object.getPtr(name).?.* = value;
}

test "exact canonical origins, HTTPS and loopback HTTP only" {
    for ([_][]const u8{ site, "http://localhost", "http://127.12.34.56", "http://[::1]:8080", "https://speaker.example.test", "https://127.0.0.1:444", "https://[2001:db8::1]" }) |value| try expect(origin.valid(value));
    for ([_][]const u8{ "", "null", "https://", "https://UPPER.test", "https://speaker.example.test/", "https://speaker.example.test#frag", "https://speaker.example.test?q", "https://user@localhost", "https://speaker.example.test:443", "https://example.test:0", "https://example.test:0444", "https://example.0", "https://0x7f.0x01", "http://127.1", "http://127.0.0.01", "http://127.0.0.256", "http://[::ffff:7f00:1]", "http://localhost.evil.test", "http://198.51.100.1", "http://0.0.0.0", "http://[0:0:0:0:0:0:0:1]", "https://[2001:db8:0:0:0:0:0:1]" }) |value| try expect(!origin.valid(value));
}

test "request validation prevents header and route injection" {
    try expect(request.validOperation(uuid));
    try expect(!request.validOperation("12345678-1234-1234-9234-123456789abc"));
    try expect(!request.validToken(token ++ "\n"));
    try expect(!request.validSession("../inbox"));
    try expect(!request.validSession("abc%2Fdef"));
    try expect(!request.validMessage(" \n\u{3000}"));
    try expect(request.validMessage("hi 🦀"));
    try expect(request.validMessage(&([_]u8{'a'} ** request.message_limit)));
    try expect(!request.validMessage(&([_]u8{'a'} ** (request.message_limit + 1))));
}

test "scope and explicit action guard one POST; preview has placeholder only" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var guest = runtime.Runtime(Host){ .allocator = allocator };
    defer guest.deinit();
    Host.count = 0;
    Host.fail = false;
    const c = try context(a);
    const p = try runtime.parse(a, payload_json, runtime.max_action);
    var bad = try context(a);
    objectSet(&bad, "server_origin", .{ .string = "http://unsafe.example" });
    try expect(!(try guest.action(a, "send", p, bad)));
    try expect((try guest.projection(a, bad)).issue.? == .unsupported_origin);
    objectSet(&bad, "server_origin", .{ .string = site });
    objectSet(&bad, "session_id", .{ .string = "session-2" });
    try expect(!(try guest.action(a, "send", p, bad)));
    objectSet(&bad, "session_id", .{ .string = "session-1" });
    objectSet(&bad, "user_action", .{ .bool = false });
    try expect(!(try guest.action(a, "send", p, bad)));
    objectSet(&bad, "user_action", .{ .bool = true });
    objectSet(&bad, "target_visible", .{ .bool = false });
    try expect(!(try guest.action(a, "send", p, bad)));
    try expect(!(try guest.action(a, "retry", p, c)));
    try eq(@as(u32, 0), Host.count);

    try expect(try guest.action(a, "preview", p, c));
    const preview = (try guest.projection(a, c)).preview.?;
    try expect(std.mem.indexOf(u8, preview, "Bearer <EXTERNAL_SPEAKER_TOKEN>") != null);
    try expect(std.mem.indexOf(u8, preview, "'\\''quote'\\''") != null);
    try expect(std.mem.indexOf(u8, preview, token) == null);
    try eq(@as(u32, 0), Host.count);

    try expect(try guest.action(a, "send", p, c));
    try expect((try guest.projection(a, c)).status == .unavailable);
    try eq(@as(u32, 0), Host.count);
    try expect(try guest.action(a, "list", try listAction(a), c));
    try strings("resource-list", Host.resource_kind);
    try strings("{}", Host.resource_wire[0..Host.resource_len]);
    try expect(guest.complete(a, try grantCompletion(a, active_id, active_endpoint, true), c));
    try expect((try guest.projection(a, c)).host_credentials);

    try expect(try guest.action(a, "send", p, c));
    try expect(!(try guest.action(a, "send", p, c)));
    const wire = try std.json.parseFromSlice(struct {
        url: []const u8,
        resource: []const u8,
        config_pin: []const u8,
        method: []const u8,
        headers: struct { @"Content-Type": []const u8, @"Idempotency-Key": []const u8 },
        body: []const u8,
    }, a, Host.bytes[0..Host.len], .{});
    defer wire.deinit();
    try strings(active_endpoint, wire.value.url);
    try strings(active_id, wire.value.resource);
    try strings(pin, wire.value.config_pin);
    try strings("POST", wire.value.method);
    try expect(std.mem.indexOf(u8, Host.bytes[0..Host.len], "Authorization") == null);
    try strings("application/json", wire.value.headers.@"Content-Type");
    try strings(uuid, wire.value.headers.@"Idempotency-Key");
    try strings("{\"body\":\"A 'quote'\\nand \\\"line\\\"\"}", wire.value.body);

    const completion = try runtime.parse(a,
        \\{"request_id":99,"ok":true,"value":{"status":202,"body":"{\"status\":\"queued\",\"ordinal\":18446744073709551615,\"operation_id\":\"
    ++ uuid ++ "\\\"}\"}}", runtime.max_completion);
    objectSet(&bad, "target_visible", .{ .bool = true });
    objectSet(&bad, "server_origin", .{ .string = "http://127.0.0.1:19766" });
    try expect(!guest.complete(a, completion, bad));
    try expect((try guest.projection(a, bad)).status == null);
    var changed_history = try context(a);
    objectSet(&changed_history, "history_generation", .{ .integer = 3 });
    try expect(!guest.complete(a, completion, changed_history));
    try expect((try guest.projection(a, changed_history)).status == null);
    try expect(guest.complete(a, completion, c));
    try expect(!guest.complete(a, completion, c));
    const result = try guest.projection(a, c);
    try expect(result.status.? == .queued and result.http_status.? == 202);
    try strings("18446744073709551615", result.ordinal.?);
    try strings(uuid, result.operation.?);
    try expect(std.mem.indexOf(u8, result.preview.?, token) == null);
    try strings(wire.value.body, result.request.?.body);
    try eq(@as(u16, 202), result.response.?.status);
    try expect(try guest.action(a, "send", p, c));
    try eq(@as(u32, 1), Host.count);
    try expect((try guest.projection(a, c)).status.? == .operation_already_used);

    var p2 = try runtime.parse(a, payload_json, runtime.max_action);
    objectSet(&p2, "operation", .{ .string = other_uuid });
    Host.fail = true;
    try expect(try guest.action(a, "send", p2, c));
    try expect((try guest.projection(a, c)).status.? == .outcome_unknown);
    try eq(@as(u32, 2), Host.count);
    try expect(try guest.action(a, "preview", p, bad));
    try expect(std.mem.indexOf(u8, (try guest.projection(a, bad)).preview.?, "http://127.0.0.1:19766/api/v1/sessions/session-1/inbox") != null);
    try expect((try guest.projection(a, c)).status == null);
    try eq(@as(u32, 2), Host.count);
}

test "acknowledged POST starts exact SSE and retains only matching ordered reply events" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var guest = runtime.Runtime(Host){ .allocator = allocator };
    defer guest.deinit();
    Host.count = 0;
    Host.fail = false;
    const c = try context(a);
    try expect(try guest.action(a, "list", try runtime.parse(a, "{\"action_id\":1}", runtime.max_action), c));
    try expect(guest.complete(a, try grantCompletion(a, active_id, active_endpoint, true), c));
    try expect(try guest.action(a, "send", try runtime.parse(a, payload_json, runtime.max_action), c));
    const accepted = try std.json.stringifyAlloc(a, .{ .request_id = 99, .ok = true, .value = .{ .status = 202, .body = "{\"status\":\"queued\",\"ordinal\":1,\"operation_id\":\"" ++ uuid ++ "\",\"dialogue_id\":\"0123abcd\"}" } }, .{});
    try expect(guest.complete(a, try runtime.parse(a, accepted, runtime.max_completion), c));
    try eq(@as(u32, 2), Host.count);
    try expect(std.mem.indexOf(u8, Host.bytes[0..Host.len], "\"method\":\"GET\"") != null);
    try expect(std.mem.indexOf(u8, Host.bytes[0..Host.len], active_endpoint) != null);
    try expect(std.mem.indexOf(u8, Host.bytes[0..Host.len], "\"X-MicroCrab-Dialogue-Id\":\"0123abcd\"") != null);
    const wrong = try sse(a, "chunk", "{\"dialogue_id\":\"0123abcd\",\"index\":1,\"message\":\"out of order\"}");
    try expect(!guest.complete(a, wrong, c));
    const chunk = try sse(a, "chunk", "{\"dialogue_id\":\"0123abcd\",\"index\":0,\"message\":\"explicit reply\",\"is_final\":true}");
    try expect(guest.complete(a, chunk, c));
    try expect(!guest.complete(a, chunk, c));
    try expect((try guest.projection(a, c)).reply.?.status == .consumed);
    const escaped = try std.json.stringifyAlloc(a, .{
        .dialogue_id = "0123abcd",
        .index = 1,
        .message = "x" ++ ("\x01" ** 8191),
    }, .{});
    try expect(escaped.len > 32 * 1024 and escaped.len < 64 * 1024);
    try expect(guest.complete(a, try sse(a, "chunk", escaped), c));
    const done = try sse(a, "done", "{\"dialogue_id\":\"0123abcd\",\"status\":\"completed\",\"total_chunks\":2}");
    try expect(guest.complete(a, done, c));
    const result = (try guest.projection(a, c)).reply.?;
    try expect(result.status == .completed);
    try strings("explicit reply", result.chunks[0].message);
    const terminal = try runtime.parse(a, "{\"request_id\":99,\"ok\":true,\"value\":{\"status\":200}}", runtime.max_completion);
    try expect(!guest.complete(a, terminal, c));
    try expect((try guest.projection(a, c)).reply.?.status == .completed);
}

fn sse(a: std.mem.Allocator, event: []const u8, data: []const u8) !std.json.Value {
    const body = try std.json.stringifyAlloc(a, .{ .request_id = 99, .ok = true, .value = .{ .type = "sse-event", .event = event, .data = data } }, .{});
    return runtime.parse(a, body, runtime.max_completion);
}

test "authorization requires a valid key, sends exact resource POST and redacts response" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var guest = runtime.Runtime(Host){ .allocator = allocator };
    defer guest.deinit();
    Host.count = 0;
    Host.resource_count = 0;
    Host.fail = false;
    const c = try context(a);
    const authorize_json = "{\"action_id\":9,\"endpoint\":\"" ++ external_endpoint ++ "\",\"name\":\"Remote\",\"token\":\"";
    const invalid = try runtime.parse(a, authorize_json ++ "short\"}", runtime.max_action);
    try expect(try guest.action(a, "authorize", invalid, c));
    try expect((try guest.projection(a, c)).connection_status == .unavailable);
    try eq(@as(u32, 0), Host.resource_count);
    const authorize = try runtime.parse(a, authorize_json ++ token ++ "\"}", runtime.max_action);
    var passive = try context(a);
    objectSet(&passive, "user_action", .{ .bool = false });
    try expect(!(try guest.action(a, "authorize", authorize, passive)));
    try expect(try guest.action(a, "authorize", authorize, c));
    try strings("resource-configure", Host.resource_kind);
    try strings("{\"id\":\"" ++ external_id ++ "\",\"endpoint\":\"" ++ external_endpoint ++ "\",\"enabled\":true,\"authorization\":\"Bearer " ++ token ++ "\",\"methods\":[\"POST\",\"GET\"]}", Host.resource_wire[0..Host.resource_len]);
    try expect(guest.complete(a, try grantCompletion(a, external_id, external_endpoint, true), c));
    const loaded = try guest.projection(a, c);
    try expect(loaded.connection_status == .ready);
    try expect(loaded.connections.len == 1 and loaded.connections[0].enabled);
    const projection_json = try std.json.stringifyAlloc(a, loaded, .{});
    for ([_][]const u8{ token, pin, external_id }) |private| try expect(std.mem.indexOf(u8, projection_json, private) == null);
    const send = try runtime.parse(a, "{\"session\":\"session-1\",\"endpoint\":\"" ++ external_endpoint ++ "\",\"action_id\":7,\"message\":\"hello\",\"operation\":\"" ++ uuid ++ "\"}", runtime.max_action);
    try expect(try guest.action(a, "send", send, c));
    try eq(@as(u32, 1), Host.count);
    try expect(std.mem.indexOf(u8, Host.bytes[0..Host.len], external_endpoint) != null);
    const raw_response = try std.json.stringifyAlloc(a, .{
        .request_id = 99,
        .ok = true,
        .value = .{
            .status = 403,
            .headers = .{ .@"content-type" = "text/plain", .@"set-cookie" = token, .@"x-echo" = "Bearer " ++ token },
            .body = "denied " ++ ("x" ** 100) ++ token ++ "!",
        },
    }, .{});
    try expect(guest.complete(a, try runtime.parse(a, raw_response, runtime.max_completion), c));
    const view = try guest.projection(a, c);
    try strings(external_endpoint, view.endpoint.?);
    try strings("Bearer <EXTERNAL_SPEAKER_TOKEN>", view.request.?.headers.Authorization);
    try strings("{\"body\":\"hello\"}", view.request.?.body);
    try strings("denied <REDACTED>!", view.response.?.body);
    try eq(@as(usize, 2), view.response.?.headers.len);
    try strings("content-type", view.response.?.headers[0].name);
    try strings("Bearer <REDACTED>", view.response.?.headers[1].value);
    try expect(view.status == .rejected);
}

test "artifact-disabled grants are visible but cannot send and require explicit acknowledged removal" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var guest = runtime.Runtime(Host){ .allocator = allocator };
    defer guest.deinit();
    Host.count = 0;
    Host.resource_count = 0;
    const c = try context(a);
    const disabled = try grantCompletion(a, active_id, active_endpoint, false);
    try expect(try guest.action(a, "list", try listAction(a), c));
    try expect(guest.complete(a, disabled, c));
    const grant = (try guest.projection(a, c)).connections[0];
    try strings(active_endpoint, grant.endpoint);
    try expect(!grant.enabled);
    const send = try runtime.parse(a, payload_json, runtime.max_action);
    try expect(try guest.action(a, "send", send, c));
    try expect((try guest.projection(a, c)).status == .unavailable);
    try eq(@as(u32, 0), Host.count);
    try eq(@as(u32, 1), Host.resource_count);
    const revoke = try runtime.parse(a, "{\"action_id\":9,\"endpoint\":\"" ++ active_endpoint ++ "\"}", runtime.max_action);
    try expect(try guest.action(a, "revoke", revoke, c));
    try strings("resource-configure", Host.resource_kind);
    try strings("{\"id\":\"" ++ active_id ++ "\",\"remove\":true}", Host.resource_wire[0..Host.resource_len]);
    try expect((try guest.projection(a, c)).connection_status == .pending);
    try expect(guest.complete(a, disabled, c));
    try expect((try guest.projection(a, c)).connection_status == .unavailable);
    try expect(try guest.action(a, "revoke", revoke, c));
    const removed = try runtime.parse(a, "{\"request_id\":100,\"ok\":true,\"value\":[]}", runtime.max_completion);
    try expect(guest.complete(a, removed, c));
    try eq(@as(usize, 0), (try guest.projection(a, c)).connections.len);
    try expect((try guest.projection(a, c)).connection_status == .ready);
}

test "receipt rejects mismatched outcomes, IDs, and numeric encodings" {
    const queued = "{\"operation_id\":\"" ++ uuid ++ "\",\"status\":\"queued\",\"ordinal\":1}";
    try eq(@as(u64, 1), (try request.receipt(allocator, 202, uuid, queued)).ordinal);
    try std.testing.expectError(error.InvalidReceipt, request.receipt(allocator, 200, uuid, queued));
    try std.testing.expectError(error.InvalidReceipt, request.receipt(allocator, 202, other_uuid, queued));
    try std.testing.expectError(error.InvalidReceipt, request.receipt(allocator, 202, uuid, "{\"operation_id\":\"" ++ uuid ++ "\",\"status\":\"queued\",\"ordinal\":1e3}"));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(error.DuplicateField, runtime.parse(arena.allocator(), "{\"x\":0,\"x\":1}", 100));
}

test "budget enforces quota and wipes allocated bytes on free" {
    var backing: [128]u8 = undefined;
    var parent = std.heap.FixedBufferAllocator.init(&backing);
    var budget = Budget{ .parent = parent.allocator() };
    const a = budget.allocator();
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 16 * 1024 * 1024 + 1));
    const buf = try a.alloc(u8, token.len);
    @memcpy(buf, token);
    a.free(buf);
    try expect(std.mem.allEqual(u8, backing[0..token.len], 0));
    try eq(@as(usize, 0), budget.used);
}
