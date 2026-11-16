const std = @import("std");
/// Arena backing storage used for actions is wiped even when parsing fails before
/// the Authorization field can be identified (including duplicate-key rejection).
pub const WipingAllocator = struct {
    parent: std.mem.Allocator,
    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .free = free } };
    }
    fn alloc(pointer: *anyopaque, length: usize, alignment: u8, ret: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(pointer));
        return self.parent.rawAlloc(length, alignment, ret);
    }
    fn resize(pointer: *anyopaque, bytes: []u8, alignment: u8, length: usize, ret: usize) bool {
        const self: *WipingAllocator = @ptrCast(@alignCast(pointer));
        // Arena shrinking must not expose a secret tail to reuse without wiping.
        // Declining shrink makes the arena release through our wiping free instead.
        if (length < bytes.len) return false;
        return self.parent.rawResize(bytes, alignment, length, ret);
    }
    fn free(pointer: *anyopaque, bytes: []u8, alignment: u8, ret: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(pointer));
        std.crypto.utils.secureZero(u8, bytes);
        self.parent.rawFree(bytes, alignment, ret);
    }
};
test "action arena releases partial decoded credential data through wiping allocator" {
    const Tracking = struct {
        zeroed: bool = false,
        fn alloc(_: *anyopaque, length: usize, alignment: u8, ret: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(length, alignment, ret);
        }
        fn resize(_: *anyopaque, bytes: []u8, alignment: u8, length: usize, ret: usize) bool {
            return std.testing.allocator.rawResize(bytes, alignment, length, ret);
        }
        fn free(pointer: *anyopaque, bytes: []u8, alignment: u8, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.zeroed = for (bytes) |byte| {
                if (byte != 0) break false;
            } else true;
            std.testing.allocator.rawFree(bytes, alignment, ret);
        }
    };
    var tracking: Tracking = .{};
    var wiping = WipingAllocator{ .parent = .{ .ptr = &tracking, .vtable = &.{ .alloc = Tracking.alloc, .resize = Tracking.resize, .free = Tracking.free } } };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    try std.testing.expectError(error.DuplicateField, @import("json_helpers.zig").parse(arena.allocator(), "{\"authorization\":\"transient-secret\",\"x\":1,\"x\":2}"));
    arena.deinit();
    try std.testing.expect(tracking.zeroed);
}
