const std = @import("std");
const sdl = @import("sdl").c;

const DEBUG = @import("builtin").mode == std.builtin.OptimizeMode.Debug;
const PLATFORM = @import("builtin").os.tag;
const LIB_BASE_NAME = @import("build_options").lib_base_name;

const LIB_DIRECTORY = if (PLATFORM == .windows) "zig-out/bin/" else "zig-out/lib/";
const LIB_NAME = if (PLATFORM == .windows) LIB_BASE_NAME ++ ".dll" else "lib" ++ LIB_BASE_NAME ++ ".dylib";
const LIB_NAME_RUNTIME = if (PLATFORM == .windows and DEBUG) LIB_BASE_NAME ++ "_temp.dll" else LIB_NAME;

const WINDOW_WIDTH = if (DEBUG) 800 else 1600;
const WINDOW_HEIGHT = if (DEBUG) 600 else 1200;
const WINDOW_DECORATIONS_WIDTH = if (PLATFORM == .windows) 0 else 0;
const WINDOW_DECORATIONS_HEIGHT = if (PLATFORM == .windows) 31 else 0;
const TARGET_FPS = 120;
const TARGET_FRAME_TIME: f32 = 1000 / TARGET_FPS;

const GameStatePtr = *anyopaque;

var opt_dyn_lib: ?std.DynLib = null;
var build_process: ?std.process.Child = null;
var dyn_lib_last_modified: i128 = 0;
var src_last_modified: i128 = 0;
var assets_last_modified: i128 = 0;

var gameInit: *const fn (u32, u32, *sdl.SDL_Window) callconv(.c) GameStatePtr = undefined;
var gameDeinit: *const fn (GameStatePtr) callconv(.c) void = undefined;
var gameWillReload: *const fn (GameStatePtr) callconv(.c) void = undefined;
var gameReloaded: *const fn (GameStatePtr) callconv(.c) void = undefined;
var gameProcessInput: *const fn (GameStatePtr) callconv(.c) bool = undefined;
var gameTick: *const fn (GameStatePtr) callconv(.c) void = undefined;
var gameDraw: *const fn (GameStatePtr) callconv(.c) void = undefined;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) {
        @panic("SDL_Init failed.");
    }

    const window = sdl.SDL_CreateWindow("Playground", WINDOW_WIDTH, WINDOW_HEIGHT, 0);
    if (window == null) {
        @panic("Failed to create window.");
    }

    if (DEBUG) {
        var num_displays: i32 = 0;
        const displays = sdl.SDL_GetDisplays(&num_displays);
        if (num_displays > 0) {
            const display_mode = sdl.SDL_GetCurrentDisplayMode(displays[0]);
            const window_offset_x: c_int = WINDOW_DECORATIONS_WIDTH;
            const window_offset_y: c_int = WINDOW_DECORATIONS_HEIGHT;

            _ = sdl.SDL_SetWindowPosition(window, display_mode[0].w - WINDOW_WIDTH - window_offset_x, window_offset_y);
        }
        _ = sdl.SDL_SetWindowAlwaysOnTop(window, true);
    }

    loadDll() catch |err| {
        std.log.err("Failed to load the game DLL.", .{});
        return err;
    };

    const state = gameInit(WINDOW_WIDTH, WINDOW_HEIGHT, window.?);

    if (DEBUG) {
        initChangeTimes(allocator);
    }

    var frame_start_time: u64 = 0;
    var frame_elapsed_time: u64 = 0;
    while (true) {
        frame_start_time = sdl.SDL_GetTicks();

        if (DEBUG) {
            checkForChanges(state, allocator);
        }

        if (!gameProcessInput(state)) {
            break;
        }

        gameTick(state);
        gameDraw(state);

        frame_elapsed_time = sdl.SDL_GetTicks() - frame_start_time;

        if (!DEBUG) {
            if (frame_elapsed_time < TARGET_FRAME_TIME) {
                sdl.SDL_Delay(@intFromFloat(TARGET_FRAME_TIME - @as(f32, @floatFromInt(frame_elapsed_time))));
            }
        }
    }

    gameDeinit(state);

    sdl.SDL_DestroyWindow(window);
    sdl.SDL_Quit();

    if (DEBUG) {
        _ = debug_allocator.detectLeaks();
    }
}

fn initChangeTimes(allocator: std.mem.Allocator) void {
    _ = dllHasChanged();
    _ = assetsHaveChanged(allocator);
}

fn checkForChanges(state: GameStatePtr, allocator: std.mem.Allocator) void {
    const assetsChanged = assetsHaveChanged(allocator);
    if (dllHasChanged()) {
        gameWillReload(state);

        unloadDll() catch unreachable;
        loadDll() catch @panic("Failed to load the game lib.");

        gameReloaded(state);
    } else if (assetsChanged) {
        gameWillReload(state);
        gameReloaded(state);
    }
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

    if (DEBUG and PLATFORM == .windows) {
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
        gameInit = dyn_lib.lookup(@TypeOf(gameInit), "init") orelse return error.LookupFail;
        gameDeinit = dyn_lib.lookup(@TypeOf(gameDeinit), "deinit") orelse return error.LookupFail;
        gameWillReload = dyn_lib.lookup(@TypeOf(gameWillReload), "willReload") orelse return error.LookupFail;
        gameReloaded = dyn_lib.lookup(@TypeOf(gameReloaded), "reloaded") orelse return error.LookupFail;
        gameProcessInput = dyn_lib.lookup(@TypeOf(gameProcessInput), "processInput") orelse return error.LookupFail;
        gameTick = dyn_lib.lookup(@TypeOf(gameTick), "tick") orelse return error.LookupFail;
        gameDraw = dyn_lib.lookup(@TypeOf(gameDraw), "draw") orelse return error.LookupFail;
    }

    std.log.info("Game DLL loaded.", .{});
}
