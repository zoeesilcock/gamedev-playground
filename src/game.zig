const std = @import("std");
const aseprite = @import("aseprite.zig");
const entities = @import("entities.zig");
const math = @import("math.zig");
const pool = @import("pool.zig");
const imgui = if (INTERNAL) @import("imgui.zig") else struct {};
const debug = if (INTERNAL) @import("internal/debug.zig") else struct {
    pub const DebugState = void;
};

const loggingAllocator = if (INTERNAL) @import("internal/logging_allocator.zig").loggingAllocator else undefined;

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");

    if (INTERNAL) {
        @cInclude("dcimgui.h");
    }
});

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
const Pool = pool.Pool;

const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;
const Z = math.Z;

const Color = math.Color;
const R = math.R;
const G = math.G;
const B = math.B;
const A = math.A;

// TODO: Remove once Zig has finished migrating to unmanaged-style containers.
const ArrayList = std.ArrayListUnmanaged;
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
};

// const LEVELS: []const []const u8 = &.{
//     "test",
// };

const Title = enum {
    NONE,
    PAUSED,
    GET_READY,
    CLEARED,
    DEATH,
    GAME_OVER,
};

pub const State = struct {
    debug_allocator: *DebugAllocator,
    game_allocator: *DebugAllocator,
    allocator: std.mem.Allocator,
    debug_state: debug.DebugState,

    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    render_texture: *c.SDL_Texture,
    dest_rect: c.SDL_FRect,

    window_width: u32,
    window_height: u32,

    world_scale: f32,
    ui_scale: f32,
    world_width: u32,
    world_height: u32,

    assets: Assets,
    level_index: u32,

    time: u64,
    delta_time: u64,
    delta_time_actual: u64,
    input: Input,
    ball_horizontal_bounce_start_time: u64,

    is_paused: bool,
    fullscreen: bool,

    lives_remaining: u32,

    // Entities.
    entities: ArrayList(*Entity),
    entities_free: ArrayList(u32),
    entities_iterator: EntityIterator,
    ball_id: EntityId,

    transform_pool: Pool(TransformComponent),
    collider_pool: Pool(ColliderComponent),
    sprite_pool: Pool(SpriteComponent),
    color_pool: Pool(ColorComponent),
    block_pool: Pool(BlockComponent),

    // Titles
    current_title: Title,
    current_title_has_duration: bool,
    current_title_duration_remaining: u64,

    pub fn deltaTime(self: *State) f32 {
        return @as(f32, @floatFromInt(self.delta_time)) / 1000;
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
        }
        if (entity.collider) |collider| {
            self.collider_pool.free(collider.pool_id, self.allocator) catch @panic("Failed to free collider component");
        }
        if (entity.sprite) |sprite| {
            self.sprite_pool.free(sprite.pool_id, self.allocator) catch @panic("Failed to free sprite component");
        }
        if (entity.color) |color| {
            self.color_pool.free(color.pool_id, self.allocator) catch @panic("Failed to free color component");
        }
        if (entity.block) |block| {
            self.block_pool.free(block.pool_id, self.allocator) catch @panic("Failed to free block component");
        }
    }

    pub fn showTitle(self: *State, title: Title) void {
        self.current_title = title;
        self.current_title_has_duration = false;
    }

    pub fn showTitleForDuration(self: *State, title: Title, duration: u64) void {
        self.showTitle(title);
        self.current_title_has_duration = true;
        self.current_title_duration_remaining = duration;
    }

    pub fn updateTitles(self: *State) void {
        if (self.current_title != .NONE and self.current_title_has_duration) {
            if (self.current_title_duration_remaining >= self.delta_time_actual) {
                self.current_title_duration_remaining -= self.delta_time_actual;
            } else {
                self.current_title_duration_remaining = 0;
            }

            if (self.current_title_duration_remaining == 0) {
                self.titleDurationOver();
            }
        }
    }

    fn titleDurationOver(self: *State) void {
        switch (self.current_title) {
            .CLEARED => nextLevel(self),
            .DEATH => resetBall(self),
            .GAME_OVER => restart(self),
            else => {
                self.current_title = .NONE;
                self.current_title_has_duration = false;
            },
        }
    }

    pub fn pausedDueToTitle(self: *State) bool {
        switch (self.current_title) {
            .NONE => return false,
            else => return true,
        }
    }
};

