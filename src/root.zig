const std = @import("std");
const r = @import("dependencies/raylib.zig");
const aseprite = @import("aseprite.zig");
const ecs = @import("ecs.zig");

const PLATFORM = @import("builtin").os.tag;

const DOUBLE_CLICK_THRESHOLD: f32 = 0.3;
const DEFAULT_WORLD_SCALE: u32 = 4;
const WORLD_WIDTH: u32 = 200;
const WORLD_HEIGHT: u32 = 150;
const BALL_VELOCITY: f32 = 64;
const BALL_SPAWN = r.Vector2{ .x = 24, .y = 20 };

const LEVELS: []const []const u8 = &.{
    "assets/level1.lvl",
    "assets/level2.lvl",
    "assets/level3.lvl",
};

pub const State = struct {
    allocator: std.mem.Allocator,

    window_width: u32,
    window_height: u32,

    world_scale: f32,
    ui_scale: f32,
    world_width: u32,
    world_height: u32,

    camera: r.Camera2D,
    camera_ui: r.Camera2D,

    assets: Assets,
    level_index: u32,

    delta_time: f32,
    is_paused: bool,
    fullscreen: bool,

    debug_ui_state: DebugUIState,

    // Debug interactions.
    last_left_click_time: f64,
    last_left_click_entity: ?*ecs.Entity,
    hovered_entity: ?*ecs.Entity,

    // Components.
    transforms: std.ArrayList(*ecs.TransformComponent),
    colliders: std.ArrayList(*ecs.ColliderComponent),
    sprites: std.ArrayList(*ecs.SpriteComponent),
    ball: *ecs.Entity,
    walls: std.ArrayList(*ecs.Entity),
};

const Assets = struct {
    test_sprite: ?SpriteAsset,
    wall_gray: ?SpriteAsset,
    wall_red: ?SpriteAsset,
    wall_blue: ?SpriteAsset,
    ball: ?SpriteAsset,

    pub fn getWall(self: *Assets, color: ecs.ColorComponentValue) SpriteAsset {
        return switch (color) {
            .Red => self.wall_red.?,
            .Blue => self.wall_blue.?,
            .Gray => self.wall_gray.?,
        };
    }
};

pub const SpriteAsset = struct {
    document: aseprite.AseDocument,
    frames: []r.Texture2D,
    path: []const u8,
};

const DebugCollision = struct {
    collision: ecs.Collision,
    time_added: f64,
};

const DebugUIState = struct {
    mode: enum {
        Select,
        Edit,
    },
    current_wall_color: ?ecs.ColorComponentValue,
    show_level_editor: bool,
    show_colliders: bool,

    collisions: std.ArrayList(DebugCollision),

    pub fn addCollision(self: *DebugUIState, collision: *const ecs.Collision) void {
        self.collisions.append(.{
            .collision = collision.*,
            .time_added = r.GetTime(),
        }) catch unreachable;
    }
};

export fn init(window_width: u32, window_height: u32) *anyopaque {
    var allocator = std.heap.c_allocator;
    var state: *State = allocator.create(State) catch @panic("Out of memory");

    state.allocator = allocator;
    state.window_width = window_width;
    state.window_height = window_height;
    state.world_width = WORLD_WIDTH;
    state.world_height = WORLD_HEIGHT;

    setupCameras(state);

    state.level_index = 0;
    state.walls = std.ArrayList(*ecs.Entity).init(allocator);
    state.transforms = std.ArrayList(*ecs.TransformComponent).init(allocator);
    state.colliders = std.ArrayList(*ecs.ColliderComponent).init(allocator);
    state.sprites = std.ArrayList(*ecs.SpriteComponent).init(allocator);

    loadAssets(state);
    spawnBall(state) catch unreachable;
    loadLevel(state, LEVELS[state.level_index]) catch unreachable;

    state.debug_ui_state.mode = .Select;
    state.debug_ui_state.current_wall_color = .Red;
    state.debug_ui_state.collisions = std.ArrayList(DebugCollision).init(allocator);

    updateMouseScale(state);

    return state;
}

