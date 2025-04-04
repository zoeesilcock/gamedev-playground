const std = @import("std");
const aseprite = @import("aseprite.zig");
const entities = @import("entities.zig");
const math = @import("math.zig");
const imgui = if (INTERNAL) @import("imgui.zig") else struct {};
const debug = if (INTERNAL) @import("debug.zig") else struct {
    pub const DebugState = void;
};

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
const TransformComponent = entities.TransformComponent;
const ColliderComponent = entities.ColliderComponent;
const SpriteComponent = entities.SpriteComponent;
const ColorComponent = entities.ColorComponent;
const ColorComponentValue = entities.ColorComponentValue;
const BlockComponent = entities.BlockComponent;
const BlockType = entities.BlockType;

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

pub const State = struct {
    debug_allocator: *DebugAllocator,
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
    input: Input,
    ball_horizontal_bounce_start_time: u64,

    is_paused: bool,
    fullscreen: bool,

    lives_remaining: u32,

    // Entities.
    entities: ArrayList(*Entity),
    entities_free: ArrayList(u32),

    // Components.
    transforms: ArrayList(*TransformComponent),
    colliders: ArrayList(*ColliderComponent),
    sprites: ArrayList(*SpriteComponent),
    ball: *Entity,
    walls: ArrayList(*Entity),

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

        if (entity.transform) |_| {
            var opt_remove_at: ?usize = null;
            for (self.transforms.items, 0..) |stored_transform, index| {
                if (stored_transform.entity == entity) {
                    opt_remove_at = index;
                }
            }
            if (opt_remove_at) |remove_at| {
                _ = self.transforms.swapRemove(remove_at);
            }
        }

        if (entity.collider) |_| {
            var opt_remove_at: ?usize = null;
            for (self.colliders.items, 0..) |stored_collider, index| {
                if (stored_collider.entity == entity) {
                    opt_remove_at = index;
                }
            }
            if (opt_remove_at) |remove_at| {
                _ = self.colliders.swapRemove(remove_at);
            }
        }

        if (entity.sprite) |_| {
            var opt_remove_at: ?usize = null;
            for (self.sprites.items, 0..) |stored_sprite, index| {
                if (stored_sprite.entity == entity) {
                    opt_remove_at = index;
                }
            }
            if (opt_remove_at) |remove_at| {
                _ = self.sprites.swapRemove(remove_at);
            }
        }

        {
            var opt_remove_at: ?usize = null;
            for (self.walls.items, 0..) |stored_wall, index| {
                if (stored_wall == entity) {
                    opt_remove_at = index;
                }
            }
            if (opt_remove_at) |remove_at| {
                _ = self.walls.swapRemove(remove_at);
            }
        }

        entity.is_in_use = false;
        self.entities_free.append(self.allocator, entity.id.index) catch @panic("Failed to allocate free index");
        entity.freeAllComponents(self.allocator);
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
    var debug_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize allocator."));
    debug_allocator.* = .init;
    var allocator = debug_allocator.allocator();

    var state: *State = allocator.create(State) catch @panic("Out of memory");

    state.allocator = allocator;
    state.debug_allocator = debug_allocator;

    if (INTERNAL) {
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
    state.entities_free = .empty;

    state.level_index = 0;
    state.lives_remaining = MAX_LIVES;
    state.walls = .empty;
    state.transforms = .empty;
    state.colliders = .empty;
    state.sprites = .empty;

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

    if (state.ball.transform) |transform| {
        transform.velocity[Y] = if (transform.velocity[Y] > 0) BALL_VELOCITY else -BALL_VELOCITY;
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
                else => {},
            }
        }

        if (event.type == c.SDL_EVENT_WINDOW_RESIZED) {
            setupRenderTexture(state);
        }
    }

    if (INTERNAL) {
        debug.handleInput(state, state.allocator);
    }

    return continue_running;
}

pub export fn tick(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (!state.is_paused) {
        state.delta_time = c.SDL_GetTicks() - state.time;
    } else {
        state.delta_time = 0;
    }
    state.time = c.SDL_GetTicks();

    if (INTERNAL) {
        debug.calculateFPS(state);
        debug.recordMemoryUsage(state);
    }

    if (state.ball.transform) |transform| {
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

    const collisions = ColliderComponent.checkForCollisions(state.colliders.items, state.deltaTime());

    // Handle vertical collisions.
    if (collisions.vertical) |collision| {
        if (collision.id.equals(state.ball.id)) {
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
                            state.debug_state.addCollision(state.allocator, &collision, state.time);
                        }

                        handleBallCollision(state, entity, other_entity);
                    }
                }
            }
        }
    }

    // Handle horizontal collisions.
    if (collisions.horizontal) |collision| {
        if (collision.id.equals(state.ball.id)) {
            if (state.getEntity(collision.id)) |entity| {
                if (state.getEntity(collision.other_id)) |other_entity| {
                    if (entity.transform) |transform| {
                        transform.velocity[X] = -transform.velocity[X];
                        state.ball_horizontal_bounce_start_time = state.time;

                        if (INTERNAL) {
                            state.debug_state.addCollision(state.allocator, &collision, state.time);
                        }

                        handleBallCollision(state, entity, other_entity);
                    }
                }
            }
        }
    }

    // Handle ball specific animations.
    if (state.ball.sprite) |sprite| {
        if (state.ball.transform) |transform| {
            if (sprite.animation_completed and (sprite.isAnimating("bounce_up") or sprite.isAnimating("bounce_down"))) {
                transform.velocity = transform.next_velocity;
                sprite.startAnimation("idle", &state.assets);
            }
        }
    }

    TransformComponent.tick(state.transforms.items, state.deltaTime());
    SpriteComponent.tick(&state.assets, state.sprites.items, state.deltaTime());

    if (isLevelCompleted(state)) {
        nextLevel(state);
    }
}

