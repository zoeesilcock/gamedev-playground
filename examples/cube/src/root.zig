const std = @import("std");
const sdl = @import("sdl").c;
const loggingAllocator = if (INTERNAL) @import("logging_allocator").loggingAllocator else undefined;

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

    window: *sdl.SDL_Window,
    device: *sdl.SDL_GPUDevice,
};

pub export fn init(window_width: u32, window_height: u32, window: *sdl.SDL_Window) *anyopaque {
    _ = window_width;
    _ = window_height;

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
        .window = window,
        .device = sdl.SDL_CreateGPUDevice(
            sdl.SDL_GPU_SHADERFORMAT_SPIRV | sdl.SDL_GPU_SHADERFORMAT_DXIL | sdl.SDL_GPU_SHADERFORMAT_MSL,
            true,
            null,
        ).?,
    };

    const window_claimed = sdl.SDL_ClaimWindowForGPUDevice(state.device, state.window);
    if (!window_claimed) {
        @panic("Failed to claim window for GPU device.");
    }

    if (INTERNAL) {
        state.debug_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize debug allocator."));
        state.debug_allocator.* = .init;
    }

    return state;
}

pub export fn deinit(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    sdl.SDL_ReleaseWindowFromGPUDevice(state.device, state.window);
    sdl.SDL_DestroyGPUDevice(state.device);
}

pub export fn willReload(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn reloaded(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn processInput(state_ptr: *anyopaque) bool {
    _ = state_ptr;

    var continue_running: bool = true;
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event)) {
        if (event.type == sdl.SDL_EVENT_QUIT or (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE)) {
            continue_running = false;
            break;
        }
    }

    return continue_running;
}

pub export fn tick(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn draw(state_ptr: *anyopaque) void {
    _ = state_ptr;
}
