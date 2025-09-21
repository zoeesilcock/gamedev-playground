const std = @import("std");
const runtime = @import("runtime");

const SHADER_FORMATS: []const []const u8 = &.{ "spv", "msl", "dxil" };
const SHADERS: []const []const u8 = &.{
    "cube.vert",
    "solid_color.frag",
    "screen.vert",
    "screen.frag",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "cube";
    const log_allocations = b.option(bool, "log_allocations", "log all allocations") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "internal", internal);
    build_options.addOption([]const u8, "lib_base_name", lib_base_name);
    build_options.addOption(bool, "log_allocations", log_allocations);

    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", build_options);
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

    const compile_shaders_step = b.step("compile_shaders", "Compile SHADERS. (requires a working shadercross installation on the path)");
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

    const runtime_dep = b.dependency("runtime", .{
        .target = target,
        .optimize = optimize,
    });
    if (runtime.getSDL(runtime_dep.builder, target, optimize)) |sdl_lib| {
        module.linkLibrary(sdl_lib);
        b.installArtifact(sdl_lib);
    }

    const sdl_mod = runtime_dep.module("sdl");
    const imgui_mod = runtime_dep.module("imgui");
    const internal_mod = runtime_dep.module("internal");
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
            .{ .name = "sdl", .module = sdl_mod },
        },
    });
    const pool_mod = b.createModule(.{
        .root_source_file = b.path("../pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addImport("sdl", sdl_mod);
    module.addImport("imgui", imgui_mod);
    module.addImport("internal", internal_mod);
    module.addImport("math", math_mod);
    module.addImport("logging_allocator", logging_allocator_mod);
    module.addImport("pool", pool_mod);

    runtime.linkImgui(runtime_dep.builder, lib, target, optimize, internal);

    b.installArtifact(lib);

    if (!lib_only) {
        const test_step = b.step("test", "Run unit tests");
        const exe = runtime.buildExecutable(runtime_dep.builder, b, build_options, target, optimize, test_step);
        b.installArtifact(exe);
    }
}
