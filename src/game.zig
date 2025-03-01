const std = @import("std");
const aseprite = @import("aseprite.zig");
const ecs = @import("ecs.zig");
const math = @import("math.zig");
const imgui = @import("imgui.zig");
const debug = if (INTERNAL) @import("debug.zig") else struct {
    pub const DebugState = void;
};

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");

    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cInclude("cimgui.h");
});

const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;
const Z = math.Z;

const Color = math.Color;
const R = math.R;
const G = math.G;
const B = math.B;
const A = math.A;

const INTERNAL: bool = @import("build_options").internal;
const DEFAULT_WORLD_SCALE: u32 = 4;
const WORLD_WIDTH: u32 = 200;
const WORLD_HEIGHT: u32 = 150;
const BALL_VELOCITY: f32 = 64;
const BALL_HORIZONTAL_BOUNCE_TIME: u64 = 75;
const BALL_SPAWN = Vector2{ 24, 20 };
pub const LEVEL_NAME_BUFFER_SIZE: u32 = 128;

const LEVELS: []const []const u8 = &.{
    "level1",
    "level2",
    "level3",
};

pub const State = struct {
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

    // Components.
    transforms: std.ArrayList(*ecs.TransformComponent),
    colliders: std.ArrayList(*ecs.ColliderComponent),
    sprites: std.ArrayList(*ecs.SpriteComponent),
    ball: *ecs.Entity,
    walls: std.ArrayList(*ecs.Entity),

    pub fn deltaTime(self: *State) f32 {
        return @as(f32, @floatFromInt(self.delta_time)) / 1000;
    }
};

const Input = struct {
    left: bool = false,
    right: bool = false,
};

