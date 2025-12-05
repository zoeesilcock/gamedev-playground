const std = @import("std");
const sdl_utils = @import("sdl");
const sdl = @import("sdl").c;
const internal = @import("internal");
const aseprite = @import("aseprite");
const entities = @import("entities.zig");
const math = @import("math");
const pool = @import("pool");
const imgui = if (INTERNAL) @import("imgui") else struct {};
const debug = if (INTERNAL) @import("debug.zig") else struct {
    pub const DebugState = void;
};

const loggingAllocator = if (INTERNAL) @import("logging_allocator").loggingAllocator else undefined;
pub const std_options: std.Options = .{
    .log_level = .warn,
};

const Entity = entities.Entity;
const CollisionResult = entities.CollisionResult;
const EntityId = entities.EntityId;
const ColorComponentValue = entities.ColorComponentValue;
const BlockType = entities.BlockType;
const TitleType = entities.TitleType;
const TweenedValue = entities.TweenedValue;
const FPSState = internal.FPSState;
const AsepriteAsset = aseprite.AsepriteAsset;

const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;
const Z = math.Z;

const Color = math.Color;
const R = math.R;
const G = math.G;
const B = math.B;
const A = math.A;

const DebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = INTERNAL,
    .never_unmap = INTERNAL,
});

const INTERNAL: bool = @import("build_options").internal;
const LOG_ALLOCATIONS: bool = @import("build_options").log_allocations;
const MAX_ENTITY_COUNT = 1024;
const WORLD_WIDTH: u32 = 200;
const WORLD_HEIGHT: u32 = 150;
const BALL_VELOCITY: f32 = 64;
const BALL_HORIZONTAL_BOUNCE_TIME: u64 = 75;
const BALL_SPAWN = Vector2{ 24, 20 };
const MAX_LIVES = 3;
pub const LEVEL_NAME_BUFFER_SIZE: u32 = 128;

const LEVELS: []const []const u8 = &.{
    "level1",
    "level2",
    "level3",
    // "test",
};

