const std = @import("std");
const shared = @import("shared");
const StateManager = @import("state.zig").StateManager;
const allocator = shared.abi.allocator;

// Re-export cabi_realloc for Wasm Component Model
pub const cabi_realloc = shared.abi.cabi_realloc;

const embedded_html = @embedFile("bundle.html");

const TARGETS = [_]u32{
    @intFromEnum(shared.types.ViewTarget.sidebar),
    @intFromEnum(shared.types.ViewTarget.expanded_page),
};

const MANIFEST_ID = "microcrab.state-viewer";
const MANIFEST_NAME = "State Viewer";
const MANIFEST_VERSION = "0.1.0";
const MANIFEST_DESC = "Inspect and manage session state with modern UI";

// 56-byte static buffer for manifest return
var manifest_buf: [56]u8 = undefined;

export fn manifest() [*]const u8 {
    var stream = std.io.fixedBufferStream(&manifest_buf);
    const writer = stream.writer();

    // 0: id (ptr, len)
    writer.writeInt(u32, @intFromPtr(MANIFEST_ID.ptr), .little) catch unreachable;
    writer.writeInt(u32, MANIFEST_ID.len, .little) catch unreachable;

    // 8: name (ptr, len)
    writer.writeInt(u32, @intFromPtr(MANIFEST_NAME.ptr), .little) catch unreachable;
    writer.writeInt(u32, MANIFEST_NAME.len, .little) catch unreachable;

    // 16: version (ptr, len)
    writer.writeInt(u32, @intFromPtr(MANIFEST_VERSION.ptr), .little) catch unreachable;
    writer.writeInt(u32, MANIFEST_VERSION.len, .little) catch unreachable;

    // 24: description (tag, ptr, len)
    writer.writeInt(u32, 1, .little) catch unreachable; // Some
    writer.writeInt(u32, @intFromPtr(MANIFEST_DESC.ptr), .little) catch unreachable;
    writer.writeInt(u32, MANIFEST_DESC.len, .little) catch unreachable;

    // 36: targets (ptr, len)
    writer.writeInt(u32, @intFromPtr(&TARGETS), .little) catch unreachable;
    writer.writeInt(u32, TARGETS.len, .little) catch unreachable;

    // 44: network_origins (tag, ptr, len)
    writer.writeInt(u32, 0, .little) catch unreachable; // None
    writer.writeInt(u32, 0, .little) catch unreachable;
    writer.writeInt(u32, 0, .little) catch unreachable;

    return &manifest_buf;
}

export fn cabi_post_manifest(_: [*]const u8) void {}

// 8-byte static buffer for string returns (ptr, len)
var string_ret_buf: [8]u8 = undefined;

fn setStringRet(str: []const u8) [*]const u8 {
    var stream = std.io.fixedBufferStream(&string_ret_buf);
    const writer = stream.writer();
    writer.writeInt(u32, @intFromPtr(str.ptr), .little) catch unreachable;
    writer.writeInt(u32, str.len, .little) catch unreachable;
    return &string_ret_buf;
}

export fn init(ctx_ptr: [*]const u8, ctx_len: usize) [*]const u8 {
    const ctx = ctx_ptr[0..ctx_len];
    StateManager.initFromContext(ctx) catch {};
    const init_json = "{\"loading\":true}";
    return setStringRet(init_json);
}

export fn cabi_post_init(_: [*]const u8) void {}

// 44-byte buffer for view-output return
var view_output_buf: [44]u8 = undefined;

export fn @"render-view"(
    target: u32,
    vars_ptr: [*]const u8,
    vars_len: usize,
    ctx_ptr: [*]const u8,
    ctx_len: usize,
) [*]const u8 {
    _ = target;
    _ = vars_ptr;
    _ = vars_len;
    _ = ctx_ptr;
    _ = ctx_len;

    const view_state_json = StateManager.buildViewStateJson(allocator) catch "{}";
    const envelope = shared.json.createEnvelope(allocator, embedded_html, view_state_json) catch "{}";

    var stream = std.io.fixedBufferStream(&view_output_buf);
    const writer = stream.writer();

    // 0: schema_version = 1
    writer.writeInt(u32, 1, .little) catch unreachable;
    // 4: mode = 1 (webview_html)
    writer.writeInt(u32, @intFromEnum(shared.types.RenderMode.webview_html), .little) catch unreachable;
    // 8: content (ptr, len)
    writer.writeInt(u32, @intFromPtr(envelope.ptr), .little) catch unreachable;
    writer.writeInt(u32, envelope.len, .little) catch unreachable;
    // 16: vars_patch (tag=0, ptr=0, len=0)
    writer.writeInt(u32, 0, .little) catch unreachable;
    writer.writeInt(u32, 0, .little) catch unreachable;
    writer.writeInt(u32, 0, .little) catch unreachable;
    // 28: rerender = 0
    writer.writeInt(u32, 0, .little) catch unreachable;
    // 32: error (tag=0, ptr=0, len=0)
    writer.writeInt(u32, 0, .little) catch unreachable;
    writer.writeInt(u32, 0, .little) catch unreachable;
    writer.writeInt(u32, 0, .little) catch unreachable;

    return &view_output_buf;
}

export fn @"cabi_post_render-view"(_: [*]const u8) void {}

export fn @"on-action"(
    action_ptr: [*]const u8,
    action_len: usize,
    payload_ptr: [*]const u8,
    payload_len: usize,
    vars_ptr: [*]const u8,
    vars_len: usize,
    ctx_ptr: [*]const u8,
    ctx_len: usize,
) [*]const u8 {
    _ = vars_ptr;
    _ = vars_len;
    _ = ctx_ptr;
    _ = ctx_len;

    const action = action_ptr[0..action_len];
    const payload = payload_ptr[0..payload_len];

    const patch = StateManager.handleAction(action, payload) catch "{}";
    return setStringRet(patch);
}

export fn @"cabi_post_on-action"(_: [*]const u8) void {}

export fn @"on-phase"(
    phase_ptr: [*]const u8,
    phase_len: usize,
    payload_ptr: [*]const u8,
    payload_len: usize,
    vars_ptr: [*]const u8,
    vars_len: usize,
    ctx_ptr: [*]const u8,
    ctx_len: usize,
) [*]const u8 {
    _ = vars_ptr;
    _ = vars_len;
    _ = ctx_ptr;
    _ = ctx_len;

    const phase = phase_ptr[0..phase_len];
    const payload = payload_ptr[0..payload_len];

    const patch = StateManager.handlePhase(phase, payload) catch "{}";
    return setStringRet(patch);
}

export fn @"cabi_post_on-phase"(_: [*]const u8) void {}
