const std = @import("std");
const shared = @import("shared");
const StateManager = @import("state.zig").StateManager;
const allocator = shared.abi.allocator;
pub const cabi_realloc = shared.abi.cabi_realloc;
const embedded_html = @import("ui_assets").html;

// Canonical ABI enum list elements occupy one byte (five cases). Flattened
// function parameters still use i32. Do not store this list as u32 elements.
const TARGETS = [_]u8{ 0, 1 };
const MANIFEST_ID = "microcrab.state-viewer";
const MANIFEST_NAME = "State Viewer";
const MANIFEST_VERSION = "0.4.0";
const MANIFEST_DESC = "Inspect and manage session state";
var manifest_buf: [56]u8 align(4) = undefined;
export fn manifest() [*]const u8 {
    var stream = std.io.fixedBufferStream(&manifest_buf);
    const w = stream.writer();
    inline for (.{ MANIFEST_ID, MANIFEST_NAME, MANIFEST_VERSION }) |s| {
        w.writeInt(u32, @intFromPtr(s.ptr), .little) catch unreachable;
        w.writeInt(u32, s.len, .little) catch unreachable;
    }
    w.writeInt(u32, 1, .little) catch unreachable;
    w.writeInt(u32, @intFromPtr(MANIFEST_DESC.ptr), .little) catch unreachable;
    w.writeInt(u32, MANIFEST_DESC.len, .little) catch unreachable;
    w.writeInt(u32, @intFromPtr(&TARGETS), .little) catch unreachable;
    w.writeInt(u32, TARGETS.len, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    return &manifest_buf;
}
export fn cabi_post_manifest(_: [*]const u8) void {}
var string_ret_buf: [8]u8 align(4) = undefined;
var owned_string: ?[]const u8 = null;
var owned_view: ?[]const u8 = null;
var owned_view_patch: ?[]const u8 = null;
fn releaseString() void {
    if (owned_string) |bytes| allocator.free(bytes);
    owned_string = null;
}
fn releaseView() void {
    if (owned_view) |bytes| allocator.free(bytes);
    if (owned_view_patch) |bytes| allocator.free(bytes);
    owned_view = null;
    owned_view_patch = null;
}
fn setStringRet(str: []const u8) [*]const u8 {
    std.mem.writeInt(u32, string_ret_buf[0..4], @intFromPtr(str.ptr), .little);
    std.mem.writeInt(u32, string_ret_buf[4..8], @intCast(str.len), .little);
    return &string_ret_buf;
}
fn pluginResult(patch: []const u8) [*]const u8 {
    // The static empty object is an ignored event, so leave prior state intact.
    const result = if (patch.len > 2)
        std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"vars_patch\":{{\"state\":{s}}},\"rerender\":false}}", .{patch}) catch @trap()
    else
        allocator.dupe(u8, "{\"schema_version\":1,\"vars_patch\":{},\"rerender\":false}") catch @trap();
    releaseString();
    owned_string = result;
    return setStringRet(result);
}
fn failure(err: anyerror) [*]const u8 {
    const patch = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch @trap();
    defer allocator.free(patch);
    return pluginResult(patch);
}
export fn init(ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(ctx_ptr[0..ctx_len]);
    StateManager.initFromContext(ctx_ptr[0..ctx_len]) catch |err| return failure(err);
    const state = StateManager.buildViewStateJson(allocator) catch |err| return failure(err);
    defer allocator.free(state);
    return pluginResult(state);
}
export fn cabi_post_init(_: [*]const u8) void {
    releaseString();
}

