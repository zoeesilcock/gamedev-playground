const std = @import("std");
const gamedev_playground = @import("gamedev_playground");

pub fn build(b: *std.Build) void {
    const build_options = b.addOptions();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "diamonds";
    const log_allocations = b.option(bool, "log_allocations", "log all allocations") orelse false;
    build_options.addOption(bool, "internal", internal);
    build_options.addOption([]const u8, "lib_base_name", lib_base_name);
    build_options.addOption(bool, "log_allocations", log_allocations);
    const build_options_mod = build_options.createModule();

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

    const lib_check = b.addLibrary(.{
        .linkage = .dynamic,
        .name = lib_base_name,
        .root_module = module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);

    // Integrate gamedev_playground.
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
            "diamonds",
            build_options_mod,
            target,
            optimize,
            playground_mod,
        );
        b.installArtifact(exe);
    }
    // End of integration.

    const logging_allocator_mod = b.createModule(.{
        .root_source_file = b.path("../logging_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const math_mod = b.createModule(.{
        .root_source_file = b.path("../math.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "playground", .module = playground_mod },
        },
    });
    module.addImport("math", math_mod);
    module.addImport("logging_allocator", logging_allocator_mod);

    b.installArtifact(lib);

    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}
