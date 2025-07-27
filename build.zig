const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "game";
    const internal = b.option(bool, "internal", "include debug interface") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "internal", internal);
    build_options.addOption([]const u8, "lib_base_name", lib_base_name);

    const test_step = b.step("test", "Run unit tests");
    const exe = buildExecutable(b, b, build_options, target, optimize, test_step);
    b.installArtifact(exe);

    generateImGuiBindingsStep(b, target, optimize);
}

pub fn buildExecutable(
    b: *std.Build,
    client_b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = "gamedev-playground",
        .root_module = module,
    });

    var sdl_mod = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const imgui_mod = b.addModule("imgui", .{
        .root_source_file = b.path("src/imgui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdl", .module = sdl_mod },
        },
    });
    sdl_mod.addIncludePath(getSDLIncludePath(b, target, optimize));
    imgui_mod.addIncludePath(getSDLIncludePath(b, target, optimize));
    exe.root_module.addImport("sdl", sdl_mod);

    linkExeLibraries(b, exe, target, optimize);

    const run_step = client_b.step("run", "Run the app");
    const run_cmd = client_b.addRunArtifact(exe);
    run_cmd.step.dependOn(client_b.getInstallStep());
    if (client_b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const exe_tests = client_b.addTest(.{ .root_module = module });
    const run_exe_tests = client_b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    return exe;
}

fn linkExeLibraries(
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
    obj: *std.Build.Step.Compile,
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
                if (obj.root_module.import_table.get("imgui")) |imgui_mod| {
                    imgui_mod.addIncludePath(b.path("src/dcimgui"));
                    imgui_mod.addIncludePath(imgui_dep.path("."));
                    imgui_mod.linkLibrary(imgui_lib);
                }
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
        .preferred_link_mode = .dynamic,
    })) |sdl_dep| {
        result = sdl_dep.artifact("SDL3");
    }
    return result;
}

pub fn getSDLIncludePath(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) std.Build.LazyPath {
    var result: std.Build.LazyPath = undefined;

    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
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
        .preferred_link_mode = .dynamic,
    })) |sdl_dep| {
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

        imgui_lib = dcimgui_sdl;
    }

    return imgui_lib;
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
