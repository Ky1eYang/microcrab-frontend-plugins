const std = @import("std");
const helpers = @import("shared/src/build_helpers.zig");
const state_viewer = @import("plugins/state-viewer/build.zig");
const mcp_bridge = @import("plugins/mcp-bridge/build.zig");

pub fn build(b: *std.Build) void {
    const optimize: std.builtin.OptimizeMode = b.option(std.builtin.OptimizeMode, "optimize", "Guest optimization mode (default ReleaseSmall)") orelse switch (b.release_mode) {
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .off, .any, .small => .ReleaseSmall,
    };
    const shared = b.createModule(.{ .root_source_file = b.path("shared/src/root.zig") });
    const bundler = b.addExecutable(.{
        .name = "bundle_ui",
        .root_source_file = b.path("tools/bundle.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    const context = helpers.Context{ .shared = shared, .bundler = bundler, .optimize = optimize };
    const plugins = [_]helpers.PluginArtifacts{
        state_viewer.register(b, context),
        mcp_bridge.register(b, context),
    };
    const selection = b.option([]const u8, "plugins", "Comma-separated aggregate plugin selection (default all)");
    const install_directory = b.option([]const u8, "install-dir", "Override browser installation destinations with this directory");
    if (install_directory) |directory| {
        if (directory.len == 0) {
            std.log.err("install-dir must be nonempty", .{});
            b.invalid_user_input = true;
            return;
        }
    }
    const selected = selectPlugins(b.allocator, &plugins, selection) catch |err| {
        std.log.err("invalid plugins selection: {s}; expected state-viewer,mcp-bridge", .{@errorName(err)});
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
    const installer = b.addExecutable(.{
        .name = "install_plugins",
        .root_source_file = b.path("tools/install.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    installer.root_module.addImport("shared", shared);
    const installer_tests = b.addTest(.{
        .root_source_file = b.path("tools/install.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    installer_tests.root_module.addImport("shared", shared);
    const installer_test = b.step("installer-test", "Run native aggregate installer tests");
    installer_test.dependOn(&installer.step);
    installer_test.dependOn(&b.addRunArtifact(installer_tests).step);
    tests.dependOn(installer_test);

    helpers.addFrontendInstall(b, installer, "install-frontend", selected, install_directory);
    for (plugins) |plugin| {
        helpers.addFrontendInstall(b, installer, b.fmt("install-{s}", .{plugin.slug}), &.{plugin}, install_directory);
    }
}

fn selectPlugins(allocator: std.mem.Allocator, plugins: []const helpers.PluginArtifacts, selection: ?[]const u8) ![]const helpers.PluginArtifacts {
    const names = selection orelse return plugins;
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
