const std = @import("std");
const helpers = @import("shared").helpers;
const state_viewer = @import("plugins/state-viewer/build.zig");
const mcp_bridge = @import("plugins/mcp-bridge/build.zig");
const translator = @import("plugins/output-translator/build.zig");
const prompt_redactor = @import("plugins/prompt-redactor/build.zig");
const speaker = @import("plugins/external-speaker-test/build.zig");

pub fn build(b: *std.Build) void {
    const context = helpers.Context.init(b);
    const bundled = [_]helpers.PluginArtifacts{
        state_viewer.register(b, context, b.path("plugins/state-viewer")),
        mcp_bridge.register(b, context, b.path("plugins/mcp-bridge")),
        translator.register(b, context, b.path("plugins/output-translator")),
        prompt_redactor.register(b, context, b.path("plugins/prompt-redactor")),
    };
    const plugins = bundled ++ [_]helpers.PluginArtifacts{
        speaker.register(b, context, b.path("plugins/external-speaker-test")),
    };
    const selection = b.option([]const u8, "plugins", "Comma-separated aggregate selection (default builtins; opt-in plugins require explicit selection)");
    const install_directory = b.option([]const u8, "install-dir", "Override browser installation destinations with this directory");
    if (install_directory) |directory| {
        if (directory.len == 0) {
            std.log.err("install-dir must be nonempty", .{});
            b.invalid_user_input = true;
            return;
        }
    }
    const selected = selectPlugins(b.allocator, &plugins, &bundled, selection) catch |err| {
        std.log.err("invalid plugins selection: {s}; use comma-separated registered plugin slugs", .{@errorName(err)});
        b.invalid_user_input = true;
        return;
    };
    const all = b.step("all", "Build and validate selected WIT Components");
    const component = b.step("component", "Build and validate selected WIT Components");
    const tests = b.step("test", "Run native plugin and installer tests");
    for (selected) |plugin| {
        all.dependOn(plugin.component_step);
        component.dependOn(plugin.component_step);
        b.getInstallStep().dependOn(plugin.component_step);
        tests.dependOn(plugin.test_step);
    }
    const installer_source = b.dependency("tools", .{}).path("install.zig");
    const installer = b.addExecutable(.{
        .name = "install_plugins",
        .root_source_file = installer_source,
        .target = b.host,
        .optimize = .Debug,
    });
    installer.root_module.addImport("shared", context.shared);
    const installer_tests = b.addTest(.{
        .root_source_file = installer_source,
        .target = b.host,
        .optimize = .Debug,
    });
    installer_tests.root_module.addImport("shared", context.shared);
    const installer_test = b.step("installer-test", "Run native aggregate installer tests");
    installer_test.dependOn(&installer.step);
    installer_test.dependOn(&b.addRunArtifact(installer_tests).step);
    tests.dependOn(installer_test);

    helpers.addFrontendInstall(b, installer, "install-frontend", selected, install_directory);
    for (plugins) |plugin| {
        helpers.addFrontendInstall(b, installer, b.fmt("install-{s}", .{plugin.slug}), &.{plugin}, install_directory);
    }
}

fn selectPlugins(allocator: std.mem.Allocator, plugins: []const helpers.PluginArtifacts, bundled: []const helpers.PluginArtifacts, selection: ?[]const u8) ![]const helpers.PluginArtifacts {
    const names = selection orelse return bundled;
    var selected = std.ArrayList(helpers.PluginArtifacts).init(allocator);
    var items = std.mem.splitScalar(u8, names, ',');
    while (items.next()) |name| {
        if (name.len == 0) return error.EmptyPluginSelection;
        var found = false;
        for (plugins) |plugin| {
            if (!std.mem.eql(u8, name, plugin.slug)) continue;
            found = true;
            var duplicate = false;
            for (selected.items) |existing| {
                if (std.mem.eql(u8, existing.slug, plugin.slug)) duplicate = true;
            }
            if (!duplicate) try selected.append(plugin);
        }
        if (!found) return error.UnknownPlugin;
    }
    return selected.toOwnedSlice();
}
