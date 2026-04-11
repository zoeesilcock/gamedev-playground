const std = @import("std");
const flint = @import("flint");
const sdl = flint.sdl.c;
const GameLib = flint.GameLib;
const imgui = if (INTERNAL) flint.imgui else struct {};

const INTERNAL: bool = @import("build_options").internal;
const PLATFORM = @import("builtin").os.tag;
const LIB_BASE_NAME = @import("build_options").name;

const LIB_DEV_DIRECTORY = if (PLATFORM == .windows) "zig-out/bin/" else "zig-out/lib/";
const LIB_NAME =
    if (PLATFORM == .windows)
        LIB_BASE_NAME ++ ".dll"
    else if (PLATFORM == .macos)
        "lib" ++ LIB_BASE_NAME ++ ".dylib"
    else
        "lib" ++ LIB_BASE_NAME ++ ".so";

const WINDOW_DECORATIONS_WIDTH = if (PLATFORM == .windows) 0 else 0;
const WINDOW_DECORATIONS_HEIGHT = if (PLATFORM == .windows) 31 else 0;

var game: GameLib = .{};
var opt_dyn_lib: ?std.DynLib = null;
var build_process: ?std.process.Child = null;
var dyn_lib_last_modified: i128 = 0;
var src_last_modified: i128 = 0;
var assets_last_modified: i128 = 0;
var code_last_modified: i128 = 0;

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    loadDll(init.io) catch |err| {
        std.log.err("Failed to load the game library. Error: {t}", .{err});
        return err;
    };

    const game_settings: GameLib.Settings = game.getSettings();
    const target_frame_time: u64 = @intFromFloat(1000 / @as(f32, @floatFromInt(game_settings.target_frame_rate)));

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) {
        @panic("SDL_Init failed.");
    }

    var window_flags: sdl.SDL_WindowFlags = 0;
    if (game_settings.fullscreen) window_flags |= sdl.SDL_WINDOW_FULLSCREEN;
    if (game_settings.window_on_top) window_flags |= sdl.SDL_WINDOW_ALWAYS_ON_TOP;
    const window = flint.sdl.panicIfNull(sdl.SDL_CreateWindow(
        game_settings.title,
        @intCast(game_settings.window_width),
        @intCast(game_settings.window_height),
        window_flags,
    ), "Failed to create window.");

    if (INTERNAL) {
        var num_displays: i32 = 0;
        const displays = sdl.SDL_GetDisplays(&num_displays);
        if (num_displays > 0) {
            const display_mode = sdl.SDL_GetCurrentDisplayMode(displays[0]);
            const window_offset_x: c_int = WINDOW_DECORATIONS_WIDTH;
            const window_offset_y: c_int = WINDOW_DECORATIONS_HEIGHT;

            _ = sdl.SDL_SetWindowPosition(
                window,
                display_mode[0].w - @as(c_int, @intCast(game_settings.window_width)) - window_offset_x,
                window_offset_y,
            );
        }
    }

    var game_renderer: ?*sdl.SDL_Renderer = null;
    var game_gpu_device: ?*sdl.SDL_GPUDevice = null;
    var backing_allocator = std.heap.page_allocator;
    var state: GameLib.GameStatePtr = undefined;
    var manage_imgui_lifecycle: bool = false;
    var internal_dependencies: GameLib.Dependencies.Internal = undefined;
    var memory_usage_window: ?*flint.internal.MemoryUsageWindow = null;

    // Prepare dependencies.
    const game_gpa = backing_allocator.create(GameLib.DebugAllocator) catch
        @panic("Failed to initialize game allocator.");
    game_gpa.* = .init;
    var game_allocator: std.mem.Allocator = game_gpa.allocator();

    switch (game_settings.dependencies) {
        .Minimal => {
            // Nothing needs to be done here.
        },
        .Full2D => {
            game_renderer = flint.sdl.panicIfNull(
                sdl.SDL_CreateRenderer(window.?, null),
                "Failed to create renderer.",
            );
        },
        .Full3D => {
            game_gpu_device = flint.sdl.panicIfNull(sdl.SDL_CreateGPUDevice(
                sdl.SDL_GPU_SHADERFORMAT_SPIRV |
                    sdl.SDL_GPU_SHADERFORMAT_DXIL |
                    sdl.SDL_GPU_SHADERFORMAT_MSL |
                    sdl.SDL_GPU_SHADERFORMAT_METALLIB,
                true,
                null,
            ), "Failed to create GPU device");
            flint.sdl.panic(
                sdl.SDL_ClaimWindowForGPUDevice(game_gpu_device, window),
                "Failed to claim window for GPU device.",
            );
        },
    }

    if (INTERNAL and game_settings.dependencies.batteriesIncluded()) {
        const internal_gpa = (backing_allocator.create(GameLib.DebugAllocator) catch
            @panic("Failed to initialize game allocator."));
        internal_gpa.* = .init;
        var internal_allocator: std.mem.Allocator = internal_gpa.allocator();

        internal_dependencies = .{
            .allocator = &internal_allocator,
            .output = internal_allocator.create(flint.internal.DebugOutputWindow) catch
                @panic("Failed to allocate DebugOutputWindow."),
            .fps_window = internal_allocator.create(flint.internal.FPSWindow) catch
                @panic("Failed to allocate FPSWindow."),
            .memory_usage_window = internal_allocator.create(flint.internal.MemoryUsageWindow) catch
                @panic("Failed to allocate MemoryUsageWindow."),
        };

        internal_dependencies.output.init();
        internal_dependencies.fps_window.init(sdl.SDL_GetPerformanceFrequency());

        internal_dependencies.memory_usage_window.init();
        memory_usage_window = internal_dependencies.memory_usage_window;

        manage_imgui_lifecycle = true;
        initImgui(window.?, game_renderer, game_gpu_device, game_settings);
        internal_dependencies.imgui_context = imgui.context.?;
    }

    // Init game with the requested dependencies.
    switch (game_settings.dependencies) {
        .Minimal => {
            state = game.initMinimal(.{
                .window = window.?,
            });
        },
        .Full2D => {
            const dependencies: GameLib.Dependencies.Full2D = .{
                .allocator = &game_allocator,
                .io = &init.io,
                .window = window.?,
                .renderer = game_renderer.?,
                .internal = internal_dependencies,
            };

            state = game.initFull2D(dependencies);
        },
        .Full3D => {
            const dependencies: GameLib.Dependencies.Full3D = .{
                .allocator = &game_allocator,
                .io = &init.io,
                .window = window.?,
                .gpu_device = game_gpu_device.?,
                .internal = internal_dependencies,
            };

            state = game.initFull3D(dependencies);
        },
    }

    if (INTERNAL) {
        initChangeTimes(allocator, init.io);
    }

    var previous_frame_start_time: u64 = 0;
    var frame_start_time: u64 = 0;
    var frame_elapsed_time: u64 = 0;
    while (true) {
        frame_start_time = sdl.SDL_GetTicks();
        const delta_time = frame_start_time - previous_frame_start_time;

        if (INTERNAL) {
            const assets_changed = assetsHaveChanged(allocator, init.io);
            const code_changed = codeHasChanged(allocator, init.io);
            const dll_changed = dllHasChanged(init.io);

            if (code_changed) {
                std.log.info("Code changed, rebuilding game library...", .{});
                _ = try std.process.run(allocator, init.io, .{ .argv = &.{ "zig", "build", "-Dlib_only" } });
            }

            if (dll_changed or assets_changed) {
                game.willReload(state);

                if (dll_changed) {
                    if (manage_imgui_lifecycle) {
                        imgui.deinit();
                    }

                    unloadDll() catch unreachable;
                    loadDll(init.io) catch @panic("Failed to load the game lib.");

                    if (manage_imgui_lifecycle) {
                        initImgui(window.?, game_renderer, game_gpu_device, game_settings);
                    }
                }

                // TODO: This is a workaround for a bug that happens when dealing with large Aseprite files where the
                // file is incomplete when read too soon after saving changes to it. This may need to be tuned to
                // handle bigger files, and would be more robust if we could know when the file was ready for reading.
                try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);

                game.reloaded(state, imgui.context);
            }
        }

        if (!game.processInput(state)) {
            break;
        }

        if (INTERNAL) {
            if (memory_usage_window) |memory_usage| {
                memory_usage.recordMemoryUsage(frame_start_time, game_gpa);
            }
        }

        game.tick(state, frame_start_time, delta_time);
        game.draw(state);

        frame_elapsed_time = sdl.SDL_GetTicks() - frame_start_time;

        if (!INTERNAL) {
            if (frame_elapsed_time < target_frame_time) {
                sdl.SDL_Delay(@intCast(target_frame_time - frame_elapsed_time));
            }
        }
        previous_frame_start_time = frame_start_time;
    }

    game.deinit(state);

    if (INTERNAL and manage_imgui_lifecycle) {
        imgui.deinit();
    }

    if (game_gpu_device) |gpu_device| {
        sdl.SDL_ReleaseWindowFromGPUDevice(gpu_device, window);
        sdl.SDL_DestroyGPUDevice(gpu_device);
    }

    if (game_renderer) |renderer| {
        sdl.SDL_DestroyRenderer(renderer);
    }

    sdl.SDL_DestroyWindow(window);
    sdl.SDL_Quit();

    if (INTERNAL) {
        _ = debug_allocator.detectLeaks();
    }
}

