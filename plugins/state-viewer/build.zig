//! Root-only plugin registration; invoke `zig build state-viewer` at the repository root.
const std = @import("std");
const helpers = @import("../../shared/src/build_helpers.zig");

pub fn register(b: *std.Build, ctx: helpers.Context) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, ctx, .{
        .slug = "state-viewer",
        .stem = "state_viewer",
        .id = "microcrab.state-viewer",
        .world = "state-viewer",
        .root_source = "plugins/state-viewer/src/main.zig",
        .test_source = "plugins/state-viewer/src/state.zig",
        .surfaces = &.{.{ .field = "html", .directory = "plugins/state-viewer/ui" }},
    });
}