pub const State = struct {
    game_allocator: *DebugAllocator,
    allocator: std.mem.Allocator,

    debug_allocator: *DebugAllocator = undefined,
    debug_state: *debug.DebugState = undefined,
    fps_state: ?*FPSState = null,

    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    render_texture: *sdl.SDL_Texture = undefined,
    dest_rect: sdl.SDL_FRect = undefined,

    window_width: u32,
    window_height: u32,

    world_scale: f32,
    ui_scale: f32,
    world_width: u32,
    world_height: u32,

    assets: Assets,

    time: u64,
    delta_time: u64,
    delta_time_actual: u64,
    input: Input,
    ball_horizontal_bounce_start_time: u64,

    paused: bool,
    fullscreen: bool,

    level_index: u32,
    lives_remaining: u32,

    // Entities.
    entities: [MAX_ENTITY_COUNT]Entity,
    next_free_entity_index: u32,

    ball_id: ?EntityId,
    current_title_id: ?EntityId,

    pub fn deltaTime(self: *State) f32 {
        return @as(f32, @floatFromInt(self.delta_time)) / 1000;
    }

    pub fn deltaTimeActual(self: *State) f32 {
        return @as(f32, @floatFromInt(self.delta_time_actual)) / 1000;
    }

    pub fn getEntity(self: *State, opt_id: ?EntityId) ?*Entity {
        var result: ?*Entity = null;

        if (opt_id) |id| {
            const potential = &self.entities[id.index];
            if (potential.id.equals(id) and potential.is_in_use) {
                result = potential;
            }
        }

        return result;
    }

    pub fn addEntity(self: *State) *Entity {
        var entity_index: u32 = self.next_free_entity_index;
        var entity: *Entity = &self.entities[entity_index];

        while (entity.is_in_use) {
            entity_index += 1;
            entity = &self.entities[entity_index];
        }

        std.debug.assert(entity.is_in_use == false);

        const previous_generation = entity.id.generation;
        entity.* = .{};
        entity.is_in_use = true;
        entity.id = .{
            .index = self.next_free_entity_index,
            .generation = previous_generation + 1,
        };
        self.next_free_entity_index = entity_index + 1;

        return entity;
    }

    pub fn removeEntity(self: *State, entity: *Entity) void {
        entity.is_in_use = false;
        if (entity.id.index < self.next_free_entity_index) {
            self.next_free_entity_index = entity.id.index;
        }
    }

    pub fn showTitle(self: *State, title_type: TitleType) !void {
        try self.spawnTitle(title_type, false, 0);
    }

    pub fn showTitleForDuration(self: *State, title_type: TitleType, duration: u64) !void {
        try self.spawnTitle(title_type, true, duration);
    }

    pub fn hideTitle(self: *State) void {
        if (self.getEntity(self.current_title_id)) |title_entity| {
            self.removeEntity(title_entity);
            self.current_title_id = null;
        }
    }

    fn spawnTitle(self: *State, title_type: TitleType, has_duration: bool, duration: u64) !void {
        self.hideTitle();
        std.debug.assert(self.current_title_id == null);

        var title = try addSprite(self, @splat(0));
        title.addFlag(.is_ui);
        title.addFlag(.has_title);

        title.title_type = title_type;
        title.has_title_duration = has_duration;
        title.duration_remaining = duration;

        self.current_title_id = title.id;

        // Fade in tween.
        _ = try addTween(
            self,
            title.id,
            "sprite",
            "tint",
            .{ .color = .{ 255, 255, 255, 0 } },
            .{ .color = .{ 255, 255, 255, 255 } },
            0,
            500,
        );

        if (duration > 0) {
            // Fade out tween.
            _ = try addTween(
                self,
                title.id,
                "sprite",
                "tint",
                .{ .color = .{ 255, 255, 255, 255 } },
                .{ .color = .{ 255, 255, 255, 0 } },
                duration - 500,
                500,
            );
        }
    }

    pub fn updateTitles(self: *State) void {
        if (self.getEntity(self.current_title_id)) |title| {
            if (title.has_title_duration) {
                if (title.duration_remaining >= self.delta_time_actual) {
                    title.duration_remaining -= self.delta_time_actual;
                } else {
                    title.duration_remaining = 0;
                }

                if (title.duration_remaining == 0) {
                    self.titleDurationOver(title.title_type);
                }
            }
        }
    }

    fn titleDurationOver(self: *State, title: TitleType) void {
        self.hideTitle();

        switch (title) {
            .CLEARED => nextLevel(self),
            .DEATH => resetBall(self),
            .GAME_OVER => restart(self),
            else => {},
        }
    }

    pub fn pausedDueToTitle(self: *State) bool {
        var result: bool = false;
        if (self.getEntity(self.current_title_id)) |title_entity| {
            result = title_entity.hasFlag(.has_title);
        }
        return result;
    }
};

const Input = struct {
    left: bool = false,
    right: bool = false,
};

pub const Assets = struct {
    life_filled: ?AsepriteAsset = null,
    life_outlined: ?AsepriteAsset = null,
    life_backdrop: ?AsepriteAsset = null,

    ball_red: ?AsepriteAsset = null,
    ball_blue: ?AsepriteAsset = null,

    block_gray: ?AsepriteAsset = null,
    block_red: ?AsepriteAsset = null,
    block_blue: ?AsepriteAsset = null,
    block_change_red: ?AsepriteAsset = null,
    block_change_blue: ?AsepriteAsset = null,
    block_deadly: ?AsepriteAsset = null,

    background: ?AsepriteAsset = null,

    title_paused: ?AsepriteAsset = null,
    title_get_ready: ?AsepriteAsset = null,
    title_cleared: ?AsepriteAsset = null,
    title_death: ?AsepriteAsset = null,
    title_game_over: ?AsepriteAsset = null,

    pub fn getSpriteAsset(self: *Assets, entity: *const Entity) ?*AsepriteAsset {
        var result: ?*AsepriteAsset = null;

        if (entity.hasFlag(.player_controlled)) {
            result = self.getBall(entity.color);
        } else if (entity.hasFlag(.has_title)) {
            result = switch (entity.title_type) {
                .PAUSED => &self.title_paused.?,
                .GET_READY => &self.title_get_ready.?,
                .CLEARED => &self.title_cleared.?,
                .DEATH => &self.title_death.?,
                .GAME_OVER => &self.title_game_over.?,
                .NONE => unreachable,
            };
        } else if (entity.hasFlag(.has_block)) {
            result = self.getWall(entity.color, entity.block_type);
        } else if (entity.hasFlag(.is_background)) {
            result = &self.background.?;
        } else {
            unreachable;
        }

        return result;
    }

    pub fn getWall(self: *Assets, color: ColorComponentValue, block_type: BlockType) *AsepriteAsset {
        switch (block_type) {
            .Wall => {
                return switch (color) {
                    .Red => &self.block_red.?,
                    .Blue => &self.block_blue.?,
                    .Gray => &self.block_gray.?,
                    .None => unreachable,
                };
            },
            .ColorChange => {
                return switch (color) {
                    .Red => &self.block_change_red.?,
                    .Blue => &self.block_change_blue.?,
                    .Gray => unreachable,
                    .None => unreachable,
                };
            },
            .Deadly => {
                return switch (color) {
                    .Gray => &self.block_deadly.?,
                    else => unreachable,
                };
            },
            .None => unreachable,
        }

        unreachable;
    }

    pub fn getBall(self: *Assets, color: ColorComponentValue) *AsepriteAsset {
        return switch (color) {
            .Red => &self.ball_red.?,
            .Blue => &self.ball_blue.?,
            .Gray => unreachable,
            .None => unreachable,
        };
    }
};

