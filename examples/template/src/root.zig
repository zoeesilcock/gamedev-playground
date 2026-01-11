const std = @import("std");
const playground = @import("playground");
const sdl = playground.sdl.c;
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

const State = struct {
    game_allocator: *DebugAllocator,
    allocator: std.mem.Allocator,

    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    window_width: u32,
    window_height: u32,

    // Input.
    space_is_down: bool,

    internal: if (INTERNAL) struct {
        debug_allocator: *DebugAllocator = undefined,
        allocator: std.mem.Allocator = undefined,
        output: *playground.internal.DebugOutputWindow = undefined,
        fps_window: *playground.internal.FPSWindow = undefined,
    } else struct {} = undefined,
};

pub export fn init(window_width: u32, window_height: u32, window: *sdl.SDL_Window) GameLib.GameStatePtr {
    var backing_allocator = std.heap.page_allocator;
    var game_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize game allocator."));
    game_allocator.* = .init;

    var state: *State = game_allocator.allocator().create(State) catch @panic("Out of memory.");
    state.* = .{
        .allocator = game_allocator.allocator(),
        .game_allocator = game_allocator,

        .window = window,
        .renderer = playground.sdl.panicIfNull(sdl.SDL_CreateRenderer(window, null), "Failed to create renderer.").?,
        .window_width = window_width,
        .window_height = window_height,

        .space_is_down = false,
    };

    if (INTERNAL) {
        imgui.init(state.window, state.renderer, @floatFromInt(state.window_width), @floatFromInt(state.window_height));

        state.internal.debug_allocator =
            (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize debug allocator."));
        state.internal.debug_allocator.* = .init;
        state.internal.allocator = state.internal.debug_allocator.allocator();

        state.internal.output =
            state.internal.allocator.create(playground.internal.DebugOutputWindow) catch @panic("Out of memory.");
        state.internal.output.init();

        state.internal.fps_window =
            state.internal.allocator.create(playground.internal.FPSWindow) catch @panic("Failed to allocate FPS state.");
        state.internal.fps_window.init(sdl.SDL_GetPerformanceFrequency());
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
                    if (INTERNAL) {
                        state.internal.fps_window.cycleMode();
                    }
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
        state.internal.fps_window.addFrameTime(sdl.SDL_GetPerformanceCounter());

        state.internal.output.print("Hello world! Space is down: {s}", .{
            if (state.space_is_down) "true" else "false",
        });
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
    state.internal.fps_window.draw();
    state.internal.output.draw();

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

        playground.internal.inspectStruct(state, &.{}, false, null);
    }
}
