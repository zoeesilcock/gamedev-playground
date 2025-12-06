const std = @import("std");
const runtime = @import("runtime");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "diamonds";
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

    module.addOptions("build_options", build_options);

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
    const aseprite_mod = runtime_dep.module("aseprite");
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

    module.addImport("sdl", sdl_mod);
    module.addImport("imgui", imgui_mod);
    module.addImport("internal", internal_mod);
    module.addImport("aseprite", aseprite_mod);
    module.addImport("math", math_mod);
    module.addImport("logging_allocator", logging_allocator_mod);

    runtime.linkImgui(runtime_dep.builder, lib, target, optimize, internal);

    b.installArtifact(lib);

    if (!lib_only) {
        const test_step = b.step("test", "Run unit tests");
        const exe = runtime.buildExecutable(
            runtime_dep.builder,
            b,
            "diamonds",
            build_options,
            target,
            optimize,
            test_step,
        );
        b.installArtifact(exe);
    }
}
