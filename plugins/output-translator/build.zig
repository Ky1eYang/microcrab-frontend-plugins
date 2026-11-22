const std = @import("std");
const helpers = @import("shared").helpers;

pub fn build(b: *std.Build) void {
    helpers.buildStandalone(b, @This());
}

pub fn register(b: *std.Build, ctx: helpers.Context, package: std.Build.LazyPath) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, ctx, package, .{
        .slug = "output-translator",
        .stem = "output_translator",
        .id = "microcrab.output-translator",
        .world = "output-translator",
        .root_source = "src/main.zig",
        .test_source = "src/tests.zig",
        .surfaces = &.{
            .{ .field = "settings_html", .directory = "ui/settings" },
            .{ .field = "sidebar_html", .directory = "ui/sidebar" },
            .{ .field = "block_html", .directory = "ui/block" },
        },
    });
}