const Input = struct {
    left: bool = false,
    right: bool = false,
};

pub const Assets = struct {
    life_filled: ?SpriteAsset,
    life_outlined: ?SpriteAsset,
    life_backdrop: ?SpriteAsset,

    ball_red: ?SpriteAsset,
    ball_blue: ?SpriteAsset,

    block_gray: ?SpriteAsset,
    block_red: ?SpriteAsset,
    block_blue: ?SpriteAsset,
    block_change_red: ?SpriteAsset,
    block_change_blue: ?SpriteAsset,
    block_deadly: ?SpriteAsset,

    background: ?SpriteAsset,

    title_paused: ?SpriteAsset,
    title_get_ready: ?SpriteAsset,
    title_cleared: ?SpriteAsset,
    title_death: ?SpriteAsset,
    title_game_over: ?SpriteAsset,

    pub fn getSpriteAsset(self: *Assets, sprite: *const SpriteComponent) ?*SpriteAsset {
        var result: ?*SpriteAsset = null;

        if (sprite.entity.color) |color| {
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

    pub fn getWall(self: *Assets, color: ColorComponentValue, block_type: BlockType) *SpriteAsset {
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

    pub fn getBall(self: *Assets, color: ColorComponentValue) *SpriteAsset {
        return switch (color) {
            .Red => &self.ball_red.?,
            .Blue => &self.ball_blue.?,
            .Gray => unreachable,
        };
    }
};

pub const SpriteAsset = struct {
    document: aseprite.AseDocument,
    frames: []*c.SDL_Texture,
    path: []const u8,

    pub fn deinit(self: *SpriteAsset, allocator: std.mem.Allocator) void {
        self.document.deinit(allocator);
        allocator.free(self.frames);
    }
};

fn sdlPanicIfNull(result: anytype, message: []const u8) @TypeOf(result) {
    if (result == null) {
        std.log.err("{s} SDL error: {s}", .{ message, c.SDL_GetError() });
        @panic(message);
    }

    return result;
}

fn sdlPanic(result: bool, message: []const u8) void {
    if (result == false) {
        std.log.err("{s} SDL error: {s}", .{ message, c.SDL_GetError() });
        @panic(message);
    }
}

pub export fn init(window_width: u32, window_height: u32, window: *c.SDL_Window, renderer: *c.SDL_Renderer) *anyopaque {
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

    state.allocator = allocator;
    state.game_allocator = game_allocator;

    if (INTERNAL) {
        state.debug_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize debug allocator."));
        state.debug_allocator.* = .init;
        state.debug_state.init() catch @panic("Failed to init DebugState");
    }

    state.window = window;
    state.renderer = renderer;

    state.window_width = window_width;
    state.window_height = window_height;
    state.world_width = WORLD_WIDTH;
    state.world_height = WORLD_HEIGHT;

    state.time = c.SDL_GetTicks();
    state.delta_time = 0;
    state.input = Input{};
    state.ball_horizontal_bounce_start_time = 0;

    state.entities = .empty;
    state.entities.ensureUnusedCapacity(state.allocator, 100) catch @panic("Failed to allocate space for entities.");
    state.entities_free = .empty;
    state.entities_free.ensureUnusedCapacity(state.allocator, 100) catch @panic("Failed to allocate space for free entities.");
    state.entities_iterator = .{ .entities = &state.entities };

    state.transform_pool = Pool(TransformComponent).init(100, state.allocator) catch @panic("Failed to create transform pool");
    state.collider_pool = Pool(ColliderComponent).init(100, state.allocator) catch @panic("Failed to create transform pool");
    state.sprite_pool = Pool(SpriteComponent).init(100, state.allocator) catch @panic("Failed to create transform pool");
    state.color_pool = Pool(ColorComponent).init(100, state.allocator) catch @panic("Failed to create transform pool");
    state.block_pool = Pool(BlockComponent).init(100, state.allocator) catch @panic("Failed to create transform pool");

    state.level_index = 0;
    state.lives_remaining = MAX_LIVES;

    state.current_title = .NONE;
    state.current_title_has_duration = false;
    state.current_title_duration_remaining = 0;

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
    deinit();
    state.* = @as(
        *State,
        @ptrCast(
            @alignCast(
                init(
                    state.window_width,
                    state.window_height,
                    state.window,
                    state.renderer,
                ),
            ),
        ),
    ).*;
}

pub export fn deinit() void {
    if (INTERNAL) {
        imgui.deinit();
    }
}

pub fn setupRenderTexture(state: *State) void {
    _ = c.SDL_GetWindowSize(state.window, @ptrCast(&state.window_width), @ptrCast(&state.window_height));
    state.world_scale = @as(f32, @floatFromInt(state.window_height)) / @as(f32, @floatFromInt(state.world_height));

    const horizontal_offset: f32 =
        (@as(f32, @floatFromInt(state.window_width)) - (@as(f32, @floatFromInt(state.world_width)) * state.world_scale)) / 2;
    state.dest_rect = c.SDL_FRect{
        .x = horizontal_offset,
        .y = 0,
        .w = @as(f32, @floatFromInt(state.world_width)) * state.world_scale,
        .h = @as(f32, @floatFromInt(state.world_height)) * state.world_scale,
    };

    state.render_texture = sdlPanicIfNull(c.SDL_CreateTexture(
        state.renderer,
        c.SDL_PIXELFORMAT_RGBA32,
        c.SDL_TEXTUREACCESS_TARGET,
        @intCast(state.world_width),
        @intCast(state.world_height),
    ), "Failed to initialize main render texture.");

    sdlPanic(
        c.SDL_SetTextureScaleMode(state.render_texture, c.SDL_SCALEMODE_NEAREST),
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
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        const event_used = if (INTERNAL) imgui.processEvent(&event) else false;
        if (event_used) {
            continue;
        }

        if (event.type == c.SDL_EVENT_QUIT or (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_ESCAPE)) {
            continue_running = false;
            break;
        }

        if (INTERNAL) {
            debug.processInputEvent(state, event);
        }

        // Game input.
        if (event.type == c.SDL_EVENT_KEY_DOWN or event.type == c.SDL_EVENT_KEY_UP) {
            const is_down = event.type == c.SDL_EVENT_KEY_DOWN;
            switch (event.key.key) {
                c.SDLK_LEFT => {
                    state.input.left = is_down;
                },
                c.SDLK_RIGHT => {
                    state.input.right = is_down;
                },
                c.SDLK_F => {
                    if (is_down) {
                        state.fullscreen = !state.fullscreen;
                        _ = c.SDL_SetWindowFullscreen(state.window, state.fullscreen);
                    }
                },
                c.SDLK_P => {
                    if (is_down) {
                        state.is_paused = !state.is_paused;

                        if (state.is_paused) {
                            state.showTitle(.PAUSED);
                        } else {
                            state.showTitle(.NONE);
                        }
                    }
                },
                else => {},
            }
        }

        if (event.type == c.SDL_EVENT_WINDOW_RESIZED) {
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

    state.delta_time_actual = c.SDL_GetTicks() - state.time;
    if (!state.is_paused and !state.pausedDueToTitle()) {
        state.delta_time = state.delta_time_actual;
    } else {
        state.delta_time = 0;
    }
    state.time = c.SDL_GetTicks();

    if (INTERNAL) {
        debug.calculateFPS(state);
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
    SpriteComponent.tick(&state.assets, &iter, state.deltaTime());

    if (isLevelCompleted(state) and state.current_title == .NONE) {
        if (!INTERNAL) {
            state.showTitleForDuration(.CLEARED, 2000);
        } else {
            if (!state.debug_state.show_editor and !state.debug_state.testing_level) {
                state.showTitleForDuration(.CLEARED, 2000);
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
                    state.showTitleForDuration(.DEATH, 2000);
                } else {
                    state.showTitleForDuration(.GAME_OVER, 2000);
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

    sdlPanic(c.SDL_SetRenderTarget(state.renderer, state.render_texture), "Failed to set render target.");
    {
        _ = c.SDL_SetRenderDrawColor(state.renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(state.renderer);
        drawWorld(state);
        drawGameUI(state);
    }

    _ = c.SDL_SetRenderTarget(state.renderer, null);
    {
        _ = c.SDL_SetRenderDrawColor(state.renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(state.renderer);
        _ = c.SDL_RenderTexture(state.renderer, state.render_texture, null, &state.dest_rect);

        if (INTERNAL) {
            debug.drawDebugOverlay(state);
            debug.drawDebugUI(state);
        }
    }
    _ = c.SDL_RenderPresent(state.renderer);
}

fn drawWorld(state: *State) void {
    var iter: EntityIterator = .{ .entities = &state.entities };
    while (iter.next(&.{ .sprite, .transform })) |entity| {
        if (entity.sprite.?.getTexture(&state.assets)) |texture| {
            drawTextureAt(state, texture, entity.transform.?.position, entity.transform.?.scale, entity.sprite.?.tint);
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

    const opt_title: ?SpriteAsset = switch (state.current_title) {
        .PAUSED => state.assets.title_paused,
        .GET_READY => state.assets.title_get_ready,
        .CLEARED => state.assets.title_cleared,
        .DEATH => state.assets.title_death,
        .GAME_OVER => state.assets.title_game_over,
        else => null,
    };

    if (opt_title) |title| {
        const texture = title.frames[0];
        const title_position: Vector2 = .{
            (@as(f32, @floatFromInt(state.window_width)) / state.world_scale / 2) -
                (@as(f32, @floatFromInt(texture.w)) / 2),
            (@as(f32, @floatFromInt(state.window_height)) / state.world_scale / 2) -
                (@as(f32, @floatFromInt(texture.h)) / 2)
            };
        drawTextureAt(state, texture, title_position, @splat(1), @splat(255));
    }
}

fn drawTextureAt(state: *State, texture: *c.SDL_Texture, position: Vector2, scale: Vector2, tint: Color) void {
    const texture_rect = c.SDL_FRect{
        .x = @round(position[X]),
        .y = @round(position[Y]),
        .w = @as(f32, @floatFromInt(texture.w)) * scale[X],
        .h = @as(f32, @floatFromInt(texture.h)) * scale[Y],
    };

    sdlPanic(c.SDL_SetTextureColorMod(texture, tint[R], tint[G], tint[B]), "Failed to set texture color mod.");
    sdlPanic(c.SDL_SetTextureAlphaMod(texture, tint[A]), "Failed to set texture alpha mod.");

    _ = c.SDL_RenderTexture(state.renderer, texture, null, &texture_rect);
}

fn loadAssets(state: *State) void {
    state.assets.life_filled = loadSprite("assets/life_filled.aseprite", state.renderer, state.allocator);
    state.assets.life_outlined = loadSprite("assets/life_outlined.aseprite", state.renderer, state.allocator);
    state.assets.life_backdrop = loadSprite("assets/life_backdrop.aseprite", state.renderer, state.allocator);

    state.assets.ball_red = loadSprite("assets/ball_red.aseprite", state.renderer, state.allocator);
    state.assets.ball_blue = loadSprite("assets/ball_blue.aseprite", state.renderer, state.allocator);

    state.assets.block_gray = loadSprite("assets/block_gray.aseprite", state.renderer, state.allocator);
    state.assets.block_red = loadSprite("assets/block_red.aseprite", state.renderer, state.allocator);
    state.assets.block_blue = loadSprite("assets/block_blue.aseprite", state.renderer, state.allocator);
    state.assets.block_change_red = loadSprite("assets/block_change_red.aseprite", state.renderer, state.allocator);
    state.assets.block_change_blue = loadSprite("assets/block_change_blue.aseprite", state.renderer, state.allocator);
    state.assets.block_deadly = loadSprite("assets/block_deadly.aseprite", state.renderer, state.allocator);

    state.assets.background = loadSprite("assets/background.aseprite", state.renderer, state.allocator);

    state.assets.title_paused = loadSprite("assets/title_paused.aseprite", state.renderer, state.allocator);
    state.assets.title_get_ready = loadSprite("assets/title_get_ready.aseprite", state.renderer, state.allocator);
    state.assets.title_cleared = loadSprite("assets/title_cleared.aseprite", state.renderer, state.allocator);
    state.assets.title_death = loadSprite("assets/title_death.aseprite", state.renderer, state.allocator);
    state.assets.title_game_over = loadSprite("assets/title_game_over.aseprite", state.renderer, state.allocator);
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
}

fn loadSprite(path: []const u8, renderer: *c.SDL_Renderer, allocator: std.mem.Allocator) ?SpriteAsset {
    var result: ?SpriteAsset = null;

    if (aseprite.loadDocument(path, allocator) catch undefined) |doc| {
        var textures: ArrayList(*c.SDL_Texture) = .empty;

        for (doc.frames) |frame| {
            const surface = sdlPanicIfNull(
                c.SDL_CreateSurface(
                    doc.header.width,
                    doc.header.height,
                    c.SDL_PIXELFORMAT_RGBA32,
                ),
                "Failed to create a surface to blit sprite data into",
            );
            defer c.SDL_DestroySurface(surface);

            for (frame.cel_chunks) |cel_chunk| {
                var dest_rect = c.SDL_Rect{
                    .x = cel_chunk.x,
                    .y = cel_chunk.y,
                    .w = cel_chunk.data.compressedImage.width,
                    .h = cel_chunk.data.compressedImage.height,
                };
                const cel_surface = sdlPanicIfNull(
                    c.SDL_CreateSurfaceFrom(
                        cel_chunk.data.compressedImage.width,
                        cel_chunk.data.compressedImage.height,
                        c.SDL_PIXELFORMAT_RGBA32,
                        @ptrCast(@constCast(cel_chunk.data.compressedImage.pixels)),
                        cel_chunk.data.compressedImage.width * @sizeOf(u32),
                    ),
                    "Failed to create surface from data",
                );
                defer c.SDL_DestroySurface(cel_surface);

                sdlPanic(
                    c.SDL_BlitSurface(cel_surface, null, surface, &dest_rect),
                    "Failed to blit cel surface into sprite surface",
                );
            }

            const texture = sdlPanicIfNull(
                c.SDL_CreateTextureFromSurface(renderer, surface),
                "Failed to create texture from surface",
            );
            textures.append(allocator, texture.?) catch undefined;
        }

        std.log.info("loadSprite: {s}: {d}", .{ path, doc.frames.len });

        result = SpriteAsset{
            .path = path,
            .document = doc,
            .frames = textures.toOwnedSlice(allocator) catch &.{},
        };
    }

    return result;
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

        state.showTitleForDuration(.GET_READY, 2000);
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
    const wall_count = try file.reader().readInt(u32, .little);

    unloadLevel(state);

    for (0..wall_count) |_| {
        const color = try file.reader().readInt(u32, .little);
        const block_type = try file.reader().readInt(u32, .little);
        const x = try file.reader().readInt(i32, .little);
        const y = try file.reader().readInt(i32, .little);

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
    resetBall(state);
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
