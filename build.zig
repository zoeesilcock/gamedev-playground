const std = @import("std");
const integration = @import("src/lib/build/integration.zig");
const MatrixStep = @import("src/lib/build/MatrixStep.zig");

// Types.
pub const IntegrateOptions = integration.IntegrateOptions;
pub const IntegrateResult = integration.IntegrateResult;
pub const BuildMatrixStep = MatrixStep;
pub const BuildGameFnType = MatrixStep.BuildGameFnType;
pub const BuildResult = MatrixStep.BuildResult;

const EXAMPLE_PATHS = [_][]const u8{
    "examples/template",
    "examples/diamonds",
    "examples/cube",
};
const PLATFORM = @import("builtin").os.tag;
const PLATFORM_CPU = @import("builtin").target.cpu;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const name = b.option([]const u8, "name", "name of the shared library") orelse "game";
    const internal = b.option(bool, "internal", "include debug interface") orelse true;

    const exe_build_options = b.addOptions();
    exe_build_options.addOption(bool, "internal", internal);
    exe_build_options.addOption([]const u8, "name", name);
    const exe_build_options_mod = exe_build_options.createModule();

    const build_options = b.addOptions();
    build_options.addOption(bool, "internal", internal);
    const build_options_mod = build_options.createModule();

    // Default to building Flint if no other step is specified.
    var build_all_step = b.step("all", "Build all");
    b.default_step = build_all_step;

    // Flint module.
    const flint_mod = addFlintModule(b, b, target, optimize, build_all_step, build_options_mod, internal, .default);

    // Main executable.
    const exe = addFlintExecutable(b, target, optimize, exe_build_options_mod, flint_mod, "flint");
    build_all_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    // Tests.
    const test_step = b.step("test", "Run unit tests");

    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .use_llvm = true });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    const lib_tests = b.addTest(.{ .root_module = flint_mod, .use_llvm = true });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Build all examples.
    const build_examples_step = b.step("examples", "Builds all permutations of the examples for testing purposes.");
    for (EXAMPLE_PATHS) |example_path| {
        const build_example_cmd = b.addSystemCommand(&.{
            "zig",
            "build",
            "all",
            "--build-file",
            b.fmt("{s}/build.zig", .{example_path}),
        });
        build_examples_step.dependOn(&build_example_cmd.step);
    }

    // Docs.
    const docs_mod = b.addModule("docs", .{
        .root_source_file = b.path("src/lib/docs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const docs = b.addObject(.{
        .name = "docs",
        .root_module = docs_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // New project generator executable.
    buildNewExecutable(b, exe_build_options_mod, target);
}

pub fn integrate(b: *std.Build, options: IntegrateOptions) IntegrateResult {
    const flint_b = options.dependency.builder;

    options.build_options.addOption(bool, "internal", options.internal);
    options.build_options.addOption([]const u8, "name", options.name);
    const build_options_mod = options.build_options.createModule();

    const flint_mod = addFlintModule(
        flint_b,
        b,
        options.target,
        options.optimize,
        options.install_step,
        build_options_mod,
        options.internal,
        options.dest_dir,
    );

    var exe: ?*std.Build.Step.Compile = null;
    if (!options.lib_only) {
        exe = addFlintExecutable(
            flint_b,
            options.target,
            options.optimize,
            build_options_mod,
            flint_mod,
            options.name,
        );

        if (!options.skip_run_step) {
            const run_step = b.step("run", "Run the game");
            const run_cmd = b.addRunArtifact(exe.?);
            run_cmd.step.dependOn(b.getInstallStep());
            run_cmd.addPassthruArgs();
            run_step.dependOn(&run_cmd.step);
        }
    }

    return .{
        .flint_mod = flint_mod,
        .exe = exe,
        .build_options_mod = build_options_mod,
    };
}

pub fn addFlintModule(
    b: *std.Build,
    client_b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_step: *std.Build.Step,
    build_options_mod: *std.Build.Module,
    internal: bool,
    dest_dir: std.Build.Step.InstallArtifact.Options.Dir,
) *std.Build.Module {
    const flint_mod = b.addModule("flint", .{
        .root_source_file = b.path("src/lib/flint.zig"),
        .target = target,
        .optimize = optimize,
    });
    flint_mod.addImport("build_options", build_options_mod);
    if (getSDLIncludePath(b, target, optimize)) |sdl_include_path| {
        flint_mod.addIncludePath(sdl_include_path);
    }
    if (internal) {
        linkImgui(b, flint_mod, target, optimize, install_step);
    }
    linkSDL(b, client_b, flint_mod, target, optimize, install_step, dest_dir);
    return flint_mod;
}

pub fn addFlintExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
    flint_mod: *std.Build.Module,
    name: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "flint", .module = flint_mod },
        },
    });
    module.addImport("build_options", build_options_mod);
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = module,
        .use_llvm = true,
    });

    if (target.result.os.tag.isDarwin()) {
        exe.root_module.addRPathSpecial("@loader_path/lib");
        exe.root_module.addRPathSpecial("@loader_path");
    } else if (target.result.os.tag == .linux) {
        exe.root_module.addRPathSpecial("$ORIGIN/lib");
        exe.root_module.addRPathSpecial("$ORIGIN");
    }

    return exe;
}

