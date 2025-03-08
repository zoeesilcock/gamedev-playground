const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    const internal = b.option(bool, "internal", "include debug interface") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "internal", internal);

    const test_step = b.step("test", "Run unit tests");

    if (!lib_only) {
        buildExecutable(b, build_options, target, optimize, test_step);
    }

    buildGameLib(b, build_options, target, optimize, test_step, internal);
    checkGameLibStep(b, build_options, target, optimize, internal);

    generateImGuiBindingsStep(b, target, optimize);
}

fn buildExecutable(
    b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const exe = b.addExecutable(.{
        .name = "gamedev-playground",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", build_options);

    linkExecutableLibraries(b, exe, target, optimize);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_tests.root_module.addOptions("build_options", build_options);
    linkExecutableLibraries(b, exe_tests, target, optimize);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}

fn buildGameLib(
    b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    internal: bool,
) void {
    const lib = createGameLib(b, build_options, target, optimize, internal);
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_tests.root_module.addOptions("build_options", build_options);
    linkGameLibraries(b, lib_tests, target, optimize, internal);
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}

fn checkGameLibStep(
    b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    internal: bool,
) void {
    const lib = createGameLib(b, build_options, target, optimize, internal);

    const check = b.step("check", "Check if lib compiles");
    check.dependOn(&lib.step);
}

fn createGameLib(
    b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    internal: bool,
) *std.Build.Step.Compile {
    const lib = b.addSharedLibrary(.{
        .name = "playground",
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addOptions("build_options", build_options);

    linkGameLibraries(b, lib, target, optimize, internal);

    return lib;
}

fn linkExecutableLibraries(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    obj.root_module.linkLibrary(createSDLLib(b, target, optimize));
}

fn linkGameLibraries(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    internal: bool,
) void {
    obj.root_module.linkLibrary(createSDLLib(b, target, optimize));

    if (internal) {
        const imgui_dep = b.dependency("imgui", .{
            .target = target,
            .optimize = optimize,
        });
        obj.addIncludePath(b.path("src/dcimgui"));
        obj.addIncludePath(imgui_dep.path("."));
        obj.linkLibrary(createImGuiLib(b, target, optimize, imgui_dep));
    }
}

fn createSDLLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
    });

    b.installArtifact(sdl_dep.artifact("SDL3"));

    return sdl_dep.artifact("SDL3");
}

fn createImGuiLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
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
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
    });
    const dcimgui_sdl = b.addStaticLibrary(.{
        .name = "dcimgui_sdl",
        .target = target,
        .optimize = optimize,
    });

    dcimgui_sdl.root_module.link_libcpp = true;
    dcimgui_sdl.addIncludePath(sdl_dep.path("include"));
    dcimgui_sdl.addIncludePath(imgui_dep.path("."));
    dcimgui_sdl.addIncludePath(imgui_dep.path("backends/"));
    dcimgui_sdl.addIncludePath(b.path("src/dcimgui/"));

    const imgui_sources: []const std.Build.LazyPath = &.{
        b.path("src/dcimgui/dcimgui.cpp"),
        imgui_dep.path("imgui.cpp"),
        imgui_dep.path("imgui_demo.cpp"),
        imgui_dep.path("imgui_draw.cpp"),
        imgui_dep.path("imgui_tables.cpp"),
        imgui_dep.path("imgui_widgets.cpp"),
        imgui_dep.path("backends/imgui_impl_sdlrenderer3.cpp"),
        imgui_dep.path("backends/imgui_impl_sdl3.cpp"),
    };

    for (IMGUI_C_DEFINES) |c_define| {
        dcimgui_sdl.root_module.addCMacro(c_define[0], c_define[1]);
    }

    for (imgui_sources) |file| {
        dcimgui_sdl.addCSourceFile(.{
            .file = file,
            .flags = IMGUI_C_FLAGS,
        });
    }

    b.installArtifact(dcimgui_sdl);

    return dcimgui_sdl;
}

fn generateImGuiBindingsStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const imgui_dep = b.dependency("imgui", .{
        .target = target,
        .optimize = optimize,
    });
    const dear_bindings_dep = b.dependency("dear_bindings", .{
        .target = target,
        .optimize = optimize,
    });
    const generate_bindings_step = b.step("generate_imgui_bindings", "Generate C-bindings for imgui");
    const dear_bindings = b.addSystemCommand(&.{
        "python",
        "dear_bindings.py",
    });
    dear_bindings.setCwd(dear_bindings_dep.path("."));
    dear_bindings.addArg("-o");
    dear_bindings.addFileArg(b.path("src/dcimgui/dcimgui"));
    dear_bindings.addFileArg(imgui_dep.path("imgui.h"));
    generate_bindings_step.dependOn(&dear_bindings.step);
}
