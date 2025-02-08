const std = @import("std");

const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

const DEBUG = @import("builtin").mode == std.builtin.OptimizeMode.Debug;
const PLATFORM = @import("builtin").os.tag;

const LIB_OUTPUT_DIR = if (PLATFORM == .windows) "zig-out/bin/" else "zig-out/lib/";
const LIB_PATH = if (PLATFORM == .windows) "zig-out/bin/playground.dll" else "zig-out/lib/libplayground.dylib";
const LIB_PATH_RUNTIME = if (PLATFORM == .windows) "zig-out/bin/playground_temp.dll" else LIB_PATH;

const WINDOW_WIDTH = if (DEBUG) 800 else 1200;
const WINDOW_HEIGHT = if (DEBUG) 600 else 800;
const WINDOW_DECORATIONS_WIDTH = if (PLATFORM == .windows) 16 else 0;
const WINDOW_DECORATIONS_HEIGHT = if (PLATFORM == .windows) 39 else 0;
const TARGET_FPS = 120;
const TARGET_FRAME_TIME = 1000 / TARGET_FPS;

const GameStatePtr = *anyopaque;

var opt_dyn_lib: ?std.DynLib = null;
var build_process: ?std.process.Child = null;
var dyn_lib_last_modified: i128 = 0;
var src_last_modified: i128 = 0;
var assets_last_modified: i128 = 0;

var gameInit: *const fn (u32, u32, *c.SDL_Window, *c.SDL_Renderer) GameStatePtr = undefined;
var gameDeinit: *const fn () void = undefined;
var gameWillReload: *const fn (GameStatePtr) void = undefined;
var gameReloaded: *const fn (GameStatePtr) void = undefined;
var gameProcessInput: *const fn (GameStatePtr) bool = undefined;
var gameTick: *const fn (GameStatePtr) void = undefined;
var gameDraw: *const fn (GameStatePtr) void = undefined;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
        std.log.debug("SDL_Init failed", .{});
        return;
    }

    const window = c.SDL_CreateWindow("Playground", WINDOW_WIDTH, WINDOW_HEIGHT, 0);
    const renderer = c.SDL_CreateRenderer(window, null);

    if (window == null or renderer == null) {
        std.log.debug("Failed to create window", .{});
    }

    if (DEBUG) {
        var num_displays: i32 = 0;
        const displays = c.SDL_GetDisplays(&num_displays);
        if (num_displays > 0) {
            const display_mode = c.SDL_GetCurrentDisplayMode(displays[0]);
            const window_offset_x: c_int = 12;
            const window_offset_y: c_int = 12 + WINDOW_DECORATIONS_HEIGHT;

            _ = c.SDL_SetWindowPosition(window, display_mode[0].w - WINDOW_WIDTH - window_offset_x, window_offset_y);
        }
        _ = c.SDL_SetWindowAlwaysOnTop(window, true);
    }

    loadDll() catch @panic("Failed to load the game lib.");
    const state = gameInit(WINDOW_WIDTH, WINDOW_HEIGHT, window.?, renderer.?);
    initChangeTimes(allocator);

    var frame_start_time: u64 = 0;
    var frame_elapsed_time: u64 = 0;
    while (true) {
        frame_start_time = c.SDL_GetTicks();

        checkForChanges(state, allocator);

        if (!gameProcessInput(state)) {
            break;
        }

        gameTick(state);
        gameDraw(state);

        frame_elapsed_time = c.SDL_GetTicks() - frame_start_time;

        if (!DEBUG) {
            if (frame_elapsed_time < TARGET_FRAME_TIME) {
                c.SDL_Delay(@intCast(TARGET_FRAME_TIME - frame_elapsed_time));
            }
        }
    }

    defer gameDeinit();

    c.SDL_DestroyRenderer(renderer);
    c.SDL_DestroyWindow(window);

    c.SDL_Quit();
}

fn initChangeTimes(allocator: std.mem.Allocator) void {
    _ = dllHasChanged();
    _ = srcHasChanged(allocator);
    _ = assetsHaveChanged(allocator);
}

fn checkForChanges(state: GameStatePtr, allocator: std.mem.Allocator) void {
    if (dllHasChanged()) {
        if (build_process != null) {
            checkRecompileResult() catch {
                std.debug.print("Failed to recompile the game lib.\n", .{});
            };
        }

        gameWillReload(state);
        unloadDll() catch unreachable;
        loadDll() catch @panic("Failed to load the game lib.");
        gameReloaded(state);
        _ = assetsHaveChanged(allocator);
    } else if (assetsHaveChanged(allocator)) {
        gameWillReload(state);
        gameReloaded(state);
    }
}

fn dllHasChanged() bool {
    var result = false;
    const stat = std.fs.cwd().statFile(LIB_PATH) catch return false;
    if (stat.mtime > dyn_lib_last_modified) {
        dyn_lib_last_modified = stat.mtime;
        result = true;
    }
    return result;
}

fn srcHasChanged(allocator: std.mem.Allocator) bool {
    return checkForChangesInDirectory(allocator, "src", &src_last_modified) catch false;
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
        const stat = try assets.statFile(entry.path);
        if (stat.mtime > last_change.*) {
            last_change.* = stat.mtime;
            result = true;
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

    if (PLATFORM == .windows) {
        var output = try std.fs.cwd().openDir(LIB_OUTPUT_DIR, .{});
        try output.copyFile("playground.dll", output, "playground_temp.dll", .{});
    }

    var dyn_lib = std.DynLib.open(LIB_PATH_RUNTIME) catch {
        return error.OpenFail;
    };

    opt_dyn_lib = dyn_lib;
    gameInit = dyn_lib.lookup(@TypeOf(gameInit), "init") orelse return error.LookupFail;
    gameDeinit = dyn_lib.lookup(@TypeOf(gameDeinit), "deinit") orelse return error.LookupFail;
    gameWillReload = dyn_lib.lookup(@TypeOf(gameWillReload), "willReload") orelse return error.LookupFail;
    gameReloaded = dyn_lib.lookup(@TypeOf(gameReloaded), "reloaded") orelse return error.LookupFail;
    gameProcessInput = dyn_lib.lookup(@TypeOf(gameProcessInput), "processInput") orelse return error.LookupFail;
    gameTick = dyn_lib.lookup(@TypeOf(gameTick), "tick") orelse return error.LookupFail;
    gameDraw = dyn_lib.lookup(@TypeOf(gameDraw), "draw") orelse return error.LookupFail;

    std.debug.print("Game lib loaded.\n", .{});
}

fn recompileDll(allocator: std.mem.Allocator) !void {
    const process_args = [_][]const u8{
        "zig",
        "build",
        "-Dlib_only=true",
    };

    build_process = std.process.Child.init(&process_args, allocator);
    try build_process.?.spawn();
}

fn checkRecompileResult() !void {
    if (build_process) |*process| {
        const term = try process.wait();
        switch (term) {
            .Exited => |exited| {
                if (exited == 2) return error.RecompileFail;
            },
            else => return,
        }

        build_process = null;
    }
}
