const std = @import("std");
const helpers = @import("shared").helpers;

pub fn build(b: *std.Build) void {
    helpers.buildStandalone(b, @This());
}

pub fn register(b: *std.Build, ctx: helpers.Context, package: std.Build.LazyPath) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, ctx, package, .{
        .slug = "state-viewer",
        .stem = "state_viewer",
        .id = "microcrab.state-viewer",
        .world = "state-viewer",
        .root_source = "src/main.zig",
        .test_source = "src/state.zig",
        .surfaces = &.{.{ .field = "html", .directory = "ui" }},
    });
}
