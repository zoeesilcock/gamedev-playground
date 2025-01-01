const std = @import("std");
const r = @import("dependencies/raylib.zig");
const aseprite = @import("aseprite.zig");
const ecs = @import("ecs.zig");

const PLATFORM = @import("builtin").os.tag;

const DOUBLE_CLICK_THRESHOLD: f32 = 0.3;
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
    world_width: u32,
    world_height: u32,

    render_texture: ?r.RenderTexture2D,
    source_rect: r.Rectangle,
    dest_rect: r.Rectangle,

    assets: Assets,
    level_index: u32,

    delta_time: f32,
    is_paused: bool,
    debug_ui_state: DebugUIState,

    // Debug interactions.
    last_left_click_time: f64,
    last_left_click_entity: ?*ecs.Entity,
    hovered_entity: ?*ecs.Entity,

    // Components.
    walls: std.ArrayList(*ecs.Entity),
    transforms: std.ArrayList(*ecs.TransformComponent),
    sprites: std.ArrayList(*ecs.SpriteComponent),
    ball: *ecs.Entity,
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

const DebugUIState = struct {
    mode: enum {
        Select,
        Edit,
    },
    current_wall_color: ?ecs.ColorComponentValue,
    show_level_editor: bool,
};

export fn init(window_width: u32, window_height: u32) *anyopaque {
    var allocator = std.heap.c_allocator;
    var state: *State = allocator.create(State) catch @panic("Out of memory");

    state.allocator = allocator;
    state.window_width = window_width;
    state.window_height = window_height;

    state.world_scale = 4;
    state.world_width = @intFromFloat(@divFloor(@as(f32, @floatFromInt(state.window_width)), state.world_scale));
    state.world_height = @intFromFloat(@divFloor(@as(f32, @floatFromInt(state.window_height)), state.world_scale));
    state.render_texture = r.LoadRenderTexture(@intCast(state.world_width), @intCast(state.world_height));
    state.source_rect = r.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(state.render_texture.?.texture.width),
        .height = -@as(f32, @floatFromInt(state.render_texture.?.texture.height)),
    };
    state.dest_rect = r.Rectangle{ 
        .x = @as(f32, @floatFromInt(state.window_width)) - state.source_rect.width * state.world_scale,
        .y = 0,
        .width = state.source_rect.width * state.world_scale,
        .height = state.source_rect.height * state.world_scale,
    };

    state.level_index = 0;
    state.walls = std.ArrayList(*ecs.Entity).init(allocator);
    state.transforms = std.ArrayList(*ecs.TransformComponent).init(allocator);
    state.sprites = std.ArrayList(*ecs.SpriteComponent).init(allocator);

    loadAssets(state);
    spawnBall(state);
    loadLevel(state, LEVELS[state.level_index]) catch unreachable;

    state.debug_ui_state.mode = .Select;
    state.debug_ui_state.current_wall_color = .Red;

    r.SetMouseScale(1 / state.world_scale, 1 / state.world_scale);

    return state;
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
                                const tiled_position = getTiledPosition(r.GetMousePosition(), &state.assets.getWall(editor_wall_color));
                                _ = addWall(state, editor_wall_color, tiled_position) catch undefined;
                            }
                        }
                    } else {
                        if (r.GetTime() - state.last_left_click_time < DOUBLE_CLICK_THRESHOLD and
                            state.last_left_click_entity.? == hovered_entity) {
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
                            const tiled_position = getTiledPosition(r.GetMousePosition(), &state.assets.getWall(editor_wall_color));
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

    const collisions = ecs.TransformComponent.checkForCollisions(state.transforms.items, state.delta_time);

    // Handle vertical collisions.
    if (collisions.vertical) |collision| {
        if (collision.self.entity == state.ball) {
            collision.self.next_velocity = collision.self.velocity;
            collision.self.next_velocity.y = -collision.self.next_velocity.y;
            collision.self.entity.sprite.?.startAnimation(if (collision.self.velocity.y < 0) "bounce_up" else "bounce_down");

            collision.self.velocity.y = 0;

            // Check if the other sprite is a wall of the same color as the ball.
            if (collision.other.entity.color) |other_color| {
                if (collision.self.entity.color.?.color == other_color.color) {
                    removeEntity(state, collision.other.entity);
                }
            }
        } else {
            collision.self.velocity.y = -collision.self.velocity.y;
        }
    }

    // Handle horizontal collisions.
    if (collisions.horizontal) |collision| {
        if (collision.self.entity == state.ball) {
            collision.self.velocity.x = 0;

            // Check if the other sprite is a wall of the same color as the ball.
            if (collision.other.entity.color) |other_color| {
                if (collision.self.entity.color.?.color == other_color.color) {
                    removeEntity(state, collision.other.entity);
                }
            }
        }
    }

    // Handle ball specific animations.
    if (state.ball.sprite) |sprite| {
        if (state.ball.transform) |transform| {
            if (
                (sprite.isAnimating("bounce_up") or sprite.isAnimating("bounce_down"))
                and sprite.animation_completed
            ) {
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

    if (state.render_texture) |render_texture| {
        r.BeginTextureMode(render_texture);
        {
            r.ClearBackground(r.BLACK);
            drawWorld(state);
            drawDebugUI(state);
        }
        r.EndTextureMode();

        {
            r.ClearBackground(r.DARKGRAY);
            r.DrawTexturePro(render_texture.texture, state.source_rect, state.dest_rect, r.Vector2{}, 0, r.WHITE);
        }
    }
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

    {
        // Draw the current mouse position.
        const mouse_position = r.GetMousePosition();
        r.DrawCircle(@intFromFloat(mouse_position.x), @intFromFloat(mouse_position.y), 3, r.YELLOW);
    }

    // Highlight the currently hovered entity.
    if (state.hovered_entity) |hovered_entity| {
        if (hovered_entity.transform) |transform| {
            r.DrawRectangleLines(
                @intFromFloat(transform.position.x),
                @intFromFloat(transform.position.y),
                @intFromFloat(transform.size.x), 
                @intFromFloat(transform.size.y),
                r.RED
            );
        }
    }
}

fn drawDebugUI(state: *State) void {
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

fn drawButtonHighlight(rect: r.Rectangle) void {
    r.DrawRectangleLines(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @intFromFloat(rect.width),
        @intFromFloat(rect.height),
        r.RED,
    );
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

fn spawnBall(state: *State) void {
    if (state.assets.ball) |*sprite| {
        var color_component: *ecs.ColorComponent = state.allocator.create(ecs.ColorComponent) catch undefined;
        color_component.color = .Red;

        if (addSprite(state, sprite, BALL_SPAWN) catch null) |entity| {
            entity.color = color_component;
            state.ball = entity;

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
    var color_component: *ecs.ColorComponent = try state.allocator.create(ecs.ColorComponent);
    const sprite_asset = &switch(color) {
        .Gray => state.assets.wall_gray.?,
        .Red => state.assets.wall_red.?,
        .Blue => state.assets.wall_blue.?,
    };

    const new_entity = try addSprite(state, sprite_asset, position);

    color_component.color = color;
    new_entity.color = color_component;
    try state.walls.append(new_entity);

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
        if (transform.collidesWithPoint(mouse_position)) {
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
            std.debug.print("Error spawning process: {}\n", .{ err });
        };
    }
}