pub export fn init(window_width: u32, window_height: u32, window: *sdl.SDL_Window) *anyopaque {
    sdl_utils.logError(sdl.SDL_SetWindowTitle(window, "Diamonds"), "Failed to set window title");

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
        .renderer = sdl_utils.panicIfNull(sdl.SDL_CreateRenderer(window, null), "Failed to create renderer.").?,

        .window_width = window_width,
        .window_height = window_height,

        .world_scale = 1,
        .ui_scale = 1,
        .world_width = WORLD_WIDTH,
        .world_height = WORLD_HEIGHT,

        .assets = .{},

        .time = sdl.SDL_GetTicks(),
        .delta_time = 0,
        .delta_time_actual = 0,
        .input = .{},
        .ball_horizontal_bounce_start_time = 0,

        .paused = false,
        .fullscreen = false,

        .level_index = 0,
        .lives_remaining = MAX_LIVES,

        .entities = [1]Entity{.{}} ** MAX_ENTITY_COUNT,
        .next_free_entity_index = 0,

        .ball_id = null,
        .current_title_id = null,
    };

    if (INTERNAL) {
        state.debug_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize debug allocator."));
        state.debug_allocator.* = .init;
        state.debug_state = state.debug_allocator.allocator().create(debug.DebugState) catch @panic("Out of memory");
        state.debug_state.init() catch @panic("Failed to init DebugState");

        state.fps_state =
            state.debug_allocator.allocator().create(FPSState) catch @panic("Failed to allocate FPS state");
        state.fps_state.?.init(sdl.SDL_GetPerformanceFrequency());
    }

    loadAssets(state);
    spawnBackground(state) catch unreachable;
    spawnBall(state) catch unreachable;
    loadLevel(state, LEVELS[state.level_index]) catch unreachable;

    setupRenderTexture(state);

    if (INTERNAL) {
        imgui.init(state.window, state.renderer, @floatFromInt(state.window_width), @floatFromInt(state.window_height));
    }

    return state;
}

pub fn restart(state: *State) void {
    deinit(state);

    state.* = @as(
        *State,
        @ptrCast(
            @alignCast(
                init(
                    state.window_width,
                    state.window_height,
                    state.window,
                ),
            ),
        ),
    ).*;
}

pub export fn deinit(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        imgui.deinit();
    }

    sdl.SDL_DestroyRenderer(state.renderer);
}

pub fn setupRenderTexture(state: *State) void {
    _ = sdl.SDL_GetWindowSize(state.window, @ptrCast(&state.window_width), @ptrCast(&state.window_height));
    state.world_scale = @as(f32, @floatFromInt(state.window_height)) / @as(f32, @floatFromInt(state.world_height));

    const horizontal_offset: f32 =
        (@as(f32, @floatFromInt(state.window_width)) - (@as(f32, @floatFromInt(state.world_width)) * state.world_scale)) / 2;
    state.dest_rect = sdl.SDL_FRect{
        .x = horizontal_offset,
        .y = 0,
        .w = @as(f32, @floatFromInt(state.world_width)) * state.world_scale,
        .h = @as(f32, @floatFromInt(state.world_height)) * state.world_scale,
    };

    state.render_texture = sdl_utils.panicIfNull(sdl.SDL_CreateTexture(
        state.renderer,
        sdl.SDL_PIXELFORMAT_RGBA32,
        sdl.SDL_TEXTUREACCESS_TARGET,
        @intCast(state.world_width),
        @intCast(state.world_height),
    ), "Failed to initialize main render texture.");

    sdl_utils.panic(
        sdl.SDL_SetTextureScaleMode(state.render_texture, sdl.SDL_SCALEMODE_NEAREST),
        "Failed to set scale mode for the main render texture.",
    );
}

