const std = @import("std");

/// Canonical ABI inputs, parsing arenas and output buffers share one live cap.
/// Do not grow or shrink in place: allocator fallback frees and wipes old buffers.
pub const Budget = struct {
    const limit = 16 * 1024 * 1024;
    parent: std.mem.Allocator,
    used: usize = 0,

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: u8, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.used <= limit);
        if (len > limit - self.used) return null;
        const ptr = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.used += len;
        return ptr;
    }

    fn resize(_: *anyopaque, buf: []u8, _: u8, len: usize, _: usize) bool {
        return buf.len == len;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: u8, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        std.debug.assert(buf.len <= self.used);
        std.crypto.utils.secureZero(u8, buf);
        self.parent.rawFree(buf, alignment, ret);
        self.used -= buf.len;
    }
};