fn initImgui(
    window: *sdl.SDL_Window,
    game_renderer: ?*sdl.SDL_Renderer,
    game_gpu_device: ?*sdl.SDL_GPUDevice,
    game_settings: GameLib.Settings,
) void {
    if (game_renderer) |renderer| {
        imgui.init(
            window,
            renderer,
            @floatFromInt(game_settings.window_width),
            @floatFromInt(game_settings.window_height),
        );
    } else if (game_gpu_device) |gpu_device| {
        imgui.initGPU(
            window,
            gpu_device,
            @floatFromInt(game_settings.window_width),
            @floatFromInt(game_settings.window_height),
        );
    }
}

fn initChangeTimes(allocator: std.mem.Allocator, io: std.Io) void {
    _ = dllHasChanged(io);
    _ = assetsHaveChanged(allocator, io);
    _ = codeHasChanged(allocator, io);
}

fn dllHasChanged(io: std.Io) bool {
    var result = false;
    const stat = std.Io.Dir.cwd().statFile(io, LIB_DEV_DIRECTORY ++ LIB_NAME, .{}) catch return false;
        result = true;
    }
    return result;
}

fn assetsHaveChanged(allocator: std.mem.Allocator, io: std.Io) bool {
    return checkForChangesInDirectory(allocator, io, "assets", &assets_last_modified) catch false;
}