var view_output_buf: [44]u8 align(4) = undefined;
fn viewOutput(mode: shared.types.RenderMode, content: []const u8, err: ?[]const u8) [*]const u8 {
    @memset(&view_output_buf, 0);
    std.mem.writeInt(u32, view_output_buf[0..4], 1, .little);
    std.mem.writeInt(u32, view_output_buf[4..8], @intFromEnum(mode), .little);
    std.mem.writeInt(u32, view_output_buf[8..12], @intFromPtr(content.ptr), .little);
    std.mem.writeInt(u32, view_output_buf[12..16], @intCast(content.len), .little);
    if (err) |message| {
        std.mem.writeInt(u32, view_output_buf[32..36], 1, .little);
        std.mem.writeInt(u32, view_output_buf[36..40], @intFromPtr(message.ptr), .little);
        std.mem.writeInt(u32, view_output_buf[40..44], @intCast(message.len), .little);
    }
    return &view_output_buf;
}
fn viewFailure(err: anyerror) [*]const u8 {
    return viewOutput(.native_json, "null", @errorName(err));
}
fn informationalView(ctx: []const u8) ![*]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, ctx, .{});
    defer parsed.deinit();
    const locale = if (parsed.value == .object) parsed.value.object.get("locale") else null;
    const english = if (locale) |v| v == .string and std.mem.startsWith(u8, v.string, "en") else false;
    const message = if (english) "Select a conversation to inspect its session state." else "请选择一个会话以查看其状态。";
    const html = try std.fmt.allocPrint(allocator, "<p role=\"status\" style=\"font:14px var(--microcrab-font-sans);line-height:1.6;margin:20px;color:inherit\">{s}</p>", .{message});
    defer allocator.free(html);
    const envelope = try shared.json.createEnvelope(allocator, html, "{}");
    releaseView();
    owned_view = envelope;
    return viewOutput(.webview_html, envelope, null);
}
export fn @"render-view"(target: u32, vars_ptr: [*]const u8, vars_len: usize, ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(vars_ptr[0..vars_len]);
    defer allocator.free(ctx_ptr[0..ctx_len]);
    // Reject undeclared targets before any context or State effects.
    if (target != 0 and target != 1) return viewOutput(.native_json, "null", null);
    const ctx = ctx_ptr[0..ctx_len];
    StateManager.updateContext(ctx) catch |err| return viewFailure(err);
    if (!StateManager.hasSession()) return informationalView(ctx) catch |err| viewFailure(err);
    StateManager.ensureInspection() catch |err| return viewFailure(err);
    const state = StateManager.buildViewStateJson(allocator) catch |err| return viewFailure(err);
    defer allocator.free(state);
    const patch = std.fmt.allocPrint(allocator, "{{\"state\":{s}}}", .{state}) catch |err| return viewFailure(err);
    const envelope = shared.json.createEnvelope(allocator, embedded_html, "{\"$ref\":\"state\"}") catch |err| {
        allocator.free(patch);
        return viewFailure(err);
    };
    releaseView();
    owned_view = envelope;
    owned_view_patch = patch;
    const output = viewOutput(.webview_html, envelope, null);
    std.mem.writeInt(u32, view_output_buf[16..20], 1, .little);
    std.mem.writeInt(u32, view_output_buf[20..24], @intFromPtr(patch.ptr), .little);
    std.mem.writeInt(u32, view_output_buf[24..28], @intCast(patch.len), .little);
    return output;
}
export fn @"cabi_post_render-view"(_: [*]const u8) void {
    releaseView();
}
fn allowsActions(ctx: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, ctx, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidContext;
    const surface = parsed.value.object.get("surface") orelse return false;
    if (surface != .object) return false;
    const target = surface.object.get("target") orelse return false;
    return target == .string and (std.mem.eql(u8, target.string, "sidebar") or std.mem.eql(u8, target.string, "expanded-page"));
}
export fn @"on-action"(action_ptr: [*]const u8, action_len: usize, payload_ptr: [*]const u8, payload_len: usize, vars_ptr: [*]const u8, vars_len: usize, ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(action_ptr[0..action_len]);
    defer allocator.free(payload_ptr[0..payload_len]);
    defer allocator.free(vars_ptr[0..vars_len]);
    defer allocator.free(ctx_ptr[0..ctx_len]);
    const ctx = ctx_ptr[0..ctx_len];
    StateManager.updateContext(ctx) catch |err| return failure(err);
    const allowed = allowsActions(ctx) catch |err| return failure(err);
    if (!allowed or !StateManager.hasSession()) return pluginResult("{}");
    const patch = StateManager.handleAction(action_ptr[0..action_len], payload_ptr[0..payload_len]) catch |err| return failure(err);
    // StateManager returns the static empty object for ignored events; all
    // nonempty projections are owned allocations copied by pluginResult.
    defer if (patch.len > 2) allocator.free(patch);
    return pluginResult(patch);
}
export fn @"cabi_post_on-action"(_: [*]const u8) void {
    releaseString();
}
export fn @"on-phase"(phase_ptr: [*]const u8, phase_len: usize, payload_ptr: [*]const u8, payload_len: usize, vars_ptr: [*]const u8, vars_len: usize, ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    defer allocator.free(phase_ptr[0..phase_len]);
    defer allocator.free(payload_ptr[0..payload_len]);
    defer allocator.free(vars_ptr[0..vars_len]);
    defer allocator.free(ctx_ptr[0..ctx_len]);
    StateManager.updateContext(ctx_ptr[0..ctx_len]) catch |err| return failure(err);
    if (!StateManager.hasSession()) return pluginResult("{}");
    const patch = StateManager.handlePhase(phase_ptr[0..phase_len], payload_ptr[0..payload_len]) catch |err| return failure(err);
    // StateManager returns the static empty object for ignored events; all
    // nonempty projections are owned allocations copied by pluginResult.
    defer if (patch.len > 2) allocator.free(patch);
    return pluginResult(patch);
}
export fn @"cabi_post_on-phase"(_: [*]const u8) void {
    releaseString();
}
