const std = @import("std");
const r = @import("dependencies/raylib.zig");
const aseprite = @import("aseprite.zig");
const ecs = @import("ecs.zig");

const PLATFORM = @import("builtin").os.tag;

const DOUBLE_CLICK_THRESHOLD: f32 = 0.3;
const BALL_VELOCITY: f32 = 0.05;

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

    last_left_click_time: f64,

    // Components
    transforms: std.ArrayList(*ecs.TransformComponent),
    sprites: std.ArrayList(*ecs.SpriteComponent),
    ball: *ecs.Entity,
};

const Assets = struct {
    test_sprite: ?SpriteAsset,
    wall: ?SpriteAsset,
    ball: ?SpriteAsset,
};

pub const SpriteAsset = struct {
    document: aseprite.AseDocument,
    frames: []r.Texture2D,
};

export fn init(window_width: u32, window_height: u32) *anyopaque {
    var allocator = std.heap.c_allocator;
    var state: *State = allocator.create(State) catch @panic("Out of memory");

    state.allocator = allocator;
    state.window_width = window_width;
    state.window_height = window_height;

    state.world_scale = 2;
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

    state.transforms = std.ArrayList(*ecs.TransformComponent).init(allocator);
    state.sprites = std.ArrayList(*ecs.SpriteComponent).init(allocator);

    loadAssets(state);
    loadLevel(state);

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

    if (r.IsMouseButtonPressed(0)) {
        if (r.GetTime() - state.last_left_click_time < DOUBLE_CLICK_THRESHOLD) {
            openSprite(state);
        }

        state.last_left_click_time = r.GetTime();
    }

    for (state.sprites.items) |sprite| {
        if (sprite.asset.document.frames.len > 1) {
            const current_frame = sprite.asset.document.frames[sprite.frame_index];
            var from_frame: u16 = 0;
            var to_frame: u16 = @intCast(sprite.asset.document.frames.len);

            if (sprite.current_animation) |tag| {
                from_frame = tag.from_frame;
                to_frame = tag.to_frame;
            }

            const frame_end_time: f64 =
                sprite.frame_start_time + (@as(f64, @floatFromInt(current_frame.header.frame_duration)) / 1000);

            if (r.GetTime() > frame_end_time) {
                var next_frame = sprite.frame_index + 1;
                if (next_frame > to_frame) {
                    if (sprite.loop_animation) {
                        next_frame = from_frame;
                    } else {
                        sprite.animation_completed = true;
                        next_frame = to_frame;
                        continue;
                    }
                }

                sprite.setFrame(next_frame);
            }
        }
    }

    if (state.ball.transform) |transform| {
        if (r.IsKeyDown(r.KEY_LEFT)) {
            transform.velocity.x = -BALL_VELOCITY;
        } else if (r.IsKeyDown(r.KEY_RIGHT)) {
            transform.velocity.x = BALL_VELOCITY;
        } else {
            transform.velocity.x = 0;
        }

        if (
            (state.ball.sprite.?.isAnimating("bounce_up") or state.ball.sprite.?.isAnimating("bounce_down"))
            and state.ball.sprite.?.animation_completed
        ) {
            state.ball.transform.?.velocity = state.ball.transform.?.next_velocity;
            state.ball.sprite.?.startAnimation("idle");
        }
    }

    for (state.transforms.items) |transform| {
        if (transform.velocity.x != 0 or transform.velocity.y != 0) {
            var next_transform = transform.*;

            next_transform.position.y += next_transform.velocity.y;
            if (collides(state, &next_transform)) {
                if (transform.entity == state.ball) {
                    transform.next_velocity = transform.velocity;
                    transform.next_velocity.y = -transform.next_velocity.y;
                    state.ball.sprite.?.startAnimation(if (transform.velocity.y < 0) "bounce_up" else "bounce_down");

                    transform.velocity.y = 0;
                } else {
                    transform.velocity.y = -transform.velocity.y;
                }
            }

            next_transform.position.x += next_transform.velocity.x;
            if (collides(state, &next_transform)) {
                // transform.velocity.x = -transform.velocity.x;
                transform.velocity.x = 0;
            }

            transform.position.x += transform.velocity.x;
            transform.position.y += transform.velocity.y;
        }
    }
}

fn collides(state: *State, transform: *ecs.TransformComponent) bool {
    var result = false;

    for (state.transforms.items) |other| {
        if (transform.entity != other.entity and transform.collidesWith(other)) {
            result = true;
            break;
        }
    }

    return result;
}

