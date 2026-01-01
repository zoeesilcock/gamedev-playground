//! This defines the API that your game library needs to implement, do so by defining each of these functions in your
//! game library (most likely the `root.zig` file) and marking them with `pub export`.
const std = @import("std");
const sdl = @import("sdl.zig").c;

/// Type that signifies a pointer to your game state, you will need to cast it to the type you are using for your game
/// state.
/// ## Example if you struct is called State:
/// ```
/// const state: *State = @ptrCast(@alignCast(state_ptr));
/// ```
pub const GameStatePtr = *anyopaque;

/// Called when the game starts, use to setup your game state and return a pointer to it which will be held by the main
/// executable and passed to all subsequent calls into the game.
init: *const fn (u32, u32, *sdl.SDL_Window) callconv(.c) GameStatePtr = undefined,
deinit: *const fn (GameStatePtr) callconv(.c) void = undefined,

/// Called just before a code/asset hot reload. Use it for any clean up needed to support hot reloading,
/// like unloading your assets.
willReload: *const fn (GameStatePtr) callconv(.c) void = undefined,
/// Called after a code/asset hot reload. Use it to load your assets again.
reloaded: *const fn (GameStatePtr) callconv(.c) void = undefined,

/// Called on every frame, return false from it to exit the game.
processInput: *const fn (GameStatePtr) callconv(.c) bool = undefined,
tick: *const fn (GameStatePtr) callconv(.c) void = undefined,
draw: *const fn (GameStatePtr) callconv(.c) void = undefined,

pub fn load(self: *@This(), dyn_lib: *std.DynLib) !void {
    self.init = dyn_lib.lookup(@TypeOf(self.init), "init") orelse return error.LookupFail;
    self.deinit = dyn_lib.lookup(@TypeOf(self.deinit), "deinit") orelse return error.LookupFail;
    self.willReload = dyn_lib.lookup(@TypeOf(self.willReload), "willReload") orelse return error.LookupFail;
    self.reloaded = dyn_lib.lookup(@TypeOf(self.reloaded), "reloaded") orelse return error.LookupFail;
    self.processInput = dyn_lib.lookup(@TypeOf(self.processInput), "processInput") orelse return error.LookupFail;
    self.tick = dyn_lib.lookup(@TypeOf(self.tick), "tick") orelse return error.LookupFail;
    self.draw = dyn_lib.lookup(@TypeOf(self.draw), "draw") orelse return error.LookupFail;
}
