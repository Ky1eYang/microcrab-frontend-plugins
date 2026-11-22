const std = @import("std");
const helpers = @import("shared").helpers;

const definition: helpers.PluginDefinition = .{
    .slug = "external-speaker-test",
    .stem = "external_speaker_test",
    .id = "microcrab.external-speaker-test",
    // Reuse the production world; wasm-tools emits only linked imports.
    .world = "output-translator",
    .root_source = "src/main.zig",
    .test_source = "src/tests.zig",
    .surfaces = &.{.{ .field = "panel_html", .directory = "ui" }},
    .default_enabled = false,
};

pub fn build(b: *std.Build) void {
    helpers.buildStandalone(b, @This());
}

pub fn register(b: *std.Build, context: helpers.Context, package: std.Build.LazyPath) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, context, package, definition);
}
