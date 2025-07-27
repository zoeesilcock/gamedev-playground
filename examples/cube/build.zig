const std = @import("std");
const runtime = @import("runtime");

pub fn build(b: *std.Build) void {
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
    const lib = b.addSharedLibrary(.{
        .name = lib_base_name,
        .root_module = module,
    });

    module.addOptions("build_options", build_options);

    const runtime_dep = b.dependency("runtime", .{
        .target = target,
        .optimize = optimize,
    });
    if (runtime.getSDL(runtime_dep.builder, target, optimize)) |sdl_lib| {
        module.linkLibrary(sdl_lib);
        b.installArtifact(sdl_lib);
    }

    const shadercross_dep = b.dependency("shadercross", .{});
    const spirvheaders_dep = b.dependency("spirvheaders", .{});
    const shadercross = b.addStaticLibrary(.{
        .name = "SDL_shadercross",
        .target = target,
        .optimize = optimize,
    });
    const spirvcross_dep = b.dependency("spirvcross", .{});

    shadercross.linkLibC();
    shadercross.addIncludePath(spirvcross_dep.path(""));
    shadercross.addIncludePath(spirvheaders_dep.path("include/spirv/1.2/"));
    shadercross.addIncludePath(shadercross_dep.path("include"));
    shadercross.addIncludePath(runtime.getSDLIncludePath(runtime_dep.builder, target, optimize));
    shadercross.addCSourceFile(.{
        .file = shadercross_dep.path("src/SDL_shadercross.c"),
        .flags = &.{
            "-std=c99",
            "-Werror",
        },
        });
    shadercross.installHeadersDirectory(shadercross_dep.path("include"), "", .{});
    module.linkLibrary(shadercross);
    b.installArtifact(shadercross);

    const imgui_mod = runtime_dep.module("imgui");
    const sdl_mod = runtime_dep.module("sdl");
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
