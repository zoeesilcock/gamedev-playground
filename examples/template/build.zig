const std = @import("std");
const flint = @import("flint");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const name = b.option([]const u8, "name", "name of the game (used for exe and lib)") orelse "template";
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;

    // Integrate Flint.
    const result = flint.integrate(b, .{
        .dependency = b.dependency("flint", .{ .target = target, .optimize = optimize }),
        .target = target,
        .optimize = optimize,
        .build_options = b.addOptions(),
        .name = name,
        .internal = internal,
        .lib_only = lib_only,
    });

    // Game library.
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("build_options", result.build_options_mod);
    module.addImport("flint", result.flint_mod);

    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = module,
    });
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);

    if (result.exe) |exe| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    const lib_check = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);

    // Tests.
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}
