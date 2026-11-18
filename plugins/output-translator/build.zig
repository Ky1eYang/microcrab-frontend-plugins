const std = @import("std");
const helpers = @import("../../shared/src/build_helpers.zig");
pub fn register(b: *std.Build, ctx: helpers.Context) helpers.PluginArtifacts {
    return helpers.buildPlugin(b, ctx, .{ .slug = "output-translator", .stem = "output_translator", .id = "microcrab.output-translator", .world = "output-translator", .root_source = "plugins/output-translator/src/main.zig", .test_source = "plugins/output-translator/src/tests.zig", .surfaces = &.{ .{ .field = "settings_html", .directory = "plugins/output-translator/ui/settings" }, .{ .field = "sidebar_html", .directory = "plugins/output-translator/ui/sidebar" }, .{ .field = "block_html", .directory = "plugins/output-translator/ui/block" } } });
}
