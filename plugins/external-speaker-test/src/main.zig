const std = @import("std");
const shared = @import("shared");
const assets = @import("ui_assets");
const contract = @import("runtime.zig");

var budget = @import("budget.zig").Budget{ .parent = std.heap.wasm_allocator };
const allocator = budget.allocator();
const Host = struct {
    pub fn net(wire: []const u8) ?u32 {
        return requestId(shared.host.net.send("http", wire));
    }
    pub fn resources(kind: []const u8, wire: []const u8) ?u32 {
        return requestId(shared.host.resources.send(kind, wire));
    }
    fn requestId(result: shared.host.ResultU32) ?u32 {
        return switch (result) {
            .ok => |id| id,
            .err => |diagnostic| blk: {
                allocator.free(diagnostic);
                break :blk null;
            },
        };
    }
};
var runtime = contract.Runtime(Host){ .allocator = allocator };

export fn cabi_realloc(old: ?*anyopaque, size: usize, alignment: usize, new_size: usize) callconv(.C) ?*anyopaque {
    const actual_alignment = @max(1, alignment);
    const log: u8 = @intCast(std.math.log2(actual_alignment));
    if (new_size == 0) {
        if (old) |p| if (size > 0) allocator.rawFree(@as([*]u8, @ptrCast(p))[0..size], log, @returnAddress());
        return @ptrFromInt(actual_alignment);
    }
    const p = allocator.rawAlloc(new_size, log, @returnAddress()) orelse return null;
    if (old) |v| if (size > 0) {
        const input = @as([*]u8, @ptrCast(v))[0..size];
        const preserve = @min(size, new_size);
        @memcpy(p[0..preserve], input[0..preserve]);
        allocator.rawFree(input, log, @returnAddress());
    };
    return p;
}

const targets = [_]u8{ 0, 1 };
const AbiString = extern struct { ptr: [*]const u8, len: usize };
const no_origins = [_]AbiString{};
const Manifest = extern struct {
    id: AbiString,
    name: AbiString,
    version: AbiString,
    has_description: u32,
    description: AbiString,
    targets: AbiString,
    has_origins: u32,
    origins_ptr: [*]const AbiString,
    origins_len: usize,
};
const plugin_manifest = Manifest{
    .id = str("microcrab.external-speaker-test"),
    .name = str("External Speaker Test"),
    .version = str("0.4.3"),
    .has_description = 1,
    .description = str("Test speaker messages and replies in authorized Session inboxes. Requires External Messaging to be explicitly enabled for the destination Project. Not for production."),
    .targets = str(&targets),
    .has_origins = 0,
    .origins_ptr = &no_origins,
    .origins_len = 0,
};
export fn manifest() *const Manifest {
    return &plugin_manifest;
}
export fn cabi_post_manifest(_: *const Manifest) void {}

fn str(value: []const u8) AbiString {
    return .{ .ptr = value.ptr, .len = value.len };
}
const View = extern struct {
    schema_version: u32 = 1,
    mode: u32 = 0,
    content: AbiString = str("null"),
    has_vars: u32 = 0,
    vars: AbiString = str(""),
    rerender: u32 = 0,
    has_error: u32 = 0,
    diagnostic: AbiString = str(""),
};
comptime {
    std.debug.assert(@sizeOf(Manifest) == 56);
    std.debug.assert(@sizeOf(View) == 44);
}
var result_text: AbiString = undefined;
var result_view: View = .{};
var owned_view: ?[]const u8 = null;

fn stringResult(value: []const u8) *const AbiString {
    result_text = str(value);
    return &result_text;
}
export fn init(ctx: [*]const u8, n: usize) *const AbiString {
    defer allocator.free(ctx[0..n]);
    return stringResult(contract.unchanged);
}
export fn cabi_post_init(_: *const AbiString) void {}

export fn @"on-action"(np: [*]const u8, n: usize, pp: [*]const u8, p: usize, vp: [*]const u8, v: usize, cp: [*]const u8, c: usize) *const AbiString {
    defer allocator.free(np[0..n]);
    defer allocator.free(pp[0..p]); // Budget wipes canonical input, including rejected payloads.
    defer allocator.free(vp[0..v]);
    defer allocator.free(cp[0..c]);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // All decoded copies, including incomplete/invalid JSON, are wiped.
    const a = arena.allocator();
    const ctx = contract.parse(a, cp[0..c], contract.max_context) catch return stringResult(contract.unchanged);
    const payload = contract.parse(a, pp[0..p], contract.max_action) catch return failedAction();
    const changed = runtime.action(a, np[0..n], payload, ctx) catch return failedAction();
    return stringResult(if (changed and runtime.actionNeedsRender(np[0..n], ctx)) contract.rerender else contract.unchanged);
}
fn failedAction() *const AbiString {
    return stringResult("{\"schema_version\":1,\"error\":\"External Speaker action could not be processed\"}");
}
export fn @"cabi_post_on-action"(_: *const AbiString) void {}

export fn @"on-phase"(np: [*]const u8, n: usize, pp: [*]const u8, p: usize, vp: [*]const u8, v: usize, cp: [*]const u8, c: usize) *const AbiString {
    defer allocator.free(np[0..n]);
    defer allocator.free(pp[0..p]);
    defer allocator.free(vp[0..v]);
    defer allocator.free(cp[0..c]);
    if (!std.mem.eql(u8, np[0..n], "event-result")) return stringResult(contract.unchanged);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = contract.parse(a, cp[0..c], contract.max_context) catch return stringResult(contract.unchanged);
    const payload = contract.parse(a, pp[0..p], contract.max_completion) catch .null;
    const changed = if (payload == .null) runtime.unreadableCompletion(ctx) else runtime.complete(a, payload, ctx);
    return stringResult(if (changed) contract.rerender else contract.unchanged);
}
export fn @"cabi_post_on-phase"(_: *const AbiString) void {}

export fn @"render-view"(target: u32, vp: [*]const u8, v: usize, cp: [*]const u8, c: usize) *const View {
    defer allocator.free(vp[0..v]);
    defer allocator.free(cp[0..c]);
    if (owned_view) |prev| allocator.free(prev);
    owned_view = null;
    result_view = .{};
    if (target != 0 and target != 1) return &result_view;
    const envelope = render(cp[0..c]) catch {
        result_view.has_error = 1;
        result_view.diagnostic = str("External Speaker view is unavailable");
        return &result_view;
    };
    owned_view = envelope;
    result_view.mode = 1;
    result_view.content = str(envelope);
    return &result_view;
}
fn render(source: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try contract.parse(a, source, contract.max_context);
    const projection = try runtime.projection(a, ctx);
    const json = try std.json.stringifyAlloc(a, projection, .{});
    return shared.json.createEnvelope(allocator, assets.panel_html, json);
}
export fn @"cabi_post_render-view"(_: *const View) void {
    if (owned_view) |prev| allocator.free(prev);
    owned_view = null;
}
