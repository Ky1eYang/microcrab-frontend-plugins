//! One-shot, exact-mount preview handoff from on-action to render-view.
const std = @import("std");
const scanner = @import("scanner.zig");

pub const action_name = "scan-preview";
pub const max_payload_bytes = scanner.max_input_bytes * 6 + 128;
pub const max_context_bytes = 16 * 1024;
pub const ttl_ms = 3000;
pub const nonce_bytes = 32;

pub const Target = enum(u8) {
    sidebar = 0,
    expanded_page = 1,

    pub fn parse(value: []const u8) ?Target {
        if (std.mem.eql(u8, value, "sidebar")) return .sidebar;
        if (std.mem.eql(u8, value, "expanded-page")) return .expanded_page;
        return null;
    }
};

pub const Context = struct {
    schema_version: u8,
    session_id: ?[]const u8,
    instance_generation: u64,
    history_generation: u64,
    surface_generation: u64,
    target_visible: bool,
    surface: struct { target: []const u8, surface_id: []const u8 },
    user_action: bool = false,
    host_monotonic_ms: f64,

    pub fn scope(self: Context) ?Scope {
        const target = Target.parse(self.surface.target) orelse return null;
        if (self.schema_version != 1 or !self.target_visible or !std.math.isFinite(self.host_monotonic_ms) or self.host_monotonic_ms < 0) return null;
        if (self.surface.surface_id.len == 0 or self.surface.surface_id.len > 2048) return null;
        var hash: [32]u8 = undefined;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(self.surface.surface_id);
        // Length-prefix strings so no pair of identifiers can alias another pair.
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(self.surface.surface_id.len), .little);
        h.update(&length);
        if (self.session_id) |session| {
            h.update(session);
            h.update(&.{1});
        } else h.update(&.{0});
        h.final(&hash);
        return .{
            .ids = hash,
            .instance_generation = self.instance_generation,
            .history_generation = self.history_generation,
            .surface_generation = self.surface_generation,
            .target = target,
        };
    }
};

pub const Scope = struct {
    ids: [32]u8,
    instance_generation: u64,
    history_generation: u64,
    surface_generation: u64,
    target: Target,
};

pub const Request = struct {
    id: []const u8,
    text: []const u8,
};

const PreviewStatus = enum { ready, no_matches, rejected };

pub const Projection = struct {
    id: []const u8,
    status: PreviewStatus,
    count: usize = 0,
    text: ?[]const u8 = null,
};

pub const Pending = struct {
    const Entry = struct { scope: Scope, created_ms: f64, id: [nonce_bytes]u8, status: PreviewStatus, count: usize, len: usize };
    entry: ?Entry = null,
    buffer: [scanner.max_output_bytes]u8 = undefined,

    pub fn clear(self: *Pending) void {
        std.crypto.utils.secureZero(u8, &self.buffer);
        self.entry = null;
    }

    pub fn expire(self: *Pending, now: f64) void {
        const entry = self.entry orelse return;
        if (now < entry.created_ms or now - entry.created_ms >= ttl_ms) self.clear();
    }

    pub fn prepare(self: *Pending, ctx: Context, request: Request) bool {
        if (!ctx.user_action) return false;
        const scope = ctx.scope() orelse return false;
        if (request.id.len != nonce_bytes) return false;
        for (request.id) |byte| {
            if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
        }
        self.clear();
        self.entry = .{ .scope = scope, .created_ms = ctx.host_monotonic_ms, .id = request.id[0..nonce_bytes].*, .status = .rejected, .count = 0, .len = 0 };
        const result = scanner.scan(request.text, &self.buffer) catch {
            std.crypto.utils.secureZero(u8, &self.buffer);
            return true;
        };
        if (result.count == 0) {
            // Avoid returning the original unchanged when nothing was found.
            std.crypto.utils.secureZero(u8, &self.buffer);
            self.entry.?.status = .no_matches;
        } else {
            self.entry.?.status = .ready;
            self.entry.?.count = result.count;
            self.entry.?.len = result.text.len;
        }
        return true;
    }

    /// Borrows one matching projection; caller clears it after encoding.
    pub fn get(self: *Pending, ctx: Context, target: Target) ?Projection {
        if (std.math.isFinite(ctx.host_monotonic_ms)) self.expire(ctx.host_monotonic_ms);
        const scope = ctx.scope() orelse return null;
        if (self.entry) |*entry| {
            if (scope.target != target or !std.meta.eql(scope, entry.scope)) return null;
            return .{
                .id = &entry.id,
                .status = entry.status,
                .count = entry.count,
                .text = if (entry.status == .ready) self.buffer[0..entry.len] else null,
            };
        }
        return null;
    }
};
