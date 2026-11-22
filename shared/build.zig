const std = @import("std");

pub const helpers = @import("src/build_helpers.zig");

pub fn build(b: *std.Build) void {
    _ = b.addModule("shared", .{
        .root_source_file = b.path("src/root.zig"),
    });
}
