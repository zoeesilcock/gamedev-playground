const std = @import("std");

const Example = enum {
    diamonds,
    cube,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
    const internal = b.option(bool, "internal", "include debug interface") orelse true;
    const log_allocations = b.option(bool, "log_allocations", "log all allocations") orelse false;
    const example: Example = b.option(Example, "example", "which example to build") orelse .diamonds;

    const build_options = b.addOptions();
    build_options.addOption(bool, "internal", internal);
    build_options.addOption(bool, "log_allocations", log_allocations);
    build_options.addOption(Example, "example", example);

    const test_step = b.step("test", "Run unit tests");

    if (!lib_only) {
        buildExecutable(b, build_options, target, optimize, test_step, internal);
    }

    try buildGameLib(b, build_options, target, optimize, test_step, internal, example);
    try checkGameLibStep(b, build_options, target, optimize, internal, example);

    generateImGuiBindingsStep(b, target, optimize);
}

fn buildExecutable(
    b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    internal: bool,
) void {
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

    if (optimize == .Debug) {
        linkExeOnlyLibraries(b, exe, target, optimize);
    } else {
        linkGameLibraries(b, exe, target, optimize, internal);
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = module });
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
    example: Example,
) !void {
    const lib = try createGameLib(b, build_options, target, optimize, internal, example);

    if (optimize == .Debug) {
        b.installArtifact(lib);
    }

    const lib_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}

fn checkGameLibStep(
    b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    internal: bool,
    example: Example,
) !void {
    const lib = try createGameLib(b, build_options, target, optimize, internal, example);

    const check = b.step("check", "Check if lib compiles");
    check.dependOn(&lib.step);
}

fn createGameLib(
    b: *std.Build,
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    internal: bool,
    example: Example,
) !*std.Build.Step.Compile {
    var buf: [64]u8 = undefined;
    const example_name = @tagName(example);
    const module = b.createModule(.{
        .root_source_file = b.path(try std.fmt.bufPrint(&buf, "src/examples/{s}/root.zig", .{example_name})),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", build_options);

    const aseprite_module = b.createModule(.{
        .root_source_file = b.path("src/aseprite.zig"),
        .target = target,
        .optimize = optimize,
    });
    const imgui_module = b.createModule(.{
        .root_source_file = b.path("src/imgui.zig"),
        .target = target,
        .optimize = optimize,
    });
    const logging_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/internal/logging_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const math_module = b.createModule(.{
        .root_source_file = b.path("src/math.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pool_module = b.createModule(.{
        .root_source_file = b.path("src/pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addImport("math", math_module);
    module.addImport("imgui", imgui_module);
    module.addImport("logging_allocator", logging_allocator_module);
    if (example == .diamonds) {
        module.addImport("aseprite", aseprite_module);
        module.addImport("pool", pool_module);
    }

    const lib_name = try std.fmt.bufPrint(&buf, "playground-{s}", .{example_name});
    const lib = b.addSharedLibrary(.{
        .name = lib_name,
        .root_module = module,
    });

    linkGameLibraries(b, lib, target, optimize, internal);

    return lib;
}

fn linkExeOnlyLibraries(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (createSDLLib(b, target, optimize)) |sdl_lib| {
        obj.root_module.linkLibrary(sdl_lib);
    }
}

fn linkGameLibraries(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    internal: bool,
) void {
    if (createSDLLib(b, target, optimize)) |sdl_lib| {
        obj.root_module.linkLibrary(sdl_lib);

        obj.root_module.import_table.get("imgui").?.linkLibrary(sdl_lib);
        obj.root_module.import_table.get("math").?.linkLibrary(sdl_lib);
    }

    if (internal) {
        if (b.lazyDependency("imgui", .{
            .target = target,
            .optimize = optimize,
        })) |imgui_dep| {
            obj.addIncludePath(b.path("src/dcimgui"));
            obj.addIncludePath(imgui_dep.path("."));

            obj.root_module.import_table.get("imgui").?.addIncludePath(b.path("src/dcimgui"));
            obj.root_module.import_table.get("imgui").?.addIncludePath(imgui_dep.path("."));

            // TODO: This is required to make the C imports of SDL in math compatible with debug, but why?
            obj.root_module.import_table.get("math").?.addIncludePath(b.path("src/dcimgui"));
            obj.root_module.import_table.get("math").?.addIncludePath(imgui_dep.path("."));

            if (createImGuiLib(b, target, optimize, imgui_dep)) |imgui_lib| {
                obj.linkLibrary(imgui_lib);
                obj.root_module.import_table.get("imgui").?.linkLibrary(imgui_lib);

                // TODO: This is required to make the C imports of SDL in math compatible with debug, but why?
                obj.root_module.import_table.get("math").?.linkLibrary(imgui_lib);
            }
        }
    }
}

fn createSDLLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    var sdl_lib: ?*std.Build.Step.Compile = null;

    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .dynamic,
    })) |sdl_dep| {
        b.installArtifact(sdl_dep.artifact("SDL3"));
        sdl_lib = sdl_dep.artifact("SDL3");
    }

    return sdl_lib;
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
