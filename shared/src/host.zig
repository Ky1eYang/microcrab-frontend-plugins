const std = @import("std");

pub const ResultU32 = union(enum) {
    ok: u32,
    err: []const u8,
};

pub const session_state = struct {
    extern "microcrab:client-plugin/session-state@0.3.0" fn request(
        kind_ptr: [*]const u8,
        kind_len: usize,
        payload_ptr: [*]const u8,
        payload_len: usize,
        ret_ptr: [*]u8,
    ) void;

    pub fn send(kind: []const u8, payload: []const u8) ResultU32 {
        var ret_buf: [12]u8 = undefined;
        request(kind.ptr, kind.len, payload.ptr, payload.len, &ret_buf);
        const tag = std.mem.readInt(u32, ret_buf[0..4], .little);
        if (tag == 0) {
            const val = std.mem.readInt(u32, ret_buf[4..8], .little);
            return .{ .ok = val };
        } else {
            const err_ptr = @as([*]const u8, @ptrFromInt(std.mem.readInt(u32, ret_buf[4..8], .little)));
            const err_len = std.mem.readInt(u32, ret_buf[8..12], .little);
            return .{ .err = err_ptr[0..err_len] };
        }
    }
};

pub const session_state_write = struct {
    extern "microcrab:client-plugin/session-state-write@0.3.0" fn request(
        kind_ptr: [*]const u8,
        kind_len: usize,
        payload_ptr: [*]const u8,
        payload_len: usize,
        ret_ptr: [*]u8,
    ) void;

    pub fn send(kind: []const u8, payload: []const u8) ResultU32 {
        var ret_buf: [12]u8 = undefined;
        request(kind.ptr, kind.len, payload.ptr, payload.len, &ret_buf);
        const tag = std.mem.readInt(u32, ret_buf[0..4], .little);
        if (tag == 0) {
            const val = std.mem.readInt(u32, ret_buf[4..8], .little);
            return .{ .ok = val };
        } else {
            const err_ptr = @as([*]const u8, @ptrFromInt(std.mem.readInt(u32, ret_buf[4..8], .little)));
            const err_len = std.mem.readInt(u32, ret_buf[8..12], .little);
            return .{ .err = err_ptr[0..err_len] };
        }
    }
};
