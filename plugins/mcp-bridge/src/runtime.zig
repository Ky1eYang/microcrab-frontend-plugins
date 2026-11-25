const std = @import("std");
const j = @import("json_helpers.zig");
const protocol = @import("protocol.zig");
const discovery = @import("discovery.zig");
const pins_module = @import("call_pins.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const max_operations = 32;
const max_history = 128;
const history_byte_limit = 2 * 1024 * 1024;
const operation_byte_limit = 16 * 1024 * 1024;
const max_configured_servers = 32;
pub const guest_version = "0.4.1";

/// Counts the arena backing allocations, including retained parsing/catalog data.
/// A failed admission frees the operation; it never partially executes a remote call.
const Budget = struct {
    parent: A,
    used: usize = 0,
    fn allocator(self: *Budget) A {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .free = free } };
    }
    fn alloc(pointer: *anyopaque, n: usize, alignment: u8, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(pointer));
        if (n > operation_byte_limit -| self.used) return null;
        const bytes = self.parent.rawAlloc(n, alignment, ret) orelse return null;
        self.used += n;
        return bytes;
    }
    fn resize(pointer: *anyopaque, bytes: []u8, alignment: u8, n: usize, ret: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(pointer));
        if (n > bytes.len and n - bytes.len > operation_byte_limit -| self.used) return false;
        if (!self.parent.rawResize(bytes, alignment, n, ret)) return false;
        self.used = self.used - bytes.len + n;
        return true;
    }
    fn free(pointer: *anyopaque, bytes: []u8, alignment: u8, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(pointer));
        self.used -= bytes.len;
        self.parent.rawFree(bytes, alignment, ret);
    }
};
const Slot = struct {
    arena: *std.heap.ArenaAllocator,
    operation: protocol.Operation,
    request_id: ?u32 = null,
    ui_test: bool = false,
    call_dispatched: bool = false,
    record_id: u64 = 0,
};
const Record = struct {
    arena: *std.heap.ArenaAllocator,
    id: u64,
    tool: []const u8,
    server: []const u8,
    status: []const u8 = "pending",
    start_time_ms: f64,
    start_monotonic_ms: f64,
    duration_ms: ?f64 = null,
    turn_id: V,
    round_id: V,
    unknown: bool = false,
    arguments: []const u8,
    output: []const u8 = "",
    bytes: usize,
};
const ConfigRequest = struct { id: u32 };

