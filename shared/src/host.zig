const std = @import("std");

pub const ResultU32 = union(enum) {
    ok: u32,
    err: []const u8,
};

pub const net = struct {
    extern "microcrab:client-plugin/net@0.4.0" fn request(kind_ptr: [*]const u8, kind_len: usize, payload_ptr: [*]const u8, payload_len: usize, ret_ptr: [*]u8) void;
    pub fn send(kind: []const u8, payload: []const u8) ResultU32 {
        var result: [12]u8 = undefined;
        request(kind.ptr, kind.len, payload.ptr, payload.len, &result);
        return decodeRequestResult(&result);
    }
};

pub const resources = struct {
    extern "microcrab:client-plugin/resources@0.4.0" fn request(kind_ptr: [*]const u8, kind_len: usize, payload_ptr: [*]const u8, payload_len: usize, ret_ptr: [*]u8) void;
    pub fn send(kind: []const u8, payload: []const u8) ResultU32 {
        var result: [12]u8 = undefined;
        request(kind.ptr, kind.len, payload.ptr, payload.len, &result);
        return decodeRequestResult(&result);
    }
};

fn decodeRequestResult(result: *const [12]u8) ResultU32 {
    if (result[0] == 0) return .{ .ok = std.mem.readInt(u32, result[4..8], .little) };
    const pointer = @as([*]const u8, @ptrFromInt(std.mem.readInt(u32, result[4..8], .little)));
    const length = std.mem.readInt(u32, result[8..12], .little);
    return .{ .err = pointer[0..length] };
}

pub const session_state = struct {
    extern "microcrab:client-plugin/session-state@0.4.0" fn request(
        kind_ptr: [*]const u8,
        kind_len: usize,
        payload_ptr: [*]const u8,
        payload_len: usize,
        ret_ptr: [*]u8,
    ) void;

    pub fn send(kind: []const u8, payload: []const u8) ResultU32 {
        var ret_buf: [12]u8 = undefined;
        request(kind.ptr, kind.len, payload.ptr, payload.len, &ret_buf);
        return decodeRequestResult(&ret_buf);
    }
};

pub const session_state_write = struct {
    extern "microcrab:client-plugin/session-state-write@0.4.0" fn request(
        kind_ptr: [*]const u8,
        kind_len: usize,
        payload_ptr: [*]const u8,
        payload_len: usize,
        ret_ptr: [*]u8,
    ) void;

    pub fn send(kind: []const u8, payload: []const u8) ResultU32 {
        var ret_buf: [12]u8 = undefined;
        request(kind.ptr, kind.len, payload.ptr, payload.len, &ret_buf);
        return decodeRequestResult(&ret_buf);
    }
};
