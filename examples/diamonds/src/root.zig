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

const Entity = entities.Entity;
const EntityId = entities.EntityId;
const EntityIterator = entities.EntityIterator;
const TransformComponent = entities.TransformComponent;
const ColliderComponent = entities.ColliderComponent;
const SpriteComponent = entities.SpriteComponent;
const ColorComponent = entities.ColorComponent;
const ColorComponentValue = entities.ColorComponentValue;
const BlockComponent = entities.BlockComponent;
const BlockType = entities.BlockType;
const TitleComponent = entities.TitleComponent;
const TitleType = entities.TitleType;
const TweenComponent = entities.TweenComponent;
const TweenedValue = entities.TweenedValue;
const Pool = pool.Pool;
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
    entities: std.ArrayList(*Entity),
    entities_free: std.ArrayList(u32),
    entities_iterator: EntityIterator,
    ball_id: ?EntityId,
    current_title_id: ?EntityId,

    transform_pool: Pool(TransformComponent),
    collider_pool: Pool(ColliderComponent),
    sprite_pool: Pool(SpriteComponent),
    color_pool: Pool(ColorComponent),
    block_pool: Pool(BlockComponent),
    title_pool: Pool(TitleComponent),
    tween_pool: Pool(TweenComponent),

    pub fn deltaTime(self: *State) f32 {
        return @as(f32, @floatFromInt(self.delta_time)) / 1000;
    }

    pub fn deltaTimeActual(self: *State) f32 {
        return @as(f32, @floatFromInt(self.delta_time_actual)) / 1000;
    }

    pub fn getEntity(self: *State, opt_id: ?EntityId) ?*Entity {
        var result: ?*Entity = null;

        if (opt_id) |id| {
            const potential = self.entities.items[id.index];
            if (potential.id.equals(id) and potential.is_in_use) {
                result = potential;
            }
        }

        return result;
    }

    pub fn addEntity(self: *State) !*Entity {
        var result: *Entity = undefined;

        if (self.entities_free.pop()) |free_index| {
            result = self.entities.items[free_index];
            result.is_in_use = true;
            result.id.generation += 1;
        } else {
            result = try Entity.init(self.allocator);
            result.id.index = @intCast(self.entities.items.len);
            result.id.generation = 0;
            result.is_in_use = true;
            self.entities.append(self.allocator, result) catch @panic("Failed to allocate entity");
        }

        return result;
    }

    pub fn removeEntity(self: *State, entity: *Entity) void {
        std.debug.assert(entity.is_in_use == true);

        entity.is_in_use = false;
        self.entities_free.append(self.allocator, entity.id.index) catch @panic("Failed to allocate free index");

        if (entity.transform) |transform| {
            self.transform_pool.free(transform.pool_id, self.allocator) catch @panic("Failed to free transform component");
            entity.transform = null;
        }
        if (entity.collider) |collider| {
            self.collider_pool.free(collider.pool_id, self.allocator) catch @panic("Failed to free collider component");
            entity.collider = null;
        }
        if (entity.sprite) |sprite| {
            self.sprite_pool.free(sprite.pool_id, self.allocator) catch @panic("Failed to free sprite component");
            entity.sprite = null;
        }
        if (entity.color) |color| {
            self.color_pool.free(color.pool_id, self.allocator) catch @panic("Failed to free color component");
            entity.color = null;
        }
        if (entity.block) |block| {
            self.block_pool.free(block.pool_id, self.allocator) catch @panic("Failed to free block component");
            entity.block = null;
        }
        if (entity.title) |title| {
            self.title_pool.free(title.pool_id, self.allocator) catch @panic("Failed to free title component");
            entity.title = null;
        }
        if (entity.tween) |tween| {
            self.tween_pool.free(tween.pool_id, self.allocator) catch @panic("Failed to free tween component");
            entity.tween = null;
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

        if (addSprite(self, @splat(0)) catch null) |title_entity| {
            var title_component: *TitleComponent = try self.title_pool.getOrCreate(self.allocator);
            title_component.entity = title_entity;
            title_component.type = title_type;
            title_component.has_duration = has_duration;
            title_component.duration_remaining = duration;

            title_entity.title = title_component;
            self.current_title_id = title_entity.id;

            // Fade in tween.
            _ = try addTween(
                self,
                title_entity.id,
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
                    title_entity.id,
                    "sprite",
                    "tint",
                    .{ .color = .{ 255, 255, 255, 255 } },
                    .{ .color = .{ 255, 255, 255, 0 } },
                    duration - 500,
                    500,
                );
            }
        }
    }

    pub fn updateTitles(self: *State) void {
        if (self.getEntity(self.current_title_id)) |title_entity| {
            if (title_entity.title) |title| {
                if (title.has_duration) {
                    if (title.duration_remaining >= self.delta_time_actual) {
                        title.duration_remaining -= self.delta_time_actual;
                    } else {
                        title.duration_remaining = 0;
                    }

                    if (title.duration_remaining == 0) {
                        self.titleDurationOver(title.type);
                    }
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
            result = title_entity.title != null;
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

    pub fn getSpriteAsset(self: *Assets, sprite: *const SpriteComponent) ?*AsepriteAsset {
        var result: ?*AsepriteAsset = null;

        if (sprite.entity.title) |title| {
            result = switch (title.type) {
                .PAUSED => &self.title_paused.?,
                .GET_READY => &self.title_get_ready.?,
                .CLEARED => &self.title_cleared.?,
                .DEATH => &self.title_death.?,
                .GAME_OVER => &self.title_game_over.?,
            };
        } else if (sprite.entity.color) |color| {
            switch (sprite.entity.entity_type) {
                .Ball => result = self.getBall(color.color),
                .Wall => {
                    if (sprite.entity.block) |block| {
                        result = self.getWall(color.color, block.type);
                    }
                },
                else => unreachable,
            }
        } else {
            result = switch (sprite.entity.entity_type) {
                .Background => &self.background.?,
                else => unreachable,
            };
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
                };
            },
            .ColorChange => {
                return switch (color) {
                    .Red => &self.block_change_red.?,
                    .Blue => &self.block_change_blue.?,
                    .Gray => unreachable,
                };
            },
            .Deadly => {
                return switch (color) {
                    .Gray => &self.block_deadly.?,
                    else => unreachable,
                };
            },
        }

        unreachable;
    }

    pub fn getBall(self: *Assets, color: ColorComponentValue) *AsepriteAsset {
        return switch (color) {
            .Red => &self.ball_red.?,
            .Blue => &self.ball_blue.?,
            .Gray => unreachable,
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

        .entities = .empty,
        .entities_free = .empty,
        .entities_iterator = .{ .entities = &state.entities },
        .ball_id = null,
        .current_title_id = null,

        .transform_pool = Pool(TransformComponent).init(100, state.allocator) catch @panic("Failed to create transform pool"),
        .collider_pool = Pool(ColliderComponent).init(100, state.allocator) catch @panic("Failed to create collider pool"),
        .sprite_pool = Pool(SpriteComponent).init(100, state.allocator) catch @panic("Failed to create sprite pool"),
        .color_pool = Pool(ColorComponent).init(100, state.allocator) catch @panic("Failed to create color pool"),
        .block_pool = Pool(BlockComponent).init(100, state.allocator) catch @panic("Failed to create block pool"),
        .title_pool = Pool(TitleComponent).init(@typeInfo(TitleType).@"enum".fields.len, state.allocator) catch @panic("Failed to create title pool"),
        .tween_pool = Pool(TweenComponent).init(100, state.allocator) catch @panic("Failed to create tween pool"),
    };

    state.entities.ensureUnusedCapacity(state.allocator, 100) catch @panic("Failed to allocate space for entities.");
    state.entities_free.ensureUnusedCapacity(state.allocator, 100) catch @panic("Failed to allocate space for free entities.");

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
        if (ball.transform) |transform| {
            transform.velocity[Y] = if (transform.velocity[Y] > 0) BALL_VELOCITY else -BALL_VELOCITY;
        }
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

    const opt_ball = state.getEntity(state.ball_id);
    if (opt_ball) |ball| {
        if (ball.transform) |transform| {
            if ((state.ball_horizontal_bounce_start_time + BALL_HORIZONTAL_BOUNCE_TIME) < state.time) {
                if (state.input.left) {
                    transform.velocity[X] = -BALL_VELOCITY;
                } else if (state.input.right) {
                    transform.velocity[X] = BALL_VELOCITY;
                } else {
                    transform.velocity[X] = 0;
                }
            }
        }
    }

    var iter: EntityIterator = .{ .entities = &state.entities };
    const collisions = ColliderComponent.checkForCollisions(&iter, state.deltaTime());

    // Handle vertical collisions.
    if (collisions.vertical) |collision| {
        if (collision.id.equals(state.ball_id)) {
            if (state.getEntity(collision.id)) |entity| {
                if (state.getEntity(collision.other_id)) |other_entity| {
                    if (entity.transform) |transform| {
                        transform.next_velocity = transform.velocity;
                        transform.next_velocity[Y] = -transform.next_velocity[Y];

                        entity.sprite.?.startAnimation(
                            if (transform.velocity[Y] < 0) "bounce_up" else "bounce_down",
                            &state.assets,
                        );
                        transform.velocity[Y] = 0;

                        if (INTERNAL) {
                            state.debug_state.addCollision(state.debug_allocator.allocator(), &collision, state.time);
                        }

                        handleBallCollision(state, entity, other_entity);
                    }
                }
            }
        }
    }

    // Handle horizontal collisions.
    if (collisions.horizontal) |collision| {
        if (collision.id.equals(state.ball_id)) {
            if (state.getEntity(collision.id)) |entity| {
                if (state.getEntity(collision.other_id)) |other_entity| {
                    if (entity.transform) |transform| {
                        transform.velocity[X] = -transform.velocity[X];
                        state.ball_horizontal_bounce_start_time = state.time;

                        if (INTERNAL) {
                            state.debug_state.addCollision(state.debug_allocator.allocator(), &collision, state.time);
                        }

                        handleBallCollision(state, entity, other_entity);
                    }
                }
            }
        }
    }

    // Handle ball specific animations.
    if (opt_ball) |ball| {
        if (ball.sprite) |sprite| {
            if (ball.transform) |transform| {
                if (sprite.animation_completed and (sprite.isAnimating("bounce_up") or sprite.isAnimating("bounce_down"))) {
                    transform.velocity = transform.next_velocity;
                    sprite.startAnimation("idle", &state.assets);
                }
            }
        }
    }

    iter.reset();
    TransformComponent.tick(&iter, state.deltaTime());

    iter.reset();
    TweenComponent.tick(state, &iter, state.deltaTimeActual());

    // Remove any completed tweens.
    iter.reset();
    while (iter.next(&.{.tween})) |entity| {
        const tween = entity.tween.?;
        if (entity.is_in_use) {
            if (tween.time_passed > tween.duration + tween.delay) {
                state.removeEntity(entity);
            }
        }
    }

    iter.reset();
    SpriteComponent.tick(&state.assets, &iter, state.deltaTime());

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
    if (ball.color) |ball_color| {
        if (block.block) |other_block| {
            if (other_block.type == .Deadly) {
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

            if (block.color) |other_color| {
                if (other_block.type == .Wall and other_color.color == ball_color.color) {
                    state.removeEntity(block);
                } else if (other_block.type == .ColorChange and other_color.color != ball_color.color) {
                    ball_color.color = other_color.color;
                }
            }
        }
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
    var iter: EntityIterator = .{ .entities = &state.entities };
    while (iter.next(&.{ .sprite, .transform })) |entity| {
        if (entity.title == null) {
            if (entity.sprite.?.getTexture(&state.assets)) |texture| {
                drawTextureAt(state, texture, entity.transform.?.position, entity.transform.?.scale, entity.sprite.?.tint);
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

    var iter: EntityIterator = .{ .entities = &state.entities };
    while (iter.next(&.{ .sprite, .title })) |entity| {
        if (entity.sprite.?.getTexture(&state.assets)) |texture| {
            const title_position: Vector2 = entity.title.?.getPosition(state.dest_rect, state.world_scale, &state.assets);
            drawTextureAt(state, texture, title_position, entity.transform.?.scale, entity.sprite.?.tint);
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
    if (addSprite(state, @splat(0)) catch null) |entity| {
        entity.entity_type = .Background;
    }
}

fn spawnBall(state: *State) !void {
    if (addSprite(state, BALL_SPAWN) catch null) |entity| {
        var collider_component: *ColliderComponent = state.collider_pool.getOrCreate(state.allocator) catch undefined;
        entity.entity_type = .Ball;
        collider_component.entity = entity;
        collider_component.shape = .Circle;
        collider_component.radius = 6;
        collider_component.offset = @splat(1);

        var color_component: *ColorComponent = state.color_pool.getOrCreate(state.allocator) catch undefined;
        color_component.entity = entity;
        color_component.color = .Red;

        entity.color = color_component;
        entity.collider = collider_component;

        state.ball_id = entity.id;

        if (entity.sprite) |ball_sprite| {
            ball_sprite.startAnimation("idle", &state.assets);
        }

        resetBall(state);
    }
}

fn resetBall(state: *State) void {
    if (state.getEntity(state.ball_id)) |ball| {
        ball.transform.?.position = BALL_SPAWN;
        ball.transform.?.velocity[Y] = BALL_VELOCITY;
        ball.color.?.color = .Red;
        ball.sprite.?.startAnimation("idle", &state.assets);

        state.showTitleForDuration(.GET_READY, 2000) catch @panic("Failed to show Get Ready title");
    }
}

fn unloadLevel(state: *State) void {
    var iter: EntityIterator = .{ .entities = &state.entities };
    while (iter.next(&.{.block})) |entity| {
        state.removeEntity(entity);
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
    var iter: EntityIterator = .{ .entities = &state.entities };
    while (iter.next(&.{ .block, .color })) |entity| {
        if (entity.block.?.type == .Wall and entity.color.?.color != .Gray) {
            result = false;
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
    var entity: *Entity = try state.addEntity();
    var tween: *TweenComponent = try state.tween_pool.getOrCreate(state.allocator);

    tween.delay = delay;
    tween.duration = duration;
    tween.time_passed = 0;

    tween.target = target;
    tween.target_component = component;
    tween.target_field = field;

    tween.start_value = start_value;
    tween.end_value = end_value;

    entity.tween = tween;
    return entity;
}

fn addSprite(state: *State, position: Vector2) !*Entity {
    var entity: *Entity = try state.addEntity();
    var sprite: *SpriteComponent = try state.sprite_pool.getOrCreate(state.allocator);
    var transform: *TransformComponent = try state.transform_pool.getOrCreate(state.allocator);

    sprite.entity = entity;
    sprite.tint = @splat(255);
    sprite.frame_index = 0;
    sprite.duration_shown = 0;
    sprite.loop_animation = false;
    sprite.animation_completed = false;
    sprite.current_animation = null;

    transform.entity = entity;
    transform.position = position;
    transform.scale = @splat(1);
    transform.velocity = @splat(0);
    transform.next_velocity = @splat(0);

    entity.transform = transform;
    entity.sprite = sprite;

    return entity;
}

pub fn addWall(state: *State, color: ColorComponentValue, block_type: BlockType, position: Vector2) !*Entity {
    const new_entity = try addSprite(state, position);

    if (block_type == .ColorChange and color == .Gray) {
        return error.InvalidColor;
    }

    if (block_type == .Deadly and color != .Gray) {
        return error.InvalidColor;
    }

    const sprite_asset = state.assets.getWall(color, block_type);
    var collider_component: *ColliderComponent = state.collider_pool.getOrCreate(state.allocator) catch undefined;
    new_entity.entity_type = .Wall;
    collider_component.entity = new_entity;
    collider_component.shape = .Square;
    collider_component.size = Vector2{
        @floatFromInt(sprite_asset.document.header.width),
        @floatFromInt(sprite_asset.document.header.height),
    };
    collider_component.offset = @splat(0);
    new_entity.collider = collider_component;

    var color_component: *ColorComponent = try state.color_pool.getOrCreate(state.allocator);
    color_component.entity = new_entity;
    color_component.color = color;
    new_entity.color = color_component;

    var block_component: *BlockComponent = try state.block_pool.getOrCreate(state.allocator);
    block_component.entity = new_entity;
    block_component.type = block_type;
    new_entity.block = block_component;

    return new_entity;
}
