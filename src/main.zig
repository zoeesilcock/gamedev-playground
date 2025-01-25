const std = @import("std");
const r = @import("dependencies/raylib.zig");

const DEBUG = @import("builtin").mode == std.builtin.OptimizeMode.Debug;
const PLATFORM = @import("builtin").os.tag;

const LIB_OUTPUT_DIR = if (PLATFORM == .windows) "zig-out/bin/" else "zig-out/lib/";
const LIB_PATH = if (PLATFORM == .windows) "zig-out/bin/playground.dll" else "zig-out/lib/libplayground.dylib";
const LIB_PATH_RUNTIME = if (PLATFORM == .windows) "zig-out/bin/playground_temp.dll" else LIB_PATH;

const WINDOW_WIDTH = if (DEBUG) 800 else 800;
const WINDOW_HEIGHT = if (DEBUG) 600 else 600;
const WINDOW_DECORATIONS_WIDTH = if (PLATFORM == .windows) 16 else 0;
const WINDOW_DECORATIONS_HEIGHT = if (PLATFORM == .windows) 39 else 0;
const TARGET_FPS = 120;

const GameStatePtr = *anyopaque;

var opt_dyn_lib: ?std.DynLib = null;
var build_process: ?std.process.Child = null;
var dyn_lib_last_modified: i128 = 0;
var src_last_modified: i128 = 0;
var assets_last_modified: i128 = 0;

var gameInit: *const fn (u32, u32) GameStatePtr = undefined;
var gameReload: *const fn (GameStatePtr) void = undefined;
var gameTick: *const fn (GameStatePtr) void = undefined;
var gameDraw: *const fn (GameStatePtr) void = undefined;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    r.SetConfigFlags(r.FLAG_WINDOW_HIGHDPI);
    r.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Playground");

    const current_monitor = r.GetCurrentMonitor();
    const monitor_width = r.GetMonitorWidth(current_monitor);

    if (DEBUG) {
        const window_offset_x: c_int = 12;
        const window_offset_y: c_int = 12 + WINDOW_DECORATIONS_HEIGHT;

        r.SetWindowPosition(monitor_width - WINDOW_WIDTH - window_offset_x, window_offset_y);
        r.SetWindowState(r.FLAG_WINDOW_TOPMOST);
    } else {
        r.SetTargetFPS(TARGET_FPS);
    }

    loadDll() catch @panic("Failed to load the game lib.");
    const state = gameInit(WINDOW_WIDTH, WINDOW_HEIGHT);

    initChangeTimes(allocator);

    while (!r.WindowShouldClose()) {
        checkForChanges(state, allocator);

        gameTick(state);

        r.BeginDrawing();
        {
            gameDraw(state);

            if (build_process != null) {
                r.DrawText("Recompiling", 12, WINDOW_HEIGHT - 60, 16, r.WHITE);
            }
        }
        r.EndDrawing();
    }

    r.CloseWindow();
}

fn initChangeTimes(allocator: std.mem.Allocator) void {
    _ = dllHasChanged();
    _ = srcHasChanged(allocator);
    _ = assetsHaveChanged(allocator);
}

fn checkForChanges(state: GameStatePtr, allocator: std.mem.Allocator) void {
    if (r.IsKeyPressed(r.KEY_F5) or srcHasChanged(allocator)) {
        recompileDll(allocator) catch @panic("Failed to recompile the lib.");
    }

    if (dllHasChanged()) {
        if (build_process != null) {
            checkRecompileResult() catch {
                std.debug.print("Failed to recompile the game lib.\n", .{});
            };
        }

        unloadDll() catch unreachable;
        loadDll() catch @panic("Failed to load the game lib.");
        gameReload(state);
        _ = assetsHaveChanged(allocator);
    } else if (assetsHaveChanged(allocator)) {
        gameReload(state);
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
    gameReload = dyn_lib.lookup(@TypeOf(gameReload), "reload") orelse return error.LookupFail;
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
