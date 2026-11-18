const std = @import("std");
const shared = @import("shared");
pub const net = shared.host.net;
pub const resources = shared.host.resources;
pub const storage = struct {
    extern "microcrab:client-plugin/storage@0.4.0" fn get(p: [*]const u8, n: usize, r: [*]u8) void;
    extern "microcrab:client-plugin/storage@0.4.0" fn set(p: [*]const u8, n: usize, v: [*]const u8, l: usize, r: [*]u8) void;
    pub fn read(key: []const u8) ?[]const u8 {
        var r: [12]u8 = undefined;
        get(key.ptr, key.len, &r);
        if (r[0] == 0) return null;
        const p: [*]const u8 = @ptrFromInt(std.mem.readInt(u32, r[4..8], .little));
        return p[0..std.mem.readInt(u32, r[8..12], .little)];
    }
    pub fn write(key: []const u8, value: []const u8) shared.host.ResultU32 {
        var r: [12]u8 = undefined;
        set(key.ptr, key.len, value.ptr, value.len, &r);
        if (r[0] == 0) return .{ .ok = std.mem.readInt(u32, r[4..8], .little) };
        const p: [*]const u8 = @ptrFromInt(std.mem.readInt(u32, r[4..8], .little));
        return .{ .err = p[0..std.mem.readInt(u32, r[8..12], .little)] };
    }
};
pub const conversation = struct {
    extern "microcrab:client-plugin/conversation@0.4.0" fn request(p: [*]const u8, n: usize, v: [*]const u8, l: usize, r: [*]u8) void;
    pub fn send(kind: []const u8, value: []const u8) shared.host.ResultU32 {
        var r: [12]u8 = undefined;
        request(kind.ptr, kind.len, value.ptr, value.len, &r);
        if (r[0] == 0) return .{ .ok = std.mem.readInt(u32, r[4..8], .little) };
        const p: [*]const u8 = @ptrFromInt(std.mem.readInt(u32, r[4..8], .little));
        return .{ .err = p[0..std.mem.readInt(u32, r[8..12], .little)] };
    }
};
