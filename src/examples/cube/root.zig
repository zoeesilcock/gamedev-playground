const std = @import("std");
const loggingAllocator = if (INTERNAL) @import("logging_allocator").loggingAllocator else undefined;

pub const c_sdl = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

const INTERNAL: bool = @import("build_options").internal;
const LOG_ALLOCATIONS: bool = @import("build_options").log_allocations;

const DebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = INTERNAL,
    .never_unmap = INTERNAL,
});

pub const State = struct {
    game_allocator: *DebugAllocator,
    allocator: std.mem.Allocator,
    debug_allocator: *DebugAllocator = undefined,
};

pub export fn init(window_width: u32, window_height: u32, window: *c_sdl.SDL_Window, renderer: *c_sdl.SDL_Renderer) *anyopaque {
    _ = window_width;
    _ = window_height;
    _ = window;
    _ = renderer;

    var backing_allocator = std.heap.page_allocator;
    var game_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize game allocator."));
    game_allocator.* = .init;

    var allocator = game_allocator.allocator();
    if (INTERNAL and LOG_ALLOCATIONS) {
        const logging_allocator = loggingAllocator(game_allocator.allocator());
        var logging_allocator_ptr = (backing_allocator.create(@TypeOf(logging_allocator)) catch @panic("Failed to initialize logging allocator."));
        logging_allocator_ptr.* = logging_allocator;
        allocator = logging_allocator_ptr.allocator();
    }

    var state: *State = allocator.create(State) catch @panic("Out of memory");
    state.* = .{
        .allocator = allocator,
        .game_allocator = game_allocator,
    };

    if (INTERNAL) {
        state.debug_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize debug allocator."));
        state.debug_allocator.* = .init;
    }

    return state;
}

pub export fn deinit() void {
}

pub export fn willReload(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn reloaded(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn processInput(state_ptr: *anyopaque) bool {
    _ = state_ptr;
    return true;
}

pub export fn tick(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn draw(state_ptr: *anyopaque) void {
    _ = state_ptr;
}
