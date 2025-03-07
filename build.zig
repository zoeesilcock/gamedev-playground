const std = @import("std");

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

    linkGameLibraries(b, lib, target, optimize, internal);
    linkGameLibraries(b, lib_unit_tests, target, optimize, internal);

    b.installArtifact(lib);

    const lib_check = b.addSharedLibrary(.{
        .name = "playground",
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkGameLibraries(b, lib_check, target, optimize, internal);
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
    internal: bool,
) void {
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
    });
    obj.root_module.linkLibrary(sdl_dep.artifact("SDL3"));

    if (internal) {
        const imgui_dep = b.dependency("imgui", .{
            .target = target,
            .optimize = optimize,
        });

        obj.addIncludePath(b.path("src/dcimgui"));
        obj.addIncludePath(imgui_dep.path("."));

        const imgui = createImGuiLib(b, target, optimize, imgui_dep);
        const imgui_sdl = createImGuiSDLLib(b, target, optimize, sdl_dep, imgui_dep, imgui);
        obj.linkLibrary(imgui_sdl);
    }
}

pub const IMGUI_C_DEFINES: []const [2][]const u8 = &.{
    .{ "IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1" },
    .{ "IMGUI_DISABLE_OBSOLETE_KEYIO", "1" },
    .{ "IMGUI_IMPL_API", "extern \"C\"" },
    .{ "IMGUI_USE_WCHAR32", "1" },
    .{ "ImTextureID", "ImU64" },
};

pub const IMGUI_C_FLAGS: []const []const u8 = &.{
    "-std=c++11",
    "-fvisibility=hidden",
};

fn createImGuiLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const dcimgui = b.addStaticLibrary(.{
        .name = "dcimgui",
        .target = target,
        .optimize = optimize,
    });
    dcimgui.root_module.link_libcpp = true;

    const imgui_sources: []const std.Build.LazyPath = &.{
        b.path("src/dcimgui/dcimgui.cpp"),
        imgui_dep.path("imgui.cpp"),
        imgui_dep.path("imgui_demo.cpp"),
        imgui_dep.path("imgui_draw.cpp"),
        imgui_dep.path("imgui_tables.cpp"),
        imgui_dep.path("imgui_widgets.cpp"),
    };

    for (IMGUI_C_DEFINES) |c_define| {
        dcimgui.root_module.addCMacro(c_define[0], c_define[1]);
    }
    dcimgui.addIncludePath(b.path("src/dcimgui/"));
    dcimgui.addIncludePath(imgui_dep.path("."));

    for (imgui_sources) |file| {
        dcimgui.addCSourceFile(.{
            .file = file,
            .flags = IMGUI_C_FLAGS,
        });
    }

    return dcimgui;
}

fn createImGuiSDLLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl_dep: *std.Build.Dependency,
    imgui_dep: *std.Build.Dependency,
    dcimgui: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const imgui_sdl = b.addStaticLibrary(.{
        .name = "imgui_sdl",
        .target = target,
        .optimize = optimize,
    });
    imgui_sdl.root_module.link_libcpp = true;
    imgui_sdl.linkLibrary(dcimgui);

    for (IMGUI_C_DEFINES) |c_define| {
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
        .flags = IMGUI_C_FLAGS,
    });
    imgui_sdl.addCSourceFile(.{
        .file = imgui_dep.path("backends/imgui_impl_sdl3.cpp"),
        .flags = IMGUI_C_FLAGS,
    });

    return imgui_sdl;
}