pub export fn willReload(state_ptr: *anyopaque) void {
    _ = state_ptr;

    if (INTERNAL) {
        imgui.deinit();
    }
}

pub export fn reloaded(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    unloadAssets(state);
    loadAssets(state);

    if (INTERNAL) {
        imgui.init(state.window, state.renderer, @floatFromInt(state.window_width), @floatFromInt(state.window_height));
    }

    if (state.getEntity(state.ball_id)) |ball| {
        ball.velocity[Y] = if (ball.velocity[Y] > 0) BALL_VELOCITY else -BALL_VELOCITY;
    }
}

pub export fn processInput(state_ptr: *anyopaque) bool {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        state.debug_state.input.reset();
    }

    var continue_running: bool = true;
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event)) {
        const event_used = if (INTERNAL) imgui.processEvent(&event) else false;
        if (event_used) {
            continue;
        }

        if (event.type == sdl.SDL_EVENT_QUIT or (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE)) {
            continue_running = false;
            break;
        }

        if (INTERNAL) {
            debug.processInputEvent(state, event);
        }

        // Game input.
        if (event.type == sdl.SDL_EVENT_KEY_DOWN or event.type == sdl.SDL_EVENT_KEY_UP) {
            const is_down = event.type == sdl.SDL_EVENT_KEY_DOWN;
            switch (event.key.key) {
                sdl.SDLK_LEFT => {
                    state.input.left = is_down;
                },
                sdl.SDLK_RIGHT => {
                    state.input.right = is_down;
                },
                sdl.SDLK_F => {
                    if (is_down) {
                        state.fullscreen = !state.fullscreen;
                        _ = sdl.SDL_SetWindowFullscreen(state.window, state.fullscreen);
                    }
                },
                sdl.SDLK_P => {
                    if (is_down) {
                        state.paused = !state.paused;

                        if (state.paused) {
                            state.showTitle(.PAUSED) catch @panic("Failed to show Paused title");
                        } else {
                            state.hideTitle();
                        }
                    }
                },
                else => {},
            }
        }

        if (event.type == sdl.SDL_EVENT_WINDOW_RESIZED) {
            setupRenderTexture(state);
        }
    }

    if (INTERNAL) {
        debug.handleInput(state, state.debug_allocator.allocator());
    }

    return continue_running;
}