fn setupCameras(state: *State) void {
    const dpi = r.GetWindowScaleDPI();
    const window_position = r.GetWindowPosition();
    state.window_width = @intFromFloat(@divFloor(@as(f32, @floatFromInt(r.GetRenderWidth())), dpi.x));
    state.window_height = @intFromFloat(@divFloor(@as(f32, @floatFromInt(r.GetRenderHeight())), dpi.y));

    if (state.fullscreen) {
        // This is specific to borderless fullscreen on Mac.
        state.window_height -= @intFromFloat(window_position.y);
    }

    state.world_scale = @as(f32, @floatFromInt(state.window_height)) / @as(f32, @floatFromInt(state.world_height));
    state.ui_scale = state.world_scale / 2;

    const horizontal_offset: f32 =
        (@as(f32, @floatFromInt(state.window_width)) - (@as(f32, @floatFromInt(state.world_width)) * state.world_scale)) / 2;

    state.camera = r.Camera2D{
        .offset = r.Vector2{ .x = horizontal_offset, .y = 0 },
        .target = r.Vector2{ .x = 0, .y = 0 },
        .rotation = 0,
        .zoom = state.world_scale,
    };

    state.camera_ui = r.Camera2D{
        .offset = r.Vector2{ .x = 0, .y = 0 },
        .target = r.Vector2{ .x = 0, .y = 0 },
        .rotation = 0,
        .zoom = state.ui_scale,
    };

    updateMouseScale(state);
}

export fn reload(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    loadAssets(state);

    if (state.ball.transform) |transform| {
        transform.velocity.y = if (transform.velocity.y > 0) BALL_VELOCITY else -BALL_VELOCITY;
    }
}

