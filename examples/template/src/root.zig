const std = @import("std");
const playground = @import("playground");
const sdl_utils = playground.sdl;
const sdl = playground.sdl.c;
const internal = playground.internal;
const imgui = if (INTERNAL) playground.imgui else struct {};

// Build options.
const INTERNAL: bool = @import("build_options").internal;

// Types.
const GameLib = playground.GameLib;
const DebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = INTERNAL,
    .never_unmap = INTERNAL,
});

pub const State = struct {
    game_allocator: *DebugAllocator,
    allocator: std.mem.Allocator,

    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    window_width: u32,
    window_height: u32,

    // Input.
    space_is_down: bool,

    // Internal.
    debug_allocator: *DebugAllocator = undefined,
    debug_output: *internal.DebugOutputWindow = undefined,
    fps_window: *internal.FPSWindow = undefined,
};

pub export fn init(window_width: u32, window_height: u32, window: *sdl.SDL_Window) GameLib.GameStatePtr {
    var backing_allocator = std.heap.page_allocator;
    var game_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize game allocator."));
    game_allocator.* = .init;

    var state: *State = game_allocator.allocator().create(State) catch @panic("Out of memory");
    state.* = .{
        .allocator = game_allocator.allocator(),
        .game_allocator = game_allocator,

        .window = window,
        .renderer = sdl_utils.panicIfNull(sdl.SDL_CreateRenderer(window, null), "Failed to create renderer.").?,
        .window_width = window_width,
        .window_height = window_height,

        .space_is_down = false,
    };

    if (INTERNAL) {
        imgui.init(state.window, state.renderer, @floatFromInt(state.window_width), @floatFromInt(state.window_height));

        state.debug_allocator =
            (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize debug allocator."));
        state.debug_allocator.* = .init;

        state.debug_output =
            state.debug_allocator.allocator().create(internal.DebugOutputWindow) catch @panic("Out of memory");
        state.debug_output.init();

        state.fps_window =
            state.debug_allocator.allocator().create(internal.FPSWindow) catch @panic("Failed to allocate FPS state");
        state.fps_window.init(sdl.SDL_GetPerformanceFrequency());
    }

    return state;
}

pub export fn deinit(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        imgui.deinit();
    }

    sdl.SDL_DestroyRenderer(state.renderer);
}

pub export fn willReload(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    _ = state;

    if (INTERNAL) {
        imgui.deinit();
    }
}

pub export fn reloaded(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        imgui.init(state.window, state.renderer, @floatFromInt(state.window_width), @floatFromInt(state.window_height));
    }
}

pub export fn processInput(state_ptr: GameLib.GameStatePtr) bool {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    var continue_running: bool = true;
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event)) {
        if (INTERNAL and imgui.processEvent(&event)) {
            continue;
        }

        if (event.type == sdl.SDL_EVENT_QUIT or
            (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE))
        {
            continue_running = false;
            break;
        }

        if (event.type == sdl.SDL_EVENT_KEY_DOWN or event.type == sdl.SDL_EVENT_KEY_UP) {
            const is_down = event.type == sdl.SDL_EVENT_KEY_DOWN;
            switch (event.key.key) {
                sdl.SDLK_F1 => {
                    state.fps_window.cycleMode();
                },
                // Process your game input here.
                sdl.SDLK_SPACE => {
                    state.space_is_down = is_down;
                },
                else => {},
            }
        }
    }

    return continue_running;
}

pub export fn tick(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        state.fps_window.addFrameTime(sdl.SDL_GetPerformanceCounter());

        state.debug_output.print("Hello world! Space is down: {s}", .{if (state.space_is_down) "true" else "false"});
    }

    // Update your game state here.
}

pub export fn draw(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    _ = sdl.SDL_SetRenderTarget(state.renderer, null);
    {
        _ = sdl.SDL_SetRenderDrawColor(state.renderer, 0, 0, 0, 255);
        _ = sdl.SDL_RenderClear(state.renderer);

        // Draw your game world here.
        drawGame(state);

        if (INTERNAL) {
            imgui.newFrame();
            // Draw your internal UI and visualizations here.
            drawInternalUI(state);
            imgui.render(state.renderer);
        }
    }
    _ = sdl.SDL_RenderPresent(state.renderer);
}

fn drawGame(state: *State) void {
    if (state.space_is_down) {
        _ = sdl.SDL_SetRenderDrawColor(state.renderer, 0, 127, 0, 255);
        _ = sdl.SDL_RenderClear(state.renderer);
    }
}

fn drawInternalUI(state: *State) void {
    state.fps_window.draw();
    state.debug_output.draw();

    // Game state inspector
    {
        imgui.c.ImGui_SetNextWindowPosEx(
            imgui.c.ImVec2{ .x = 10, .y = 100 },
            imgui.c.ImGuiCond_FirstUseEver,
            imgui.c.ImVec2{ .x = 0, .y = 0 },
        );
        imgui.c.ImGui_SetNextWindowSize(imgui.c.ImVec2{ .x = 300, .y = 400 }, imgui.c.ImGuiCond_FirstUseEver);

        _ = imgui.c.ImGui_Begin("Game state", null, imgui.c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer imgui.c.ImGui_End();

        internal.inspectStruct(state, &.{}, false, null);
    }
}
