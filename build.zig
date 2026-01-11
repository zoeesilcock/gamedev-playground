const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "game";
    const internal = b.option(bool, "internal", "include debug interface") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "internal", internal);
    build_options.addOption([]const u8, "lib_base_name", lib_base_name);

    // Exposed module.
    const playground_mod = b.addModule("playground", .{
        .root_source_file = b.path("src/lib/playground.zig"),
        .target = target,
        .optimize = optimize,
    });
    playground_mod.addOptions("build_options", build_options);
    if (getSDLIncludePath(b, target, optimize)) |sdl_include_path| {
        playground_mod.addIncludePath(sdl_include_path);
    }
    linkImgui(b, playground_mod, target, optimize, internal);

    // Main executable.
    const exe = buildExecutable(b, b, "gamedev-playground", build_options, target, optimize, playground_mod);
    b.installArtifact(exe);

    // Tests.
    const test_step = b.step("test", "Run unit tests");

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    const lib_tests = b.addTest(.{ .root_module = playground_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Docs.
    const docs = b.addObject(.{
        .name = "playground",
        .root_module = playground_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}

pub fn buildExecutable(
    b: *std.Build,
    client_b: *std.Build,
    name: []const u8,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    playground_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "playground", .module = playground_mod },
        },
    });
    module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });

    linkSDL(b, exe, target, optimize);

    const run_step = client_b.step("run", "Run the app");
    const run_cmd = client_b.addRunArtifact(exe);
    run_cmd.step.dependOn(client_b.getInstallStep());
    if (client_b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    return exe;
}

pub fn linkSDL(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (getSDL(b, target, optimize)) |sdl_lib| {
        obj.root_module.linkLibrary(sdl_lib);
        b.installArtifact(sdl_lib);
    }
}

pub fn linkImgui(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    internal: bool,
) void {
    if (internal) {
        if (b.lazyDependency("imgui", .{
            .target = target,
            .optimize = optimize,
        })) |imgui_dep| {
            if (createImGuiLib(b, target, optimize, imgui_dep)) |imgui_lib| {
                module.addIncludePath(b.path("src/lib/dcimgui"));
                module.addIncludePath(imgui_dep.path("."));
                module.linkLibrary(imgui_lib);
            }
        }
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

fn createImGuiLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
) ?*std.Build.Step.Compile {
    var imgui_lib: ?*std.Build.Step.Compile = null;
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
            dcimgui_sdl.addIncludePath(sdl_dep.path("include"));
            dcimgui_sdl.addIncludePath(imgui_dep.path(""));
            dcimgui_sdl.addIncludePath(imgui_dep.path("backends/"));
            dcimgui_sdl.addIncludePath(dear_bindings_dep.path(""));
            dcimgui_sdl.installHeadersDirectory(
                dear_bindings_dep.path(""),
                "",
                .{ .include_extensions = &.{".h"} },
            );

            const imgui_sources: []const std.Build.LazyPath = &.{
                dear_bindings_dep.path("dcimgui.cpp"),
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
                dcimgui_sdl.addCSourceFile(.{
                    .file = file,
                    .flags = IMGUI_C_FLAGS,
                });
            }

            b.installArtifact(dcimgui_sdl);

            imgui_lib = dcimgui_sdl;
        }
    }

    return imgui_lib;
}
