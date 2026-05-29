//! This allows building various permutations of your game for testing purposes. The results will be placed in the
//! ./zig-out/builds directory of your project. The buildGame function is called on each permutation, that function is
//! where you place all the build logic your game needs.
const std = @import("std");
const integration = @import("integration.zig");

const PLATFORM = @import("builtin").os.tag;
const PLATFORM_CPU = @import("builtin").target.cpu;
const DEFAULT_TARGETS = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};
const DEFAULT_OPTIMIZE_MODES = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast };
const DEFAULT_INTERNAL_MODES = [_]bool{ true, false };

// Types.
const Step = std.Build.Step;
const IntegrateOptions = integration.IntegrateOptions;
const BuildMatrixStep = @This();

/// The buildGame function called by the buildMatrix for each permutation of the matrix.
pub const BuildGameFnType = *const fn (b: *std.Build, flint_options: IntegrateOptions) BuildResult;

/// The result expected back from the buildGame function.
pub const BuildResult = struct {
    exe: ?*std.Build.Step.Compile,
    lib: *std.Build.Step.Compile,
    assets_path: ?std.Build.LazyPath,
};

/// The options that can be passed to the build matrix. It contains a default set of targets, optimization modes and
/// internal modes but you can pass your own sets for either of them instead.
pub const Options = struct {
    options: IntegrateOptions,
    buildGame: BuildGameFnType,
    targets: []const std.Target.Query = &DEFAULT_TARGETS,
    optimize_modes: []const std.builtin.OptimizeMode = &DEFAULT_OPTIMIZE_MODES,
    internal_modes: []const bool = &DEFAULT_INTERNAL_MODES,
};

step: Step,
options: Options,

pub fn create(b: *std.Build, step_options: Options) *BuildMatrixStep {
    const matrix = b.allocator.create(BuildMatrixStep) catch @panic("OOM");
    matrix.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "build_matrix",
            .owner = b,
            .makeFn = make,
        }),
        .options = step_options,
    };

    const options = step_options.options;
    var step = &matrix.step;

    for (step_options.targets) |target_query| {
        // Skip MacOS when on a different platform without specifying the sysroot which is required for SDL.
        if (b.sysroot == null and target_query.os_tag == .macos and target_query.os_tag != PLATFORM) {
            continue;
        }

        // If we are building for the same OS and CPU as the build is running on we consider it a native build.
        const use_native_query = (target_query.os_tag == PLATFORM and target_query.cpu_arch == PLATFORM_CPU.arch);

        const target = b.resolveTargetQuery(target_query);
        for (step_options.optimize_modes) |optimize| {
            for (step_options.internal_modes) |internal| {
                const dest_path: []const u8 = b.fmt("builds/{s}-{s}-{s}-{s}-{s}", .{
                    options.name,
                    @tagName(target_query.os_tag.?),
                    @tagName(target_query.cpu_arch.?),
                    @tagName(optimize),
                    if (internal) "internal" else "release",
                });
                const dest_dir: std.Build.Step.InstallArtifact.Options.Dir = .{ .override = .{ .custom = dest_path } };
                const result = step_options.buildGame(b, .{
                    .dependency = options.dependency,
                    // Workaround for the fact that zig build system considers any values in the target query to be
                    // non-native even if they match the build machine. Without this the SDL build.zig will complain
                    // about missing --sysroot even when we are running on MacOS and don't actually need to specify it.
                    // By passing a the default target in this case the target will be considered native.
                    .target = if (use_native_query) options.target else target,
                    .optimize = optimize,
                    .build_options = b.addOptions(),
                    .name = options.name,
                    .internal = internal,
                    .skip_run_step = true,
                    .install_step = step,
                    .dest_dir = dest_dir,
                });

                // Install executable.
                if (result.exe) |exe| {
                    step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = dest_dir }).step);
                }

                // Install game library.
                step.dependOn(&b.addInstallArtifact(result.lib, .{ .dest_dir = dest_dir }).step);

                // Install game assets.
                if (result.assets_path) |assets_path| {
                    step.dependOn(&b.addInstallDirectory(.{
                        .source_dir = assets_path,
                        .install_dir = .{ .custom = dest_path },
                        .install_subdir = "assets",
                    }).step);
                }
            }
        }
    }

    return matrix;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;

    const b = step.owner;
    const matrix: *BuildMatrixStep = @fieldParentPtr("step", step);

    for (matrix.options.targets) |target_query| {
        // Skip MacOS when on a different platform without specifying the sysroot which is required for SDL.
        if (b.sysroot == null and target_query.os_tag == .macos and target_query.os_tag != PLATFORM) {
            std.log.info("MacOS skipped since --sysroot was not specified, the Apple SDKs are required for cross compiling to this target.", .{});
        }
    }
}
