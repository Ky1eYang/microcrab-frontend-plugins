const std = @import("std");
const helpers = @import("shared").helpers;

pub fn build(b: *std.Build) void {
    helpers.buildStandalone(b, @This());
}

pub fn register(b: *std.Build, ctx: helpers.Context, package: std.Build.LazyPath) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, ctx, package, .{
        .slug = "mcp-bridge",
        .stem = "mcp_bridge",
        .id = "microcrab.mcp-bridge",
        .world = "tool-plugin",
        .root_source = "src/main.zig",
        .test_source = "src/tests.zig",
        .surfaces = &.{
            .{ .field = "settings_html", .directory = "ui/settings" },
            .{ .field = "sidebar_html", .directory = "ui/sidebar" },
        },
    });
}