export fn draw(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (state.render_texture) |render_texture| {
        r.BeginTextureMode(render_texture);
        {
            r.ClearBackground(r.BLACK);
            drawWorld(state);
        }
        r.EndTextureMode();

        {
            r.ClearBackground(r.DARKGRAY);
            r.DrawTexturePro(render_texture.texture, state.source_rect, state.dest_rect, r.Vector2{}, 0, r.WHITE);
        }
    }
}

fn loadAssets(state: *State) void {
    // state.assets.test_texture = r.LoadTexture("assets/test.png");

    state.assets.test_sprite = loadSprite("assets/test_animation.aseprite", state.allocator);
    state.assets.ball = loadSprite("assets/ball.aseprite", state.allocator);
    state.assets.wall = loadSprite("assets/wall.aseprite", state.allocator);
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
            .document = doc,
            .frames = textures.toOwnedSlice() catch &.{},
        };
    }

    return result;
}

fn loadLevel(state: *State) void {
    if (state.assets.wall) |*sprite| {
        var position = r.Vector2{ .x = 0, .y = 0 };

        // Top edge.
        for (0..6) |_| {
            _ = addSprite(state, sprite, position) catch undefined;
            position.x += @floatFromInt(sprite.document.header.width);
        }

        // Right edge.
        for (0..5) |_| {
            _ = addSprite(state, sprite, position) catch undefined;
            position.y += @floatFromInt(sprite.document.header.width);
        }

        // Left edge.
        position.x = 0;
        position.y = @floatFromInt(sprite.document.header.height);
        _ = addSprite(state, sprite, position) catch undefined;

        position.y += @floatFromInt(sprite.document.header.height);
        _ = addSprite(state, sprite, position) catch undefined;

        position.y += @floatFromInt(sprite.document.header.height);
        _ = addSprite(state, sprite, position) catch undefined;

        // Bottom edge.
        position.y += @floatFromInt(sprite.document.header.height);
        for (0..6) |_| {
            _ = addSprite(state, sprite, position) catch undefined;
            position.x += @floatFromInt(sprite.document.header.width);
        }
    }

    if (state.assets.ball) |*sprite| {
        const position = r.Vector2{ .x = 64, .y = 64 };
        if (addSprite(state, sprite, position) catch null) |entity| {
            entity.transform.?.velocity.y = BALL_VELOCITY;
            state.ball = entity;
        }
    }

    if (state.assets.test_sprite) |*sprite| {
        const position = r.Vector2{
            .x = @as(f32, @floatFromInt(state.world_width)) / 2,
            .y = @as(f32, @floatFromInt(state.world_height)) / 2,
        };
        const entity = addSprite(state, sprite, position) catch undefined;
        entity.sprite.?.loop_animation = true;
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
}

fn addSprite(state: *State, sprite_asset: *SpriteAsset, position: r.Vector2) !*ecs.Entity {
    var entity: *ecs.Entity = try state.allocator.create(ecs.Entity);
    var sprite: *ecs.SpriteComponent = try state.allocator.create(ecs.SpriteComponent);
    var transform: *ecs.TransformComponent = try state.allocator.create(ecs.TransformComponent);

    sprite.entity = entity;
    sprite.asset = sprite_asset;
    sprite.frame_index = 0;
    sprite.frame_start_time = 0;
    sprite.loop_animation = false;
    sprite.animation_completed = false;
    sprite.current_animation = null;

    transform.entity = entity;
    transform.size = r.Vector2{
        .x = @floatFromInt(sprite_asset.document.header.width),
        .y = @floatFromInt(sprite_asset.document.header.height),
    };
    transform.position = position;

    entity.transform = transform;
    entity.sprite = sprite;

    try state.transforms.append(transform);
    try state.sprites.append(sprite);

    return entity;
}

fn openSprite(state: *State) void {
    const process_args = if (PLATFORM == .windows) [_][]const u8{ 
        // "Aseprite.exe",
        "explorer.exe",
        ".\\assets\\test.aseprite",
    } else [_][]const u8{ 
        "open",
        "./assets/test.aseprite",
    };

    var aseprite_process = std.process.Child.init(&process_args, state.allocator);
    aseprite_process.spawn() catch |err| {
        std.debug.print("Error spawning process: {}\n", .{ err });
    };
}