fn linkSDL(
    b: *std.Build,
    client_b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_step: *std.Build.Step,
    dest_dir: std.Build.Step.InstallArtifact.Options.Dir,
) void {
    if (getSDL(b, target, optimize)) |sdl_lib| {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/lib/sdl.h"),
            .target = target,
            .optimize = optimize,
        });
        if (getSDLIncludePath(b, target, optimize)) |sdl_include_path| {
            translate_c.addIncludePath(sdl_include_path);
        }
        module.addImport("sdl_c", translate_c.createModule());

        module.linkLibrary(sdl_lib);
        install_step.dependOn(&client_b.addInstallArtifact(sdl_lib, .{ .dest_dir = dest_dir }).step);
    }
}

pub fn getSDL(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    var result: ?*std.Build.Step.Compile = null;
    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .dynamic,
    })) |sdl_dep| {
        result = sdl_dep.artifact("SDL3");
    }
    return result;
}

pub fn getSDLIncludePath(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?std.Build.LazyPath {
    var result: ?std.Build.LazyPath = null;

    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .dynamic,
    })) |sdl_dep| {
        result = sdl_dep.path("include");
    }

    return result;
}

fn linkImgui(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_step: *std.Build.Step,
) void {
    if (b.lazyDependency("imgui", .{
        .target = target,
        .optimize = optimize,
    })) |imgui_dep| {
        if (createImGuiModule(b, target, optimize, imgui_dep, install_step)) |imgui_mod| {
            module.addImport("imgui_c", imgui_mod);
        }
    }
}

fn createImGuiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
    install_step: *std.Build.Step,
) ?*std.Build.Module {
    var imgui_mod: ?*std.Build.Module = null;
    const IMGUI_C_DEFINES: []const [2][]const u8 = &.{
        .{ "IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1" },
        .{ "IMGUI_DISABLE_OBSOLETE_KEYIO", "1" },
        .{ "IMGUI_IMPL_API", "extern \"C\"" },
        .{ "IMGUI_USE_WCHAR32", "1" },
        .{ "ImTextureID", "ImU64" },
    };
    const IMGUI_C_FLAGS: []const []const u8 = &.{
        "-std=c++11",
        "-fvisibility=hidden",
    };
    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .dynamic,
    })) |sdl_dep| {
        if (b.lazyDependency("dear_bindings", .{})) |dear_bindings_dep| {
            const module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            });
            const dcimgui_sdl = b.addLibrary(.{
                .name = "dcimgui_sdl",
                .root_module = module,
            });

            dcimgui_sdl.root_module.link_libcpp = true;
            module.addIncludePath(sdl_dep.path("include"));
            module.addIncludePath(imgui_dep.path(""));
            module.addIncludePath(imgui_dep.path("backends/"));
            module.addIncludePath(dear_bindings_dep.path(""));
            dcimgui_sdl.installHeadersDirectory(
                dear_bindings_dep.path(""),
                "",
                .{ .include_extensions = &.{".h"} },
            );

            const imgui_sources: []const std.Build.LazyPath = &.{
                dear_bindings_dep.path("dcimgui.cpp"),
                dear_bindings_dep.path("dcimgui_internal.cpp"),
                imgui_dep.path("imgui.cpp"),
                imgui_dep.path("imgui_demo.cpp"),
                imgui_dep.path("imgui_draw.cpp"),
                imgui_dep.path("imgui_tables.cpp"),
                imgui_dep.path("imgui_widgets.cpp"),
                imgui_dep.path("backends/imgui_impl_sdlrenderer3.cpp"),
                imgui_dep.path("backends/imgui_impl_sdlgpu3.cpp"),
                imgui_dep.path("backends/imgui_impl_sdl3.cpp"),
            };

            for (IMGUI_C_DEFINES) |c_define| {
                dcimgui_sdl.root_module.addCMacro(c_define[0], c_define[1]);
            }

            for (imgui_sources) |file| {
                module.addCSourceFile(.{
                    .file = file,
                    .flags = IMGUI_C_FLAGS,
                });
            }

            install_step.dependOn(&b.addInstallArtifact(dcimgui_sdl, .{}).step);

            const translate_c = b.addTranslateC(.{
                .root_source_file = b.path("src/lib/imgui.h"),
                .target = target,
                .optimize = optimize,
            });
            translate_c.addIncludePath(dear_bindings_dep.path(""));
            translate_c.addIncludePath(imgui_dep.path("."));

            imgui_mod = translate_c.createModule();
            imgui_mod.?.linkLibrary(dcimgui_sdl);
        }
    }

    return imgui_mod;
}

fn buildNewExecutable(
    b: *std.Build,
    build_options_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    const new_optimize = b.option(
        std.builtin.OptimizeMode,
        "new_optimize",
        "optimization mode for the new project generator (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const module = b.createModule(.{
        .root_source_file = b.path("src/new.zig"),
        .target = target,
        .optimize = new_optimize,
    });
    module.addImport("build_options", build_options_mod);
    const new_exe = b.addExecutable(.{
        .name = "flint-new",
        .root_module = module,
    });

    const run_step = b.step("new", "Run the new project generator");
    const run_cmd = b.addRunArtifact(new_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);
    run_step.dependOn(&b.addInstallArtifact(new_exe, .{}).step);
}
