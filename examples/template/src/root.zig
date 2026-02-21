const std = @import("std");
const playground = @import("playground");
const sdl = playground.sdl.c;
const imgui = playground.imgui;

pub const std_options: std.Options = .{
    .log_level = if (INTERNAL) .info else .err,
    .logFn = GameLib.logFn,
};

// Build options.
const INTERNAL: bool = @import("build_options").internal;

// Types.
const GameLib = playground.GameLib;
const DebugAllocator = GameLib.DebugAllocator;

const State = struct {
    dependencies: GameLib.Dependencies.Full2D,

    // Time.
    time: u64 = 0,
    delta_time: u64 = 0,

    // Input.
    space_is_down: bool = false,

    // Internal.
    internal: if (INTERNAL) extern struct {
        output: *playground.internal.DebugOutputWindow = undefined,
    } else extern struct {} = undefined,

    pub fn create(dependencies: GameLib.Dependencies.Full2D) !*State {
        const state: *State = try dependencies.allocator.create(State);
        state.* = .{
            .dependencies = dependencies,
        };

        if (INTERNAL) {
            state.internal.output = dependencies.internal.output;
        }

        return state;
    }
};

const settings: GameLib.Settings = .{
    .title = "Template",
    .dependencies = .Full2D,
};

pub export fn getSettings() GameLib.Settings {
    return settings;
}

pub export fn init(dependencies: GameLib.Dependencies.Full2D) GameLib.GameStatePtr {
    const state: *State = State.create(dependencies) catch @panic("Failed to create game state.");

    if (INTERNAL) {
        imgui.setup(state.dependencies.internal.imgui_context, .Renderer);
    }

    return state;
}

pub export fn deinit(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    _ = state;
}

pub export fn willReload(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    _ = state;
}

pub export fn reloaded(state_ptr: GameLib.GameStatePtr, imgui_context: ?*imgui.c.ImGuiContext) void {
    if (INTERNAL) {
        const state: *State = @ptrCast(@alignCast(state_ptr));
        state.dependencies.internal.imgui_context = imgui_context.?;
        imgui.setup(imgui_context, .Renderer);
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
                        state.dependencies.internal.fps_window.cycleMode();
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

pub export fn tick(state_ptr: GameLib.GameStatePtr, time: u64, delta_time: u64) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    state.time = time;
    state.delta_time = delta_time;

    if (INTERNAL) {
        state.dependencies.internal.fps_window.addFrameTime(sdl.SDL_GetPerformanceCounter());

        state.internal.output.print("Hello world! Space is down: {s}", .{
            if (state.space_is_down) "true" else "false",
        });
    }

    // Update your game state here.
}

pub export fn draw(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    _ = sdl.SDL_SetRenderTarget(state.dependencies.renderer, null);
    {
        _ = sdl.SDL_SetRenderDrawColor(state.dependencies.renderer, 0, 0, 0, 255);
        _ = sdl.SDL_RenderClear(state.dependencies.renderer);

        // Draw your game world here.
        drawGame(state);

        if (INTERNAL) {
            imgui.newFrame();
            // Draw your internal UI and visualizations here.
            drawInternalUI(state);
            imgui.render(state.dependencies.renderer);
        }
    }
    _ = sdl.SDL_RenderPresent(state.dependencies.renderer);
}

fn drawGame(state: *State) void {
    if (state.space_is_down) {
        _ = sdl.SDL_SetRenderDrawColor(state.dependencies.renderer, 0, 127, 0, 255);
        _ = sdl.SDL_RenderClear(state.dependencies.renderer);
    }
}

fn drawInternalUI(state: *State) void {
    state.dependencies.internal.fps_window.draw();
    state.dependencies.internal.output.draw();

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