fn codeHasChanged(allocator: std.mem.Allocator, io: std.Io) bool {
    return checkForChangesInDirectory(allocator, io, "src", &code_last_modified) catch false;
}

fn checkForChangesInDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8, last_change: *i128) !bool {
    var result = false;

    var directory = try flint.fs.openDirRelative(io, path, .{ .access_sub_paths = true, .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) {
            const stat = try directory.statFile(io, entry.path, .{});
                result = true;
                break;
            }
        }
    }

    return result;
}

fn unloadDll() !void {
    if (opt_dyn_lib) |*dyn_lib| {
        dyn_lib.close();
        opt_dyn_lib = null;
    } else {
        return error.AlreadyUnloaded;
    }
}

fn loadDll(io: std.Io) !void {
    if (opt_dyn_lib != null) return error.AlreadyLoaded;

    var lib_name: []const u8 = LIB_NAME;

    // For hot reloading the game library to work on Windows we need to load a copy of the library,
    // otherwise the zig build wouldn't be allowed to overwrite the .dll file.
    if (INTERNAL and PLATFORM == .windows) {
        // Only make a copy of the library if we are in the dev directory (zig-out/bin/ on Windows).
        if (flint.fs.fileExists(io, LIB_DEV_DIRECTORY ++ LIB_NAME)) {
            const temp_copy_name: []const u8 = LIB_BASE_NAME ++ "_temp.dll";
            var dev_directory = try std.fs.cwd().openDir(LIB_DEV_DIRECTORY, .{});
            try dev_directory.copyFile(LIB_NAME, dev_directory, temp_copy_name, .{});
            lib_name = temp_copy_name;
        }
    }

    var buffer: [1024]u8 = undefined;
    var lib_path: []const u8 = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ LIB_DEV_DIRECTORY, lib_name });

    // Try to load the game library from the dev directory.
    opt_dyn_lib = std.DynLib.open(lib_path) catch null;
    if (opt_dyn_lib != null) {
        std.log.info("Loading game library ({s}).", .{lib_path});
    }

    if (opt_dyn_lib == null) {
        // Try to load the game library from the current working directory.
        lib_path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ "./", lib_name });
        opt_dyn_lib = std.DynLib.open(lib_path) catch null;
        if (opt_dyn_lib != null) {
            std.log.info("Loading game library ({s}).", .{lib_path});
        }
    }

    if (opt_dyn_lib == null) {
        // Try to load the game library from the "lib" directory in the current working directory.
        lib_path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ "./lib/", lib_name });
        opt_dyn_lib = std.DynLib.open(lib_path) catch null;
        if (opt_dyn_lib != null) {
            std.log.info("Loading game library ({s}).", .{lib_path});
        }
    }

    if (opt_dyn_lib) |*dyn_lib| {
        try game.load(dyn_lib);
    } else {
        return error.LibraryNotFound;
    }
}
