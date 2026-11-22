const std = @import("std");
const helpers = @import("shared").helpers;

pub fn build(b: *std.Build) void {
    helpers.buildStandalone(b, @This());
}

pub fn register(b: *std.Build, ctx: helpers.Context, package: std.Build.LazyPath) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, ctx, package, .{
        .slug = "prompt-redactor",
        .stem = "prompt_redactor",
        .id = "microcrab.prompt-redactor",
        .world = "fixture",
        .root_source = "src/main.zig",
        .test_source = "src/tests.zig",
        .surfaces = &.{.{ .field = "html", .directory = "ui" }},
        .default_enabled = false,
    });
}
