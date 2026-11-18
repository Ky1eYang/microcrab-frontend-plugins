const std = @import("std");
/// Every guest allocation, including Canonical ABI inputs and operation arenas,
/// shares this cap. Allocation failures are surfaced; text is never shortened.
pub const limit = 2 * 1024 * 1024;
pub const Budget = struct {
    parent: std.mem.Allocator,
    used: usize = 0,
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .free = free };
    fn alloc(ctx: *anyopaque, len: usize, alignment: u8, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (len > limit - self.used) return null;
        const p = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.used += len;
        return p;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: u8, len: usize, ret: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (len > buf.len and len - buf.len > limit - self.used) return false;
        if (!self.parent.rawResize(buf, alignment, len, ret)) return false;
        self.used = self.used - buf.len + len;
        return true;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: u8, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        std.crypto.utils.secureZero(u8, buf);
        self.parent.rawFree(buf, alignment, ret);
        self.used -= buf.len;
    }
};
test "aggregate allocation cap and release" {
    var b = Budget{ .parent = std.testing.allocator };
    const a = b.allocator();
    const p = try a.alloc(u8, limit);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    a.free(p);
    try std.testing.expectEqual(@as(usize, 0), b.used);
}
