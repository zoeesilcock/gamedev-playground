const std = @import("std");
const gamedev_playground = @import("gamedev_playground");

pub fn build(b: *std.Build) void {
    // Build options.
    const build_options = b.addOptions();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "template";
    build_options.addOption(bool, "internal", internal);
    build_options.addOption([]const u8, "lib_base_name", lib_base_name);
    const build_options_mod = build_options.createModule();

    // Game library.
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("build_options", build_options_mod);

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = lib_base_name,
        .root_module = module,
    });
    b.installArtifact(lib);

    const lib_check = b.addLibrary(.{
        .linkage = .dynamic,
        .name = lib_base_name,
        .root_module = module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);

    // Tests.
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Integrate gamedev-playground.
    const playground_dep = b.dependency("gamedev_playground", .{
        .target = target,
        .optimize = optimize,
    });
    const playground_mod = playground_dep.module("playground");
    playground_mod.addImport("build_options", build_options_mod);
    module.addImport("playground", playground_mod);
    gamedev_playground.linkSDL(playground_dep.builder, lib, target, optimize);

    if (!lib_only) {
        const exe = gamedev_playground.buildExecutable(
            playground_dep.builder,
            b,
            "template",
            build_options_mod,
            target,
            optimize,
            playground_mod,
        );
        b.installArtifact(exe);
    }
}