export fn tick(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    { // Handle input.
        if (r.IsKeyReleased(r.KEY_TAB)) {
            state.is_paused = !state.is_paused;
        }

        if (r.IsKeyReleased(r.KEY_E)) {
            state.debug_ui_state.show_level_editor = !state.debug_ui_state.show_level_editor;
            updateMouseScale(state);
        }

        if (r.IsKeyReleased(r.KEY_F)) {
            state.fullscreen = !state.fullscreen;
            r.ToggleBorderlessWindowed();
            // r.ToggleFullscreen();
            setupCameras(state);
        }

        if (r.IsKeyReleased(r.KEY_C)) {
            state.debug_ui_state.show_colliders = !state.debug_ui_state.show_colliders;
        }

        if (r.IsKeyReleased(r.KEY_S)) {
            saveLevel(state, "assets/level1.lvl") catch unreachable;
        }

        if (r.IsKeyReleased(r.KEY_L)) {
            loadLevel(state, "assets/level1.lvl") catch unreachable;
        }

        if (state.ball.transform) |transform| {
            if (r.IsKeyDown(r.KEY_LEFT)) {
                transform.velocity.x = -BALL_VELOCITY;
            } else if (r.IsKeyDown(r.KEY_RIGHT)) {
                transform.velocity.x = BALL_VELOCITY;
            } else {
                transform.velocity.x = 0;
            }
        }

        state.hovered_entity = getHoveredEntity(state);

        // Level editor.
        if (!state.debug_ui_state.show_level_editor) {
            if (state.hovered_entity) |hovered_entity| {
                if (r.IsMouseButtonPressed(0)) {
                    if (state.debug_ui_state.mode == .Edit) {
                        if (state.debug_ui_state.current_wall_color) |editor_wall_color| {
                            if (editor_wall_color == hovered_entity.color.?.color) {
                                removeEntity(state, hovered_entity);
                            } else {
                                removeEntity(state, hovered_entity);
                                const tiled_position = getTiledPosition(
                                    r.GetMousePosition(),
                                    &state.assets.getWall(editor_wall_color),
                                );
                                _ = addWall(state, editor_wall_color, tiled_position) catch undefined;
                            }
                        }
                    } else {
                        if (r.GetTime() - state.last_left_click_time < DOUBLE_CLICK_THRESHOLD and
                            state.last_left_click_entity.? == hovered_entity)
                        {
                            openSprite(state, hovered_entity);
                        }
                    }

                    state.last_left_click_time = r.GetTime();
                    state.last_left_click_entity = hovered_entity;
                }
            } else {
                if (r.IsMouseButtonPressed(0)) {
                    if (state.debug_ui_state.mode == .Edit) {
                        if (state.debug_ui_state.current_wall_color) |editor_wall_color| {
                            const tiled_position = getTiledPosition(
                                r.GetMousePosition(),
                                &state.assets.getWall(editor_wall_color),
                            );
                            _ = addWall(state, editor_wall_color, tiled_position) catch undefined;
                        }
                    }
                }
            }
        }
    }

    if (!state.is_paused) {
        state.delta_time = r.GetFrameTime();
    } else {
        state.delta_time = 0;
    }

    const collisions = ecs.ColliderComponent.checkForCollisions(state.colliders.items, state.delta_time);

    // Handle vertical collisions.
    if (collisions.vertical) |collision| {
        if (collision.self.entity == state.ball) {
            if (collision.self.entity.transform) |transform| {
                transform.next_velocity = transform.velocity;
                transform.next_velocity.y = -transform.next_velocity.y;
                collision.self.entity.sprite.?.startAnimation(if (transform.velocity.y < 0) "bounce_up" else "bounce_down");

                transform.velocity.y = 0;
                state.debug_ui_state.addCollision(&collision);

                // Check if the other sprite is a wall of the same color as the ball.
                if (collision.other.entity.color) |other_color| {
                    if (collision.self.entity.color.?.color == other_color.color) {
                        removeEntity(state, collision.other.entity);
                    }
                }
            }
        } else {
            if (collision.self.entity.transform) |transform| {
                transform.velocity.y = -transform.velocity.y;
            }
        }
    }

    // Handle horizontal collisions.
    if (collisions.horizontal) |collision| {
        if (collision.self.entity == state.ball) {
            if (collision.self.entity.transform) |transform| {
                transform.velocity.x = 0;
                state.debug_ui_state.addCollision(&collision);

                // Check if the other sprite is a wall of the same color as the ball.
                if (collision.other.entity.color) |other_color| {
                    if (collision.self.entity.color.?.color == other_color.color) {
                        removeEntity(state, collision.other.entity);
                    }
                }
            }
        }
    }

    // Handle ball specific animations.
    if (state.ball.sprite) |sprite| {
        if (state.ball.transform) |transform| {
            if ((sprite.isAnimating("bounce_up") or sprite.isAnimating("bounce_down")) and sprite.animation_completed) {
                transform.velocity = transform.next_velocity;
                sprite.startAnimation("idle");
            }
        }
    }

    ecs.TransformComponent.tick(state.transforms.items, state.delta_time);
    ecs.SpriteComponent.tick(state.sprites.items, state.delta_time);

    if (isLevelCompleted(state)) {
        nextLevel(state);
    }
}

export fn draw(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    r.ClearBackground(r.BLACK);

    r.BeginMode2D(state.camera);
    drawWorld(state);
    drawDebugOverlay(state);
    r.EndMode2D();

    r.BeginMode2D(state.camera_ui);
    drawDebugUI(state);
    r.EndMode2D();
}

fn drawWorld(state: *State) void {
    for (state.sprites.items) |sprite| {
        if (sprite.entity.transform) |transform| {
            if (sprite.getTexture()) |texture| {
                const offset = sprite.getOffset();
                var position = transform.position;
                position.x += offset.x;
                position.y += offset.y;

                r.DrawTextureV(texture, position, r.WHITE);
            }
        }
    }
}

fn drawDebugCollider(collider: *ecs.ColliderComponent, color: r.Color, line_thickness: f32) void {
    if (collider.entity.transform) |transform| {
        switch (collider.shape) {
            .Square => {
                r.DrawRectangleLinesEx(
                    r.Rectangle{
                        .x = transform.position.x,
                        .y = transform.position.y,
                        .width = transform.size.x,
                        .height = transform.size.y,
                    },
                    line_thickness,
                    color,
                );
            },
            .Circle => {
                const center: r.Vector2 = .{
                    .x = transform.center().x,
                    .y = transform.center().y,
                };
                r.DrawCircleLinesV(
                    center,
                    collider.radius,
                    color,
                );
            },
        }
    }
}