fn handleBallCollision(state: *State, ball: *Entity, block: *Entity) void {
    if (ball.color) |ball_color| {
        if (block.block) |other_block| {
            if (other_block.type == .Deadly) {
                if (state.lives_remaining > 0) {
                    state.lives_remaining -= 1;
                    resetBall(state);
                } else {
                    // Game over!
                    restart(state);
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
    for (state.sprites.items) |sprite| {
        if (sprite.entity.transform) |transform| {
            if (sprite.getTexture(&state.assets)) |texture| {
                const offset = sprite.getOffset(&state.assets);
                var position = transform.position;
                position += offset;

                drawTextureAt(state, texture, position);
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
        drawTextureAt(state, texture, position);
    }

    position += inner_offset;

    if (state.assets.life_filled) |filled| {
        if (state.assets.life_outlined) |outlined| {
            for (0..MAX_LIVES) |i| {
                const texture = (if (state.lives_remaining > i) filled else outlined).frames[0];
                drawTextureAt(state, texture, position);
                position[X] += @floatFromInt(texture.w + horizontal_space);
            }
        }
    }
}

fn drawTextureAt(state: *State, texture: *c.SDL_Texture, position: Vector2) void {
    const texture_rect = c.SDL_FRect{
        .x = @round(position[X]),
        .y = @round(position[Y]),
        .w = @floatFromInt(texture.w),
        .h = @floatFromInt(texture.h),
    };

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
            const surface = sdlPanicIfNull(c.SDL_CreateSurfaceFrom(
                frame.cel_chunk.data.compressedImage.width,
                frame.cel_chunk.data.compressedImage.height,
                c.SDL_PIXELFORMAT_RGBA32,
                @ptrCast(@constCast(frame.cel_chunk.data.compressedImage.pixels)),
                frame.cel_chunk.data.compressedImage.width * @sizeOf(u32),
            ), "Failed to create surface from data");
            defer c.SDL_DestroySurface(surface);

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
        var collider_component: *ColliderComponent = state.allocator.create(ColliderComponent) catch undefined;
        entity.entity_type = .Ball;
        collider_component.entity = entity;
        collider_component.shape = .Circle;
        collider_component.radius = 6;
        collider_component.offset = @splat(1);

        var color_component: *ColorComponent = state.allocator.create(ColorComponent) catch undefined;
        color_component.entity = entity;
        color_component.color = .Red;

        entity.color = color_component;
        entity.collider = collider_component;

        state.ball = entity;
        try state.colliders.append(state.allocator, collider_component);

        if (entity.sprite) |ball_sprite| {
            ball_sprite.startAnimation("idle", &state.assets);
        }

        resetBall(state);
    }
}

fn resetBall(state: *State) void {
    state.ball.transform.?.position = BALL_SPAWN;
    state.ball.transform.?.velocity[Y] = BALL_VELOCITY;
    state.ball.color.?.color = .Red;
    state.ball.sprite.?.startAnimation("idle", &state.assets);
}

fn unloadLevel(state: *State) void {
    for (state.walls.items) |wall| {
        state.removeEntity(wall);
    }

    state.walls.clearRetainingCapacity();
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

    for (state.walls.items) |wall| {
        if (wall.block.?.type == .Wall and wall.color.?.color != .Gray) {
            result = false;
        }
    }

    return result;
}

fn addSprite(state: *State, position: Vector2) !*Entity {
    var entity: *Entity = try state.addEntity();
    var sprite: *SpriteComponent = try state.allocator.create(SpriteComponent);
    var transform: *TransformComponent = try state.allocator.create(TransformComponent);

    sprite.entity = entity;
    sprite.frame_index = 0;
    sprite.duration_shown = 0;
    sprite.loop_animation = false;
    sprite.animation_completed = false;
    sprite.current_animation = null;

    transform.entity = entity;
    transform.position = position;
    transform.velocity = @splat(0);

    entity.transform = transform;
    entity.sprite = sprite;

    try state.transforms.append(state.allocator, transform);
    try state.sprites.append(state.allocator, sprite);

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
    var collider_component: *ColliderComponent = state.allocator.create(ColliderComponent) catch undefined;
    new_entity.entity_type = .Wall;
    collider_component.entity = new_entity;
    collider_component.shape = .Square;
    collider_component.size = Vector2{
        @floatFromInt(sprite_asset.document.header.width),
        @floatFromInt(sprite_asset.document.header.height),
    };
    collider_component.offset = @splat(0);
    new_entity.collider = collider_component;

    var color_component: *ColorComponent = try state.allocator.create(ColorComponent);
    color_component.entity = new_entity;
    color_component.color = color;
    new_entity.color = color_component;

    var block_component: *BlockComponent = try state.allocator.create(BlockComponent);
    block_component.entity = new_entity;
    block_component.type = block_type;
    new_entity.block = block_component;

    try state.walls.append(state.allocator, new_entity);
    try state.colliders.append(state.allocator, collider_component);

    return new_entity;
}