pub export fn tick(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    state.delta_time_actual = sdl.SDL_GetTicks() - state.time;
    if (!state.paused and !state.pausedDueToTitle()) {
        state.delta_time = state.delta_time_actual;
    } else {
        state.delta_time = 0;
    }
    state.time = sdl.SDL_GetTicks();

    if (INTERNAL) {
        state.fps_state.?.addFrameTime(sdl.SDL_GetPerformanceCounter());
        debug.recordMemoryUsage(state);
    }

    state.updateTitles();

    const opt_ball: ?*Entity = state.getEntity(state.ball_id);
    if (opt_ball) |ball| {
        if ((state.ball_horizontal_bounce_start_time + BALL_HORIZONTAL_BOUNCE_TIME) < state.time) {
            if (state.input.left) {
                ball.velocity[X] = -BALL_VELOCITY;
            } else if (state.input.right) {
                ball.velocity[X] = BALL_VELOCITY;
            } else {
                ball.velocity[X] = 0;
            }
        }
    }

    const delta_time = state.deltaTime();
    const delta_time_actual = state.deltaTimeActual();
    const collisions: CollisionResult = Entity.checkForCollisions(state, delta_time);

    // Handle vertical collisions.
    if (collisions.vertical) |collision| {
        if (collision.id.equals(state.ball_id)) {
            if (state.getEntity(collision.id)) |entity| {
                if (state.getEntity(collision.other_id)) |other_entity| {
                    entity.next_velocity = entity.velocity;
                    entity.next_velocity[Y] = -entity.next_velocity[Y];

                    const bounce_animation = if (entity.velocity[Y] < 0) "bounce_up" else "bounce_down";
                    entity.startAnimation(bounce_animation, &state.assets);
                    entity.velocity[Y] = 0;

                    if (INTERNAL) {
                        state.debug_state.addCollision(state.debug_allocator.allocator(), &collision, state.time);
                    }

                    handleBallCollision(state, entity, other_entity);
                }
            }
        }
    }

    // Handle horizontal collisions.
    if (collisions.horizontal) |collision| {
        if (collision.id.equals(state.ball_id)) {
            if (state.getEntity(collision.id)) |entity| {
                if (state.getEntity(collision.other_id)) |other_entity| {
                    entity.velocity[X] = -entity.velocity[X];
                    state.ball_horizontal_bounce_start_time = state.time;

                    if (INTERNAL) {
                        state.debug_state.addCollision(state.debug_allocator.allocator(), &collision, state.time);
                    }

                    handleBallCollision(state, entity, other_entity);
                }
            }
        }
    }

    // Handle ball specific animations.
    if (opt_ball) |ball| {
        if (ball.animation_completed and (ball.isAnimating("bounce_up") or ball.isAnimating("bounce_down"))) {
            ball.velocity = ball.next_velocity;
            ball.startAnimation("idle", &state.assets);
        }
    }

    // Update transforms.
    for (&state.entities) |*entity| {
        if (entity.is_in_use and entity.hasFlag(.has_transform)) {
            entity.position += entity.velocity * @as(Vector2, @splat(delta_time));
        }
    }

    // Update tweens.
    for (&state.entities) |*entity| {
        if (entity.is_in_use and entity.hasFlag(.has_tween)) {
            const total_duration = entity.tween_delay + entity.tween_duration;
            entity.tween_time_passed += @intFromFloat(delta_time_actual * 1000);

            if (entity.tween_time_passed <= total_duration and entity.tween_delay <= entity.tween_time_passed) {
                const t: f32 =
                    @as(f32, @floatFromInt(entity.tween_time_passed - entity.tween_delay)) /
                    @as(f32, @floatFromInt(entity.tween_duration));

                const type_info = @typeInfo(Entity);
                if (state.getEntity(entity.tween_target)) |target| {
                    inline for (type_info.@"struct".fields) |entity_field_info| {
                        if (std.mem.eql(u8, entity_field_info.name, entity.tween_target_field)) {
                            const current_value = &@field(target, entity_field_info.name);
                            switch (@TypeOf(current_value)) {
                                *f32 => {
                                    current_value.* = math.lerp(entity.tween_start_value.f32, entity.tween_end_value.f32, t);
                                },
                                *Color => {
                                    current_value.* = .{
                                        math.lerpU8(entity.tween_start_value.color[R], entity.tween_end_value.color[R], t),
                                        math.lerpU8(entity.tween_start_value.color[G], entity.tween_end_value.color[G], t),
                                        math.lerpU8(entity.tween_start_value.color[B], entity.tween_end_value.color[B], t),
                                        math.lerpU8(entity.tween_start_value.color[A], entity.tween_end_value.color[A], t),
                                    };
                                },
                                else => {},
                            }
                        }
                    }
                }
            } else if (entity.tween_time_passed > entity.tween_duration + entity.tween_delay) {
                // Remove completed tweens.
                state.removeEntity(entity);
            }
        }
    }

    // Update sprites.
    for (&state.entities) |*entity| {
        if (entity.is_in_use and entity.hasFlag(.has_sprite)) {
            if (state.assets.getSpriteAsset(entity)) |sprite_asset| {
                if (sprite_asset.document.frames.len > 1) {
                    const current_frame = sprite_asset.document.frames[entity.frame_index];
                    var from_frame: u16 = 0;
                    var to_frame: u16 = @intCast(sprite_asset.document.frames.len);

                    if (entity.current_animation) |tag| {
                        from_frame = tag.from_frame;
                        to_frame = tag.to_frame;
                    }

                    entity.duration_shown += delta_time;

                    if (entity.duration_shown * 1000 >= @as(f64, @floatFromInt(current_frame.header.frame_duration))) {
                        var next_frame = entity.frame_index + 1;
                        if (next_frame > to_frame) {
                            if (entity.loop_animation) {
                                next_frame = from_frame;
                            } else {
                                entity.animation_completed = true;
                                next_frame = to_frame;
                                continue;
                            }
                        }

                        entity.setFrame(next_frame, sprite_asset);
                    }
                }
            }
        }
    }

    if (isLevelCompleted(state) and state.getEntity(state.current_title_id) == null) {
        if (!INTERNAL) {
            state.showTitleForDuration(.CLEARED, 2000) catch @panic("Failed to show Cleared title");
        } else {
            if (!state.debug_state.show_editor and !state.debug_state.testing_level) {
                state.showTitleForDuration(.CLEARED, 2000) catch @panic("Failed to show Cleared title");
            } else if (state.debug_state.testing_level) {
                loadLevel(state, state.debug_state.currentLevelName()) catch unreachable;
            }
        }
    }
}

