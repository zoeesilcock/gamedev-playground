const std = @import("std");
const flint = @import("flint");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const name = b.option([]const u8, "name", "name of the game (used for exe and lib)") orelse "template";
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;

    // Integrate Flint.
    const flint_options: flint.IntegrateOptions = .{
        .dependency = b.dependency("flint", .{ .target = target, .optimize = optimize, .internal = internal }),
        .target = target,
        .optimize = optimize,
        .build_options = b.addOptions(),
        .name = name,
        .internal = internal,
        .lib_only = lib_only,
        .install_step = b.getInstallStep(),
        .dest_dir = .default,
    };
    const result = flint.integrate(b, flint_options);

    // Install executable.
    if (result.exe) |exe| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // Game library.
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = flint_options.target,
        .optimize = flint_options.optimize,
    });
    module.addImport("build_options", result.build_options_mod);
    module.addImport("flint", result.flint_mod);

    const lib = b.addLibrary(.{
        .name = flint_options.name,
        .linkage = .dynamic,
        .root_module = module,
        .use_llvm = true,
    });

    // Install library.
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);

    // Check library.
    const lib_check = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = lib.root_module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);

    // Tests.
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Build all variations.
    const build_all_step = b.step("all", "Builds all permutations of the game for testing purposes.");
    flint.buildMatrixDefault(b, build_all_step, name, b.path("assets"));
}
