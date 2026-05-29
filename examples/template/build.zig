const std = @import("std");
const flint = @import("flint");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const name = b.option([]const u8, "name", "name of the game (used for exe and lib)") orelse "template";
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;

    // Build game.
    const flint_options: flint.IntegrateOptions = .{
        .dependency = b.dependency("flint", .{ .target = target, .optimize = optimize }),
        .target = target,
        .optimize = optimize,
        .build_options = b.addOptions(),
        .name = name,
        .internal = internal,
        .lib_only = lib_only,
        .install_step = b.getInstallStep(),
        .dest_dir = .default,
    };
    const result = buildGame(b, flint_options);

    // Build all variations.
    const build_all_step = b.step("all", "Builds all permutations of the game for testing purposes.");
    const build_matrix = flint.BuildMatrixStep.create(b, .{ .options = flint_options, .buildGame = &buildGame });
    build_all_step.dependOn(&build_matrix.step);

    // Install executable.
    if (result.exe) |exe| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // Install library.
    b.getInstallStep().dependOn(&b.addInstallArtifact(result.lib, .{}).step);

    // Check library.
    const lib_check = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = result.lib.root_module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);

    // Tests.
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = result.lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}

fn buildGame(
    b: *std.Build,
    flint_options: flint.IntegrateOptions,
) flint.BuildResult {
    // Integrate Flint.
    const result = flint.integrate(b, flint_options);

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

    return .{ .exe = result.exe, .lib = lib, .assets_path = b.path("assets") };
}
