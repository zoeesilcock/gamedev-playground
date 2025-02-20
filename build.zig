const std = @import("std");
const ZigImGui_build_script = @import("zig_imgui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    const internal = b.option(bool, "internal", "include debug interface") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "internal", internal);

    const lib = b.addSharedLibrary(.{
        .name = "playground",
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addOptions("build_options", build_options);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    linkGameLibraries(b, lib, target, optimize);
    linkGameLibraries(b, lib_unit_tests, target, optimize);

    b.installArtifact(lib);

    const lib_check = b.addSharedLibrary(.{
        .name = "playground",
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkGameLibraries(b, lib_check, target, optimize);
    const check = b.step("check", "Check if lib compiles");
    check.dependOn(&lib_check.step);

    if (!lib_only) {
        const exe = b.addExecutable(.{
            .name = "gamedev-playground",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(exe);

        linkExecutableLibraries(b, exe, target, optimize);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        const exe_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}
fn linkExecutableLibraries(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
    });
    obj.root_module.linkLibrary(sdl_dep.artifact("SDL3"));
}

fn linkGameLibraries(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
    });
    obj.root_module.linkLibrary(sdl_dep.artifact("SDL3"));

    const zig_imgui_dep = b.dependency("zig_imgui", .{
        .target = target,
        .optimize = optimize,
    });
    obj.addIncludePath(zig_imgui_dep.path("src/generated"));
    obj.linkLibrary(createImGuiSDLLib(b, target, optimize, zig_imgui_dep));
}

fn createImGuiSDLLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zig_imgui_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .static,
    });
    const imgui_dep = zig_imgui_dep.builder.dependency("imgui", .{
        .target = target,
        .optimize = optimize,
    });
    const imgui_sdl = b.addStaticLibrary(.{
        .name = "imgui_sdl",
        .target = target,
        .optimize = optimize,
    });
    imgui_sdl.root_module.link_libcpp = true;
    imgui_sdl.linkLibrary(zig_imgui_dep.artifact("cimgui"));

    for (ZigImGui_build_script.IMGUI_C_DEFINES) |c_define| {
        imgui_sdl.root_module.addCMacro(c_define[0], c_define[1]);
    }

    imgui_sdl.linkLibrary(sdl_dep.artifact("SDL3"));
    imgui_sdl.root_module.addCMacro("SDL_DISABLE_OLD_NAMES", "0");
    imgui_sdl.root_module.addCMacro("SDL_FALSE", "false");
    imgui_sdl.root_module.addCMacro("SDL_TRUE", "true");
    imgui_sdl.root_module.addCMacro("SDL_bool", "bool");

    imgui_sdl.addIncludePath(imgui_dep.path("."));
    imgui_sdl.addIncludePath(imgui_dep.path("backends/"));
    imgui_sdl.addCSourceFile(.{
        .file = imgui_dep.path("backends/imgui_impl_sdlrenderer3.cpp"),
        .flags = ZigImGui_build_script.IMGUI_C_FLAGS,
    });
    imgui_sdl.addCSourceFile(.{
        .file = imgui_dep.path("backends/imgui_impl_sdl3.cpp"),
        .flags = ZigImGui_build_script.IMGUI_C_FLAGS,
    });

    return imgui_sdl;
}
