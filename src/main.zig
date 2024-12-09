const std = @import("std");
const r = @import("dependencies/raylib.zig");

const DEBUG = @import("builtin").mode == std.builtin.OptimizeMode.Debug;

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;
const TARGET_FPS = 120;
const LIB_PATH = "zig-out/lib/libplayground.dylib";

const GameStatePtr = *anyopaque;

var opt_dyn_lib: ?std.DynLib = null;
var build_process: ?std.process.Child = null;
var dyn_lib_last_modified: i128 = 0;
var src_last_modified: i128 = 0;
var assets_last_modified: i128 = 0;

var gameInit: *const fn(u32, u32) GameStatePtr = undefined;
var gameReload: *const fn(GameStatePtr) void = undefined;
var gameTick: *const fn(GameStatePtr) void = undefined;
var gameDraw: *const fn(GameStatePtr) void = undefined;

pub fn main() !void {
    r.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Playground");

    if (!DEBUG) {
        r.SetTargetFPS(TARGET_FPS);
    }

    loadDll() catch @panic("Failed to load the game lib.");
    const allocator = std.heap.c_allocator;
    const state = gameInit(WINDOW_WIDTH, WINDOW_HEIGHT);

    _ = dllHasChanged();
    _ = srcHasChanged(allocator);
    _ = assetsHaveChanged(allocator);

    while (!r.WindowShouldClose()) {
        if (r.IsKeyPressed(r.KEY_F5) or srcHasChanged(allocator)) {
            try recompileDll(allocator);
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

        gameTick(state);

        r.BeginDrawing();
        {
            gameDraw(state);
            r.DrawFPS(10, WINDOW_HEIGHT - 30);

            if (build_process != null) {
                r.DrawText("Re-compiling", 10, WINDOW_HEIGHT - 60, 16, r.WHITE);
            }
        }
        r.EndDrawing();
    }

    r.CloseWindow();
}

fn loadDll() !void {
    if (opt_dyn_lib != null) return error.AlreadyLoaded;
    var dyn_lib = std.DynLib.open(LIB_PATH) catch {
        return error.OpenFail;
    };

    opt_dyn_lib = dyn_lib;
    gameInit = dyn_lib.lookup(@TypeOf(gameInit), "init") orelse return error.LookupFail;
    gameReload = dyn_lib.lookup(@TypeOf(gameReload), "reload") orelse return error.LookupFail;
    gameTick = dyn_lib.lookup(@TypeOf(gameTick), "tick") orelse return error.LookupFail;
    gameDraw = dyn_lib.lookup(@TypeOf(gameDraw), "draw") orelse return error.LookupFail;

    std.debug.print("Game lib loaded.\n", .{});
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
            else => return
        }

        build_process = null;
    }
}
