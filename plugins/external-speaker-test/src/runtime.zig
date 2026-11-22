const std = @import("std");
const shared = @import("shared");
const request = @import("request.zig");
const origin_rules = @import("origin.zig");
const Connection = struct { endpoint: []const u8, name: []const u8, enabled: bool };
const Grant = struct { id: []const u8, pin: []const u8, endpoint: []const u8, enabled: bool };
const ConnectionStatus = enum { pending, ready, unavailable };
const Control = enum { list, authorize, revoke };
const max_grants = 32; // Production PluginResources bound, including disabled artifacts.
const resource_prefix = "speaker-";
const resource_id_len = resource_prefix.len + std.base64.url_safe_no_pad.Encoder.calcSize(32);
const Header = struct { name: []const u8, value: []const u8 };
const HttpResponse = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,
    truncated: bool = false,
};
const ReplyStatus = enum { waiting, queued, consumed, completed, cancelled, interrupted, unavailable };
const ReplyChunk = struct { index: u32, message: []const u8, is_final: bool };
const Reply = struct {
    id: [8]u8,
    status: ReplyStatus = .waiting,
    chunks: std.BoundedArray(ReplyChunk, 16) = .{},
    text_bytes: usize = 0,
    visible_bytes: usize = 0,
    truncated: bool = false,
    reason: ?[]const u8 = null,
};
const ReplyView = struct { dialogue_id: []const u8, status: ReplyStatus, chunks: []const ReplyChunk, reason: ?[]const u8, truncated: bool };
const Value = std.json.Value;
const equal = std.mem.eql;

pub const max_context = 8192;
pub const max_action = 56 * 1024;
pub const max_completion = 128 * 1024;
// Match the Host SSE frame ceiling. JSON escaping can expand 8 KiB of raw
// reply text to nearly 48 KiB; decoded messages keep their separate limit.
const max_reply_event_data_bytes = 64 * 1024;
pub const unchanged = "{\"schema_version\":1}";
pub const rerender = "{\"schema_version\":1,\"rerender\":true}";
const Target = enum(u1) { sidebar, @"expanded-page" };
const Status = enum {
    invalid_message,
    invalid_operation,
    unavailable,
    preview,
    pending,
    queued,
    consumed,
    rejected,
    outcome_unknown,
    operation_already_used,
};

const Scope = struct {
    session: []const u8,
    origin: []const u8,
    mount: []const u8,
    generation: u32,
    history: u32,
};

const Panel = struct {
    session: [128]u8 = undefined,
    session_len: usize = 0,
    origin: [origin_rules.max_len]u8 = undefined,
    origin_len: usize = 0,
    mount: [256]u8 = undefined,
    mount_len: usize = 0,
    generation: u32 = 0,
    history: u32 = 0,
    action_id: ?u32 = null,
    preview: ?[]u8 = null,
    preview_operation: ?[36]u8 = null,
    operation: ?[36]u8 = null,
    pending: ?u32 = null,
    status: ?Status = null,
    http_status: ?u16 = null,
    ordinal: ?u64 = null,
    inspection_arena: ?std.heap.ArenaAllocator = null,
    inspection: ?request.Inspection = null,
    response: ?HttpResponse = null,
    reply: ?Reply = null,
    reply_pending: ?u32 = null,
    external: bool = false,
    connection_pending: ?struct { request_id: u32, action: Control, resource: [resource_id_len]u8 } = null,
    connection_action_id: ?u32 = null,
    connection_status: ?ConnectionStatus = null,
    grants_arena: ?std.heap.ArenaAllocator = null,
    grants: []const Grant = &.{},

    fn clearInspection(self: *Panel, a: std.mem.Allocator) void {
        if (self.preview) |value| a.free(value);
        if (self.inspection_arena) |*arena| arena.deinit();
        self.preview = null;
        self.inspection_arena = null;
        self.inspection = null;
        self.response = null;
        self.reply = null;
        self.reply_pending = null;
        self.external = false;
    }

    fn deinit(self: *Panel, a: std.mem.Allocator) void {
        self.clearInspection(a);
        self.clearGrants();
    }

    fn clearGrants(self: *Panel) void {
        if (self.grants_arena) |*arena| arena.deinit();
        self.grants_arena = null;
        self.grants = &.{};
    }

    fn matches(self: *const Panel, scope: Scope) bool {
        return self.generation == scope.generation and self.history == scope.history and
            equal(u8, scope.session, self.session[0..self.session_len]) and
            equal(u8, scope.origin, self.origin[0..self.origin_len]) and
            equal(u8, scope.mount, self.mount[0..self.mount_len]);
    }

    fn reset(self: *Panel, a: std.mem.Allocator, scope: Scope) void {
        self.deinit(a);
        self.* = .{};
        @memcpy(self.session[0..scope.session.len], scope.session);
        @memcpy(self.origin[0..scope.origin.len], scope.origin);
        self.origin_len = scope.origin.len;
        @memcpy(self.mount[0..scope.mount.len], scope.mount);
        self.session_len = scope.session.len;
        self.mount_len = scope.mount.len;
        self.generation = scope.generation;
        self.history = scope.history;
        std.debug.assert(self.matches(scope));
    }
};

