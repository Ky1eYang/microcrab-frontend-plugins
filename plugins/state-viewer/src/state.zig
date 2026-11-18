const std = @import("std");
const shared = @import("shared");
const allocator = shared.abi.allocator;
const Value = std.json.Value;
const limit = 4 * 1024 * 1024;

const Unique = shared.json.UniqueValue(true);
fn parseWithAllocator(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(Value) {
    if (text.len > limit) return error.JsonExceeds4MiB;
    const parsed = try std.json.parseFromSlice(Unique, a, text, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    return .{ .arena = parsed.arena, .value = parsed.value.value };
}
fn parse(text: []const u8) !std.json.Parsed(Value) {
    return parseWithAllocator(allocator, text);
}
fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn string(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
fn equals(value: Value, text: []const u8) bool {
    return if (string(value)) |s| std.mem.eql(u8, s, text) else false;
}
fn truth(value: Value) bool {
    return value == .bool and value.bool;
}
fn encode(value: anytype) ![]const u8 {
    return std.json.stringifyAlloc(allocator, value, .{});
}
fn replace(dest: *[]const u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    if (dest.len > 0) allocator.free(dest.*);
    dest.* = next;
}
fn clear(dest: *[]const u8) void {
    if (dest.len > 0) allocator.free(dest.*);
    dest.* = "";
}
fn validWitness(value: Value) bool {
    const runtime = string(field(value, "runtime_instance_id")) orelse return false;
    const revision = string(field(value, "variables_revision")) orelse return false;
    if (runtime.len == 0 or revision.len == 0) return false;
    for (revision) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
fn validUuid(id: []const u8) bool {
    if (id.len != 36) return false;
    var nonzero = false;
    for (id, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else {
            if (!std.ascii.isHex(c)) return false;
            if (c != '0') nonzero = true;
        }
    }
    return nonzero;
}
fn fieldExists(values: Value, metadata: Value, key: []const u8) bool {
    return (values == .object and values.object.contains(key)) or
        equals(field(field(metadata, key), "visibility"), "secret");
}
fn permitted(values: Value, metadata: Value, descriptors: Value, key: []const u8, deleting: bool) bool {
    if (values != .object) return false;
    const meta = field(metadata, key);
    if (!fieldExists(values, metadata, key)) return false;
    if (!deleting and equals(field(meta, "visibility"), "secret")) return false;
    const descriptor = field(descriptors, key);
    if (!equals(field(descriptor, "kind"), "custom")) return false;
    if (deleting) return truth(field(descriptor, "deletable")) and equals(field(meta, "owner"), "client");
    return truth(field(descriptor, "editable"));
}
fn requestId(value: Value) ?u32 {
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn resultSucceeded(payload: Value) !bool {
    if (payload != .object) return error.EventResultMustBeObject;
    var keys = payload.object.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "request_id") and !std.mem.eql(u8, key, "ok") and !std.mem.eql(u8, key, "value") and !std.mem.eql(u8, key, "error")) return error.UnexpectedEventResultField;
    }
    if (requestId(field(payload, "request_id")) == null) return error.InvalidEventResultRequestId;
    const ok = field(payload, "ok");
    if (ok != .bool) return error.EventResultRequiresBooleanOk;
    if (payload.object.contains("error") and field(payload, "error") != .string) return error.EventResultErrorMustBeString;
    if (ok.bool) {
        if (!payload.object.contains("value")) return error.EventResultSuccessRequiresValue;
        if (payload.object.contains("error")) return error.EventResultSuccessCannotContainError;
    } else if (payload.object.contains("value")) return error.EventResultFailureCannotContainValue;
    return ok.bool;
}

pub const StateManager = struct {
    values_json: []const u8 = "",
    metadata_json: []const u8 = "",
    descriptors_json: []const u8 = "",
    witness: []const u8 = "",
    session_id: []const u8 = "",
    scope: []const u8 = "",
    target: []const u8 = "",
    loading: bool = false,
    has_snapshot: bool = false,
    show_invisible: bool = false,
    error_msg: []const u8 = "",
    locale: []const u8 = "zh-CN",
    inspection_request: ?u32 = null,
    mutation_request: ?u32 = null,
    observation_request: ?u32 = null,
    mutation_status: []const u8 = "idle",
    mutation_operation_id: []const u8 = "",
    mutation_error: []const u8 = "",
    // These immutable copies survive refreshes and uncertain completions.
    mutation_expected: []const u8 = "",
    mutation_change: []const u8 = "",

    pub var global: StateManager = .{};

    pub fn initFromContext(ctx_json: []const u8) !void {
        try updateContext(ctx_json);
    }

    pub fn updateContext(ctx_json: []const u8) !void {
        updateContextInner(ctx_json) catch |err| {
            clear(&global.session_id);
            clear(&global.target);
            global.inspection_request = null;
            global.loading = false;
            global.has_snapshot = false;
            if (global.mutation_request != null or global.observation_request != null) global.mutation_status = "unknown";
            global.mutation_request = null;
            global.observation_request = null;
            try replace(&global.error_msg, @errorName(err));
            return err;
        };
    }
    fn updateContextInner(ctx_json: []const u8) !void {
        var parsed = try parse(ctx_json);
        defer parsed.deinit();
        const ctx = parsed.value;
        if (ctx != .object) return error.ContextMustBeObject;
        const sid_value = field(ctx, "session_id");
        if (sid_value != .null and sid_value != .string) return error.SessionIdMustBeStringOrNull;
        const sid = string(sid_value) orelse "";
        const scope = try encode(.{ field(ctx, "server_origin"), field(ctx, "owner_id"), sid_value, field(ctx, "instance_generation"), field(ctx, "history_generation") });
        defer allocator.free(scope);
        if (!std.mem.eql(u8, global.scope, scope)) {
            clear(&global.values_json);
            clear(&global.metadata_json);
            clear(&global.descriptors_json);
            clear(&global.witness);
            clear(&global.error_msg);
            clear(&global.mutation_operation_id);
            clear(&global.mutation_error);
            clear(&global.mutation_expected);
            clear(&global.mutation_change);
            global.loading = false;
            global.has_snapshot = false;
            global.inspection_request = null;
            global.mutation_request = null;
            global.observation_request = null;
            global.mutation_status = "idle";
            try replace(&global.scope, scope);
        }
        try replace(&global.session_id, sid);
        const target = string(field(field(ctx, "surface"), "target")) orelse "";
        try replace(&global.target, target);
        if (string(field(ctx, "locale"))) |locale| global.locale = if (std.mem.startsWith(u8, locale, "en")) "en-US" else "zh-CN";
    }

    pub fn hasSession() bool {
        return global.session_id.len > 0;
    }
    fn writableSurface() bool {
        return hasSession() and (std.mem.eql(u8, global.target, "sidebar") or std.mem.eql(u8, global.target, "expanded-page"));
    }
    pub fn ensureInspection() !void {
        if (!hasSession() or global.loading or global.has_snapshot) return;
        try refresh();
    }
    fn refresh() !void {
        if (!hasSession() or global.loading) return;
        switch (shared.host.session_state.send("state-inspection", "{}")) {
            .ok => |id| {
                global.inspection_request = id;
                global.loading = true;
                clear(&global.error_msg);
            },
            .err => |message| {
                defer if (message.len > 0) allocator.free(message);
                try replace(&global.error_msg, message);
            },
        }
    }
    fn failure(message: []const u8) ![]const u8 {
        try replace(&global.error_msg, message);
        return buildViewStateJson(allocator);
    }
    pub fn handleAction(action: []const u8, payload_json: []const u8) ![]const u8 {
        return actionInner(action, payload_json) catch |err| failure(@errorName(err));
    }
    fn actionInner(action: []const u8, payload_json: []const u8) ![]const u8 {
        var parsed = try parse(payload_json);
        defer parsed.deinit();
        if (parsed.value != .object) return error.ActionPayloadMustBeObject;
        if (!writableSurface()) return error.SessionSurfaceRequired;
        if (std.mem.eql(u8, action, "refresh")) {
            try refresh();
        } else if (std.mem.eql(u8, action, "toggle-invisible")) {
            global.show_invisible = !global.show_invisible;
        } else if (std.mem.eql(u8, action, "save-json") or std.mem.eql(u8, action, "delete-field")) {
            try mutate(parsed.value, std.mem.eql(u8, action, "delete-field"));
        } else if (std.mem.eql(u8, action, "observe-operation") or std.mem.eql(u8, action, "observe-json")) {
            try observe();
        }
        return buildViewStateJson(allocator);
    }
    fn mutate(payload: Value, deleting: bool) !void {
        if (global.mutation_request != null or global.observation_request != null or std.mem.eql(u8, global.mutation_status, "queued") or std.mem.eql(u8, global.mutation_status, "unknown")) return error.ObservePendingOperationBeforeSaving;
        if (!global.has_snapshot) return error.AtomicInspectionRequired;
        const key = string(field(payload, "key")) orelse return error.MissingStringKey;
        if (key.len == 0) return error.EmptyKey;
        const op = string(field(payload, "operation_id")) orelse return error.OperationUuidRequired;
        if (!validUuid(op)) return error.InvalidOperationUuid;
        if (std.mem.eql(u8, op, global.mutation_operation_id)) return error.OperationUuidAlreadyUsed;
        var values = try parse(global.values_json);
        defer values.deinit();
        var metadata = try parse(global.metadata_json);
        defer metadata.deinit();
        var descriptors = try parse(global.descriptors_json);
        defer descriptors.deinit();
        const exists = fieldExists(values.value, metadata.value, key);
        const is_new_value = field(payload, "is_new");
        if (is_new_value != .null and is_new_value != .bool) return error.IsNewMustBeBoolean;
        const is_new = truth(is_new_value);
        if (is_new and (exists or deleting)) return error.NewFieldAlreadyExists;
        if (!is_new and !permitted(values.value, metadata.value, descriptors.value, key, deleting)) return error.DescriptorDoesNotPermitMutation;
        var current_witness = try parse(global.witness);
        defer current_witness.deinit();
        const expected = if (field(payload, "expected") != .null) field(payload, "expected") else current_witness.value;
        if (!validWitness(expected)) return error.InvalidExpectedWitness;
        if (!deleting and !payload.object.contains("value")) return error.MissingValue;
        var change = std.ArrayList(u8).init(allocator);
        defer change.deinit();
        const writer = change.writer();
        if (deleting) {
            try writer.writeAll("{\"remove\":[");
            try std.json.stringify(key, .{}, writer);
            try writer.writeAll("]}");
        } else if (is_new) {
            try writer.writeAll("{\"scoped_set\":[{\"name\":");
            try std.json.stringify(key, .{}, writer);
            try writer.writeAll(",\"value\":");
            try std.json.stringify(field(payload, "value"), .{}, writer);
            try writer.writeAll(",\"visibility\":\"visible\",\"persistence\":\"persisted\",\"editors\":[\"agent\",\"client\",\"runtime\"]}]}");
        } else {
            try writer.writeAll("{\"set\":{");
            try std.json.stringify(key, .{}, writer);
            try writer.writeByte(':');
            try std.json.stringify(field(payload, "value"), .{}, writer);
            try writer.writeAll("}}");
        }
        const expected_json = try encode(expected);
        defer allocator.free(expected_json);
        var change_value = try parse(change.items);
        defer change_value.deinit();
        const request = try encode(.{ .operation_id = op, .expected = expected, .change = change_value.value });
        defer allocator.free(request);
        if (request.len > limit) return error.JsonExceeds4MiB;
        try replace(&global.mutation_operation_id, op);
        try replace(&global.mutation_expected, expected_json);
        try replace(&global.mutation_change, change.items);
        clear(&global.mutation_error);
        clear(&global.error_msg);
        switch (shared.host.session_state_write.send("state-change", request)) {
            .ok => |id| {
                global.mutation_request = id;
                global.mutation_status = "saving";
            },
            .err => |message| {
                defer if (message.len > 0) allocator.free(message);
                global.mutation_status = "error";
                try replace(&global.mutation_error, message);
            },
        }
    }
    fn observe() !void {
        if (global.mutation_operation_id.len == 0 or global.observation_request != null) return error.NoOperationToObserve;
        if (!std.mem.eql(u8, global.mutation_status, "unknown") and !std.mem.eql(u8, global.mutation_status, "queued")) return error.OperationDoesNotNeedObservation;
        const request = try encode(.{ .operation_id = global.mutation_operation_id });
        defer allocator.free(request);
        switch (shared.host.session_state_write.send("state-operation", request)) {
            .ok => |id| global.observation_request = id,
            .err => |message| {
                defer if (message.len > 0) allocator.free(message);
                try replace(&global.mutation_error, message);
            },
        }
    }
    pub fn handlePhase(phase: []const u8, payload_json: []const u8) ![]const u8 {
        if (!std.mem.eql(u8, phase, "event-result")) return "{}";
        return complete(payload_json) catch |err| failure(@errorName(err));
    }
    fn complete(payload_json: []const u8) ![]const u8 {
        var parsed = try parse(payload_json);
        defer parsed.deinit();
        const payload = parsed.value;
        const id = requestId(field(payload, "request_id")) orelse return "{}";
        const inspecting = global.inspection_request == id;
        const mutating = global.mutation_request == id;
        const observing = global.observation_request == id;
        if (!inspecting and !mutating and !observing) return "{}";
        // The observed 0.4 broker sends only request_id, ok, value/error.
        const successful = resultSucceeded(payload) catch |err| {
            if (inspecting) {
                global.inspection_request = null;
                global.loading = false;
            } else {
                if (mutating) global.mutation_request = null else global.observation_request = null;
                global.mutation_status = "unknown";
                try replace(&global.mutation_error, @errorName(err));
            }
            return failure(@errorName(err));
        };
        const result = field(payload, "value");
        if (inspecting) {
            global.inspection_request = null;
            global.loading = false;
            if (!successful) return failure(string(field(payload, "error")) orelse "State inspection failed without an error message");
            if (field(result, "values") != .object or field(result, "metadata") != .object or field(result, "descriptors") != .object or !validWitness(field(result, "witness"))) return failure("Atomic inspection requires values, metadata, descriptors and a valid witness");
            // Prepare the entire snapshot before replacing any visible part.
            var installed = false;
            const v = try encode(field(result, "values"));
            errdefer if (!installed) allocator.free(v);
            const m = try encode(field(result, "metadata"));
            errdefer if (!installed) allocator.free(m);
            const d = try encode(field(result, "descriptors"));
            errdefer if (!installed) allocator.free(d);
            const w = try encode(field(result, "witness"));
            clear(&global.values_json);
            clear(&global.metadata_json);
            clear(&global.descriptors_json);
            clear(&global.witness);
            global.values_json = v;
            global.metadata_json = m;
            global.descriptors_json = d;
            global.witness = w;
            installed = true;
            global.has_snapshot = true;
            clear(&global.error_msg);
        } else {
            if (mutating) global.mutation_request = null else global.observation_request = null;
            if (!successful) {
                global.mutation_status = "unknown";
                try replace(&global.mutation_error, string(field(payload, "error")) orelse "Operation outcome is unknown");
            } else if (!equals(field(result, "operation_id"), global.mutation_operation_id)) {
                global.mutation_status = "unknown";
                try replace(&global.mutation_error, "Operation receipt identity mismatch");
            } else {
                const status = field(result, "status");
                if (equals(status, "applied")) {
                    global.mutation_status = "saved";
                    clear(&global.mutation_error);
                    // A pre-write inspection must not overwrite the post-write one.
                    global.inspection_request = null;
                    global.loading = false;
                    try refresh();
                } else if (equals(status, "queued")) {
                    global.mutation_status = "queued";
                } else if (equals(status, "rejected")) {
                    global.mutation_status = "error";
                    const reason = try encode(field(result, "reason"));
                    defer allocator.free(reason);
                    try replace(&global.mutation_error, reason);
                } else {
                    global.mutation_status = "unknown";
                    const reason = try encode(result);
                    defer allocator.free(reason);
                    try replace(&global.mutation_error, reason);
                }
            }
        }
        return buildViewStateJson(allocator);
    }
    pub fn buildViewStateJson(alloc: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(alloc);
        errdefer list.deinit();
        const writer = list.writer();
        try writer.writeAll("{\"values\":");
        try writer.writeAll(if (global.values_json.len > 0) global.values_json else "{}");
        try writer.writeAll(",\"metadata\":");
        try writer.writeAll(if (global.metadata_json.len > 0) global.metadata_json else "{}");
        try writer.writeAll(",\"descriptors\":");
        try writer.writeAll(if (global.descriptors_json.len > 0) global.descriptors_json else "{}");
        try writer.writeAll(",\"witness\":");
        try writer.writeAll(if (global.witness.len > 0) global.witness else "null");
        const rest = try std.json.stringifyAlloc(alloc, .{
            .session_id = global.session_id,
            .loading = global.loading,
            .has_snapshot = global.has_snapshot,
            .show_invisible = global.show_invisible,
            .locale = global.locale,
            .@"error" = global.error_msg,
            .mutation_status = global.mutation_status,
            .mutation_operation_id = global.mutation_operation_id,
            .mutation_error = global.mutation_error,
            .mutation_observing = global.observation_request != null,
        }, .{});
        defer alloc.free(rest);
        try writer.writeByte(',');
        try writer.writeAll(rest[1..]);
        return list.toOwnedSlice();
    }
};

test "event result requires the exact broker envelope and explicit boolean success" {
    const a = std.testing.allocator;
    const Case = struct { text: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .text = "{\"request_id\":1,\"value\":{}}", .expected = error.EventResultRequiresBooleanOk },
        .{ .text = "{\"request_id\":1,\"ok\":\"true\",\"value\":{}}", .expected = error.EventResultRequiresBooleanOk },
        .{ .text = "{\"request_id\":1,\"ok\":true,\"result\":{}}", .expected = error.UnexpectedEventResultField },
        .{ .text = "{\"request_id\":1,\"ok\":true,\"kind\":\"state-change\",\"value\":{}}", .expected = error.UnexpectedEventResultField },
        .{ .text = "{\"request_id\":1,\"ok\":true}", .expected = error.EventResultSuccessRequiresValue },
    };
    for (cases) |case| {
        var parsed = try parseWithAllocator(a, case.text);
        defer parsed.deinit();
        try std.testing.expectError(case.expected, resultSucceeded(parsed.value));
    }
    var applied = try parseWithAllocator(a, "{\"request_id\":1,\"ok\":true,\"value\":{\"status\":\"rejected\",\"reason\":{\"code\":\"variable_conflict\"}}}");
    defer applied.deinit();
    try std.testing.expect(try resultSucceeded(applied.value));
    try std.testing.expect(equals(field(field(field(applied.value, "value"), "reason"), "code"), "variable_conflict"));
    var failed = try parseWithAllocator(a, "{\"request_id\":1,\"ok\":false,\"error\":\"transport scope expired\"}");
    defer failed.deinit();
    try std.testing.expect(!try resultSucceeded(failed.value));
}

test "UUIDs require complete hex identity and never synthesize a fallback" {
    try std.testing.expect(validUuid("449f2b2f-480a-40f4-9a21-e207a8802b65"));
    try std.testing.expect(!validUuid("449f2b2z-480a-40f4-9a21-e207a8802b65"));
    try std.testing.expect(!validUuid("00000000-0000-0000-0000-000000000000"));
}

test "descriptor policy fails closed and deletion requires client ownership" {
    const a = std.testing.allocator;
    var values = try std.json.parseFromSlice(Value, a, "{\"x\":1}", .{});
    defer values.deinit();
    var metadata = try std.json.parseFromSlice(Value, a, "{\"x\":{\"owner\":\"agent\"}}", .{});
    defer metadata.deinit();
    var descriptors = try std.json.parseFromSlice(Value, a, "{\"x\":{\"kind\":\"custom\",\"editable\":true,\"deletable\":true}}", .{});
    defer descriptors.deinit();
    try std.testing.expect(permitted(values.value, metadata.value, descriptors.value, "x", false));
    try std.testing.expect(!permitted(values.value, metadata.value, descriptors.value, "x", true));
    try std.testing.expect(!permitted(values.value, metadata.value, .null, "x", false));
}

test "metadata-only Secret deletion requires exact custom descriptor and client ownership" {
    const a = std.testing.allocator;
    const Case = struct {
        values: []const u8 = "{}",
        metadata: []const u8 = "{\"TOKEN\":{\"visibility\":\"secret\",\"owner\":\"client\"}}",
        descriptors: []const u8 = "{\"TOKEN\":{\"kind\":\"custom\",\"editable\":false,\"deletable\":true}}",
        deleting: bool = true,
        allowed: bool = false,
    };
    const cases = [_]Case{
        .{ .allowed = true },
        .{ .descriptors = "{\"TOKEN\":{\"kind\":\"custom\",\"editable\":false,\"deletable\":false}}" },
        .{ .descriptors = "{\"TOKEN\":{\"kind\":\"framework\",\"deletable\":true}}" },
        .{ .descriptors = "{}" },
        .{ .metadata = "{\"TOKEN\":{\"visibility\":\"secret\",\"owner\":\"agent\"}}" },
        .{ .metadata = "{\"TOKEN\":{\"visibility\":\"secret\"}}" },
        .{ .metadata = "{\"TOKEN\":{\"visibility\":\"visible\",\"owner\":\"client\"}}" },
        .{ .metadata = "{\"TOKEN\":{\"visibility\":\"invisible\",\"owner\":\"client\"}}" },
        .{ .metadata = "{}" },
        .{ .deleting = false },
        .{ .deleting = false, .descriptors = "{\"TOKEN\":{\"kind\":\"custom\",\"editable\":true,\"deletable\":true}}" },
        .{ .values = "null" },
        .{ .values = "{\"TOKEN\":\"{{secret:TOKEN}}\"}", .allowed = true },
        .{ .values = "{\"TOKEN\":\"{{secret:TOKEN}}\"}", .deleting = false, .descriptors = "{\"TOKEN\":{\"kind\":\"custom\",\"editable\":true,\"deletable\":true}}" },
        .{ .values = "{\"TOKEN\":1}", .metadata = "{\"TOKEN\":{\"visibility\":\"visible\",\"owner\":\"client\"}}", .allowed = true },
    };
    for (cases) |case| {
        var values = try parseWithAllocator(a, case.values);
        defer values.deinit();
        var metadata = try parseWithAllocator(a, case.metadata);
        defer metadata.deinit();
        var descriptors = try parseWithAllocator(a, case.descriptors);
        defer descriptors.deinit();
        try std.testing.expectEqual(case.allowed, permitted(values.value, metadata.value, descriptors.value, "TOKEN", case.deleting));
        try std.testing.expect(!fieldExists(values.value, metadata.value, "OTHER"));
        try std.testing.expect(!permitted(values.value, metadata.value, descriptors.value, "OTHER", case.deleting));
    }
}

test "new variable collision checks include omitted Secret names" {
    const a = std.testing.allocator;
    var values = try parseWithAllocator(a, "{\"PUBLIC\":0}");
    defer values.deinit();
    var metadata = try parseWithAllocator(a, "{\"TOKEN\":{\"visibility\":\"secret\"},\"MISSING\":{\"visibility\":\"visible\"}}");
    defer metadata.deinit();
    try std.testing.expect(fieldExists(values.value, metadata.value, "TOKEN"));
    try std.testing.expect(fieldExists(values.value, metadata.value, "PUBLIC"));
    try std.testing.expect(!fieldExists(values.value, metadata.value, "MISSING"));
    try std.testing.expect(!fieldExists(values.value, metadata.value, "NEW"));
}

test "canonical dynamic parser rejects nested duplicate keys and trailing JSON" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.DuplicateField, parseWithAllocator(a, "{\"value\":{\"x\":1,\"x\":2}}"));
    try std.testing.expectError(error.SyntaxError, parseWithAllocator(a, "{} {}"));
    try std.testing.expectError(error.DuplicateField, parseWithAllocator(a, "{\"x\":1,\"\\u0078\":2}"));
}

test "canonical JSON preserves numeric values and accepts nested containers" {
    const a = std.testing.allocator;
    const source = "{\"x\":[true,false,null,{\"huge\":18446744073709551616,\"decimal\":0.12345678901234567890123456789}],\"text\":\"values: not a field\"}";
    var parsed = try parseWithAllocator(a, source);
    defer parsed.deinit();
    const output = try std.json.stringifyAlloc(a, parsed.value, .{});
    defer a.free(output);
    try std.testing.expectEqualStrings(source, output);
}

test "JSON input budget and witness and request identities fail closed" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, limit + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.JsonExceeds4MiB, parseWithAllocator(a, oversized));
    try std.testing.expect(!validWitness(.null));
    try std.testing.expect(requestId(.{ .integer = -1 }) == null);
    try std.testing.expect(requestId(.{ .integer = 4294967296 }) == null);
    try std.testing.expect(requestId(.{ .string = "1" }) == null);
    try std.testing.expectEqual(@as(?u32, 23), requestId(.{ .integer = 23 }));
}
