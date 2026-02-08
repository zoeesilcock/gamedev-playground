const std = @import("std");
const playground = @import("playground");
const sdl = playground.sdl.c;
const GameLib = playground.GameLib;
const imgui = if (INTERNAL) playground.imgui else struct {};

const INTERNAL: bool = @import("build_options").internal;
const PLATFORM = @import("builtin").os.tag;
const LIB_BASE_NAME = @import("build_options").lib_base_name;

const LIB_DIRECTORY = if (PLATFORM == .windows) "zig-out/bin/" else "zig-out/lib/";
const LIB_NAME =
    if (PLATFORM == .windows)
        LIB_BASE_NAME ++ ".dll"
    else if (PLATFORM == .macos)
        "lib" ++ LIB_BASE_NAME ++ ".dylib"
    else
        "lib" ++ LIB_BASE_NAME ++ ".so";
const LIB_NAME_RUNTIME = if (PLATFORM == .windows and INTERNAL) LIB_BASE_NAME ++ "_temp.dll" else LIB_NAME;
const WINDOW_DECORATIONS_WIDTH = if (PLATFORM == .windows) 0 else 0;
const WINDOW_DECORATIONS_HEIGHT = if (PLATFORM == .windows) 31 else 0;

var game: GameLib = .{};
var opt_dyn_lib: ?std.DynLib = null;
var build_process: ?std.process.Child = null;
var dyn_lib_last_modified: i128 = 0;
var src_last_modified: i128 = 0;
var assets_last_modified: i128 = 0;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    loadDll() catch |err| {
        std.log.err("Failed to load the game DLL.", .{});
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
    const window = playground.sdl.panicIfNull(sdl.SDL_CreateWindow(
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
            game_renderer = playground.sdl.panicIfNull(
                sdl.SDL_CreateRenderer(window.?, null),
                "Failed to create renderer.",
            );
        },
        .Full3D => {
            game_gpu_device = playground.sdl.panicIfNull(sdl.SDL_CreateGPUDevice(
                sdl.SDL_GPU_SHADERFORMAT_SPIRV |
                    sdl.SDL_GPU_SHADERFORMAT_DXIL |
                    sdl.SDL_GPU_SHADERFORMAT_MSL |
                    sdl.SDL_GPU_SHADERFORMAT_METALLIB,
                true,
                null,
            ), "Failed to create GPU device");
            playground.sdl.panic(
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
            .output = internal_allocator.create(playground.internal.DebugOutputWindow) catch
                @panic("Out of memory."),
            .fps_window = internal_allocator.create(playground.internal.FPSWindow) catch
                @panic("Failed to allocate FPS state."),
        };

        internal_dependencies.output.init();
        internal_dependencies.fps_window.init(sdl.SDL_GetPerformanceFrequency());

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
                .window = window.?,
                .renderer = game_renderer.?,
                .internal = internal_dependencies,
            };

            state = game.initFull2D(dependencies);
        },
        .Full3D => {
            const dependencies: GameLib.Dependencies.Full3D = .{
                .allocator = &game_allocator,
                .window = window.?,
                .gpu_device = game_gpu_device.?,
                .internal = internal_dependencies,
            };

            state = game.initFull3D(dependencies);
        },
    }

    if (INTERNAL) {
        initChangeTimes(allocator);
    }

    var previous_frame_start_time: u64 = 0;
    var frame_start_time: u64 = 0;
    var frame_elapsed_time: u64 = 0;
    while (true) {
        frame_start_time = sdl.SDL_GetTicks();
        const delta_time = frame_start_time - previous_frame_start_time;

        if (INTERNAL) {
            const assetsChanged = assetsHaveChanged(allocator);
            const dllChanged = dllHasChanged();

            if (dllChanged or assetsChanged) {
                game.willReload(state);

                if (dllChanged) {
                    if (manage_imgui_lifecycle) {
                        imgui.deinit();
                    }

                    unloadDll() catch unreachable;
                    loadDll() catch @panic("Failed to load the game lib.");

                    if (manage_imgui_lifecycle) {
                        std.log.warn("init on change", .{});
                        initImgui(window.?, game_renderer, game_gpu_device, game_settings);
                    }
                }

                game.reloaded(state, imgui.context);
            }
        }

        if (!game.processInput(state)) {
            break;
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

fn initChangeTimes(allocator: std.mem.Allocator) void {
    _ = dllHasChanged();
    _ = assetsHaveChanged(allocator);
}

fn dllHasChanged() bool {
    var result = false;
    const stat = std.fs.cwd().statFile(LIB_DIRECTORY ++ LIB_NAME) catch return false;
    if (stat.mtime > dyn_lib_last_modified) {
        dyn_lib_last_modified = stat.mtime;
        result = true;
    }
    return result;
}

fn assetsHaveChanged(allocator: std.mem.Allocator) bool {
    return checkForChangesInDirectory(allocator, "assets", &assets_last_modified) catch false;
}

fn checkForChangesInDirectory(allocator: std.mem.Allocator, path: []const u8, last_change: *i128) !bool {
    var result = false;

    var assets = try std.fs.cwd().openDir(path, .{ .access_sub_paths = true, .iterate = true });
    defer assets.close();

    var walker = try assets.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const stat = try assets.statFile(entry.path);
            if (stat.mtime > last_change.*) {
                last_change.* = stat.mtime;
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

fn loadDll() !void {
    if (opt_dyn_lib != null) return error.AlreadyLoaded;

    if (INTERNAL and PLATFORM == .windows) {
        var output = try std.fs.cwd().openDir(LIB_DIRECTORY, .{});
        try output.copyFile(LIB_NAME, output, LIB_NAME_RUNTIME, .{});
    }

    opt_dyn_lib = std.DynLib.open(LIB_DIRECTORY ++ LIB_NAME_RUNTIME) catch null;
    if (opt_dyn_lib == null) {
        std.log.info("Failed to load DLL from first location ({s}).", .{LIB_DIRECTORY ++ LIB_NAME_RUNTIME});
        opt_dyn_lib = std.DynLib.open(LIB_NAME_RUNTIME) catch {
            std.log.err("Failed to load DLL from secondary location ({s}).", .{LIB_NAME_RUNTIME});
            return error.OpenFail;
        };
    }

    if (opt_dyn_lib) |*dyn_lib| {
        try game.load(dyn_lib);
    }

    std.log.info("Game DLL loaded.", .{});
}
