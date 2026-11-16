const std = @import("std");
const j = @import("json_helpers.zig");
const args = @import("arguments.zig");
const cp = @import("call_pins.zig");
const discovery = @import("discovery.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
pub const versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26" };
pub const Stage = enum { resources, initialize, notify, list, call };
pub const Operation = struct {
    allocator: A,
    identity: V,
    request: V,
    resource: V = .null,
    stage: Stage = .resources,
    rpc_id: []const u8 = "",
    session: ?[]const u8 = null,
    version: ?[]const u8 = null,
    tools: std.ArrayList(V),
    cursors: std.ArrayList([]const u8),
    pages: usize = 0,
    catalog_bytes: usize = 0,
    aggregate: bool = false,
    resources: std.ArrayList(V),
    servers: std.ArrayList(V),
    offset: usize = 0,
    seen: usize = 0,
    summaries: usize = 0,
    /// Sanitized concrete HTTP/RPC diagnostic; no remote message/body is copied.
    diagnostic: ?[]const u8 = null,
    pub fn init(a: A, request: V, identity: V) !Operation {
        return .{ .allocator = a, .request = try j.clone(a, request), .identity = try j.clone(a, identity), .tools = std.ArrayList(V).init(a), .cursors = std.ArrayList([]const u8).init(a), .resources = std.ArrayList(V).init(a), .servers = std.ArrayList(V).init(a) };
    }
    pub fn rpcBody(self: *Operation, sequence: u64, method: []const u8, params: V) !V {
        const a = self.allocator;
        self.rpc_id = try std.fmt.allocPrint(a, "{s}:{d}", .{ j.text(j.get(self.identity, "invocation_id")) orelse "invalid", sequence });
        var out = j.object(a);
        try j.set(&out, "jsonrpc", j.string("2.0"));
        try j.set(&out, "id", j.string(self.rpc_id));
        try j.set(&out, "method", j.string(try a.dupe(u8, method)));
        try j.set(&out, "params", try j.clone(a, params));
        return out;
    }
    pub fn httpPayload(self: *const Operation, body: V, notification: bool) !V {
        const a = self.allocator;
        var headers = j.object(a);
        try j.set(&headers, "Content-Type", j.string("application/json"));
        try j.set(&headers, "Accept", j.string("application/json, text/event-stream"));
        if (self.session) |s| try j.set(&headers, "Mcp-Session-Id", j.string(try a.dupe(u8, s)));
        if (self.version) |s| try j.set(&headers, "MCP-Protocol-Version", j.string(try a.dupe(u8, s)));
        var out = j.object(a);
        try j.set(&out, "resource", try j.clone(a, j.get(self.resource, "id")));
        try j.set(&out, "config_pin", try j.clone(a, j.get(self.resource, "config_pin")));
        try j.set(&out, "method", j.string("POST"));
        try j.set(&out, "headers", headers);
        try j.set(&out, "body", j.string(try j.stringify(a, body)));
        if (notification) try j.set(&out, "response_mode", j.string("discard")) else try j.set(&out, "response_id", j.string(try a.dupe(u8, self.rpc_id)));
        return out;
    }
    /// RpcRejected is a known rejection; other Call-stage failures have unknown outcome.
    pub fn outcomeUnknown(self: *const Operation, err: anyerror) bool {
        return self.stage == .call and err != error.RpcRejected;
    }
    pub fn rpcResult(self: *Operation, response: V) !V {
        const a = self.allocator;
        const status = j.uint(j.get(response, "status")) orelse return error.MissingHttpStatus;
        if (status < 200 or status >= 300) {
            self.diagnostic = try std.fmt.allocPrint(a, "MCP server returned HTTP {d}", .{status});
            return error.HttpFailure;
        }
        const headers = j.get(response, "headers");
        if (j.text(j.get(headers, "mcp-session-id"))) |s| {
            if (s.len == 0 or s.len > 1024) return error.InvalidMcpSession;
            for (s) |c| if (c < 0x21 or c > 0x7e) return error.InvalidMcpSession;
            if (self.session) |old| {
                if (!std.mem.eql(u8, old, s)) return error.ChangedMcpSession;
            }
            self.session = try a.dupe(u8, s);
        }
        const raw_type = j.text(j.get(headers, "content-type")) orelse "";
        var parts = std.mem.splitScalar(u8, raw_type, ';');
        const content_type = std.mem.trim(u8, parts.first(), " \t\r\n");
        if (!std.mem.eql(u8, content_type, "application/json") and !std.mem.eql(u8, content_type, "text/event-stream")) return error.UnsupportedMcpContentType;
        const body = j.text(j.get(response, "body")) orelse return error.InvalidRpcEnvelope;
        const rpc = j.parse(a, body) catch |e| {
            if (e == error.OutOfMemory) return e;
            return error.InvalidRpcEnvelope;
        };
        if (rpc != .object or !j.is(j.get(rpc, "jsonrpc"), "2.0") or !j.is(j.get(rpc, "id"), self.rpc_id) or rpc.object.contains("result") == rpc.object.contains("error")) return error.InvalidRpcIdentity;
        if (rpc.object.get("error")) |e| {
            const code = j.get(e, "code");
            const signed: i64 = switch (code) {
                .integer => |n| n,
                .number_string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidRpcError,
                else => return error.InvalidRpcError,
            };
            if (j.get(e, "message") != .string) return error.InvalidRpcError;
            self.diagnostic = try std.fmt.allocPrint(a, "MCP server rejected JSON-RPC request (code {d})", .{signed});
            return error.RpcRejected;
        }
        return try j.clone(a, j.get(rpc, "result"));
    }
    pub fn admitPage(self: *Operation, result: V) !?[]const u8 {
        self.pages += 1;
        if (self.pages > 100) return error.CatalogPageLimit;
        const tools = j.get(result, "tools");
        if (tools != .array) return error.InvalidToolList;
        for (tools.array.items) |t| {
            const name = j.text(j.get(t, "name")) orelse return error.InvalidToolName;
            const schema = j.get(t, "inputSchema");
            if (name.len == 0 or name.len > 256 or schema != .object or !j.is(j.get(schema, "type"), "object")) return error.InvalidToolDefinition;
            if (t == .object) if (t.object.get("description")) |d| if (d != .string) return error.InvalidToolDescription;
            for (self.tools.items) |old| if (j.is(j.get(old, "name"), name)) return error.DuplicateToolName;
            if (self.tools.items.len >= 1000) return error.CatalogToolLimit;
            const encoded_len = blk: {
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                const sa = scratch.allocator();
                var projected = j.object(sa);
                for ([_][]const u8{ "name", "description", "inputSchema" }) |key| try j.set(&projected, key, j.get(t, key));
                break :blk (try j.stringify(sa, projected)).len;
            };
            if (encoded_len > 2 * 1024 * 1024 - self.catalog_bytes) return error.CatalogByteLimit;
            var retained = j.object(self.allocator);
            for ([_][]const u8{ "name", "description", "inputSchema" }) |key| try j.set(&retained, key, try j.clone(self.allocator, j.get(t, key)));
            try self.tools.append(retained);
            self.catalog_bytes += encoded_len;
        }
        if (result == .object) if (result.object.get("nextCursor")) |v| {
            const cursor = j.text(v) orelse return error.InvalidRemoteCursor;
            if (cursor.len == 0 or cursor.len > 4096 or self.pages >= 100) return error.InvalidRemoteCursor;
            for (self.cursors.items) |old| if (std.mem.eql(u8, cursor, old)) return error.RepeatedRemoteCursor;
            const owned = try self.allocator.dupe(u8, cursor);
            try self.cursors.append(owned);
            return owned;
        };
        return null;
    }
    pub fn callParams(self: *const Operation) !V {
        const a = self.allocator;
        for (self.tools.items) |tool| if (try j.equal(a, j.get(tool, "name"), j.get(self.request, "tool"))) {
            const schema = j.get(tool, "inputSchema");
            const digest = try j.pin(a, schema);
            if (!j.is(j.get(self.request, "schema_pin"), &digest) or !try j.equal(a, j.get(self.request, "config_pin"), j.get(self.resource, "config_pin"))) return error.ChangedSchemaOrConfig;
            const arguments = if (self.request == .object) self.request.object.get("arguments") orelse j.object(a) else j.object(a);
            if (arguments != .object) return error.ArgumentsMustBeObject;
            try args.validate(a, schema, arguments);
            var out = j.object(a);
            try j.set(&out, "name", try j.clone(a, j.get(tool, "name")));
            try j.set(&out, "arguments", try j.clone(a, arguments));
            return out;
        };
        return error.ToolAbsent;
    }
    pub fn beginCatalog(self: *Operation, resource: V) !void {
        self.resource = try j.clone(self.allocator, resource);
        self.stage = .initialize;
        self.session = null;
        self.version = null;
        self.rpc_id = "";
        self.diagnostic = null;
        self.tools.clearRetainingCapacity();
        self.cursors.clearRetainingCapacity();
        self.pages = 0;
        self.catalog_bytes = 0;
    }
    pub fn retainServer(self: *Operation, failure: ?[]const u8) !void {
        const a = self.allocator;
        const count = if (failure != null) 0 else self.tools.items.len;
        const start = self.offset -| self.seen;
        var summaries = j.array(a);
        if (failure == null and start < self.tools.items.len) for (self.tools.items[start..@min(self.tools.items.len, start + (discovery.limit(self.request) -| self.summaries))]) |tool| try summaries.array.append(try discovery.summary(a, tool));
        self.summaries += summaries.array.items.len;
        self.seen += @max(1, count);
        var server = j.object(a);
        try j.set(&server, "id", try j.clone(a, j.get(self.resource, "id")));
        try j.set(&server, "config_pin", try j.clone(a, j.get(self.resource, "config_pin")));
        var all = j.array(a);
        for (self.tools.items) |tool| try all.array.append(tool);
        const digest = try j.pin(a, all);
        try j.set(&server, "catalog_pin", j.string(try a.dupe(u8, &digest)));
        try j.set(&server, "tool_count", .{ .integer = @intCast(count) });
        try j.set(&server, "tools", summaries);
        if (failure) |e| try j.set(&server, "error", j.string(try a.dupe(u8, e)));
        try self.servers.append(server);
        self.tools.clearRetainingCapacity();
    }
    pub fn discoveryComplete(self: *const Operation, pins: *cp.CallPins, cursors: *discovery.Cursors) !V {
        const a = self.allocator;
        if (self.aggregate) return cursors.aggregate(a, self.identity, self.request, self.resources.items, self.servers.items);
        if (j.is(j.get(self.request, "action"), "list") or self.request != .object or !self.request.object.contains("tool")) return cursors.server(a, self.identity, self.request, self.resource, self.tools.items);
        for (self.tools.items) |tool| if (try j.equal(a, j.get(tool, "name"), j.get(self.request, "tool"))) {
            const schema = try j.pin(a, j.get(tool, "inputSchema"));
            const target = cp.CallTarget{ .server = j.text(j.get(self.resource, "id")) orelse return error.InvalidResource, .tool = j.text(j.get(tool, "name")) orelse return error.InvalidToolName, .config_pin = j.text(j.get(self.resource, "config_pin")) orelse return error.InvalidResource, .schema_pin = &schema };
            const token = try pins.mint(self.identity, target);
            var out = j.object(a);
            try j.set(&out, "call_pin", j.string(try a.dupe(u8, token)));
            try j.set(&out, "server", try j.clone(a, j.get(self.resource, "id")));
            try j.set(&out, "tool", try j.clone(a, j.get(tool, "name")));
            try j.set(&out, "parameters", try j.clone(a, j.get(tool, "inputSchema")));
            try j.set(&out, "schema_pin", j.string(try a.dupe(u8, schema[0..16])));
            const config = try discovery.short(a, j.get(self.resource, "config_pin"));
            try j.set(&out, "config_pin", j.string(try a.dupe(u8, &config)));
            try j.set(&out, "usage_hint", j.string("Call with pin=call_pin and arguments; omit server, tool, config_pin and schema_pin."));
            return out;
        };
        return error.ToolAbsent;
    }
};
test "all public operation declarations compile" {
    std.testing.refAllDeclsRecursive(@This());
}
test "describe pinned call revalidates full schema and owns request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pins = cp.CallPins.init(std.testing.allocator);
    defer pins.deinit();
    var cursors = discovery.Cursors.init(std.testing.allocator);
    defer cursors.deinit();
    const identity = try j.parse(a, "{\"session_id\":\"s\",\"invocation_id\":\"i\"}");
    const resource = try j.parse(a, "{\"id\":\"server\",\"config_pin\":\"revision\"}");
    var op = try Operation.init(a, try j.parse(a, "{\"action\":\"describe\",\"tool\":\"run\"}"), identity);
    try op.beginCatalog(resource);
    const page = try j.parse(a, "{\"tools\":[{\"name\":\"run\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"}},\"required\":[\"x\"]}}]}");
    try std.testing.expect(try op.admitPage(page) == null);
    const described = try op.discoveryComplete(&pins, &cursors);
    var request = try j.parse(a, "{\"action\":\"call\",\"arguments\":{\"x\":1}}");
    try j.set(&request, "pin", try j.clone(a, j.get(described, "call_pin")));
    try pins.expandRequest(identity, &request);
    pins.reset();
    var call = try Operation.init(a, request, identity);
    try call.beginCatalog(resource);
    _ = try call.admitPage(page);
    const params = try call.callParams();
    try std.testing.expect(j.is(j.get(params, "name"), "run"));
    try j.set(&call.request, "schema_pin", j.string("changed"));
    try std.testing.expectError(error.ChangedSchemaOrConfig, call.callParams());
    op.aggregate = true;
    try op.resources.append(resource);
    try op.retainServer(null);
    const aggregate_page = try op.discoveryComplete(&pins, &cursors);
    try std.testing.expect(j.get(aggregate_page, "servers").array.items.len == 1);
}
test "RPC identity rejection preserves uncertainty and notification wire contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var op = try Operation.init(a, j.object(a), try j.parse(a, "{\"invocation_id\":\"i\"}"));
    op.stage = .call;
    _ = try op.rpcBody(1, "tools/call", j.object(a));
    const response = try j.parse(a, "{\"status\":200,\"headers\":{\"content-type\":\"application/json\"},\"body\":\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":\\\"wrong\\\",\\\"result\\\":{}}\"}");
    try std.testing.expectError(error.InvalidRpcIdentity, op.rpcResult(response));
    try std.testing.expect(op.outcomeUnknown(error.InvalidRpcIdentity));
    try std.testing.expect(!op.outcomeUnknown(error.RpcRejected));
    const payload = try op.httpPayload(j.object(a), true);
    try std.testing.expect(j.is(j.get(payload, "response_mode"), "discard"));
    try std.testing.expect(j.get(payload, "response_id") == .null);
    const rejected = try j.parse(a, "{\"status\":200,\"headers\":{\"content-type\":\"application/json\"},\"body\":\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":\\\"i:1\\\",\\\"error\\\":{\\\"code\\\":-32602,\\\"message\\\":\\\"private credential\\\"}}\"}");
    try std.testing.expectError(error.RpcRejected, op.rpcResult(rejected));
    try std.testing.expect(std.mem.indexOf(u8, op.diagnostic.?, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, op.diagnostic.?, "private") == null);
}
test "catalog pages reject duplicates loops and excessive pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var op = try Operation.init(a, j.object(a), j.object(a));
    const page = try j.parse(a, "{\"tools\":[{\"name\":\"run\",\"inputSchema\":{\"type\":\"object\"}}],\"nextCursor\":\"next\"}");
    _ = try op.admitPage(page);
    try std.testing.expectError(error.DuplicateToolName, op.admitPage(page));
    try op.beginCatalog(.null);
    const empty = try j.parse(a, "{\"tools\":[],\"nextCursor\":\"next\"}");
    _ = try op.admitPage(empty);
    try std.testing.expectError(error.RepeatedRemoteCursor, op.admitPage(empty));
    op.pages = 100;
    try std.testing.expectError(error.CatalogPageLimit, op.admitPage(empty));
}