fn handleBallCollision(state: *State, ball: *Entity, block: *Entity) void {
    if (block.block_type == .Deadly) {
        if (state.lives_remaining > 0) {
            if (!INTERNAL or !state.debug_state.testing_level) {
                state.lives_remaining -= 1;
            }
            state.showTitleForDuration(.DEATH, 2000) catch @panic("Failed to show Death title");
        } else {
            state.showTitleForDuration(.GAME_OVER, 2000) catch @panic("Failed to show Game Over title");
            return;
        }
    }

    if (block.block_type == .Wall and block.color == ball.color) {
        state.removeEntity(block);
    } else if (block.block_type == .ColorChange and block.color != ball.color) {
        ball.color = block.color;
    }
}

pub export fn draw(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    sdl_utils.panic(sdl.SDL_SetRenderTarget(state.renderer, state.render_texture), "Failed to set render target.");
    {
        _ = sdl.SDL_SetRenderDrawColor(state.renderer, 0, 0, 0, 255);
        _ = sdl.SDL_RenderClear(state.renderer);
        drawWorld(state);
        drawGameUI(state);
    }

    _ = sdl.SDL_SetRenderTarget(state.renderer, null);
    {
        _ = sdl.SDL_SetRenderDrawColor(state.renderer, 0, 0, 0, 255);
        _ = sdl.SDL_RenderClear(state.renderer);
        _ = sdl.SDL_RenderTexture(state.renderer, state.render_texture, null, &state.dest_rect);

        if (INTERNAL) {
            debug.drawDebugOverlay(state);
            debug.drawDebugUI(state);
        }
    }
    _ = sdl.SDL_RenderPresent(state.renderer);
}

fn drawWorld(state: *State) void {
    for (&state.entities) |*entity| {
        if (entity.is_in_use and entity.hasFlag(.has_sprite) and entity.hasFlag(.has_transform) and !entity.hasFlag(.is_ui)) {
            if (entity.getTexture(&state.assets)) |texture| {
                drawTextureAt(state, texture, entity.position, entity.scale, entity.tint);
            }
        }
    }
}

fn drawGameUI(state: *State) void {
    const inner_offset: Vector2 = .{ 3, 2 };
    const horizontal_space: u32 = 2;

    var position = Vector2{ 0, 0 };
    if (state.assets.life_backdrop) |backdrop| {
        const texture = backdrop.frames[0];
        position[X] =
            (@as(f32, @floatFromInt(state.window_width)) / state.world_scale / 2) -
            (@as(f32, @floatFromInt(texture.w)) / 2);
        drawTextureAt(state, texture, position, @splat(1), @splat(255));
    }

    position += inner_offset;

    if (state.assets.life_filled) |filled| {
        if (state.assets.life_outlined) |outlined| {
            for (0..MAX_LIVES) |i| {
                const texture = (if (state.lives_remaining > i) filled else outlined).frames[0];
                drawTextureAt(state, texture, position, @splat(1), @splat(255));
                position[X] += @floatFromInt(texture.w + horizontal_space);
            }
        }
    }

    for (&state.entities) |*entity| {
        if (entity.is_in_use and entity.hasFlag(.has_sprite) and entity.hasFlag(.has_transform) and entity.hasFlag(.is_ui)) {
            if (entity.getTexture(&state.assets)) |texture| {
                position = entity.getUIPosition(state.dest_rect, state.world_scale, &state.assets);
                drawTextureAt(state, texture, position, entity.scale, entity.tint);
            }
        }
    }
}