pub const Assets = struct {
    test_sprite: ?SpriteAsset,

    block_gray: ?SpriteAsset,
    block_red: ?SpriteAsset,
    block_blue: ?SpriteAsset,

    block_change_red: ?SpriteAsset,
    block_change_blue: ?SpriteAsset,
    block_deadly: ?SpriteAsset,

    ball_red: ?SpriteAsset,
    ball_blue: ?SpriteAsset,

    pub fn getSpriteAsset(self: *Assets, sprite: *ecs.SpriteComponent) ?*SpriteAsset {
        var result: ?*SpriteAsset = null;

        if (sprite.entity.color) |color| {
            switch (sprite.entity.entity_type) {
                .Ball => result = self.getBall(color.color),
                .Wall => {
                    if (sprite.entity.block) |block| {
                        result = self.getWall(color.color, block.type);
                    }
                },
            }
        }

        return result;
    }

    pub fn getWall(self: *Assets, color: ecs.ColorComponentValue, block_type: ecs.BlockType) *SpriteAsset {
        if (block_type == .Wall) {
            return switch (color) {
                .Red => &self.block_red.?,
                .Blue => &self.block_blue.?,
                .Gray => &self.block_gray.?,
            };
        } else if (block_type == .ColorChange) {
            return switch (color) {
                .Red => &self.block_change_red.?,
                .Blue => &self.block_change_blue.?,
                .Gray => unreachable,
            };
        } else if (block_type == .Deadly) {
            return &self.block_deadly.?;
        }

        unreachable;
    }

    pub fn getBall(self: *Assets, color: ecs.ColorComponentValue) *SpriteAsset {
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

export fn init(window_width: u32, window_height: u32, window: *c.SDL_Window, renderer: *c.SDL_Renderer) *anyopaque {
    var allocator = std.heap.c_allocator;
    var state: *State = allocator.create(State) catch @panic("Out of memory");

    state.allocator = allocator;

    if (INTERNAL) {
        state.debug_state.init(state.allocator) catch unreachable;
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

    state.level_index = 0;
    state.walls = std.ArrayList(*ecs.Entity).init(allocator);
    state.transforms = std.ArrayList(*ecs.TransformComponent).init(allocator);
    state.colliders = std.ArrayList(*ecs.ColliderComponent).init(allocator);
    state.sprites = std.ArrayList(*ecs.SpriteComponent).init(allocator);

    loadAssets(state);
    spawnBall(state) catch unreachable;
    loadLevel(state, LEVELS[state.level_index]) catch unreachable;

    setupRenderTexture(state);
    imgui.init(state.window, state.renderer, @floatFromInt(state.window_width), @floatFromInt(state.window_height));

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

export fn deinit() void {
    imgui.deinit();
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

export fn willReload(state_ptr: *anyopaque) void {
    _ = state_ptr;
    imgui.deinit();
}

export fn reloaded(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    loadAssets(state);
    imgui.init(state.window, state.renderer, @floatFromInt(state.window_width), @floatFromInt(state.window_height));

    if (state.ball.transform) |transform| {
        transform.velocity[Y] = if (transform.velocity[Y] > 0) BALL_VELOCITY else -BALL_VELOCITY;
    }
}

export fn processInput(state_ptr: *anyopaque) bool {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        state.debug_state.input.reset();
    }

    var continue_running: bool = true;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        const event_used = imgui.processEvent(event);
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
        debug.handleInput(state);
    }

    return continue_running;
}

export fn tick(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (!state.is_paused) {
        state.delta_time = c.SDL_GetTicks() - state.time;
    } else {
        state.delta_time = 0;
    }
    state.time = c.SDL_GetTicks();

    if (INTERNAL) {
        debug.calculateFPS(state);
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

    const collisions = ecs.ColliderComponent.checkForCollisions(state.colliders.items, state.deltaTime());

    // Handle vertical collisions.
    if (collisions.vertical) |collision| {
        if (collision.self.entity == state.ball) {
            if (collision.self.entity.transform) |transform| {
                transform.next_velocity = transform.velocity;
                transform.next_velocity[Y] = -transform.next_velocity[Y];

                collision.self.entity.sprite.?.startAnimation(
                    if (transform.velocity[Y] < 0) "bounce_up" else "bounce_down",
                    &state.assets,
                );
                transform.velocity[Y] = 0;

                if (INTERNAL) {
                    state.debug_state.addCollision(&collision, state.time);
                }

                handleBallCollision(state, collision.self.entity, collision.other.entity);
            }
        } else {
            if (collision.self.entity.transform) |transform| {
                transform.velocity[Y] = -transform.velocity[Y];
            }
        }
    }

    // Handle horizontal collisions.
    if (collisions.horizontal) |collision| {
        if (collision.self.entity == state.ball) {
            if (collision.self.entity.transform) |transform| {
                transform.velocity[X] = -transform.velocity[X];
                state.ball_horizontal_bounce_start_time = state.time;

                if (INTERNAL) {
                    state.debug_state.addCollision(&collision, state.time);
                }

                handleBallCollision(state, collision.self.entity, collision.other.entity);
            }
        }
    }

    // Handle ball specific animations.
    if (state.ball.sprite) |sprite| {
        if (state.ball.transform) |transform| {
            if ((sprite.isAnimating("bounce_up") or sprite.isAnimating("bounce_down")) and sprite.animation_completed) {
                transform.velocity = transform.next_velocity;
                sprite.startAnimation("idle", &state.assets);
            }
        }
    }

    ecs.TransformComponent.tick(state.transforms.items, state.deltaTime());
    ecs.SpriteComponent.tick(&state.assets, state.sprites.items, state.deltaTime());

    if (isLevelCompleted(state)) {
        nextLevel(state);
    }
}

fn handleBallCollision(state: *State, ball: *ecs.Entity, block: *ecs.Entity) void {
    if (ball.color) |ball_color| {
        if (block.color) |other_color| {
            if (block.block) |other_block| {
                if (other_block.type == .Wall and other_color.color == ball_color.color) {
                    removeEntity(state, block);
                }
                if (other_block.type == .ColorChange and other_color.color != ball_color.color) {
                    ball_color.color = other_color.color;
                }
            }
        }
    }
}

export fn draw(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    sdlPanic(c.SDL_SetRenderTarget(state.renderer, state.render_texture), "Failed to set render target.");
    {
        _ = c.SDL_SetRenderDrawColor(state.renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(state.renderer);
        drawWorld(state);
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

                const texture_rect = c.SDL_FRect{
                    .x = @round(position[X]),
                    .y = @round(position[Y]),
                    .w = @floatFromInt(texture.w),
                    .h = @floatFromInt(texture.h),
                };

                _ = c.SDL_RenderTexture(state.renderer, texture, null, &texture_rect);
            }
        }
    }
}

fn loadAssets(state: *State) void {
    state.assets.test_sprite = loadSprite("assets/test_animation.aseprite", state.renderer, state.allocator);

    state.assets.ball_red = loadSprite("assets/ball_red.aseprite", state.renderer, state.allocator);
    state.assets.ball_blue = loadSprite("assets/ball_blue.aseprite", state.renderer, state.allocator);

    state.assets.block_gray = loadSprite("assets/block_gray.aseprite", state.renderer, state.allocator);
    state.assets.block_red = loadSprite("assets/block_red.aseprite", state.renderer, state.allocator);
    state.assets.block_blue = loadSprite("assets/block_blue.aseprite", state.renderer, state.allocator);
    state.assets.block_change_red = loadSprite("assets/block_change_red.aseprite", state.renderer, state.allocator);
    state.assets.block_change_blue = loadSprite("assets/block_change_blue.aseprite", state.renderer, state.allocator);
    state.assets.block_deadly = loadSprite("assets/block_deadly.aseprite", state.renderer, state.allocator);
}

fn loadSprite(path: []const u8, renderer: *c.SDL_Renderer, allocator: std.mem.Allocator) ?SpriteAsset {
    var result: ?SpriteAsset = null;

    if (aseprite.loadDocument(path, allocator) catch undefined) |doc| {
        var textures = std.ArrayList(*c.SDL_Texture).init(allocator);

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
            textures.append(texture.?) catch undefined;
        }

        std.log.info("loadSprite: {s}: {d}", .{ path, doc.frames.len });

        result = SpriteAsset{
            .path = path,
            .document = doc,
            .frames = textures.toOwnedSlice() catch &.{},
        };
    }

    return result;
}

fn spawnBall(state: *State) !void {
    if (addSprite(state, BALL_SPAWN) catch null) |entity| {
        var collider_component: *ecs.ColliderComponent = state.allocator.create(ecs.ColliderComponent) catch undefined;
        entity.entity_type = .Ball;
        collider_component.entity = entity;
        collider_component.shape = .Circle;
        collider_component.radius = 6;
        collider_component.offset = @splat(1);

        var color_component: *ecs.ColorComponent = state.allocator.create(ecs.ColorComponent) catch undefined;
        color_component.entity = entity;
        color_component.color = .Red;

        entity.color = color_component;
        entity.collider = collider_component;

        state.ball = entity;
        try state.colliders.append(collider_component);

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
}

fn unloadLevel(state: *State) void {
    for (state.walls.items) |wall| {
        removeEntity(state, wall);
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

fn addSprite(state: *State, position: Vector2) !*ecs.Entity {
    var entity: *ecs.Entity = try ecs.Entity.init(state.allocator);
    var sprite: *ecs.SpriteComponent = try state.allocator.create(ecs.SpriteComponent);
    var transform: *ecs.TransformComponent = try state.allocator.create(ecs.TransformComponent);

    sprite.entity = entity;
    sprite.frame_index = 0;
    sprite.duration_shown = 0;
    sprite.loop_animation = false;
    sprite.animation_completed = false;
    sprite.current_animation = null;

    transform.entity = entity;
    // transform.size = Vector2{
    //     @floatFromInt(sprite_asset.document.header.width),
    //     @floatFromInt(sprite_asset.document.header.height),
    // };
    transform.position = position;
    transform.velocity = @splat(0);

    entity.transform = transform;
    entity.sprite = sprite;

    try state.transforms.append(transform);
    try state.sprites.append(sprite);

    return entity;
}

pub fn addWall(state: *State, color: ecs.ColorComponentValue, block_type: ecs.BlockType, position: Vector2) !*ecs.Entity {
    const new_entity = try addSprite(state, position);

    if (block_type == .ColorChange and color == .Gray) {
        return error.InvalidColor;
    }

    const sprite_asset = state.assets.getWall(color, block_type);
    var collider_component: *ecs.ColliderComponent = state.allocator.create(ecs.ColliderComponent) catch undefined;
    new_entity.entity_type = .Wall;
    collider_component.entity = new_entity;
    collider_component.shape = .Square;
    collider_component.size = Vector2{
        @floatFromInt(sprite_asset.document.header.width),
        @floatFromInt(sprite_asset.document.header.height),
    };
    collider_component.offset = @splat(0);
    new_entity.collider = collider_component;

    if (block_type != .Deadly) {
        var color_component: *ecs.ColorComponent = try state.allocator.create(ecs.ColorComponent);
        color_component.entity = new_entity;
        color_component.color = color;
        new_entity.color = color_component;
    }

    var block_component: *ecs.BlockComponent = try state.allocator.create(ecs.BlockComponent);
    block_component.entity = new_entity;
    block_component.type = block_type;
    new_entity.block = block_component;

    try state.walls.append(new_entity);
    try state.colliders.append(collider_component);

    return new_entity;
}

pub fn removeEntity(state: *State, entity: *ecs.Entity) void {
    if (entity.transform) |_| {
        var opt_remove_at: ?usize = null;
        for (state.transforms.items, 0..) |stored_transform, index| {
            if (stored_transform.entity == entity) {
                opt_remove_at = index;
            }
        }
        if (opt_remove_at) |remove_at| {
            _ = state.transforms.swapRemove(remove_at);
        }
    }

    if (entity.collider) |_| {
        var opt_remove_at: ?usize = null;
        for (state.colliders.items, 0..) |stored_collider, index| {
            if (stored_collider.entity == entity) {
                opt_remove_at = index;
            }
        }
        if (opt_remove_at) |remove_at| {
            _ = state.colliders.swapRemove(remove_at);
        }
    }

    if (entity.sprite) |_| {
        var opt_remove_at: ?usize = null;
        for (state.sprites.items, 0..) |stored_sprite, index| {
            if (stored_sprite.entity == entity) {
                opt_remove_at = index;
            }
        }
        if (opt_remove_at) |remove_at| {
            _ = state.sprites.swapRemove(remove_at);
        }
    }

    {
        var opt_remove_at: ?usize = null;
        for (state.walls.items, 0..) |stored_wall, index| {
            if (stored_wall == entity) {
                opt_remove_at = index;
            }
        }
        if (opt_remove_at) |remove_at| {
            _ = state.walls.swapRemove(remove_at);
        }
    }
}
