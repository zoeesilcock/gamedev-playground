//! This defines the API that your game library needs to implement, do so by defining each of these functions in your
//! game library (most likely the `root.zig` file) and marking them with `pub export`. All functions are required
//! except for the init functions, in that case you need to define exactly one of them depending on which dependency
//! type you want your game to be initialized with.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl.zig").c;
const os = @import("os.zig");
const imgui = if (INTERNAL) @import("imgui.zig").c else struct {
    pub const ImGuiContext: type = anyopaque;
};
const internal = if (INTERNAL) @import("internal.zig") else struct {
    pub const DebugOutputWindow: type = anyopaque;
    pub const FPSWindow: type = anyopaque;
    pub const MemoryUsageWindow: type = anyopaque;
};

// Build options.
const INTERNAL: bool = @import("build_options").internal;
const PLATFORM = @import("builtin").os.tag;

// Types.
pub const DebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = INTERNAL,
    .never_unmap = INTERNAL,
});
const GameLib = @This();

/// Settings that your game library can define.
pub const Settings = extern struct {
    title: [*c]const u8 = "Flint",
    window_width: u32 = if (INTERNAL) 800 else 1600,
    window_height: u32 = if (INTERNAL) 600 else 1200,
    window_floating: bool = INTERNAL,
    window_on_top: bool = INTERNAL,
    fullscreen: bool = !INTERNAL,
    target_frame_rate: u32 = 120,
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
        io: *const std.Io,
        window: *sdl.SDL_Window,
        renderer: *sdl.SDL_Renderer,

        internal: Internal = undefined,
    };

    /// A batteries included set of dependencies for 2D rendering, preferable in most cases.
    pub const Full3D = extern struct {
        allocator: *std.mem.Allocator,
        io: *const std.Io,
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
initMinimal: ?*const fn (Dependencies.Minimal) callconv(.c) GameStatePtr = null,
/// Called when the game starts, used to setup your game state and return a pointer to it which will be held by the main
/// executable and passed to all subsequent calls into the game. Includes a full set of dependencies for 2D games.
initFull2D: ?*const fn (Dependencies.Full2D) callconv(.c) GameStatePtr = null,
/// Called when the game starts, used to setup your game state and return a pointer to it which will be held by the main
/// executable and passed to all subsequent calls into the game. Includes a full set of dependencies for 3D games.
initFull3D: ?*const fn (Dependencies.Full3D) callconv(.c) GameStatePtr = null,

/// Called just before the game exits.
deinit: *const fn (GameStatePtr) callconv(.c) void = undefined,

/// Called just before a code/asset hot reload. Use it for any clean up needed to support hot reloading,
/// like unloading your assets.
willReload: *const fn (GameStatePtr) callconv(.c) void = undefined,
/// Called after a code/asset hot reload. Use it to load your assets again.
reloaded: *const fn (GameStatePtr, ?*imgui.ImGuiContext) callconv(.c) void = undefined,

/// Called on every frame, return false from it to exit the game.
processInput: *const fn (GameStatePtr) callconv(.c) bool = undefined,
/// Called on every frame, use this to update your game state based on how much time has passed.
tick: *const fn (GameStatePtr, time: u64, delta_time: u64) callconv(.c) void = undefined,
/// Called on every frame, use this to draw your game.
draw: *const fn (GameStatePtr) callconv(.c) void = undefined,

/// Returns the type of dependencies expected by the game based on which init function is defined.
pub fn getDependcyType(self: GameLib) !DependenciesType {
    return if (self.initMinimal != null)
        .Minimal
    else if (self.initFull2D != null)
        .Full2D
    else if (self.initFull3D != null)
        .Full3D
    else
        return error.NoInitFound;
}

/// Loads the function pointers to the game library being loaded. This is used by Flint internally.
pub fn load(self: *GameLib, dyn_lib: *os.LoadedLibrary) !void {
    var init_function_found: bool = false;
    const self_info = @typeInfo(GameLib).@"struct";
    inline for (self_info.fields) |struct_field| {
        var fn_found: bool = false;
        const lib_fn_name = struct_field.name;

        switch (@typeInfo(struct_field.type)) {
            .pointer => |ptr_info| {
                if (@typeInfo(ptr_info.child) == .@"fn") {
                    fn_found = try self.lookupFunction(dyn_lib, lib_fn_name, struct_field.type);
                }
            },
            .optional => |optional_info| {
                const ptr_info = @typeInfo(optional_info.child);
                if (ptr_info == .pointer) {
                    fn_found = try self.lookupFunction(dyn_lib, lib_fn_name, optional_info.child);
                }
            },
            else => {},
        }

        if (fn_found) {
            if (isInitFunction(lib_fn_name)) {
                if (init_function_found) {
                    std.log.err("Multiple init functions found in the game library, only one is allowed.", .{});
                    return error.MultipleInits;
                }

                init_function_found = true;
            }
        } else {
            if (!isInitFunction(lib_fn_name)) {
                std.log.err("Failed to locate the `{s}` function in the game library, it is required", .{lib_fn_name});
                return error.LookupFail;
            }
        }
    }

    if (!init_function_found) {
        std.log.err("Failed to locate any init functions in the game library, one is required.", .{});
        return error.LookupFail;
    }
}

fn isInitFunction(name: []const u8) bool {
    return std.mem.eql(u8, name, "initMinimal") or
        std.mem.eql(u8, name, "initFull2D") or
        std.mem.eql(u8, name, "initFull3D");
}

fn lookupFunction(
    self: *GameLib,
    dyn_lib: *os.LoadedLibrary,
    comptime name: [:0]const u8,
    comptime T: type,
) !bool {
    var fn_found: bool = false;
    const fn_ptr = &@field(self, name);

    if (PLATFORM == .windows) {
        if (os.windows.GetProcAddress(dyn_lib.*, name)) |function| {
            fn_ptr.* = @ptrCast(function);
            fn_found = true;
        }
    } else {
        if (dyn_lib.lookup(T, name)) |function| {
            fn_ptr.* = function;
            fn_found = true;
        }
    }

    return fn_found;
}
