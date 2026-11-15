const std = @import("std");

pub const allocator = std.heap.wasm_allocator;

export fn cabi_realloc(
    old_ptr: ?*anyopaque,
    old_size: usize,
    alignment: usize,
    new_size: usize,
) callconv(.C) ?*anyopaque {
    if (new_size == 0) {
        return @ptrFromInt(if (alignment == 0) 1 else alignment);
    }
    const align_val = if (alignment == 0) 1 else alignment;
    const ptr_align_u8: u8 = @intCast(std.math.log2(align_val));

    const new_mem = allocator.rawAlloc(new_size, ptr_align_u8, @returnAddress()) orelse return null;

    if (old_ptr) |ptr| {
        const copy_len = if (old_size < new_size) old_size else new_size;
        @memcpy(new_mem[0..copy_len], @as([*]const u8, @ptrCast(ptr))[0..copy_len]);
        allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..old_size], ptr_align_u8, @returnAddress());
    }

    return new_mem;
}

pub fn allocateBytes(bytes: []const u8) ![*]const u8 {
    const mem = try allocator.alloc(u8, bytes.len);
    @memcpy(mem, bytes);
    return mem.ptr;
}

pub fn allocateString(str: []const u8) ![*]const u8 {
    return allocateBytes(str);
}
