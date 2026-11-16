//! Build-time utilities. Plugin registrations receive the root Build; no standalone package entry is exposed.
const std = @import("std");

pub const Context = struct {
    shared: *std.Build.Module,
    bundler: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
};
pub const Surface = struct { field: []const u8, directory: []const u8 };
pub const PluginDefinition = struct {
    slug: []const u8,
    stem: []const u8,
    id: []const u8,
    world: []const u8,
    root_source: []const u8,
    test_source: []const u8,
    surfaces: []const Surface,
    default_enabled: bool = true,
};
pub const PluginArtifacts = struct {
    slug: []const u8,
    id: []const u8,
    default_enabled: bool,
    component: std.Build.LazyPath,
    component_step: *std.Build.Step,
    test_step: *std.Build.Step,
};

pub fn buildPlugin(b: *std.Build, ctx: Context, def: PluginDefinition) PluginArtifacts {
    const assets = b.addWriteFiles();
    var asset_source = std.ArrayList(u8).init(b.allocator);
    for (def.surfaces) |surface| {
        const bundle = b.addRunArtifact(ctx.bundler);
        bundle.addFileArg(b.path(b.fmt("{s}/index.html", .{surface.directory})));
        bundle.addFileArg(b.path(b.fmt("{s}/style.css", .{surface.directory})));
        bundle.addFileArg(b.path(b.fmt("{s}/app.js", .{surface.directory})));
        const filename = b.fmt("{s}.html", .{surface.field});
        _ = assets.addCopyFile(bundle.addOutputFileArg(filename), filename);
        asset_source.writer().print("pub const {s} = @embedFile(\"{s}\");\n", .{ surface.field, filename }) catch @panic("out of memory");
    }
    const ui = b.createModule(.{ .root_source_file = assets.add("ui_assets.zig", asset_source.items) });
    const wasm = b.addExecutable(.{
        .name = def.stem,
        .root_source_file = b.path(def.root_source),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = ctx.optimize,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.root_module.addImport("shared", ctx.shared);
    wasm.root_module.addImport("ui_assets", ui);

    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed" });
    embed.addDirectoryArg(b.path("wit"));
    embed.addArgs(&.{ "-w", def.world });
    embed.addFileArg(wasm.getEmittedBin());
    embed.addArg("-o");
    const embedded = embed.addOutputFileArg(b.fmt("{s}.embedded.wasm", .{def.stem}));
    const componentize = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    componentize.addFileArg(embedded);
    componentize.addArg("-o");
    const component = componentize.addOutputFileArg(b.fmt("{s}.component.wasm", .{def.stem}));
    const validate = b.addSystemCommand(&.{ "wasm-tools", "validate" });
    validate.addFileArg(component);
    // `validate` also accepts Core modules. WIT extraction additionally requires a Component.
    const wit = b.addSystemCommand(&.{ "wasm-tools", "component", "wit" });
    wit.addFileArg(component);
    wit.addArg("-o");
    _ = wit.addOutputFileArg(b.fmt("{s}.wit", .{def.stem}));
    const install = b.addInstallFileWithDir(component, .bin, b.fmt("{s}.component.wasm", .{def.stem}));
    install.step.dependOn(&validate.step);
    install.step.dependOn(&wit.step);
    const step = b.step(def.slug, b.fmt("Build and validate {s} WIT Component", .{def.id}));
    step.dependOn(&install.step);

    const diagnostic = b.step(b.fmt("{s}-core", .{def.slug}), "Install diagnostic Core module (not a distributable Component)");
    const diagnostic_file = b.addInstallFileWithDir(wasm.getEmittedBin(), .prefix, b.fmt("diagnostics/{s}.core.wasm", .{def.stem}));
    diagnostic.dependOn(&diagnostic_file.step);
    const native_tests = b.addTest(.{
        .root_source_file = b.path(def.test_source),
        .target = b.host,
        .optimize = .Debug,
    });
    native_tests.root_module.addImport("shared", ctx.shared);
    const test_step = b.step(b.fmt("{s}-test", .{def.slug}), b.fmt("Run native {s} tests", .{def.slug}));
    test_step.dependOn(&b.addRunArtifact(native_tests).step);
    return .{
        .slug = def.slug,
        .id = def.id,
        .default_enabled = def.default_enabled,
        .component = component,
        .component_step = step,
        .test_step = test_step,
    };
}

pub fn addFrontendInstall(b: *std.Build, installer: *std.Build.Step.Compile, name: []const u8, plugins: []const PluginArtifacts, destination: ?[]const u8) void {
    const run = b.addRunArtifact(installer);
    // One aggregate invocation locks, prepares and publishes both destinations.
    run.addArg("--adopt-current");
    for (plugins) |plugin| {
        run.addArgs(&.{ "--plugin", plugin.id });
        run.addFileArg(plugin.component);
        run.addArg(if (plugin.default_enabled) "true" else "false");
        run.step.dependOn(plugin.component_step);
    }
    if (destination) |directory| {
        run.addArgs(&.{ "--destination", b.pathFromRoot(directory) });
    } else {
        run.addArgs(&.{ "--destination", b.pathFromRoot("../microcrab-frontend/frontend/public/plugins"), "--destination", b.pathFromRoot("../public/plugins") });
    }
    run.has_side_effects = true;
    b.step(name, "Stage selected validated Components and atomically merge each destination index").dependOn(&run.step);
}