fn drawTextureAt(state: *State, texture: *sdl.SDL_Texture, position: Vector2, scale: Vector2, tint: Color) void {
    const texture_rect = sdl.SDL_FRect{
        .x = @round(position[X]),
        .y = @round(position[Y]),
        .w = @as(f32, @floatFromInt(texture.w)) * scale[X],
        .h = @as(f32, @floatFromInt(texture.h)) * scale[Y],
    };

    sdl_utils.panic(sdl.SDL_SetTextureColorMod(texture, tint[R], tint[G], tint[B]), "Failed to set texture color mod.");
    sdl_utils.panic(sdl.SDL_SetTextureAlphaMod(texture, tint[A]), "Failed to set texture alpha mod.");

    _ = sdl.SDL_RenderTexture(state.renderer, texture, null, &texture_rect);
}

fn loadAssets(state: *State) void {
    state.assets.life_filled = .load("assets/life_filled.aseprite", state.renderer, state.allocator);
    state.assets.life_outlined = .load("assets/life_outlined.aseprite", state.renderer, state.allocator);
    state.assets.life_backdrop = .load("assets/life_backdrop.aseprite", state.renderer, state.allocator);

    state.assets.ball_red = .load("assets/ball_red.aseprite", state.renderer, state.allocator);
    state.assets.ball_blue = .load("assets/ball_blue.aseprite", state.renderer, state.allocator);

    state.assets.block_gray = .load("assets/block_gray.aseprite", state.renderer, state.allocator);
    state.assets.block_red = .load("assets/block_red.aseprite", state.renderer, state.allocator);
    state.assets.block_blue = .load("assets/block_blue.aseprite", state.renderer, state.allocator);
    state.assets.block_change_red = .load("assets/block_change_red.aseprite", state.renderer, state.allocator);
    state.assets.block_change_blue = .load("assets/block_change_blue.aseprite", state.renderer, state.allocator);
    state.assets.block_deadly = .load("assets/block_deadly.aseprite", state.renderer, state.allocator);

    state.assets.background = .load("assets/background.aseprite", state.renderer, state.allocator);

    state.assets.title_paused = .load("assets/title_paused.aseprite", state.renderer, state.allocator);
    state.assets.title_get_ready = .load("assets/title_get_ready.aseprite", state.renderer, state.allocator);
    state.assets.title_cleared = .load("assets/title_cleared.aseprite", state.renderer, state.allocator);
    state.assets.title_death = .load("assets/title_death.aseprite", state.renderer, state.allocator);
    state.assets.title_game_over = .load("assets/title_game_over.aseprite", state.renderer, state.allocator);
}

fn unloadAssets(state: *State) void {
    state.assets.life_filled.?.deinit(state.allocator);
    state.assets.life_outlined.?.deinit(state.allocator);
    state.assets.life_backdrop.?.deinit(state.allocator);

    state.assets.ball_red.?.deinit(state.allocator);
    state.assets.ball_blue.?.deinit(state.allocator);

    state.assets.block_gray.?.deinit(state.allocator);
    state.assets.block_red.?.deinit(state.allocator);
    state.assets.block_blue.?.deinit(state.allocator);
    state.assets.block_change_red.?.deinit(state.allocator);
    state.assets.block_change_blue.?.deinit(state.allocator);
    state.assets.block_deadly.?.deinit(state.allocator);

    state.assets.background.?.deinit(state.allocator);

    state.assets.title_paused.?.deinit(state.allocator);
    state.assets.title_get_ready.?.deinit(state.allocator);
    state.assets.title_cleared.?.deinit(state.allocator);
    state.assets.title_death.?.deinit(state.allocator);
    state.assets.title_game_over.?.deinit(state.allocator);

    std.log.info("Assets unloaded.", .{});
}

fn spawnBackground(state: *State) !void {
    var entity = try addSprite(state, @splat(0));
    entity.addFlag(.is_background);
}

fn spawnBall(state: *State) !void {
    var entity = try addSprite(state, BALL_SPAWN);
    entity.addFlag(.player_controlled);
    entity.addFlag(.has_collider);

    entity.collider_shape = .Circle;
    entity.collider_radius = 6;
    entity.collider_offset = @splat(1);
    entity.color = .Red;
    entity.startAnimation("idle", &state.assets);

    state.ball_id = entity.id;

    resetBall(state);
}