pub fn Runtime(comptime Host: type) type {
    return struct {
        const Self = @This();
        allocator: A,
        budget: *Budget,
        slots: [max_operations]?*Slot = [_]?*Slot{null} ** max_operations,
        configs: std.ArrayList(ConfigRequest),
        records: std.ArrayList(*Record),
        history_bytes: usize = 0,
        sequence: u64 = 0,
        record_sequence: u64 = 0,
        pins: pins_module.CallPins,
        cursors: discovery.Cursors,
        scope: []const u8 = "",
        session: []const u8 = "",
        locale: []const u8 = "zh-CN",
        config_arena: *std.heap.ArenaAllocator,
        servers: V = .null,
        health_arena: *std.heap.ArenaAllocator,
        health: V = .null,
        status: []const u8 = "",
        last_error: []const u8 = "",
        page: usize = 0,
        selected: ?u64 = null,
        detail_field: []const u8 = "output",
        detail_offset: usize = 0,

        fn newArena(allocator: A) !*std.heap.ArenaAllocator {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            return arena;
        }
        fn freeArena(self: *Self, arena: *std.heap.ArenaAllocator) void {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        pub fn init(allocator: A) !Self {
            const budget = try allocator.create(Budget);
            errdefer allocator.destroy(budget);
            budget.* = .{ .parent = allocator };
            const config_arena = try newArena(allocator);
            errdefer {
                config_arena.deinit();
                allocator.destroy(config_arena);
            }
            const health_arena = try newArena(allocator);
            errdefer {
                health_arena.deinit();
                allocator.destroy(health_arena);
            }
            return .{ .allocator = allocator, .budget = budget, .configs = std.ArrayList(ConfigRequest).init(allocator), .records = std.ArrayList(*Record).init(allocator), .pins = pins_module.CallPins.init(allocator), .cursors = discovery.Cursors.init(allocator), .config_arena = config_arena, .health_arena = health_arena };
        }
        pub fn deinit(self: *Self) void {
            self.clearOperations();
            self.clearHistory();
            self.pins.deinit();
            self.cursors.deinit();
            self.configs.deinit();
            self.records.deinit();
            self.freeArena(self.config_arena);
            self.freeArena(self.health_arena);
            self.clearOwned(&self.scope);
            self.clearOwned(&self.session);
            self.clearOwned(&self.status);
            self.clearOwned(&self.last_error);
            if (!std.mem.eql(u8, self.locale, "zh-CN") and !std.mem.eql(u8, self.locale, "en")) self.allocator.free(self.locale);
            self.allocator.destroy(self.budget);
        }
        fn clearOwned(self: *Self, value: *[]const u8) void {
            if (value.len > 0) self.allocator.free(value.*);
            value.* = "";
        }
        fn replace(self: *Self, dest: *[]const u8, source: []const u8) !void {
            const next = try self.allocator.dupe(u8, source);
            self.clearOwned(dest);
            dest.* = next;
        }
        fn setError(self: *Self, message: []const u8) !void {
            try self.replace(&self.last_error, message[0..@min(message.len, 1024)]);
        }
        fn dropSlot(self: *Self, slot: *Slot) void {
            for (&self.slots) |*entry| if (entry.* == slot) {
                entry.* = null;
                break;
            };
            self.freeArena(slot.arena);
            self.allocator.destroy(slot);
        }
        fn clearOperations(self: *Self) void {
            for (self.slots) |entry| if (entry) |slot| self.dropSlot(slot);
            self.configs.clearRetainingCapacity();
        }
        fn evictRecord(self: *Self, index: usize) void {
            const record = self.records.orderedRemove(index);
            self.history_bytes -= record.bytes;
            self.freeArena(record.arena);
            self.allocator.destroy(record);
        }
        fn evictOldestTerminal(self: *Self) bool {
            for (self.records.items, 0..) |record, index| if (!std.mem.eql(u8, record.status, "pending")) {
                self.evictRecord(index);
                return true;
            };
            return false;
        }
        fn clearHistory(self: *Self) void {
            while (self.records.items.len > 0) self.evictRecord(0);
            self.page = 0;
            self.selected = null;
        }
        pub fn updateContext(self: *Self, a: A, ctx: V) !void {
            var scope_value = j.array(a);
            for ([_][]const u8{ "server_origin", "owner_id", "session_id", "instance_generation", "history_generation" }) |key| try scope_value.array.append(j.get(ctx, key));
            const scope = try j.canonical(a, scope_value);
            if (!std.mem.eql(u8, self.scope, scope)) {
                self.clearOperations();
                self.clearHistory();
                self.pins.reset();
                self.cursors.reset();
                try self.replace(&self.scope, scope);
                try self.replace(&self.session, j.text(j.get(ctx, "session_id")) orelse "");
                _ = self.health_arena.reset(.free_all);
                self.health = .null;
            }
            self.locale = if (std.mem.startsWith(u8, j.text(j.get(ctx, "locale")) orelse "zh", "en")) "en" else "zh-CN";
        }
        fn queueConfig(self: *Self, kind: []const u8, payload: V, a: A) !void {
            if (self.configs.items.len >= 16) return error.ConfigurationRequestLimit;
            const encoded = try j.stringify(a, payload);
            defer if (std.mem.eql(u8, kind, "resource-configure")) std.crypto.utils.secureZero(u8, encoded);
            switch (Host.resources.send(kind, encoded)) {
                .ok => |id| try self.configs.append(.{ .id = id }),
                .err => |message| {
                    defer self.allocator.free(message);
                    return error.ResourceRequestNotQueued;
                },
            }
        }
        pub fn initialize(self: *Self, a: A, ctx: V) !V {
            try self.updateContext(a, ctx);
            try self.queueConfig("resource-list", j.object(a), a);
            return self.result(a, null);
        }
        fn configured(servers: V, id: []const u8) V {
            if (servers != .array or servers.array.items.len > max_configured_servers) return .null;
            for (servers.array.items) |server| if (j.is(j.get(server, "id"), id)) return server;
            return .null;
        }
        fn serviceEnabled(server: V) bool {
            return j.truth(j.get(server, "enabled")) and !j.truth(j.get(server, "requires_reenable"));
        }
        fn matchesConfig(server: V, pin: V) bool {
            const text = j.text(pin) orelse return false;
            return text.len > 0 and serviceEnabled(server) and j.is(j.get(server, "config_pin"), text);
        }
        fn currentHealth(self: *const Self, id: []const u8, server: V) V {
            const entry = j.get(self.health, id);
            return if (matchesConfig(server, j.get(entry, "config_pin"))) entry else .null;
        }
        fn settingsHealth(self: *const Self, a: A) !V {
            var health = j.object(a);
            if (self.servers != .array) return health;
            for (self.servers.array.items) |server| {
                const id = j.text(j.get(server, "id")) orelse continue;
                const entry = self.currentHealth(id, server);
                if (entry == .null) continue;
                var row = j.object(a);
                for ([_][]const u8{ "status", "tool_count", "checked_at_ms" }) |key| {
                    if (entry.object.get(key)) |value| try j.set(&row, key, value);
                }
                try j.set(&health, id, row);
            }
            return health;
        }
        fn filteredHealth(self: *const Self, a: A, servers: V) !V {
            var health = j.object(a);
            if (servers != .array) return health;
            for (servers.array.items) |server| {
                const id = j.text(j.get(server, "id")) orelse continue;
                const entry = self.currentHealth(id, server);
                if (entry != .null) try j.set(&health, try a.dupe(u8, id), try j.clone(a, entry));
            }
            return health;
        }
        fn safeServers(self: *Self, value: V) !void {
            if (value != .array or value.array.items.len > max_configured_servers) return error.InvalidConfiguredInventory;
            // Clone only canonical public fields; no headers or credential data survive.
            const next_arena = try newArena(self.allocator);
            errdefer self.freeArena(next_arena);
            const a = next_arena.allocator();
            var next = j.array(a);
            for (value.array.items) |server| {
                var row = j.object(a);
                for ([_][]const u8{ "id", "endpoint", "origin", "enabled", "requires_reenable", "config_pin" }) |key| try j.set(&row, key, try j.clone(a, j.get(server, key)));
                try next.array.append(row);
            }
            const encoded = try j.stringify(a, next);
            if (encoded.len > 48 * 1024) return error.SettingsInventoryExceedsViewBudget;
            const next_health_arena = try newArena(self.allocator);
            errdefer self.freeArena(next_health_arena);
            const next_health = try self.filteredHealth(next_health_arena.allocator(), next);
            self.freeArena(self.config_arena);
            self.config_arena = next_arena;
            self.servers = next;
            self.freeArena(self.health_arena);
            self.health_arena = next_health_arena;
            self.health = next_health;
        }
        fn nextSequence(self: *Self) !u64 {
            self.sequence = std.math.add(u64, self.sequence, 1) catch return error.SequenceExhausted;
            return self.sequence;
        }
        fn addRecord(self: *Self, op: *const protocol.Operation, ctx: V) !u64 {
            // Observation failures never authorize retry of a call. Admission is before dispatch.
            self.record_sequence = std.math.add(u64, self.record_sequence, 1) catch return error.SequenceExhausted;
            const record = try self.allocator.create(Record);
            errdefer self.allocator.destroy(record);
            const arena = try newArena(self.allocator);
            errdefer self.freeArena(arena);
            const a = arena.allocator();
            const source = try j.stringify(a, j.get(op.request, "arguments"));
            const tool = try a.dupe(u8, j.text(j.get(op.request, "tool")) orelse (j.text(j.get(op.request, "action")) orelse "MCP"));
            const server = try a.dupe(u8, j.text(j.get(op.request, "server")) orelse "");
            record.* = .{ .arena = arena, .id = self.record_sequence, .tool = tool, .server = server, .arguments = source, .bytes = source.len + tool.len + server.len, .start_time_ms = j.number(j.get(ctx, "host_time_ms")) orelse 0, .start_monotonic_ms = j.number(j.get(ctx, "host_monotonic_ms")) orelse 0, .turn_id = try j.clone(a, j.get(op.identity, "turn_id")), .round_id = try j.clone(a, j.get(op.identity, "round_id")) };
            while (self.records.items.len >= max_history or self.history_bytes + record.bytes > history_byte_limit) if (!self.evictOldestTerminal()) return error.HistoryByteAdmissionLimit;
            try self.records.append(record);
            self.history_bytes += record.bytes;
            return record.id;
        }
        fn resolvedRecordTarget(self: *Self, slot: *Slot) !void {
            const record = self.recordFor(slot.record_id) orelse return;
            const a = record.arena.allocator();
            const tool = j.text(j.get(slot.operation.request, "tool")) orelse record.tool;
            const server = j.text(j.get(slot.operation.request, "server")) orelse record.server;
            if (!std.mem.eql(u8, tool, record.tool)) {
                record.tool = try a.dupe(u8, tool);
                record.bytes += tool.len;
                self.history_bytes += tool.len;
            }
            if (!std.mem.eql(u8, server, record.server)) {
                record.server = try a.dupe(u8, server);
                record.bytes += server.len;
                self.history_bytes += server.len;
            }
        }
        fn recordFor(self: *Self, id: u64) ?*Record {
            for (self.records.items) |r| if (r.id == id) return r;
            return null;
        }
        fn finishRecord(self: *Self, slot: *Slot, output: V, message: ?[]const u8, unknown: bool, ctx: V, status: []const u8) !void {
            const record = self.recordFor(slot.record_id) orelse return;
            const a = record.arena.allocator();
            record.output = if (message) |m| try j.stringify(a, j.string(m)) else try j.stringify(a, output);
            record.status = status;
            record.unknown = unknown;
            if (j.number(j.get(ctx, "host_monotonic_ms"))) |now| record.duration_ms = @max(0, now - record.start_monotonic_ms);
            record.bytes += record.output.len;
            self.history_bytes += record.output.len;
            while (self.history_bytes > history_byte_limit and self.records.items.len > 0) if (!self.evictOldestTerminal()) break;
        }
        fn reply(a: A, identity: V, status: []const u8, output: V, message: ?[]const u8, unknown: bool) !V {
            var completion = j.object(a);
            try j.set(&completion, "identity", try j.clone(a, identity));
            try j.set(&completion, "status", j.string(status));
            if (std.mem.eql(u8, status, "completed")) try j.set(&completion, "output", try j.clone(a, output));
            if (message) |m| {
                try j.set(&completion, "error", j.string(try a.dupe(u8, m)));
                try j.set(&completion, "outcome_unknown", .{ .bool = unknown });
            }
            return completion;
        }
        fn pending(self: *Self, a: A, slot: *Slot) !V {
            return self.result(a, if (slot.ui_test) null else try reply(a, slot.operation.identity, "pending", .null, null, false));
        }
        fn terminal(self: *Self, a: A, slot: *Slot, output: V, message: ?[]const u8, unknown: bool, ctx: V) !V {
            defer self.dropSlot(slot);
            const status: []const u8 = if (message != null) "failed" else "completed";
            if (slot.ui_test) {
                const id = j.text(j.get(slot.operation.request, "server")) orelse return self.result(a, null);
                const pin = j.get(slot.operation.request, "config_pin");
                if (!matchesConfig(configured(self.servers, id), pin)) return self.result(a, null);
                const next_health_arena = try newArena(self.allocator);
                var health_transferred = false;
                errdefer if (!health_transferred) self.freeArena(next_health_arena);
                const ha = next_health_arena.allocator();
                var health = try self.filteredHealth(ha, self.servers);
                var row = j.object(ha);
                try j.set(&row, "config_pin", try j.clone(ha, pin));
                try j.set(&row, "status", j.string(if (message != null) "failed" else "online"));
                try j.set(&row, "tool_count", .{ .integer = @intCast(slot.operation.tools.items.len) });
                if (finiteNumber(j.get(ctx, "host_time_ms"))) |n| try j.set(&row, "checked_at_ms", n);
                try j.set(&health, try ha.dupe(u8, id), row);
                self.freeArena(self.health_arena);
                self.health_arena = next_health_arena;
                self.health = health;
                health_transferred = true;
                if (message) |m| try self.setError(m) else self.clearOwned(&self.last_error);
                return self.result(a, null);
            }
            try self.finishRecord(slot, output, message, unknown, ctx, status);
            const completion = try reply(a, slot.operation.identity, status, output, message, unknown);
            return self.result(a, completion);
        }
        fn terminalError(self: *Self, a: A, slot: *Slot, err: anyerror, ctx: V) !V {
            const message = slot.operation.diagnostic orelse @errorName(err);
            return self.terminal(a, slot, .null, message, slot.call_dispatched and slot.operation.outcomeUnknown(err), ctx);
        }
        fn queueHttp(self: *Self, a: A, slot: *Slot, payload: V) !V {
            const encoded = try j.stringify(slot.arena.allocator(), payload);
            switch (Host.net.send("http", encoded)) {
                .ok => |id| {
                    slot.request_id = id;
                    if (slot.operation.stage == .call) slot.call_dispatched = true;
                    return self.pending(a, slot);
                },
                .err => |message| {
                    defer self.allocator.free(message);
                    return error.NetworkRequestNotQueued;
                },
            }
        }
        fn issue(self: *Self, a: A, slot: *Slot, method: []const u8, params: V) !V {
            const body = try slot.operation.rpcBody(try self.nextSequence(), method, params);
            return self.queueHttp(a, slot, try slot.operation.httpPayload(body, false));
        }
        fn initializeRemote(self: *Self, a: A, slot: *Slot) !V {
            const oa = slot.arena.allocator();
            const params = try j.parse(oa, "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"microcrab-mcp-bridge\",\"version\":\"" ++ guest_version ++ "\"}}");
            return self.issue(a, slot, "initialize", params);
        }
        fn completeDiscovery(self: *Self, a: A, slot: *Slot, ctx: V) !V {
            const output = try slot.operation.discoveryComplete(&self.pins, &self.cursors);
            if ((try j.stringify(a, output)).len > 60 * 1024) return error.DurableResultBudgetExceeded;
            return self.terminal(a, slot, output, null, false, ctx);
        }
        fn compactCatalog(self: *Self, slot: *Slot) !void {
            const arena = try newArena(self.allocator);
            errdefer self.freeArena(arena);
            arena.* = std.heap.ArenaAllocator.init(self.budget.allocator());
            const a = arena.allocator();
            const previous = &slot.operation;
            var next = try protocol.Operation.init(a, previous.request, previous.identity);
            next.aggregate = previous.aggregate;
            next.offset = previous.offset;
            next.seen = previous.seen;
            next.summaries = previous.summaries;
            for (previous.resources.items) |resource| try next.resources.append(try j.clone(a, resource));
            for (previous.servers.items) |server| try next.servers.append(try j.clone(a, server));
            self.freeArena(slot.arena);
            slot.arena = arena;
            slot.operation = next;
        }
        fn nextServer(self: *Self, a: A, slot: *Slot, message: ?[]const u8, ctx: V) !V {
            try slot.operation.retainServer(message);
            if (slot.operation.servers.items.len < slot.operation.resources.items.len) {
                try self.compactCatalog(slot);
                const resource = slot.operation.resources.items[slot.operation.servers.items.len];
                try slot.operation.beginCatalog(resource);
                return self.initializeRemote(a, slot);
            }
            return self.completeDiscovery(a, slot, ctx);
        }
        fn failure(self: *Self, a: A, slot: *Slot, err: anyerror, ctx: V) anyerror!V {
            var live = false;
            for (self.slots) |entry| if (entry == slot) {
                live = true;
                break;
            };
            if (!live) return err;
            if (slot.operation.aggregate and slot.operation.stage != .resources and slot.operation.stage != .call and err != error.OutOfMemory and slot.operation.servers.items.len < slot.operation.resources.items.len) {
                return self.nextServer(a, slot, slot.operation.diagnostic orelse @errorName(err), ctx) catch |next_error| self.failure(a, slot, next_error, ctx);
            }
            return self.terminalError(a, slot, err, ctx);
        }
        fn resourceLess(_: void, left: V, right: V) bool {
            return std.mem.lessThan(u8, j.text(j.get(left, "id")) orelse "", j.text(j.get(right, "id")) orelse "");
        }
        fn advance(self: *Self, a: A, slot: *Slot, event: V, ctx: V) !V {
            const op = &slot.operation;
            const oa = slot.arena.allocator();
            if (slot.ui_test) {
                // Host results may arrive after a settings change. Neither a stale
                // resource snapshot nor an in-flight HTTP reply may continue a probe.
                const id = j.text(j.get(op.request, "server")) orelse "";
                const pin = j.get(op.request, "config_pin");
                if (!matchesConfig(configured(self.servers, id), pin) or
                    (op.stage == .resources and j.truth(j.get(event, "ok")) and
                    !matchesConfig(configured(j.get(event, "value"), id), pin)))
                {
                    self.dropSlot(slot);
                    return self.result(a, null);
                }
            }
            if (!j.truth(j.get(event, "ok"))) {
                op.diagnostic = try oa.dupe(u8, j.text(j.get(event, "error")) orelse "MCP transport failed or was cancelled; check CORS, mixed-content policy and server connectivity");
                return error.TransportFailure;
            }
            const value = j.get(event, "value");
            switch (op.stage) {
                .resources => {
                    if (value != .array or value.array.items.len > max_configured_servers) return error.InvalidConfiguredInventory;
                    if (j.is(j.get(op.request, "action"), "list") and j.get(op.request, "server") == .null) {
                        op.aggregate = true;
                        for (value.array.items) |resource| if (j.truth(j.get(resource, "enabled"))) try op.resources.append(try j.clone(oa, resource));
                        std.mem.sort(V, op.resources.items, {}, resourceLess);
                        const digest = try discovery.inventory(oa, op.resources.items);
                        op.offset = try self.cursors.start(op.identity, op.request, &digest);
                        if (op.resources.items.len == 0) return self.completeDiscovery(a, slot, ctx);
                        try op.beginCatalog(op.resources.items[0]);
                        return self.initializeRemote(a, slot);
                    }
                    if (j.is(j.get(op.request, "action"), "call")) {
                        try self.pins.expandRequest(op.identity, &op.request);
                        try self.resolvedRecordTarget(slot);
                    }
                    var selected_resource: ?V = null;
                    for (value.array.items) |resource| if (j.truth(j.get(resource, "enabled")) and try j.equal(oa, j.get(resource, "id"), j.get(op.request, "server"))) {
                        selected_resource = resource;
                        break;
                    };
                    const resource = selected_resource orelse return error.ExactServerMissingOrDisabled;
                    if (j.get(op.request, "config_pin") != .null and !try j.equal(oa, j.get(op.request, "config_pin"), j.get(resource, "config_pin"))) return error.ChangedServerConfig;
                    if (!j.is(j.get(op.request, "action"), "call")) {
                        const digest = try discovery.inventory(oa, &.{resource});
                        _ = try self.cursors.start(op.identity, op.request, &digest);
                    }
                    try op.beginCatalog(resource);
                    return self.initializeRemote(a, slot);
                },
                .initialize => {
                    const output = try op.rpcResult(value);
                    const version = j.text(j.get(output, "protocolVersion")) orelse return error.UnsupportedMcpVersion;
                    var supported = false;
                    for (protocol.versions) |candidate| if (std.mem.eql(u8, candidate, version)) {
                        supported = true;
                        break;
                    };
                    if (!supported) return error.UnsupportedMcpVersion;
                    if (j.get(output, "capabilities") != .object or j.get(output, "serverInfo") != .object) return error.InvalidInitializeResult;
                    op.version = try oa.dupe(u8, version);
                    op.stage = .notify;
                    return self.queueHttp(a, slot, try op.httpPayload(try j.parse(oa, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"), true));
                },
                .notify => {
                    const status = j.uint(j.get(value, "status")) orelse 0;
                    if (status != 202 and status != 204) {
                        op.diagnostic = try std.fmt.allocPrint(oa, "MCP initialized notification failed (HTTP status {d})", .{status});
                        return error.InitializedNotificationRejected;
                    }
                    op.stage = .list;
                    return self.issue(a, slot, "tools/list", j.object(oa));
                },
                .list => {
                    const output = try op.rpcResult(value);
                    if (try op.admitPage(output)) |cursor| {
                        var params = j.object(oa);
                        try j.set(&params, "cursor", j.string(cursor));
                        return self.issue(a, slot, "tools/list", params);
                    }
                    if (op.aggregate) return self.nextServer(a, slot, null, ctx);
                    if (!j.is(j.get(op.request, "action"), "call")) return self.completeDiscovery(a, slot, ctx);
                    const params = try op.callParams();
                    op.stage = .call;
                    return self.issue(a, slot, "tools/call", params);
                },
                .call => {
                    const output = try op.rpcResult(value);
                    const content = j.get(output, "content");
                    if (output != .object or content != .array) return error.InvalidCallResult;
                    for (content.array.items) |part| if (part != .object or j.get(part, "type") != .string) return error.InvalidCallResult;
                    if (output.object.get("isError")) |v| if (v != .bool) return error.InvalidCallResult;
                    if (output.object.get("structuredContent")) |v| if (v != .object) return error.InvalidCallResult;
                    if ((try j.stringify(a, output)).len > 60 * 1024) return error.DurableResultBudgetExceeded;
                    return self.terminal(a, slot, output, null, false, ctx);
                },
            }
        }
        fn newSlot(self: *Self, request: V, identity: V, ui_test: bool) !*Slot {
            var index: ?usize = null;
            for (self.slots, 0..) |entry, i| if (entry == null) {
                index = i;
                break;
            };
            const at = index orelse return error.PendingOperationLimit;
            const slot = try self.allocator.create(Slot);
            errdefer self.allocator.destroy(slot);
            slot.arena = try newArena(self.allocator);
            errdefer self.freeArena(slot.arena);
            slot.arena.* = std.heap.ArenaAllocator.init(self.budget.allocator());
            slot.operation = try protocol.Operation.init(slot.arena.allocator(), request, identity);
            slot.request_id = null;
            slot.ui_test = ui_test;
            slot.call_dispatched = false;
            slot.record_id = 0;
            self.slots[at] = slot;
            return slot;
        }
        fn begin(self: *Self, a: A, request: V, identity: V, ctx: V, ui_test: bool) !V {
            const slot = self.newSlot(request, identity, ui_test) catch |err| return self.result(a, if (ui_test) null else try reply(a, identity, "failed", .null, @errorName(err), false));
            if (!ui_test) slot.record_id = self.addRecord(&slot.operation, ctx) catch |err| return self.terminalError(a, slot, err, ctx);
            switch (Host.resources.send("resource-list", "{}")) {
                .ok => |id| {
                    slot.request_id = id;
                    if (slot.operation.stage == .call) slot.call_dispatched = true;
                    return self.pending(a, slot);
                },
                .err => |message| {
                    defer self.allocator.free(message);
                    return self.terminal(a, slot, .null, "MCP configuration request could not be queued", false, ctx);
                },
            }
        }
        pub fn start(self: *Self, a: A, request: V, ctx: V) !V {
            try self.updateContext(a, ctx);
            const identity = j.get(ctx, "tool_invocation");
            if (identity != .object or j.get(identity, "invocation_id") != .string) return error.MissingToolIdentity;
            if (j.get(request, "action") != .string or (!j.is(j.get(request, "action"), "list") and !j.is(j.get(request, "action"), "describe") and !j.is(j.get(request, "action"), "call"))) return self.result(a, try reply(a, identity, "failed", .null, "Unsupported MCP tool action", false));
            if ((try j.stringify(a, request)).len > 64 * 1024) return self.result(a, try reply(a, identity, "failed", .null, "MCP request exceeds 64 KiB", false));
            return self.begin(a, request, identity, ctx, false);
        }
        pub fn phase(self: *Self, a: A, phase_name: []const u8, payload: V, ctx: V) !V {
            try self.updateContext(a, ctx);
            if (std.mem.eql(u8, phase_name, "history-reset")) {
                self.clearOperations();
                self.clearHistory();
                self.pins.reset();
                self.cursors.reset();
                return self.result(a, null);
            }
            if (!std.mem.eql(u8, phase_name, "event-result")) return self.result(a, null);
            const id64 = j.uint(j.get(payload, "request_id")) orelse return self.result(a, null);
            if (id64 > std.math.maxInt(u32)) return self.result(a, null);
            const id: u32 = @intCast(id64);
            for (self.configs.items, 0..) |entry, i| if (entry.id == id) {
                _ = self.configs.orderedRemove(i);
                if (j.truth(j.get(payload, "ok"))) {
                    self.safeServers(j.get(payload, "value")) catch |err| {
                        try self.setError(@errorName(err));
                        return self.result(a, null);
                    };
                    self.clearOwned(&self.last_error);
                } else try self.setError(j.text(j.get(payload, "error")) orelse "Resource configuration failed");
                return self.result(a, null);
            };
            for (self.slots) |entry| if (entry) |slot| if (slot.request_id == id) {
                slot.request_id = null;
                return self.advance(a, slot, payload, ctx) catch |err| self.failure(a, slot, err, ctx);
            };
            return self.result(a, null);
        }
        pub fn cancel(self: *Self, a: A, ctx: V) !V {
            try self.updateContext(a, ctx);
            const identity = j.get(ctx, "tool_invocation");
            for (self.slots) |entry| if (entry) |slot| {
                if (slot.ui_test or !try j.equal(a, slot.operation.identity, identity)) continue;
                defer self.dropSlot(slot);
                const op = &slot.operation;
                if (op.stage != .resources and op.stage != .initialize and op.rpc_id.len > 0) {
                    const oa = slot.arena.allocator();
                    var params = j.object(oa);
                    try j.set(&params, "requestId", j.string(op.rpc_id));
                    try j.set(&params, "reason", j.string("Client cancelled request"));
                    var body = j.object(oa);
                    try j.set(&body, "jsonrpc", j.string("2.0"));
                    try j.set(&body, "method", j.string("notifications/cancelled"));
                    try j.set(&body, "params", params);
                    const payload = try j.stringify(oa, try op.httpPayload(body, true));
                    switch (Host.net.send("http", payload)) {
                        .ok => {},
                        .err => |message| self.allocator.free(message),
                    }
                }
                try self.finishRecord(slot, .null, "Locally cancelled; a dispatched remote call may still have taken effect", slot.call_dispatched, ctx, "cancelled");
                break;
            };
            // The Host owns terminal cancellation; this export never completes twice.
            return self.result(a, null);
        }
        pub fn action(self: *Self, a: A, name: []const u8, payload: V, ctx: V) !V {
            return self.handleAction(a, name, payload, ctx) catch |err| {
                try self.setError(@errorName(err));
                return self.result(a, null);
            };
        }
        fn handleAction(self: *Self, a: A, name: []const u8, payload: V, ctx: V) !V {
            try self.updateContext(a, ctx);
            if (!j.truth(j.get(ctx, "user_action"))) return self.result(a, null);
            const target = j.get(j.get(ctx, "surface"), "target");
            if (j.is(target, "sidebar")) {
                if (std.mem.eql(u8, name, "clear-history")) self.clearHistory() else if (std.mem.eql(u8, name, "history-page")) {
                    self.page = @intCast(@min(j.uint(j.get(payload, "page")) orelse 0, 12));
                    self.selected = null;
                } else if (std.mem.eql(u8, name, "inspect-history")) {
                    self.selected = j.uint(j.get(payload, "id"));
                    self.detail_field = if (j.is(j.get(payload, "field"), "arguments")) "arguments" else "output";
                    self.detail_offset = @intCast(@min(j.uint(j.get(payload, "offset")) orelse 0, 128 * 1024));
                } else if (std.mem.eql(u8, name, "close-history")) self.selected = null;
                return self.result(a, null);
            }
            if (!j.is(target, "setting-page")) return self.result(a, null);
            self.clearOwned(&self.last_error);
            if (std.mem.eql(u8, name, "refresh-config")) try self.queueConfig("resource-list", j.object(a), a) else if (std.mem.eql(u8, name, "save-config")) {
                if (j.get(payload, "authorization") != .string or (j.text(j.get(payload, "authorization")) orelse "").len > 8192) return error.InvalidAuthorizationInput;
                if ((j.text(j.get(payload, "id")) orelse "").len > 128 or (j.text(j.get(payload, "endpoint")) orelse "").len > 2048) return error.ConfigurationPayloadBudget;
                try self.queueConfig("resource-configure", payload, a);
                // No projection, error or retained data references the password payload.
            } else if (std.mem.eql(u8, name, "remove")) {
                var p = j.object(a);
                try j.set(&p, "id", j.get(payload, "id"));
                try j.set(&p, "remove", .{ .bool = true });
                try self.queueConfig("resource-configure", p, a);
            } else if (std.mem.eql(u8, name, "server-toggle")) {
                const servers = if (self.servers == .array) self.servers.array.items else &.{};
                for (servers) |server| if (try j.equal(a, j.get(server, "id"), j.get(payload, "id"))) {
                    var p = try j.clone(a, server);
                    try j.set(&p, "authorization", j.string(""));
                    try j.set(&p, "enabled", .{ .bool = j.truth(j.get(payload, "enabled")) });
                    try self.queueConfig("resource-configure", p, a);
                    break;
                };
            } else if (std.mem.eql(u8, name, "test-connection")) {
                const id = j.text(j.get(payload, "id")) orelse return error.ExactServerMissingOrDisabled;
                const server = configured(self.servers, id);
                const pin = j.get(server, "config_pin");
                if (!matchesConfig(server, pin)) return error.ExactServerMissingOrDisabled;
                var request = j.object(a);
                try j.set(&request, "action", j.string("describe"));
                try j.set(&request, "server", j.string(id));
                try j.set(&request, "config_pin", pin);
                var identity = j.object(a);
                try j.set(&identity, "invocation_id", j.string(try std.fmt.allocPrint(a, "connection-{d}", .{try self.nextSequence()})));
                return self.begin(a, request, identity, ctx, true);
            }
            return self.result(a, null);
        }
        fn settings(self: *Self, a: A) !V {
            var out = j.object(a);
            try j.set(&out, "locale", j.string(self.locale));
            try j.set(&out, "servers", if (self.servers == .array) try j.clone(a, self.servers) else j.array(a));
            try j.set(&out, "status", j.string(self.status));
            try j.set(&out, "error", j.string(self.last_error));
            try j.set(&out, "busy", .{ .bool = self.configs.items.len > 0 });
            try j.set(&out, "health", try self.settingsHealth(a));
            try j.set(&out, "configured_count", .{ .integer = @intCast(if (self.servers == .array) self.servers.array.items.len else 0) });
            return out;
        }
        fn serviceStatus(entry: V) []const u8 {
            if (entry == .null) return "unchecked";
            const status = j.get(entry, "status");
            if (j.is(status, "pending") or j.is(status, "checking")) return "checking";
            for ([_][]const u8{ "online", "connected", "completed", "success", "healthy", "ok" }) |good| {
                if (j.is(status, good)) return "connected";
            }
            return "unavailable";
        }
        fn finiteNumber(value: V) ?V {
            if (value == .integer) return value;
            const n = j.number(value) orelse return null;
            return if (std.math.isFinite(n)) .{ .float = n } else null;
        }
        fn sidebarServices(self: *const Self, a: A) !V {
            var rows = j.array(a);
            // safeServers already bounds inventory entries and encoded bytes.
            if (self.servers != .array) return rows;
            std.debug.assert(self.servers.array.items.len <= max_configured_servers);
            for (self.servers.array.items) |server| {
                if (!serviceEnabled(server)) continue;
                const id = j.text(j.get(server, "id")) orelse continue;
                if (id.len == 0) continue;
                const entry = self.currentHealth(id, server);
                var row = j.object(a);
                try j.set(&row, "id", j.string(id));
                try j.set(&row, "status", j.string(serviceStatus(entry)));
                for ([_][]const u8{ "tool_count", "checked_at_ms" }) |key| {
                    if (finiteNumber(j.get(entry, key))) |n| try j.set(&row, key, n);
                }
                try rows.array.append(row);
            }
            return rows;
        }
        fn sidebar(self: *Self, a: A) !V {
            var out = j.object(a);
            var rows = j.array(a);
            const count = self.records.items.len;
            self.page = @min(self.page, if (count > 0) (count - 1) / 10 else 0);
            const page_start = self.page * 10;
            const stop = @min(count, page_start + 10);
            var completed: usize = 0;
            var settled: usize = 0;
            var durations: usize = 0;
            var duration_sum: f64 = 0;
            for (self.records.items) |record| {
                if (!std.mem.eql(u8, record.status, "pending")) settled += 1;
                if (std.mem.eql(u8, record.status, "completed")) completed += 1;
                if (record.duration_ms) |d| {
                    durations += 1;
                    duration_sum += d;
                }
            }
            for (page_start..stop) |position| {
                const r = self.records.items[count - 1 - position];
                var row = j.object(a);
                try j.set(&row, "id", .{ .integer = @intCast(r.id) });
                try j.set(&row, "tool", j.string(r.tool));
                try j.set(&row, "server", j.string(r.server));
                try j.set(&row, "status", j.string(r.status));
                try j.set(&row, "start_time_ms", .{ .float = r.start_time_ms });
                try j.set(&row, "duration_ms", if (r.duration_ms) |d| .{ .float = d } else .null);
                try j.set(&row, "turn_id", try j.clone(a, r.turn_id));
                try j.set(&row, "round_id", try j.clone(a, r.round_id));
                try j.set(&row, "outcome_unknown", .{ .bool = r.unknown });
                try rows.array.append(row);
            }
            var metrics = j.object(a);
            try j.set(&metrics, "total", .{ .integer = @intCast(count) });
            try j.set(&metrics, "success_rate", if (settled > 0) .{ .float = @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(settled)) } else .null);
            try j.set(&metrics, "avg_duration_ms", if (durations > 0) .{ .float = duration_sum / @as(f64, @floatFromInt(durations)) } else .null);
            try j.set(&out, "locale", j.string(self.locale));
            try j.set(&out, "session_id", j.string(self.session));
            try j.set(&out, "has_session", .{ .bool = self.session.len > 0 });
            try j.set(&out, "services", try self.sidebarServices(a));
            try j.set(&out, "records", rows);
            try j.set(&out, "metrics", metrics);
            try j.set(&out, "page", .{ .integer = @intCast(self.page) });
            try j.set(&out, "page_size", .{ .integer = 10 });
            try j.set(&out, "total_records", .{ .integer = @intCast(count) });
            try j.set(&out, "error", j.string(""));
            var detail: V = .null;
            if (self.selected) |id| if (self.recordFor(id)) |r| {
                const source = if (std.mem.eql(u8, self.detail_field, "arguments")) r.arguments else r.output;
                var offset = @min(source.len, self.detail_offset);
                while (offset > 0 and offset < source.len and source[offset] & 0xc0 == 0x80) offset -= 1;
                var end = @min(source.len, offset + 4096);
                while (end < source.len and end > offset and source[end] & 0xc0 == 0x80) end -= 1;
                detail = j.object(a);
                try j.set(&detail, "field", j.string(self.detail_field));
                try j.set(&detail, "source", j.string(try a.dupe(u8, source[offset..end])));
                try j.set(&detail, "offset", .{ .integer = @intCast(offset) });
                try j.set(&detail, "next_offset", if (end < source.len) .{ .integer = @intCast(end) } else .null);
                try j.set(&detail, "total_bytes", .{ .integer = @intCast(source.len) });
                try j.set(&detail, "omitted", .{ .bool = end < source.len });
            };
            try j.set(&out, "selected_id", if (self.selected) |id| .{ .integer = @intCast(id) } else .null);
            try j.set(&out, "detail", detail);
            return out;
        }
        fn projectionShape(value: V, depth: usize, nodes: *usize) anyerror!void {
            nodes.* += 1;
            if (nodes.* > 4096) return error.ProjectionNodeBudget;
            if (depth > 24) return error.ProjectionDepthBudget;
            switch (value) {
                .array => |items| for (items.items) |item| try projectionShape(item, depth + 1, nodes),
                .object => |map| for (map.values()) |item| try projectionShape(item, depth + 1, nodes),
                .float => |n| if (!std.math.isFinite(n)) return error.ProjectionInvalidNumber,
                else => {},
            }
        }
        pub fn validateProjection(a: A, value: V) !void {
            var nodes: usize = 0;
            try projectionShape(value, 0, &nodes);
            const encoded = try j.stringify(a, value);
            defer a.free(encoded);
            if (!std.unicode.utf8ValidateSlice(encoded)) return error.ProjectionInvalidUtf8;
            if (encoded.len > 64 * 1024) return error.ProjectionByteBudget;
        }
        fn projectionFailure(self: *Self, a: A, target: []const u8, err: anyerror) !V {
            var out = j.object(a);
            try j.set(&out, "locale", j.string(self.locale));
            try j.set(&out, "error", j.string(@errorName(err)));
            if (std.mem.eql(u8, target, "setting-page")) {
                try j.set(&out, "servers", j.array(a));
                try j.set(&out, "health", j.object(a));
                try j.set(&out, "busy", .{ .bool = false });
                try j.set(&out, "configured_count", .{ .integer = 0 });
            } else {
                try j.set(&out, "session_id", j.string(self.session));
                try j.set(&out, "has_session", .{ .bool = self.session.len > 0 });
                try j.set(&out, "services", j.array(a));
                try j.set(&out, "records", j.array(a));
                try j.set(&out, "metrics", j.object(a));
                try j.set(&out, "total_records", .{ .integer = 0 });
                try j.set(&out, "page", .{ .integer = 0 });
                try j.set(&out, "page_size", .{ .integer = 10 });
                try j.set(&out, "detail", .null);
                try j.set(&out, "selected_id", .null);
            }
            return out;
        }
        pub fn projection(self: *Self, a: A, target: []const u8) !V {
            const value = if (std.mem.eql(u8, target, "setting-page")) try self.settings(a) else try self.sidebar(a);
            validateProjection(a, value) catch |err| {
                if (err == error.OutOfMemory) return err;
                return self.projectionFailure(a, target, err);
            };
            return value;
        }
        pub fn result(self: *Self, a: A, completion: ?V) !V {
            var patch = j.object(a);
            try j.set(&patch, "settings", try self.projection(a, "setting-page"));
            try j.set(&patch, "sidebar", try self.projection(a, "sidebar"));
            var result_value = j.object(a);
            try j.set(&result_value, "schema_version", .{ .integer = 1 });
            try j.set(&result_value, "vars_patch", patch);
            try j.set(&result_value, "rerender", .{ .bool = false });
            if (completion) |c| try j.set(&result_value, "tool_completion", c);
            return result_value;
        }
    };
}