pub const Projection = struct {
    origin: []const u8,
    host_credentials: bool = true,
    session: ?[]const u8 = null,
    issue: ?enum { unsupported_origin, no_session } = null,
    action_id: ?u32 = null,
    status: ?Status = null,
    http_status: ?u16 = null,
    ordinal: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    preview_operation: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    request: ?request.Inspection = null,
    response: ?HttpResponse = null,
    reply: ?ReplyView = null,
    connection_action_id: ?u32 = null,
    connection_status: ?ConnectionStatus = null,
    connections: []const Connection = &.{},
};

pub fn parse(a: std.mem.Allocator, source: []const u8, max: usize) !Value {
    if (source.len > max) return error.InputTooLarge;
    const doc = try std.json.parseFromSliceLeaky(shared.json.UniqueValue(true), a, source, .{ .max_value_len = max });
    return doc.value;
}

fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn text(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
fn number(comptime T: type, value: Value) ?T {
    return if (value == .integer) std.math.cast(T, value.integer) else null;
}
fn isTrue(value: Value) bool {
    return value == .bool and value.bool;
}

fn surface(ctx: Value) ?Target {
    const name = text(get(get(ctx, "surface"), "target")) orelse return null;
    return std.meta.stringToEnum(Target, name);
}

fn currentOrigin(ctx: Value) ?[]const u8 {
    const origin = text(get(ctx, "server_origin")) orelse return null;
    return if (origin_rules.valid(origin)) origin else null;
}

fn resourceId(endpoint: []const u8) [resource_id_len]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(endpoint, &digest, .{});
    var id: [resource_id_len]u8 = undefined;
    @memcpy(id[0..resource_prefix.len], resource_prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(id[resource_prefix.len..], &digest);
    return id;
}

fn readyGrant(panel: *const Panel, endpoint: []const u8) ?Grant {
    if (panel.connection_status != .ready) return null;
    for (panel.grants) |grant| {
        if (grant.enabled and equal(u8, grant.endpoint, endpoint)) return grant;
    }
    return null;
}

fn storeGrants(a: std.mem.Allocator, panel: *Panel, value: Value) !void {
    if (value != .array or value.array.items.len > max_grants) return error.InvalidConnections;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const storage = arena.allocator();
    const grants = try storage.alloc(Grant, value.array.items.len);
    var count: usize = 0;
    for (value.array.items) |entry| {
        const id = text(get(entry, "id")) orelse return error.InvalidConnections;
        const endpoint = text(get(entry, "endpoint")) orelse return error.InvalidConnections;
        if (!request.validEndpoint(endpoint) or !equal(u8, id, &resourceId(endpoint))) continue;
        const pin = text(get(entry, "config_pin")) orelse return error.InvalidConnections;
        const enabled = get(entry, "enabled");
        if (pin.len == 0 or pin.len > 128 or enabled != .bool) return error.InvalidConnections;
        grants[count] = .{
            .id = try storage.dupe(u8, id),
            .pin = try storage.dupe(u8, pin),
            .endpoint = try storage.dupe(u8, endpoint),
            .enabled = enabled.bool,
        };
        count += 1;
    }
    panel.clearGrants();
    panel.grants_arena = arena;
    panel.grants = grants[0..count];
}

fn projectConnections(a: std.mem.Allocator, grants: []const Grant) ![]const Connection {
    const connections = try a.alloc(Connection, grants.len);
    for (grants, connections) |grant, *connection| {
        const url = grant.endpoint;
        // Production stores no label. Keep the session suffix in short display names.
        const label = if (url.len <= 80) url else try std.fmt.allocPrint(a, "…{s}", .{url[url.len - 77 ..]});
        connection.* = .{ .endpoint = url, .name = label, .enabled = grant.enabled };
    }
    return connections;
}

/// A known-length literal valid key cannot survive in the retained response,
/// even embedded in a longer identifier. This cannot decode transformed echoes.
fn redactResponseText(a: std.mem.Allocator, input: []const u8, limit: usize) ![]const u8 {
    var end = @min(input.len, limit);
    for (0..3) |_| {
        if (end == input.len or (input[end] & 0xc0) != 0x80) break;
        end -= 1;
    }
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var start: usize = 0;
    for (0..end + 1) |i| {
        if (i < end and request.identifierByte(input[i])) continue;
        const cut_run = i == end and end < input.len and request.identifierByte(input[end]);
        if (i > start and (i - start >= request.token_min or cut_run)) {
            try out.appendSlice("<REDACTED>");
        } else try out.appendSlice(input[start..i]);
        if (i < end) try out.append(input[i]);
        start = i + 1;
    }
    return out.toOwnedSlice();
}

fn sensitiveHeader(key: []const u8) bool {
    const names = [_][]const u8{
        "authorization",    "proxy-authorization", "authentication-info", "proxy-authentication-info",
        "www-authenticate", "proxy-authenticate",  "cookie",              "set-cookie",
        "set-cookie2",
    };
    for (names) |name| if (std.ascii.eqlIgnoreCase(key, name)) return true;
    return false;
}

fn storeResponse(panel: *Panel, value: Value, status: u16, body: []const u8) !void {
    const arena = if (panel.inspection_arena) |*owned| owned else return error.MissingRequest;
    const a = arena.allocator();
    const map = get(value, "headers");
    const headers: []const Header = if (map == .object) blk: {
        const max_headers = 32;
        const count = @min(map.object.count(), max_headers);
        const entries = try a.alloc(Header, count);
        var kept: usize = 0;
        for (map.object.keys()[0..count], map.object.values()[0..count]) |key, entry| {
            if (sensitiveHeader(key)) continue;
            const header_value = text(entry) orelse continue;
            entries[kept] = .{
                .name = try redactResponseText(a, key, 128),
                .value = try redactResponseText(a, header_value, 1024),
            };
            kept += 1;
        }
        break :blk entries[0..kept];
    } else &.{};
    panel.response = .{
        .status = status,
        .headers = headers,
        .body = try redactResponseText(a, body, request.receipt_limit),
        .truncated = body.len > request.receipt_limit or isTrue(get(value, "truncated")),
    };
}

fn scoped(ctx: Value) ?Scope {
    const origin = currentOrigin(ctx) orelse return null;
    if (!isTrue(get(ctx, "target_visible"))) return null;
    const session = text(get(ctx, "session_id")) orelse return null;
    if (!request.validSession(session)) return null;
    const mount = text(get(get(ctx, "surface"), "surface_id")) orelse return null;
    if (mount.len == 0 or mount.len > 256) return null;
    return .{
        .session = session,
        .origin = origin,
        .mount = mount,
        .generation = number(u32, get(ctx, "surface_generation")) orelse return null,
        .history = number(u32, get(ctx, "history_generation")) orelse return null,
    };
}

pub fn Runtime(comptime Host: type) type {
    return struct {
        const Self = @This();
        panels: [2]Panel = .{ .{}, .{} },
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Self) void {
            for (&self.panels) |*panel| panel.deinit(self.allocator);
        }

        fn control(self: *Self, panel: *Panel, method: Control, payload: Value) !bool {
            if (panel.connection_pending != null) return false;
            panel.connection_action_id = number(u32, get(payload, "action_id")) orelse return false;
            panel.connection_status = .unavailable;
            var resource: [resource_id_len]u8 = undefined;
            const request_id = if (method == .list) blk: {
                resource = [_]u8{0} ** resource_id_len;
                break :blk Host.resources("resource-list", "{}");
            } else blk: {
                const endpoint = text(get(payload, "endpoint")) orelse return true;
                if (!request.validEndpoint(endpoint)) return true;
                resource = resourceId(endpoint);
                const serialized = if (method == .authorize) wire: {
                    const token = text(get(payload, "token")) orelse return true;
                    if (!request.validToken(token)) return true;
                    var header_buffer: [7 + request.token_limit]u8 = undefined;
                    defer std.crypto.utils.secureZero(u8, &header_buffer);
                    const authorization = try std.fmt.bufPrint(&header_buffer, "Bearer {s}", .{token});
                    break :wire try std.json.stringifyAlloc(self.allocator, .{
                        .id = &resource,
                        .endpoint = endpoint,
                        .enabled = true,
                        .authorization = authorization,
                        .methods = .{ "POST", "GET" },
                    }, .{});
                } else try std.json.stringifyAlloc(self.allocator, .{ .id = &resource, .remove = true }, .{});
                defer {
                    if (method == .authorize) std.crypto.utils.secureZero(u8, serialized);
                    self.allocator.free(serialized);
                }
                break :blk Host.resources("resource-configure", serialized);
            };
            if (request_id) |id| {
                panel.connection_pending = .{ .request_id = id, .action = method, .resource = resource };
                panel.connection_status = .pending;
            }
            return true;
        }

        /// Pending effects already have a local loading state in the view.
        /// Publish the authoritative result once when the Host settles the effect.
        pub fn actionNeedsRender(self: *const Self, name: []const u8, ctx: Value) bool {
            const target = surface(ctx) orelse return true;
            const panel = &self.panels[@intFromEnum(target)];
            if (equal(u8, name, "send")) return panel.pending == null;
            if (equal(u8, name, "preview")) return true;
            return panel.connection_pending == null;
        }

        pub fn projection(self: *const Self, a: std.mem.Allocator, ctx: Value) !Projection {
            const origin = currentOrigin(ctx) orelse return .{ .origin = "", .issue = .unsupported_origin };
            var out = Projection{ .origin = origin };
            const target = surface(ctx) orelse return out;
            const scope = scoped(ctx) orelse {
                out.issue = .no_session;
                return out;
            };
            out.session = scope.session;
            const panel = &self.panels[@intFromEnum(target)];
            if (!panel.matches(scope)) return out;
            out.action_id = panel.action_id;
            out.status = panel.status;
            out.http_status = panel.http_status;
            out.ordinal = if (panel.ordinal) |n| try std.fmt.allocPrint(a, "{d}", .{n}) else null;
            out.preview = panel.preview;
            out.preview_operation = if (panel.preview_operation) |*id| id else null;
            out.operation = if (panel.operation) |*id| id else null;
            out.request = panel.inspection;
            out.endpoint = if (panel.external) (panel.inspection orelse unreachable).url else null;
            out.response = panel.response;
            if (panel.reply) |*reply| out.reply = .{ .dialogue_id = &reply.id, .status = reply.status, .reason = reply.reason, .chunks = reply.chunks.constSlice(), .truncated = reply.truncated };
            out.connection_action_id = panel.connection_action_id;
            out.connection_status = panel.connection_status;
            out.connections = try projectConnections(a, panel.grants);
            return out;
        }

        pub fn action(self: *Self, a: std.mem.Allocator, name: []const u8, payload: Value, ctx: Value) !bool {
            const sending = equal(u8, name, "send");
            if (!isTrue(get(ctx, "user_action")) or get(ctx, "tool_invocation") != .null) return false;
            const target = surface(ctx) orelse return false;
            const scope = scoped(ctx) orelse return false;
            const panel = &self.panels[@intFromEnum(target)];
            if (!panel.matches(scope)) panel.reset(self.allocator, scope);
            if (std.meta.stringToEnum(Control, name)) |method| return self.control(panel, method, payload);
            if (!sending and !equal(u8, name, "preview")) return false;
            const submitted_session = text(get(payload, "session")) orelse return false;
            if (!equal(u8, submitted_session, scope.session)) return false;
            if (panel.pending != null or panel.reply_pending != null) return false;
            panel.action_id = number(u32, get(payload, "action_id")) orelse return false;
            panel.clearInspection(self.allocator);
            panel.preview_operation = null;
            panel.http_status = null;
            panel.ordinal = null;
            const operation = text(get(payload, "operation")) orelse "";
            const message = text(get(payload, "message")) orelse "";
            const endpoint_value = get(payload, "endpoint");
            if (endpoint_value != .null and endpoint_value != .string) {
                panel.status = .unavailable;
                return true;
            }
            const endpoint = text(endpoint_value);
            if (endpoint) |url| {
                if (readyGrant(panel, url) == null) {
                    panel.status = .unavailable;
                    return true;
                }
            }
            panel.inspection_arena = std.heap.ArenaAllocator.init(self.allocator);
            const storage = if (panel.inspection_arena) |*arena| arena.allocator() else unreachable;
            const prepared = (if (endpoint) |url|
                request.Request.forEndpoint(storage, url, operation, message)
            else
                request.Request.prepare(storage, scope.origin, scope.session, operation, message)) catch |err| {
                panel.status = switch (err) {
                    error.InvalidOperation => .invalid_operation,
                    error.InvalidMessage => .invalid_message,
                    else => .unavailable,
                };
                return true;
            };
            var safe = prepared.inspection();
            safe.headers.@"Idempotency-Key" = try storage.dupe(u8, operation);
            panel.inspection = safe;
            panel.external = prepared.external;
            panel.preview = try prepared.preview(self.allocator);
            panel.preview_operation = operation[0..36].*;
            if (!sending) {
                panel.status = .preview;
                return true;
            }
            if (panel.operation) |used| {
                if (equal(u8, &used, operation)) {
                    panel.status = .operation_already_used;
                    return true;
                }
            }
            const grant = readyGrant(panel, prepared.url) orelse {
                panel.status = .unavailable;
                return true;
            };
            const wire = try prepared.json(a, grant.id, grant.pin);
            defer a.free(wire);
            panel.operation = operation[0..36].*;
            panel.status = .outcome_unknown;
            if (Host.net(wire)) |id| {
                panel.pending = id;
                panel.status = .pending;
            }
            return true;
        }

        pub fn unreadableCompletion(self: *Self, ctx: Value) bool {
            const target = surface(ctx) orelse return false;
            const scope = scoped(ctx) orelse return false;
            const panel = &self.panels[@intFromEnum(target)];
            if (!panel.matches(scope)) return false;
            const changed = panel.pending != null or panel.connection_pending != null or panel.reply_pending != null;
            if (panel.reply_pending != null) {
                panel.reply_pending = null;
                if (panel.reply) |*reply| switch (reply.status) {
                    .waiting, .queued, .consumed => reply.status = .unavailable,
                    else => {},
                };
            }
            if (panel.pending != null) {
                panel.pending = null;
                panel.status = .outcome_unknown;
            }
            if (panel.connection_pending != null) {
                panel.connection_pending = null;
                panel.connection_status = .unavailable;
            }
            return changed;
        }

        fn beginReply(panel: *Panel, a: std.mem.Allocator, dialogue: [8]u8) void {
            panel.reply = .{ .id = dialogue, .status = .unavailable };
            const url = (panel.inspection orelse return).url;
            const grant = readyGrant(panel, url) orelse return;
            const wire = request.Request.subscribe(a, url, grant.id, grant.pin, &dialogue) catch return;
            defer a.free(wire);
            if (Host.net(wire)) |id| {
                panel.reply_pending = id;
                panel.reply.?.status = .waiting;
            }
        }

        fn replyEvent(panel: *Panel, a: std.mem.Allocator, payload: Value) bool {
            const reply = if (panel.reply) |*value| value else return false;
            const value = get(payload, "value");
            if (!isTrue(get(payload, "ok")) or !equal(u8, text(get(value, "type")) orelse "", "sse-event")) {
                panel.reply_pending = null;
                switch (reply.status) {
                    .waiting, .queued, .consumed => {
                        reply.status = .unavailable;
                        return true;
                    },
                    else => return false,
                }
            }
            const name = text(get(value, "event")) orelse return false;
            const data = parse(a, text(get(value, "data")) orelse return false, max_reply_event_data_bytes) catch return false;
            if (!equal(u8, text(get(data, "dialogue_id")) orelse "", &reply.id)) return false;
            switch (reply.status) {
                .completed, .cancelled, .interrupted, .unavailable => return false,
                else => {},
            }
            if (equal(u8, name, "queued")) {
                if (reply.status != .waiting) return false;
                reply.status = .queued;
            } else if (equal(u8, name, "consumed")) {
                if (reply.status == .consumed) return false;
                reply.status = .consumed;
            } else if (equal(u8, name, "chunk")) {
                const index = number(u32, get(data, "index")) orelse return false;
                if (index != reply.chunks.len or reply.chunks.len == reply.chunks.capacity()) return false;
                const message = text(get(data, "message")) orelse return false;
                if (message.len > 8192 or message.len > 64 * 1024 - reply.text_bytes) return false;
                const arena = if (panel.inspection_arena) |*owned| owned else return false;
                // Leave space in the 64 KiB webview event for the POST inspection.
                const visible = @min(message.len, 8192 - reply.visible_bytes);
                const safe = if (visible == 0) "" else redactResponseText(arena.allocator(), message, visible) catch return false;
                reply.visible_bytes += visible;
                reply.truncated = reply.truncated or visible < message.len;
                reply.text_bytes += message.len;
                reply.chunks.appendAssumeCapacity(.{ .index = index, .message = safe, .is_final = isTrue(get(data, "is_final")) });
                reply.status = .consumed;
            } else if (equal(u8, name, "done")) {
                if (number(u32, get(data, "total_chunks")) != reply.chunks.len) return false;
                const status = std.meta.stringToEnum(ReplyStatus, text(get(data, "status")) orelse "") orelse return false;
                switch (status) {
                    .completed, .cancelled, .interrupted => {},
                    else => return false,
                }
                reply.status = status;
                if (text(get(data, "reason"))) |reason| {
                    const arena = if (panel.inspection_arena) |*owned| owned else return true;
                    reply.reason = redactResponseText(arena.allocator(), reason, 128) catch null;
                }
            } else return false;
            return true;
        }

        pub fn complete(self: *Self, a: std.mem.Allocator, payload: Value, ctx: Value) bool {
            const target = surface(ctx) orelse return false;
            const scope = scoped(ctx) orelse return false;
            const panel = &self.panels[@intFromEnum(target)];
            if (!panel.matches(scope)) return false;
            const id = number(u32, get(payload, "request_id")) orelse return false;
            if (panel.reply_pending == id) return replyEvent(panel, a, payload);
            const value = get(payload, "value");
            if (panel.connection_pending) |pending| {
                if (pending.request_id == id) {
                    panel.connection_pending = null;
                    panel.connection_status = .unavailable;
                    if (!isTrue(get(payload, "ok"))) return true;
                    storeGrants(self.allocator, panel, value) catch return true;
                    var grant_enabled: ?bool = null;
                    for (panel.grants) |grant| {
                        if (equal(u8, grant.id, &pending.resource)) {
                            grant_enabled = grant.enabled;
                            break;
                        }
                    }
                    const acknowledged = switch (pending.action) {
                        .list => true,
                        .authorize => grant_enabled == true,
                        .revoke => grant_enabled == null,
                    };
                    if (acknowledged) panel.connection_status = .ready;
                    return true;
                }
            }
            if (panel.pending != id) return false;
            const operation = panel.operation orelse unreachable;
            panel.pending = null;
            panel.status = .outcome_unknown;
            if (!isTrue(get(payload, "ok"))) return true;
            const code = number(u16, get(value, "status")) orelse return true;
            if (code < 100 or code > 599) return true;
            panel.http_status = code;
            const body = text(get(value, "body")) orelse "";
            storeResponse(panel, value, code, body) catch {
                panel.response = null;
            };
            if (code != 200 and code != 202) {
                if (code == 400 or code == 401 or code == 403 or code == 404 or code == 409 or code == 413 or code == 415 or code == 422 or code == 429) panel.status = .rejected;
                return true;
            }
            if (isTrue(get(value, "truncated"))) return true;
            const receipt = request.receipt(a, code, &operation, body) catch return true;
            panel.status = if (receipt.status == .queued) .queued else .consumed;
            panel.ordinal = receipt.ordinal;
            if (receipt.dialogue_id) |dialogue| beginReply(panel, a, dialogue);
            return true;
        }
    };
}
