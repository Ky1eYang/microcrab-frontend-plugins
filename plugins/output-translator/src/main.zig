const std = @import("std");
const shared = @import("shared");
const j = @import("json.zig");
const Engine = @import("runtime.zig").Runtime(@import("host.zig"));
const assets = @import("ui_assets");
var quota = @import("budget.zig").Budget{ .parent = std.heap.wasm_allocator };
const allocator = quota.allocator();
export fn cabi_realloc(old: ?*anyopaque, size: usize, alignment: usize, new_size: usize) callconv(.C) ?*anyopaque {
    const log: u8 = @intCast(std.math.log2(@max(1, alignment)));
    if (new_size == 0) {
        if (old) |p| {
            if (size > 0) allocator.rawFree(@as([*]u8, @ptrCast(p))[0..size], log, @returnAddress());
        }
        return @ptrFromInt(@max(1, alignment));
    }
    const p = allocator.rawAlloc(new_size, log, @returnAddress()) orelse return null;
    if (old) |v| {
        if (size > 0) {
            @memcpy(p[0..@min(size, new_size)], @as([*]u8, @ptrCast(v))[0..@min(size, new_size)]);
            allocator.rawFree(@as([*]u8, @ptrCast(v))[0..size], log, @returnAddress());
        }
    }
    return p;
}
var engine: ?Engine = null;
fn runtime() !*Engine {
    if (engine == null) engine = try Engine.init(allocator);
    return &engine.?;
}
const targets = [_]u8{ 0, 3, 4 };
const origins = [_]extern struct { ptr: [*]const u8, len: usize }{ .{ .ptr = "https://translate.googleapis.com".ptr, .len = "https://translate.googleapis.com".len }, .{ .ptr = "https://api.mymemory.translated.net".ptr, .len = "https://api.mymemory.translated.net".len } };
var manifest_buffer: [56]u8 align(4) = undefined;
export fn manifest() [*]const u8 {
    var stream = std.io.fixedBufferStream(&manifest_buffer);
    const w = stream.writer();
    inline for (.{ "microcrab.output-translator", "Output Translator", "0.4.0" }) |s| {
        w.writeInt(u32, @intFromPtr(s.ptr), .little) catch unreachable;
        w.writeInt(u32, s.len, .little) catch unreachable;
    }
    const desc = "Translate settled assistant text with host-owned endpoint credentials";
    w.writeInt(u32, 1, .little) catch unreachable;
    w.writeInt(u32, @intFromPtr(desc.ptr), .little) catch unreachable;
    w.writeInt(u32, desc.len, .little) catch unreachable;
    w.writeInt(u32, @intFromPtr(&targets), .little) catch unreachable;
    w.writeInt(u32, targets.len, .little) catch unreachable;
    w.writeInt(u32, 1, .little) catch unreachable;
    w.writeInt(u32, @intFromPtr(&origins), .little) catch unreachable;
    w.writeInt(u32, origins.len, .little) catch unreachable;
    return &manifest_buffer;
}
export fn cabi_post_manifest(_: [*]const u8) void {}
var string_buffer: [8]u8 align(4) = undefined;
var owned_string: ?[]const u8 = null;
fn releaseString() void {
    if (owned_string) |s| allocator.free(s);
    owned_string = null;
}
fn stringResult(s: []const u8) [*]const u8 {
    releaseString();
    owned_string = s;
    std.mem.writeInt(u32, string_buffer[0..4], @intFromPtr(s.ptr), .little);
    std.mem.writeInt(u32, string_buffer[4..8], @intCast(s.len), .little);
    return &string_buffer;
}
fn failure(err: anyerror) [*]const u8 {
    return stringResult(std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"error\":\"{s}\"}}", .{@errorName(err)}) catch @trap());
}
fn execute(kind: enum { init, action, phase }, name: []const u8, payload: []const u8, ctx_source: []const u8) ![*]const u8 {
    // This plugin decorates settled history; submitting input does not advance
    // translation work or republish cached block decorations.
    if (kind == .phase and std.mem.eql(u8, name, "before-submit"))
        return stringResult(try allocator.dupe(u8, "{\"schema_version\":1}"));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try j.parse(a, ctx_source);
    const value = if (payload.len > 0) try j.parse(a, payload) else .null;
    defer if (kind == .action) {
        if (j.text(j.get(value, "authorization"))) |secret| std.crypto.utils.secureZero(u8, @constCast(secret));
    };
    const e = try runtime();
    switch (kind) {
        .init => try e.initialize(a, ctx),
        .action => e.action(a, name, value, ctx) catch |err| {
            e.status = @errorName(err);
            if (std.mem.eql(u8, name, "settings.save")) {
                if (j.text(j.get(value, "operation_id"))) |operation| try e.rejectSave(operation);
            }
        },
        .phase => try e.phase(a, name, value, ctx),
    }
    const output = try j.stringify(allocator, try e.result(a, ctx, assets.block_html, true));
    e.published();
    return stringResult(output);
}
export fn init(p: [*]const u8, n: usize) [*]const u8 {
    defer allocator.free(p[0..n]);
    return execute(.init, "", "", p[0..n]) catch |err| failure(err);
}
export fn cabi_post_init(_: [*]const u8) void {
    releaseString();
}
export fn @"on-action"(np: [*]const u8, n: usize, pp: [*]const u8, p: usize, vp: [*]const u8, v: usize, cp: [*]const u8, c: usize) [*]const u8 {
    defer allocator.free(np[0..n]);
    defer allocator.free(pp[0..p]);
    defer allocator.free(vp[0..v]);
    defer allocator.free(cp[0..c]);
    defer std.crypto.utils.secureZero(u8, @constCast(pp[0..p]));
    return execute(.action, np[0..n], pp[0..p], cp[0..c]) catch |err| failure(err);
}
export fn @"cabi_post_on-action"(_: [*]const u8) void {
    releaseString();
}
export fn @"on-phase"(np: [*]const u8, n: usize, pp: [*]const u8, p: usize, vp: [*]const u8, v: usize, cp: [*]const u8, c: usize) [*]const u8 {
    defer allocator.free(np[0..n]);
    defer allocator.free(pp[0..p]);
    defer allocator.free(vp[0..v]);
    defer allocator.free(cp[0..c]);
    return execute(.phase, np[0..n], pp[0..p], cp[0..c]) catch |err| failure(err);
}
export fn @"cabi_post_on-phase"(_: [*]const u8) void {
    releaseString();
}
var view_buffer: [44]u8 align(4) = undefined;
var owned_view: ?[]const u8 = null;
var owned_patch: ?[]const u8 = null;
fn releaseView() void {
    if (owned_view) |s| allocator.free(s);
    if (owned_patch) |s| allocator.free(s);
    owned_view = null;
    owned_patch = null;
}
fn view(mode: u32, s: []const u8, err: ?[]const u8) [*]const u8 {
    @memset(&view_buffer, 0);
    std.mem.writeInt(u32, view_buffer[0..4], 1, .little);
    std.mem.writeInt(u32, view_buffer[4..8], mode, .little);
    std.mem.writeInt(u32, view_buffer[8..12], @intFromPtr(s.ptr), .little);
    std.mem.writeInt(u32, view_buffer[12..16], @intCast(s.len), .little);
    if (err) |e| {
        std.mem.writeInt(u32, view_buffer[32..36], 1, .little);
        std.mem.writeInt(u32, view_buffer[36..40], @intFromPtr(e.ptr), .little);
        std.mem.writeInt(u32, view_buffer[40..44], @intCast(e.len), .little);
    }
    return &view_buffer;
}
fn render(target: u32, source: []const u8) ![*]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try j.parse(a, source);
    const e = try runtime();
    try e.context(ctx);
    const result = try e.result(a, ctx, assets.block_html, false);
    var ref: []const u8 = if (target == 4) "{\"$ref\":\"settings\"}" else "{\"$ref\":\"sidebar\"}";
    if (target == 3) {
        const id = j.text(j.get(j.get(ctx, "surface"), "block_id")) orelse return view(0, "null", null);
        var found = false;
        for (e.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, id) and std.mem.eql(u8, entry.role, "user")) {
                ref = try std.fmt.allocPrint(a, "{{\"$ref\":\"user_blocks.{d}\"}}", .{i});
                found = true;
                break;
            }
        }
        if (!found) return view(0, "null", null);
    }
    const patch = try j.stringify(allocator, j.get(result, "vars_patch"));
    errdefer allocator.free(patch);
    const envelope = try shared.json.createEnvelope(allocator, if (target == 4) assets.settings_html else if (target == 3) assets.block_html else assets.sidebar_html, ref);
    releaseView();
    owned_patch = patch;
    owned_view = envelope;
    const out = view(1, envelope, null);
    std.mem.writeInt(u32, view_buffer[16..20], 1, .little);
    std.mem.writeInt(u32, view_buffer[20..24], @intFromPtr(patch.ptr), .little);
    std.mem.writeInt(u32, view_buffer[24..28], @intCast(patch.len), .little);
    return out;
}
export fn @"render-view"(target: u32, vp: [*]const u8, v: usize, cp: [*]const u8, c: usize) [*]const u8 {
    defer allocator.free(vp[0..v]);
    defer allocator.free(cp[0..c]);
    if (target != 0 and target != 3 and target != 4) return view(0, "null", null);
    return render(target, cp[0..c]) catch |err| view(0, "null", @errorName(err));
}
export fn @"cabi_post_render-view"(_: [*]const u8) void {
    releaseView();
}
