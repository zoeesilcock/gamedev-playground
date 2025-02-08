const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;

    const lib = b.addSharedLibrary(.{
        .name = "playground",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    linkLibraries(b, lib, target, optimize);
    linkLibraries(b, lib_unit_tests, target, optimize);

    b.installArtifact(lib);

    const lib_check = b.addSharedLibrary(.{
        .name = "playground",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkLibraries(b, lib_check, target, optimize);
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

        linkLibraries(b, exe, target, optimize);

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

fn linkLibraries(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // obj.linkLibCpp();

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");
    obj.root_module.linkLibrary(sdl_lib);
}