fn resetBall(state: *State) void {
    if (state.getEntity(state.ball_id)) |ball| {
        ball.position = BALL_SPAWN;
        ball.velocity[Y] = BALL_VELOCITY;
        ball.color = .Red;
        ball.startAnimation("idle", &state.assets);

        state.showTitleForDuration(.GET_READY, 2000) catch @panic("Failed to show Get Ready title");
    }
}

fn unloadLevel(state: *State) void {
    for (&state.entities) |*entity| {
        if (entity.is_in_use and entity.hasFlag(.has_block)) {
            state.removeEntity(entity);
        }
    }
}

pub fn loadLevel(state: *State, name: []const u8) !void {
    var buf: [LEVEL_NAME_BUFFER_SIZE * 2]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "assets/{s}.lvl", .{name});
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });

    var reader_buf: [10 * 1024]u8 = undefined;
    var file_reader = file.reader(&reader_buf);
    var reader: *std.Io.Reader = &file_reader.interface;
    const wall_count = try reader.takeInt(u32, .little);

    unloadLevel(state);

    for (0..wall_count) |_| {
        const color = try reader.takeInt(u32, .little);
        const block_type = try reader.takeInt(u32, .little);
        const x = try reader.takeInt(i32, .little);
        const y = try reader.takeInt(i32, .little);

        _ = try addWall(
            state,
            @enumFromInt(color),
            @enumFromInt(block_type),
            Vector2{ @floatFromInt(x), @floatFromInt(y) },
        );
    }

    resetBall(state);
}

pub fn reloadCurrentLevel(state: *State) void {
    loadLevel(state, LEVELS[state.level_index]) catch unreachable;
}

fn nextLevel(state: *State) void {
    state.level_index += 1;
    if (state.level_index > LEVELS.len - 1) {
        state.level_index = 0;
    }

    loadLevel(state, LEVELS[state.level_index]) catch unreachable;
}

fn isLevelCompleted(state: *State) bool {
    var result = true;

    for (&state.entities) |*entity| {
        if (entity.is_in_use and entity.hasFlag(.has_block)) {
            if (entity.block_type == .Wall and entity.color != .Gray) {
                result = false;
            }
        }
    }

    return result;
}

fn addTween(
    state: *State,
    target: EntityId,
    comptime component: []const u8,
    comptime field: []const u8,
    start_value: TweenedValue,
    end_value: TweenedValue,
    delay: u64,
    duration: u64,
) !*Entity {
    var entity: *Entity = state.addEntity();
    entity.addFlag(.has_tween);

    entity.tween_delay = delay;
    entity.tween_duration = duration;
    entity.tween_time_passed = 0;

    entity.tween_target = target;
    entity.tween_target_component = component;
    entity.tween_target_field = field;

    entity.tween_start_value = start_value;
    entity.tween_end_value = end_value;

    return entity;
}

fn addSprite(state: *State, position: Vector2) !*Entity {
    var entity: *Entity = state.addEntity();
    entity.addFlag(.has_sprite);
    entity.addFlag(.has_transform);

    entity.tint = @splat(255);
    entity.frame_index = 0;
    entity.duration_shown = 0;
    entity.loop_animation = false;
    entity.animation_completed = false;
    entity.current_animation = null;

    entity = entity;
    entity.position = position;
    entity.scale = @splat(1);
    entity.velocity = @splat(0);
    entity.next_velocity = @splat(0);

    return entity;
}

pub fn addWall(state: *State, color: ColorComponentValue, block_type: BlockType, position: Vector2) !*Entity {
    const new_entity = try addSprite(state, position);
    new_entity.addFlag(.has_collider);
    new_entity.addFlag(.has_block);

    if (block_type == .ColorChange and color == .Gray) {
        return error.InvalidColor;
    }

    if (block_type == .Deadly and color != .Gray) {
        return error.InvalidColor;
    }

    const sprite_asset = state.assets.getWall(color, block_type);
    new_entity.collider_shape = .Square;
    new_entity.collider_size = Vector2{
        @floatFromInt(sprite_asset.document.header.width),
        @floatFromInt(sprite_asset.document.header.height),
    };
    new_entity.collider_offset = @splat(0);

    new_entity.color = color;
    new_entity.block_type = block_type;

    return new_entity;
}
