const std = @import("std");
const shared = @import("shared");
const preview = @import("preview.zig");
const scanner = @import("scanner.zig");
const html = @import("ui_assets").html;
const allocator = shared.abi.allocator;
pub const cabi_realloc = shared.abi.cabi_realloc;

const id = "microcrab.prompt-redactor";
const name = "Prompt Redactor";
const version = "0.1.0";
const description = "Scan pasted text locally and copy a reviewed redacted preview";
const targets = [_]u8{ @intFromEnum(preview.Target.sidebar), @intFromEnum(preview.Target.expanded_page) };

comptime {
    // Allow for worst-case JSON escaping and protocol fields on the 64 KiB
    // bridge. Revisit both bounds if the host protocol or scanner cap changes.
    std.debug.assert(preview.max_payload_bytes + 256 < 64 * 1024);
    std.debug.assert(scanner.max_input_bytes * 6 + 256 < 64 * 1024);
    std.debug.assert(scanner.max_output_bytes < 48 * 1024);
}
const idle = "{\"schema_version\":1}";
const redraw = "{\"schema_version\":1,\"rerender\":true}";

var manifest_buf: [14]u32 = undefined;
var string_buf: [2]u32 = undefined;
var view_buf: [11]u32 = undefined;
var pending: preview.Pending = .{};
// JSON can escape each input byte as six bytes. This buffer covers the HTML,
// one projection, and framing; only the written part is returned to the host.
var view_bytes: [6 * (html.len + scanner.max_output_bytes) + 256]u8 = undefined;
var view_len: usize = 0;
// Both parser inputs are independently checked before parsing. Fixed scratch
// makes malformed JSON fail closed on quota rather than allocating a heap.
var scratch: [80 * 1024]u8 = undefined;

export fn manifest() [*]const u32 {
    manifest_buf = .{
        @intFromPtr(id.ptr),      id.len,                @intFromPtr(name.ptr), name.len,
        @intFromPtr(version.ptr), version.len,           1,                     @intFromPtr(description.ptr),
        description.len,          @intFromPtr(&targets), targets.len,           0,
        0,                        0,
    };
    return &manifest_buf;
}

export fn cabi_post_manifest(_: [*]const u32) void {}

fn stringResult(text: []const u8) [*]const u32 {
    string_buf = .{ @intFromPtr(text.ptr), @intCast(text.len) };
    return &string_buf;
}

fn viewOutput(mode: shared.types.RenderMode, text: []const u8) [*]const u32 {
    view_buf = .{ 1, @intFromEnum(mode), @intFromPtr(text.ptr), @intCast(text.len), 0, 0, 0, 0, 0, 0, 0 };
    return &view_buf;
}

fn parseContext(ctx: []const u8, a: std.mem.Allocator) ?preview.Context {
    if (ctx.len > preview.max_context_bytes) return null;
    return std.json.parseFromSliceLeaky(preview.Context, a, ctx, .{ .ignore_unknown_fields = true }) catch null;
}

fn expire(ctx: []const u8) void {
    if (pending.entry == null or ctx.len > preview.max_context_bytes) return;
    defer std.crypto.utils.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const Clock = struct { host_monotonic_ms: f64 };
    const clock = std.json.parseFromSliceLeaky(Clock, fba.allocator(), ctx, .{ .ignore_unknown_fields = true }) catch return;
    if (std.math.isFinite(clock.host_monotonic_ms)) pending.expire(clock.host_monotonic_ms);
}

fn wipeFree(bytes: []u8) void {
    std.crypto.utils.secureZero(u8, bytes);
    allocator.free(bytes);
}

export fn init(ctx: [*]u8, len: usize) [*]const u32 {
    defer allocator.free(ctx[0..len]);
    pending.clear();
    return stringResult(idle);
}

export fn cabi_post_init(_: [*]const u32) void {}

fn encodeView(projection: ?preview.Projection) ![]const u8 {
    var stream = std.io.fixedBufferStream(&view_bytes);
    const writer = stream.writer();
    // Clear even a partially written preview if encoding fails.
    errdefer std.crypto.utils.secureZero(u8, stream.getWritten());
    try writer.writeAll("{\"html\":");
    try std.json.encodeJsonString(html, .{}, writer);
    try writer.writeAll(",\"view_state\":");
    try std.json.stringify(projection, .{}, writer);
    try writer.writeByte('}');
    view_len = stream.getWritten().len;
    return stream.getWritten();
}

export fn @"render-view"(target: u32, vars: [*]u8, vars_len: usize, ctx: [*]u8, ctx_len: usize) [*]const u32 {
    defer allocator.free(vars[0..vars_len]);
    defer allocator.free(ctx[0..ctx_len]);
    const declared: preview.Target = switch (target) {
        0 => .sidebar,
        1 => .expanded_page,
        else => return viewOutput(.native_json, "null"),
    };
    defer std.crypto.utils.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const projection = if (parseContext(ctx[0..ctx_len], fba.allocator())) |context| pending.get(context, declared) else null;
    defer if (projection != null) pending.clear();
    const envelope = encodeView(projection) catch return viewOutput(.native_json, "null");
    return viewOutput(.webview_html, envelope);
}

export fn @"cabi_post_render-view"(_: [*]const u32) void {
    std.crypto.utils.secureZero(u8, view_bytes[0..view_len]);
    view_len = 0;
}

export fn @"on-action"(action: [*]u8, action_len: usize, payload: [*]u8, payload_len: usize, vars: [*]u8, vars_len: usize, ctx: [*]u8, ctx_len: usize) [*]const u32 {
    defer allocator.free(action[0..action_len]);
    defer wipeFree(payload[0..payload_len]);
    defer allocator.free(vars[0..vars_len]);
    defer allocator.free(ctx[0..ctx_len]);
    if (!std.mem.eql(u8, action[0..action_len], preview.action_name) or payload_len > preview.max_payload_bytes) {
        expire(ctx[0..ctx_len]);
        return stringResult(idle);
    }
    defer std.crypto.utils.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const context = parseContext(ctx[0..ctx_len], fba.allocator()) orelse return stringResult(idle);
    if (std.math.isFinite(context.host_monotonic_ms)) pending.expire(context.host_monotonic_ms);
    if (!context.user_action or context.scope() == null) return stringResult(idle);
    const request = std.json.parseFromSliceLeaky(preview.Request, fba.allocator(), payload[0..payload_len], .{}) catch return stringResult(idle);
    return stringResult(if (pending.prepare(context, request)) redraw else idle);
}

export fn @"cabi_post_on-action"(_: [*]const u32) void {}

export fn @"on-phase"(phase: [*]u8, phase_len: usize, payload: [*]u8, payload_len: usize, vars: [*]u8, vars_len: usize, ctx: [*]u8, ctx_len: usize) [*]const u32 {
    defer allocator.free(phase[0..phase_len]);
    defer allocator.free(payload[0..payload_len]);
    defer allocator.free(vars[0..vars_len]);
    defer allocator.free(ctx[0..ctx_len]);
    expire(ctx[0..ctx_len]);
    return stringResult(idle);
}

export fn @"cabi_post_on-phase"(_: [*]const u32) void {}
