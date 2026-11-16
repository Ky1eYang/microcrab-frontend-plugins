const std = @import("std");
const shared = @import("shared");
const j = @import("json_helpers.zig");
const Engine = @import("runtime.zig").Runtime(shared.host);
const allocator = shared.abi.allocator;
pub const cabi_realloc = shared.abi.cabi_realloc;
const assets = @import("ui_assets");
var engine: ?Engine = null;
fn runtime() !*Engine {
    if (engine == null) engine = try Engine.init(allocator);
    return &engine.?;
}
const targets = [_]u8{ 0, 4 };
const description = "Multi-server MCP tools. List or describe tools, then call with pin and arguments. Expired references require describe again; never retry uncertain effects.";
var manifest_buffer: [56]u8 align(4) = undefined;
export fn manifest() [*]const u8 {
    var stream = std.io.fixedBufferStream(&manifest_buffer);
    const writer = stream.writer();
    inline for (.{ "microcrab.mcp-bridge", "MCP bridge", "0.4.0" }) |text| {
        writer.writeInt(u32, @intFromPtr(text.ptr), .little) catch unreachable;
        writer.writeInt(u32, text.len, .little) catch unreachable;
    }
    writer.writeInt(u32, 1, .little) catch unreachable;
    writer.writeInt(u32, @intFromPtr(description.ptr), .little) catch unreachable;
    writer.writeInt(u32, description.len, .little) catch unreachable;
    writer.writeInt(u32, @intFromPtr(&targets), .little) catch unreachable;
    writer.writeInt(u32, targets.len, .little) catch unreachable;
    inline for (0..3) |_| writer.writeInt(u32, 0, .little) catch unreachable;
    return &manifest_buffer;
}
export fn cabi_post_manifest(_: [*]const u8) void {}
var string_buffer: [8]u8 align(4) = undefined;
var owned_string: ?[]const u8 = null;
fn releaseString() void {
    if (owned_string) |s| allocator.free(s);
    owned_string = null;
}
fn stringResult(source: []const u8) [*]const u8 {
    releaseString();
    owned_string = source;
    std.mem.writeInt(u32, string_buffer[0..4], @intFromPtr(source.ptr), .little);
    std.mem.writeInt(u32, string_buffer[4..8], @intCast(source.len), .little);
    return &string_buffer;
}
fn failure(err: anyerror) [*]const u8 {
    const source = std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"error\":\"{s}\"}}", .{@errorName(err)}) catch @trap();
    return stringResult(source);
}
const Kind = enum { init, action, phase, start, cancel };
fn execute(kind: Kind, name: []const u8, payload_source: []const u8, context_source: []const u8) ![*]const u8 {
    if (context_source.len > 64 * 1024 or payload_source.len > 4 * 1024 * 1024) return error.LifecycleJsonBudget;
    var wiping = @import("wiping_allocator.zig").WipingAllocator{ .parent = allocator };
    var arena = std.heap.ArenaAllocator.init(if (kind == .action) wiping.allocator() else allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try j.parse(a, context_source);
    const payload = if (payload_source.len > 0) try j.parse(a, payload_source) else j.object(a);
    defer if (kind == .action) {
        if (j.text(j.get(payload, "authorization"))) |secret| std.crypto.utils.secureZero(u8, @constCast(secret));
    };
    const instance = try runtime();
    const result = switch (kind) {
        .init => try instance.initialize(a, ctx),
        .action => try instance.action(a, name, payload, ctx),
        .phase => try instance.phase(a, name, payload, ctx),
        .start => try instance.start(a, payload, ctx),
        .cancel => try instance.cancel(a, ctx),
    };
    return stringResult(try j.stringify(allocator, result));
}
export fn init(ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(ctx_ptr[0..ctx_len]);
    return execute(.init, "", "", ctx_ptr[0..ctx_len]) catch |err| failure(err);
}
export fn cabi_post_init(_: [*]const u8) void {
    releaseString();
}
export fn @"start-tool"(request_ptr: [*]const u8, request_len: usize, ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(request_ptr[0..request_len]);
    defer allocator.free(ctx_ptr[0..ctx_len]);
    return execute(.start, "", request_ptr[0..request_len], ctx_ptr[0..ctx_len]) catch |err| failure(err);
}
export fn @"cabi_post_start-tool"(_: [*]const u8) void {
    releaseString();
}
export fn @"cancel-tool"(ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(ctx_ptr[0..ctx_len]);
    return execute(.cancel, "", "", ctx_ptr[0..ctx_len]) catch |err| failure(err);
}
export fn @"cabi_post_cancel-tool"(_: [*]const u8) void {
    releaseString();
}
export fn @"on-action"(action_ptr: [*]const u8, action_len: usize, payload_ptr: [*]const u8, payload_len: usize, vars_ptr: [*]const u8, vars_len: usize, ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(action_ptr[0..action_len]);
    defer allocator.free(payload_ptr[0..payload_len]);
    defer allocator.free(vars_ptr[0..vars_len]);
    defer allocator.free(ctx_ptr[0..ctx_len]);
    defer std.crypto.utils.secureZero(u8, @constCast(payload_ptr[0..payload_len]));
    return execute(.action, action_ptr[0..action_len], payload_ptr[0..payload_len], ctx_ptr[0..ctx_len]) catch |err| failure(err);
}
export fn @"cabi_post_on-action"(_: [*]const u8) void {
    releaseString();
}
export fn @"on-phase"(phase_ptr: [*]const u8, phase_len: usize, payload_ptr: [*]const u8, payload_len: usize, vars_ptr: [*]const u8, vars_len: usize, ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(phase_ptr[0..phase_len]);
    defer allocator.free(payload_ptr[0..payload_len]);
    defer allocator.free(vars_ptr[0..vars_len]);
    defer allocator.free(ctx_ptr[0..ctx_len]);
    return execute(.phase, phase_ptr[0..phase_len], payload_ptr[0..payload_len], ctx_ptr[0..ctx_len]) catch |err| failure(err);
}
export fn @"cabi_post_on-phase"(_: [*]const u8) void {
    releaseString();
}
var view_buffer: [44]u8 align(4) = undefined;
var owned_view: ?[]const u8 = null;
var owned_patch: ?[]const u8 = null;
fn releaseView() void {
    if (owned_view) |v| allocator.free(v);
    if (owned_patch) |p| allocator.free(p);
    owned_view = null;
    owned_patch = null;
}
fn viewOutput(mode: shared.types.RenderMode, content: []const u8, message: ?[]const u8) [*]const u8 {
    @memset(&view_buffer, 0);
    std.mem.writeInt(u32, view_buffer[0..4], 1, .little);
    std.mem.writeInt(u32, view_buffer[4..8], @intFromEnum(mode), .little);
    std.mem.writeInt(u32, view_buffer[8..12], @intFromPtr(content.ptr), .little);
    std.mem.writeInt(u32, view_buffer[12..16], @intCast(content.len), .little);
    if (message) |m| {
        std.mem.writeInt(u32, view_buffer[32..36], 1, .little);
        std.mem.writeInt(u32, view_buffer[36..40], @intFromPtr(m.ptr), .little);
        std.mem.writeInt(u32, view_buffer[40..44], @intCast(m.len), .little);
    }
    return &view_buffer;
}
fn render(target: u32, context_source: []const u8) ![*]const u8 {
    if (context_source.len > 64 * 1024) return error.LifecycleJsonBudget;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try j.parse(a, context_source);
    const instance = try runtime();
    try instance.updateContext(a, ctx);
    const result = try instance.result(a, null);
    const patch = try j.stringify(allocator, j.get(result, "vars_patch"));
    errdefer allocator.free(patch);
    const envelope = try shared.json.createEnvelope(allocator, if (target == 4) assets.settings_html else assets.sidebar_html, if (target == 4) "{\"$ref\":\"settings\"}" else "{\"$ref\":\"sidebar\"}");
    releaseView();
    owned_patch = patch;
    owned_view = envelope;
    const output = viewOutput(.webview_html, envelope, null);
    std.mem.writeInt(u32, view_buffer[16..20], 1, .little);
    std.mem.writeInt(u32, view_buffer[20..24], @intFromPtr(patch.ptr), .little);
    std.mem.writeInt(u32, view_buffer[24..28], @intCast(patch.len), .little);
    return output;
}
export fn @"render-view"(target: u32, vars_ptr: [*]const u8, vars_len: usize, ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(vars_ptr[0..vars_len]);
    defer allocator.free(ctx_ptr[0..ctx_len]);
    if (target != 0 and target != 4) return viewOutput(.native_json, "null", null);
    return render(target, ctx_ptr[0..ctx_len]) catch |err| viewOutput(.native_json, "null", @errorName(err));
}
export fn @"cabi_post_render-view"(_: [*]const u8) void {
    releaseView();
}
