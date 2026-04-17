const std = @import("std");
const flint = @import("flint");
const sdl = flint.sdl.c;
const imgui = flint.imgui;
const aseprite = flint.aseprite;

pub const std_options: std.Options = .{
    .log_level = if (INTERNAL) .info else .err,
};

// Build options.
const INTERNAL: bool = @import("build_options").internal;

// Types.
const GameLib = flint.GameLib;
const DebugAllocator = GameLib.DebugAllocator;
const AsepriteAsset = aseprite.AsepriteAsset;

const State = struct {
    dependencies: GameLib.Dependencies.Full2D,

    fullscreen: bool = false,

    // Time.
    time: u64 = 0,
    delta_time: u64 = 0,

    // Input.
    space_is_down: bool = false,
    mouse_position_x: f32 = 0,
    mouse_position_y: f32 = 0,
    left_mouse_is_down: bool = false,
    left_mouse_pressed: bool = false,
    left_mouse_last_pressed_time: u64 = 0,

    // Assets.
    welcome_sprite: ?AsepriteAsset = null,

    // Internal.
    internal: if (INTERNAL) extern struct {
        output: *flint.internal.DebugOutputWindow = undefined,
    } else extern struct {} = undefined,

    pub fn create(dependencies: GameLib.Dependencies.Full2D) !*State {
        const state: *State = try dependencies.allocator.create(State);
        state.* = .{
            .dependencies = dependencies,
        };

        if (INTERNAL) {
            state.internal.output = dependencies.internal.output;
            state.dependencies.internal.memory_usage_window.position = imgui.c.ImVec2{ .x = 320, .y = 40 };
            state.dependencies.internal.memory_usage_window.visible = true;
        }

        return state;
    }

    pub fn resetInput(self: *State) void {
        self.left_mouse_pressed = false;
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

    loadAssets(state);

    if (INTERNAL) {
        imgui.setup(state.dependencies.internal.imgui_context, .Renderer);
    }

    return state;
}

pub export fn deinit(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    _ = state;
}

fn loadAssets(state: *State) void {
    state.welcome_sprite = .load(
        "assets/welcome.aseprite",
        state.dependencies.renderer,
        state.dependencies.allocator.*,
        state.dependencies.io.*,
    );
}
fn unloadAssets(state: *State) void {
    state.welcome_sprite.?.deinit(state.dependencies.allocator.*);
}

pub export fn willReload(state_ptr: GameLib.GameStatePtr) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    unloadAssets(state);
}

pub export fn reloaded(state_ptr: GameLib.GameStatePtr, imgui_context: ?*imgui.ImGuiContext) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    if (INTERNAL) {
        state.dependencies.internal.imgui_context = imgui_context.?;
        imgui.setup(imgui_context, .Renderer);
    }
    loadAssets(state);
}

pub export fn processInput(state_ptr: GameLib.GameStatePtr) bool {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    state.resetInput();

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

        // Mouse.
        if (event.type == sdl.SDL_EVENT_MOUSE_MOTION) {
            state.mouse_position_x = event.motion.x;
            state.mouse_position_y = event.motion.y;
        } else if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN or event.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP) {
            const is_down = event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN;
            switch (event.button.button) {
                1 => {
                    state.left_mouse_pressed = (state.left_mouse_is_down and !is_down);
                    state.left_mouse_is_down = is_down;
                },
                else => {},
            }
        }

        // Keyboard.
        if (event.type == sdl.SDL_EVENT_KEY_DOWN or event.type == sdl.SDL_EVENT_KEY_UP) {
            const is_down = event.type == sdl.SDL_EVENT_KEY_DOWN;
            switch (event.key.key) {
                sdl.SDLK_F1 => {
                    if (INTERNAL) {
                        if (is_down) {
                            state.dependencies.internal.fps_window.cycleMode();
                        }
                    }
                },
                sdl.SDLK_F => {
                    if (is_down) {
                        state.fullscreen = !state.fullscreen;
                        _ = sdl.SDL_SetWindowFullscreen(state.dependencies.window, state.fullscreen);
                    }
                },
                sdl.SDLK_F2 => {
                    if (INTERNAL) {
                        if (is_down) {
                            state.dependencies.internal.memory_usage_window.visible =
                                !state.dependencies.internal.memory_usage_window.visible;
                        }
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

    if (state.left_mouse_pressed) {
        if (state.time - state.left_mouse_last_pressed_time < 300) {
            // TODO: Check where the double click happened so we know which sprite to open.
            aseprite.openInAseprite(&state.welcome_sprite.?, state.dependencies.allocator.*, state.dependencies.io.*);
        }

        state.left_mouse_last_pressed_time = state.time;
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

    if (state.welcome_sprite) |sprite| {
        var sprite_rect: sdl.SDL_FRect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
        _ = sdl.SDL_RenderTexture(state.dependencies.renderer, sprite.frames[0], null, &sprite_rect);
    }
}

fn drawInternalUI(state: *State) void {
    state.dependencies.internal.fps_window.draw();
    state.dependencies.internal.output.draw();
    state.dependencies.internal.memory_usage_window.draw();

    // Game state inspector
    {
        imgui.c.ImGui_SetNextWindowPosEx(
            imgui.c.ImVec2{ .x = 10, .y = 100 },
            imgui.c.ImGuiCond_FirstUseEver,
            imgui.c.ImVec2{ .x = 0, .y = 0 },
        );
        imgui.c.ImGui_SetNextWindowSize(imgui.c.ImVec2{ .x = 300, .y = 285 }, imgui.c.ImGuiCond_FirstUseEver);

        _ = imgui.c.ImGui_Begin("Game state", null, imgui.c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer imgui.c.ImGui_End();

        flint.internal.inspectStruct(state, &.{ "io", "allocator", "arena" }, false, null);
    }
}
