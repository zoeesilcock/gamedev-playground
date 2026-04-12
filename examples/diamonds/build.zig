const std = @import("std");
const flint = @import("flint");

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
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);

    const lib_check = b.addLibrary(.{
        .linkage = .dynamic,
        .name = lib_base_name,
        .root_module = module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);

    // Integrate flint.
    const flint_dep = b.dependency("flint", .{
        .target = target,
        .optimize = optimize,
    });
    const flint_mod = flint.getFlintModule(
        flint_dep.builder,
        b,
        target,
        optimize,
        b.getInstallStep(),
        build_options_mod,
        internal,
    );
    module.addImport("flint", flint_mod);

    if (!lib_only) {
        const exe = flint.buildExecutable(
            flint_dep.builder,
            b,
            target,
            optimize,
            build_options_mod,
            flint_mod,
            "diamonds",
        );
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
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
            .{ .name = "flint", .module = flint_mod },
        },
    });
    module.addImport("math", math_mod);
    module.addImport("logging_allocator", logging_allocator_mod);

    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}
