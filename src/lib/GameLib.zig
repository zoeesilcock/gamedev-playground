//! This defines the API that your game library needs to implement, do so by defining each of these functions in your
//! game library (most likely the `root.zig` file) and marking them with `pub export`.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl.zig").c;
const imgui = @import("imgui.zig").c;
const internal = @import("internal.zig");

// Build options.
const INTERNAL: bool = @import("build_options").internal;

// Types.
pub const DebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = INTERNAL,
    .never_unmap = INTERNAL,
});

/// Settings that your game library can define.
pub const Settings = extern struct {
    title: [*c]const u8 = "Playground",
    window_width: u32 = if (INTERNAL) 800 else 1600,
    window_height: u32 = if (INTERNAL) 600 else 1200,
    window_floating: bool = INTERNAL,
    window_on_top: bool = INTERNAL,
    fullscreen: bool = !INTERNAL,
    target_frame_rate: u32 = 120,
    dependencies: DependenciesType = .Minimal,
};

/// List of dependency sets available to receive on startup.
pub const DependenciesType = enum(u32) {
    Minimal,
    Full2D,
    Full3D,

    pub fn batteriesIncluded(self: DependenciesType) bool {
        return self == .Full2D or self == .Full3D;
    }
};

/// These structs define different sets of dependencies that can be provided to your library on startup.
pub const Dependencies = struct {
    /// A minimal set of dependencies, suitable when you want to do everything yourself.
    pub const Minimal = extern struct {
        window: *sdl.SDL_Window,
    };

    /// A batteries included set of dependencies for 2D rendering, preferable in most cases.
    pub const Full2D = extern struct {
        allocator: *std.mem.Allocator,
        window: *sdl.SDL_Window,
        renderer: *sdl.SDL_Renderer,

        internal: Internal = undefined,
    };

    /// A batteries included set of dependencies for 2D rendering, preferable in most cases.
    pub const Full3D = extern struct {
        allocator: *std.mem.Allocator,
        window: *sdl.SDL_Window,
        gpu_device: *sdl.SDL_GPUDevice,

        internal: Internal = undefined,
    };

    /// The internal dependencies included in the Full2D and Full3D dependency sets.
    pub const Internal = if (INTERNAL) extern struct {
        imgui_context: *imgui.ImGuiContext = undefined,
        allocator: *std.mem.Allocator = undefined,
        output: *internal.DebugOutputWindow = undefined,
        fps_window: *internal.FPSWindow = undefined,
        memory_usage_window: *internal.MemoryUsageWindow = undefined,
    } else extern struct {};
};

/// Type that signifies a pointer to your game state, you will need to cast it to the type you are using for your game
/// state.
/// ## Example if you struct is called State:
/// ```
/// const state: *State = @ptrCast(@alignCast(state_ptr));
/// ```
pub const GameStatePtr = *anyopaque;

/// Called before the game has been initialized. The settings returned will decide what type of init dependencies will
/// be passed.
getSettings: *const fn () callconv(.c) Settings = undefined,
/// Called when the game starts, used to setup your game state and return a pointer to it which will be held by the main
/// executable and passed to all subsequent calls into the game. Includes a minimal set of dependencies.
initMinimal: *const fn (Dependencies.Minimal) callconv(.c) GameStatePtr = undefined,
/// Called when the game starts, used to setup your game state and return a pointer to it which will be held by the main
/// executable and passed to all subsequent calls into the game. Includes a full set of dependencies for 2D games.
initFull2D: *const fn (Dependencies.Full2D) callconv(.c) GameStatePtr = undefined,
/// Called when the game starts, used to setup your game state and return a pointer to it which will be held by the main
/// executable and passed to all subsequent calls into the game. Includes a full set of dependencies for 3D games.
initFull3D: *const fn (Dependencies.Full3D) callconv(.c) GameStatePtr = undefined,

/// Called just before the game exits.
deinit: *const fn (GameStatePtr) callconv(.c) void = undefined,

/// Called just before a code/asset hot reload. Use it for any clean up needed to support hot reloading,
/// like unloading your assets.
willReload: *const fn (GameStatePtr) callconv(.c) void = undefined,
/// Called after a code/asset hot reload. Use it to load your assets again.
reloaded: *const fn (GameStatePtr, ?*imgui.ImGuiContext) callconv(.c) void = undefined,

/// Called on every frame, return false from it to exit the game.
processInput: *const fn (GameStatePtr) callconv(.c) bool = undefined,
tick: *const fn (GameStatePtr, time: u64, delta_time: u64) callconv(.c) void = undefined,
draw: *const fn (GameStatePtr) callconv(.c) void = undefined,

pub fn load(self: *@This(), dyn_lib: *std.DynLib) !void {
    self.getSettings = dyn_lib.lookup(@TypeOf(self.getSettings), "getSettings") orelse return error.LookupFail;
    self.initMinimal = dyn_lib.lookup(@TypeOf(self.initMinimal), "init") orelse return error.LookupFail;
    self.initFull2D = dyn_lib.lookup(@TypeOf(self.initFull2D), "init") orelse return error.LookupFail;
    self.initFull3D = dyn_lib.lookup(@TypeOf(self.initFull3D), "init") orelse return error.LookupFail;

    self.deinit = dyn_lib.lookup(@TypeOf(self.deinit), "deinit") orelse return error.LookupFail;

    self.willReload = dyn_lib.lookup(@TypeOf(self.willReload), "willReload") orelse return error.LookupFail;
    self.reloaded = dyn_lib.lookup(@TypeOf(self.reloaded), "reloaded") orelse return error.LookupFail;

    self.processInput = dyn_lib.lookup(@TypeOf(self.processInput), "processInput") orelse return error.LookupFail;
    self.tick = dyn_lib.lookup(@TypeOf(self.tick), "tick") orelse return error.LookupFail;
    self.draw = dyn_lib.lookup(@TypeOf(self.draw), "draw") orelse return error.LookupFail;
}

/// Custom logger for posix systems since the default log function doesn't work from dynamic libraries on Linux.
pub const logFn = if (builtin.os.tag == .windows) std.log.defaultLog else posixLogFn;

fn posixLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buffer: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
    nosuspend _ = std.posix.write(2, msg) catch return;
}
