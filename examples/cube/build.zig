const std = @import("std");
const flint = @import("flint");

const TARGETS = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};
const OPTIMIZE_MODES = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast };
const INTERNAL_MODES = [_]bool{ true, false };

const SHADER_FORMATS: []const []const u8 = &.{ "spv", "msl", "dxil" };
const SHADERS: []const []const u8 = &.{
    "cube.vert",
    "solid_color.frag",
    "screen.vert",
    "screen.frag",
};

var log_allocations: bool = false;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const name = b.option([]const u8, "name", "name of the shared library") orelse "cube";
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    log_allocations = b.option(bool, "log_allocations", "log all allocations") orelse false;

    // Integrate Flint.
    const flint_options: flint.IntegrateOptions = .{
        .dependency = b.dependency("flint", .{ .target = target, .optimize = optimize }),
        .target = target,
        .optimize = optimize,
        .build_options = b.addOptions(),
        .name = name,
        .internal = internal,
        .lib_only = lib_only,
        .install_step = b.getInstallStep(),
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
        .linkage = .dynamic,
        .name = name,
        .root_module = result.lib.root_module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);

    // Tests.
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = result.lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Shader compilation.
    const compile_shaders_step = b.step(
        "compile_shaders",
        "Compile SHADERS. (requires a working shadercross installation on the path)",
    );
    inline for (SHADERS) |shader| {
        inline for (SHADER_FORMATS) |shader_output_format| {
            const output_name = shader ++ "." ++ shader_output_format;
            var compile_shader = b.addSystemCommand(&.{"shadercross"});
            compile_shader.addFileArg(b.path("src/shaders/" ++ shader ++ ".hlsl"));
            compile_shader.addArg("-o");
            const compiled_shader = compile_shader.addOutputFileArg(output_name);
            const installed_shader = b.addInstallFile(compiled_shader, "../assets/shaders/" ++ output_name);

            compile_shaders_step.dependOn(&compile_shader.step);
            compile_shaders_step.dependOn(&installed_shader.step);
        }
    }

    b.getInstallStep().dependOn(compile_shaders_step);
}

fn buildGame(
    b: *std.Build,
    flint_options: flint.IntegrateOptions,
) flint.BuildResult {
    // Custom build options.
    flint_options.build_options.addOption(bool, "log_allocations", log_allocations);

    // Integrate Flint.
    const result = flint.integrate(b, flint_options);

    // Game library.
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = flint_options.target,
        .optimize = flint_options.optimize,
    });
    const logging_allocator_mod = b.createModule(.{
        .root_source_file = b.path("../logging_allocator.zig"),
        .target = flint_options.target,
        .optimize = flint_options.optimize,
    });
    const math_mod = b.createModule(.{
        .root_source_file = b.path("../math.zig"),
        .target = flint_options.target,
        .optimize = flint_options.optimize,
        .imports = &.{
            .{ .name = "flint", .module = result.flint_mod },
        },
    });
    module.addImport("build_options", result.build_options_mod);
    module.addImport("flint", result.flint_mod);
    module.addImport("logging_allocator", logging_allocator_mod);
    module.addImport("math", math_mod);

    const lib = b.addLibrary(.{
        .name = flint_options.name,
        .linkage = .dynamic,
        .root_module = module,
        .use_llvm = true,
    });

    return .{ .exe = result.exe, .lib = lib, .assets_path = b.path("assets") };
}