fn drawDebugOverlay(state: *State) void {
    const line_thickness: f32 = 0.5;

    // Highlight colliders.
    if (state.debug_ui_state.show_colliders) {
        for (state.colliders.items) |collider| {
            drawDebugCollider(collider, r.GREEN, line_thickness);
        }
    }

    // Highlight the currently hovered entity.
    if (!state.debug_ui_state.show_level_editor) {
        if (state.hovered_entity) |hovered_entity| {
            if (hovered_entity.transform) |transform| {
                r.DrawRectangleLinesEx(
                    r.Rectangle{
                        .x = transform.position.x,
                        .y = transform.position.y,
                        .width = transform.size.x,
                        .height = transform.size.y,
                    },
                    line_thickness,
                    r.RED,
                );
            }
        }

        // Draw the current mouse position.
        const mouse_position = r.GetMousePosition();
        r.DrawCircle(
            @intFromFloat(mouse_position.x),
            @intFromFloat(mouse_position.y),
            line_thickness,
            r.YELLOW,
        );
    }

    // Highlight collisions.
    var index = state.debug_ui_state.collisions.items.len;
    while (index > 0) {
        index -= 1;

        const show_time: f64 = 1;
        const collision = state.debug_ui_state.collisions.items[index];
        if (r.GetTime() > collision.time_added + show_time) {
            _ = state.debug_ui_state.collisions.swapRemove(index);
        } else {
            const time_remaining: f64 = ((collision.time_added + show_time) - r.GetTime()) / show_time;
            var color: r.Color = r.ORANGE;
            color.a = @intFromFloat(255 * time_remaining);
            drawDebugCollider(collision.collision.other, color, @floatCast(10 * time_remaining));
        }
    }
}

fn drawDebugUI(state: *State) void {
    const screen_bottom: i32 = @intFromFloat(@as(f32, @floatFromInt(state.window_height)) / state.ui_scale);
    r.DrawFPS(8, screen_bottom - 22);

    if (state.debug_ui_state.show_level_editor) {
        _ = r.GuiWindowBox(r.Rectangle{ .x = 0, .y = 0, .width = 100, .height = 140 }, "Level editor");

        var button_rect: r.Rectangle = .{ .x = 10, .y = 30, .width = 75, .height = 16 };

        if (r.GuiButton(button_rect, "Select") != 0) {
            state.debug_ui_state.mode = .Select;
        }
        if (state.debug_ui_state.mode == .Select) {
            drawButtonHighlight(button_rect);
        }

        button_rect.y += 20;
        if (r.GuiButton(button_rect, "Gray") != 0) {
            state.debug_ui_state.mode = .Edit;
            state.debug_ui_state.current_wall_color = .Gray;
        }
        if (state.debug_ui_state.mode == .Edit and state.debug_ui_state.current_wall_color == .Gray) {
            drawButtonHighlight(button_rect);
        }

        button_rect.y += 20;
        if (r.GuiButton(button_rect, "Red") != 0) {
            state.debug_ui_state.mode = .Edit;
            state.debug_ui_state.current_wall_color = .Red;
        }
        if (state.debug_ui_state.mode == .Edit and state.debug_ui_state.current_wall_color == .Red) {
            drawButtonHighlight(button_rect);
        }

        button_rect.y += 20;
        if (r.GuiButton(button_rect, "Blue") != 0) {
            state.debug_ui_state.mode = .Edit;
            state.debug_ui_state.current_wall_color = .Blue;
        }
        if (state.debug_ui_state.mode == .Edit and state.debug_ui_state.current_wall_color == .Blue) {
            drawButtonHighlight(button_rect);
        }
    }
}

