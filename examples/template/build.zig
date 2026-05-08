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

    // Build all.
    const build_all_step = b.step("all", "Builds all permutations of the game for testing purposes.");
    buildMatrix(b, build_all_step, flint_options);

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

const BuildResult = struct {
    exe: ?*std.Build.Step.Compile,
    lib: *std.Build.Step.Compile,
};

fn buildGame(
    b: *std.Build,
    integrate_options: flint.IntegrateOptions,
) BuildResult {
    // Integrate Flint.
    const result = flint.integrate(b, integrate_options);

    // Game library.
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = integrate_options.target,
        .optimize = integrate_options.optimize,
    });
    module.addImport("build_options", result.build_options_mod);
    module.addImport("flint", result.flint_mod);

    const lib = b.addLibrary(.{
        .name = integrate_options.name,
        .linkage = .dynamic,
        .root_module = module,
        .use_llvm = true,
    });

    return .{ .exe = result.exe, .lib = lib };
}

const targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    // .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
};
const optimize_modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast };
const internal_modes = [_]bool{ true, false };

fn buildMatrix(b: *std.Build, step: *std.Build.Step, options: flint.IntegrateOptions) void {
    for (targets) |target_query| {
        const target = b.resolveTargetQuery(target_query);
        for (optimize_modes) |optimize| {
            for (internal_modes) |internal| {
                const dest_path: []const u8 = b.fmt("builds/{s}-{s}-{s}-{s}-{s}", .{
                    options.name,
                    @tagName(target_query.os_tag.?),
                    @tagName(target_query.cpu_arch.?),
                    @tagName(optimize),
                    if (internal) "internal" else "release",
                });
                const dest_dir: std.Build.Step.InstallArtifact.Options.Dir = .{ .override = .{ .custom = dest_path } };
                const result = buildGame(b, .{
                    .dependency = options.dependency,
                    .target = target,
                    .optimize = optimize,
                    .build_options = b.addOptions(),
                    .name = options.name,
                    .internal = internal,
                    .disable_run = true,
                    .install_step = step,
                    .dest_dir = dest_dir,
                });

                // Executable.
                if (result.exe) |exe| {
                    step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = dest_dir }).step);
                }

                // Game library.
                step.dependOn(&b.addInstallArtifact(result.lib, .{ .dest_dir = dest_dir }).step);
            }
        }
    }
}
