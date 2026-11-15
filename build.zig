const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const shared_mod = b.createModule(.{
        .root_source_file = b.path("shared/src/root.zig"),
    });

    // 1. Build Core wasm for State Viewer
    const state_viewer = b.addExecutable(.{
        .name = "state_viewer",
        .root_source_file = b.path("plugins/state-viewer/src/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    state_viewer.entry = .disabled;
    state_viewer.rdynamic = true;
    state_viewer.root_module.addImport("shared", shared_mod);

    const install_core = b.addInstallArtifact(state_viewer, .{});
    b.getInstallStep().dependOn(&install_core.step);

    // 2. Componentize step using wasm-tools
    const component_step = b.step("component", "Build WebAssembly Component using wasm-tools");

    const core_wasm_path = b.getInstallPath(.bin, "state_viewer.wasm");
    const embedded_wasm_path = b.pathJoin(&.{ b.install_path, "bin", "state_viewer.embedded.wasm" });
    const component_wasm_path = b.pathJoin(&.{ b.install_path, "bin", "state_viewer.component.wasm" });

    // Step A: wasm-tools component embed
    const embed_cmd = b.addSystemCommand(&.{
        "wasm-tools",
        "component",
        "embed",
        "wit",
        "-w",
        "state-viewer",
        core_wasm_path,
        "-o",
        embedded_wasm_path,
    });
    embed_cmd.step.dependOn(&install_core.step);

    // Step B: wasm-tools component new
    const new_cmd = b.addSystemCommand(&.{
        "wasm-tools",
        "component",
        "new",
        embedded_wasm_path,
        "-o",
        component_wasm_path,
    });
    new_cmd.step.dependOn(&embed_cmd.step);

    // Step C: wasm-tools validate
    const validate_cmd = b.addSystemCommand(&.{
        "wasm-tools",
        "validate",
        component_wasm_path,
    });
    validate_cmd.step.dependOn(&new_cmd.step);

    component_step.dependOn(&validate_cmd.step);

    // 3. Install to frontend step
    const installer = b.addExecutable(.{
        .name = "install_plugin",
        .root_source_file = b.path("tools/install.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    const run_installer = b.addRunArtifact(installer);
    run_installer.addArg(component_wasm_path);
    run_installer.addArg("../microcrab-frontend/frontend/public/plugins");
    run_installer.step.dependOn(component_step);

    const install_frontend_step = b.step("install-frontend", "Install built component into microcrab-frontend/frontend/public/plugins");
    install_frontend_step.dependOn(&run_installer.step);
}