fn updateMouseScale(state: *State) void {
    if (state.debug_ui_state.show_level_editor) {
        r.SetMouseOffset(@intFromFloat(-state.camera_ui.offset.x), @intFromFloat(-state.camera_ui.offset.y));
        r.SetMouseScale(1 / state.ui_scale, 1 / state.ui_scale);
    } else {
        r.SetMouseOffset(@intFromFloat(-state.camera.offset.x), @intFromFloat(-state.camera.offset.y));
        r.SetMouseScale(1 / state.world_scale, 1 / state.world_scale);
    }
}

fn drawButtonHighlight(rect: r.Rectangle) void {
    r.DrawRectangleLinesEx(rect, 1, r.RED);
}

fn loadAssets(state: *State) void {
    // state.assets.test_texture = r.LoadTexture("assets/test.png");

    state.assets.test_sprite = loadSprite("assets/test_animation.aseprite", state.allocator);
    state.assets.ball = loadSprite("assets/ball.aseprite", state.allocator);
    state.assets.wall_gray = loadSprite("assets/wall_gray.aseprite", state.allocator);
    state.assets.wall_red = loadSprite("assets/wall_red.aseprite", state.allocator);
    state.assets.wall_blue = loadSprite("assets/wall_blue.aseprite", state.allocator);
}

fn loadSprite(path: []const u8, allocator: std.mem.Allocator) ?SpriteAsset {
    var result: ?SpriteAsset = null;

    if (aseprite.loadDocument(path, allocator) catch undefined) |doc| {
        var textures = std.ArrayList(r.Texture2D).init(allocator);

        for (doc.frames) |frame| {
            const image: r.Image = .{
                .data = @ptrCast(@constCast(frame.cel_chunk.data.compressedImage.pixels)),
                .width = frame.cel_chunk.data.compressedImage.width,
                .height = frame.cel_chunk.data.compressedImage.height,
                .mipmaps = 1,
                .format = r.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
            };
            textures.append(r.LoadTextureFromImage(image)) catch undefined;
        }

        std.debug.print("loadSprite: {s}: {d}\n", .{ path, doc.frames.len });

        result = SpriteAsset{
            .path = path,
            .document = doc,
            .frames = textures.toOwnedSlice() catch &.{},
        };
    }

    return result;
}

fn spawnBall(state: *State) !void {
    if (state.assets.ball) |*sprite| {
        if (addSprite(state, sprite, BALL_SPAWN) catch null) |entity| {
            var collider_component: *ecs.ColliderComponent = state.allocator.create(ecs.ColliderComponent) catch undefined;
            collider_component.entity = entity;
            collider_component.shape = .Circle;
            collider_component.radius = 8;
            collider_component.offset = r.Vector2Zero();

            var color_component: *ecs.ColorComponent = state.allocator.create(ecs.ColorComponent) catch undefined;
            color_component.entity = entity;
            color_component.color = .Red;

            entity.color = color_component;
            entity.collider = collider_component;

            state.ball = entity;
            try state.colliders.append(collider_component);

            resetBall(state);
        }
    }
}

fn resetBall(state: *State) void {
    state.ball.transform.?.position = BALL_SPAWN;
    state.ball.transform.?.velocity.y = BALL_VELOCITY;
}

fn saveLevel(state: *State, path: []const u8) !void {
    if (std.fs.cwd().createFile(path, .{ .truncate = true }) catch null) |file| {
        defer file.close();

        try file.writer().writeInt(u32, @intCast(state.walls.items.len), .little);

        for (state.walls.items) |wall| {
            if (wall.color) |color| {
                if (wall.transform) |transform| {
                    try file.writer().writeInt(u32, @intFromEnum(color.color), .little);
                    try file.writer().writeInt(i32, @intFromFloat(@round(transform.position.x)), .little);
                    try file.writer().writeInt(i32, @intFromFloat(@round(transform.position.y)), .little);
                }
            }
        }
    }
}

fn unloadLevel(state: *State) void {
    for (state.walls.items) |wall| {
        removeEntity(state, wall);
    }

    state.walls.clearRetainingCapacity();
}

