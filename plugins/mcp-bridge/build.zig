//! Root-only plugin registration; invoke `zig build mcp-bridge` at the repository root.
const std = @import("std");
const helpers = @import("../../shared/src/build_helpers.zig");

pub fn register(b: *std.Build, ctx: helpers.Context) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, ctx, .{
        .slug = "mcp-bridge",
        .stem = "mcp_bridge",
        .id = "microcrab.mcp-bridge",
        .world = "tool-plugin",
        .root_source = "plugins/mcp-bridge/src/main.zig",
        .test_source = "plugins/mcp-bridge/src/tests.zig",
        .surfaces = &.{
            .{ .field = "settings_html", .directory = "plugins/mcp-bridge/ui/settings" },
            .{ .field = "sidebar_html", .directory = "plugins/mcp-bridge/ui/sidebar" },
        },
    });
}