fn loadLevel(state: *State, path: []const u8) !void {
    if (std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch null) |file| {
        const wall_count = try file.reader().readInt(u32, .little);

        unloadLevel(state);

        for (0..wall_count) |_| {
            const color = try file.reader().readInt(u32, .little);
            const x = try file.reader().readInt(i32, .little);
            const y = try file.reader().readInt(i32, .little);

            _ = try addWall(state, @enumFromInt(color), r.Vector2{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
        }
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
        if (wall.color.?.color != .Gray) {
            result = false;
        }
    }

    return result;
}

fn addSprite(state: *State, sprite_asset: *SpriteAsset, position: r.Vector2) !*ecs.Entity {
    var entity: *ecs.Entity = try state.allocator.create(ecs.Entity);
    var sprite: *ecs.SpriteComponent = try state.allocator.create(ecs.SpriteComponent);
    var transform: *ecs.TransformComponent = try state.allocator.create(ecs.TransformComponent);

    sprite.entity = entity;
    sprite.asset = sprite_asset;
    sprite.frame_index = 0;
    sprite.duration_shown = 0;
    sprite.loop_animation = false;
    sprite.animation_completed = false;
    sprite.current_animation = null;

    transform.entity = entity;
    transform.size = r.Vector2{
        .x = @floatFromInt(sprite_asset.document.header.width),
        .y = @floatFromInt(sprite_asset.document.header.height),
    };
    transform.position = position;
    transform.velocity = r.Vector2Zero();

    entity.transform = transform;
    entity.sprite = sprite;
    entity.color = null;

    try state.transforms.append(transform);
    try state.sprites.append(sprite);

    return entity;
}

fn addWall(state: *State, color: ecs.ColorComponentValue, position: r.Vector2) !*ecs.Entity {
    const sprite_asset = &switch (color) {
        .Gray => state.assets.wall_gray.?,
        .Red => state.assets.wall_red.?,
        .Blue => state.assets.wall_blue.?,
    };
    const new_entity = try addSprite(state, sprite_asset, position);

    var collider_component: *ecs.ColliderComponent = state.allocator.create(ecs.ColliderComponent) catch undefined;
    collider_component.entity = new_entity;
    collider_component.shape = .Square;
    collider_component.size = r.Vector2{
        .x = @floatFromInt(sprite_asset.document.header.width),
        .y = @floatFromInt(sprite_asset.document.header.height),
    };
    collider_component.offset = r.Vector2Zero();

    var color_component: *ecs.ColorComponent = try state.allocator.create(ecs.ColorComponent);
    color_component.entity = new_entity;
    color_component.color = color;

    new_entity.color = color_component;
    new_entity.collider = collider_component;

    try state.walls.append(new_entity);
    try state.colliders.append(collider_component);

    return new_entity;
}

fn removeEntity(state: *State, entity: *ecs.Entity) void {
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

fn getHoveredEntity(state: *State) ?*ecs.Entity {
    var result: ?*ecs.Entity = null;
    const mouse_position = r.GetMousePosition();

    for (state.transforms.items) |transform| {
        if (transform.containsPoint(mouse_position)) {
            result = transform.entity;
            break;
        }
    }

    return result;
}

fn getTiledPosition(position: r.Vector2, asset: *const SpriteAsset) r.Vector2 {
    const tile_x = @divFloor(position.x, @as(f32, @floatFromInt(asset.document.header.width)));
    const tile_y = @divFloor(position.y, @as(f32, @floatFromInt(asset.document.header.height)));
    return r.Vector2{
        .x = tile_x * @as(f32, @floatFromInt(asset.document.header.width)),
        .y = tile_y * @as(f32, @floatFromInt(asset.document.header.height)),
    };
}

fn openSprite(state: *State, entity: *ecs.Entity) void {
    if (entity.sprite) |sprite| {
        const process_args = if (PLATFORM == .windows) [_][]const u8{
            // "Aseprite.exe",
            "explorer.exe",
            sprite.asset.path,
            // ".\\assets\\test.aseprite",
        } else [_][]const u8{
            "open",
            sprite.asset.path,
        };

        var aseprite_process = std.process.Child.init(&process_args, state.allocator);
        aseprite_process.spawn() catch |err| {
            std.debug.print("Error spawning process: {}\n", .{err});
        };
    }
}
