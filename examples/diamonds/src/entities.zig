const std = @import("std");
const sdl = @import("sdl").c;
const game = @import("root.zig");
const math = @import("math");
const aseprite = @import("aseprite");
const pool = @import("pool");

const State = @import("root.zig").State;
const Color = math.Color;
const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;
const Z = math.Z;
const AsepriteAsset = aseprite.AsepriteAsset;

const PoolId = pool.PoolId;

pub const EntityType = enum(u8) {
    Background,
    Ball,
    Wall,
};

pub const EntityId = struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub fn equals(self: EntityId, other: ?EntityId) bool {
        return other != null and
            self.index == other.?.index and
            self.generation == other.?.generation;
    }
};

pub const EntityFlags = enum(u16) {
    player_controlled = (1 << 0),
    has_transform = (1 << 1),
    has_collider = (1 << 2),
    has_sprite = (1 << 3),
    has_block = (1 << 4),
    has_title = (1 << 5),
    has_tween = (1 << 6),
    is_background = (1 << 7),
    is_ui = (1 << 8),
};

pub const Entity = struct {
    id: EntityId = .{},
    is_in_use: bool = false,
    flags: u32 = 0,

    // Transform.
    position: Vector2 = .{ 0, 0 },
    scale: Vector2 = .{ 0, 0 },
    velocity: Vector2 = .{ 0, 0 },
    next_velocity: Vector2 = .{ 0, 0 },

    // Collider.
    collider_offset: Vector2 = .{ 0, 0 },
    collider_size: Vector2 = .{ 0, 0 },
    collider_radius: f32 = 0,
    collider_shape: ColliderShape = .None,

    // Sprite
    frame_index: u32 = 0,
    tint: Color = .{ 0, 0, 0, 0 },
    duration_shown: f32 = 0,
    loop_animation: bool = false,
    animation_completed: bool = false,
    current_animation: ?*aseprite.AseTagsChunk = null,

    // Ball and blocks.
    color: ColorComponentValue = .None,

    // Blocks.
    block_type: BlockType = .None,

    // Title.
    title_type: TitleType = .NONE,
    has_title_duration: bool = false,
    duration_remaining: u64 = 0,

    // Tween.
    tween_delay: u64 = 0,
    tween_duration: u64 = 0,
    tween_time_passed: u64 = 0,
    tween_target: EntityId = .{},
    tween_target_component: []const u8 = "",
    tween_target_field: []const u8 = "",
    tween_start_value: TweenedValue = .{ .f32 = 0 },
    tween_end_value: TweenedValue = .{ .f32 = 0 },

    pub fn addFlag(self: *Entity, flag: EntityFlags) void {
        self.flags |= @intFromEnum(flag);
    }

    pub fn removeFlag(self: *Entity, flag: EntityFlags) void {
        self.flags &= ~flag;
    }

    pub fn hasFlag(self: *const Entity, flag: EntityFlags) bool {
        return (self.flags & @intFromEnum(flag)) != 0;
    }

    pub fn startAnimation(self: *Entity, name: []const u8, assets: *game.Assets) void {
        var opt_tag: ?*aseprite.AseTagsChunk = null;

        if (assets.getSpriteAsset(self)) |sprite_asset| {
            outer: for (sprite_asset.document.frames) |frame| {
                for (frame.tags) |tag| {
                    if (std.mem.eql(u8, tag.tag_name, name)) {
                        opt_tag = tag;
                        break :outer;
                    }
                }
            }

            if (opt_tag) |tag| {
                self.current_animation = tag;
                self.loop_animation = false;
                self.animation_completed = false;
                self.setFrame(tag.from_frame, sprite_asset);
            }
        }
    }

    pub fn setFrame(self: *Entity, index: u32, sprite_asset: *AsepriteAsset) void {
        if (index < sprite_asset.document.frames.len) {
            self.duration_shown = 0;
            self.frame_index = index;
        }
    }

    pub fn isAnimating(self: *Entity, name: []const u8) bool {
        var result = false;

        if (self.current_animation) |tag| {
            if (std.mem.eql(u8, name, tag.tag_name)) {
                result = true;
            }
        }

        return result;
    }

    pub fn colliderContainsPoint(self: *const Entity, point: Vector2) bool {
        var contains_point = false;

        if ((point[X] <= self.position[X] + self.colliderRight() and point[X] >= self.position[X] + self.colliderLeft()) and
            (point[Y] <= self.position[Y] + self.colliderBottom() and point[Y] >= self.position[Y] + self.colliderTop()))
        {
            contains_point = true;
        }

        return contains_point;
    }

    pub fn colliderTop(self: *const Entity) f32 {
        return self.collider_offset[Y];
    }

    pub fn colliderBottom(self: *const Entity) f32 {
        switch (self.collider_shape) {
            .Square => {
                return self.collider_offset[Y] + self.collider_size[Y];
            },
            .Circle => {
                return self.collider_offset[Y] + self.collider_radius * 2;
            },
            .None => unreachable,
        }
    }

    pub fn colliderLeft(self: *const Entity) f32 {
        return self.collider_offset[X];
    }

    pub fn colliderRight(self: *const Entity) f32 {
        switch (self.collider_shape) {
            .Square => {
                return self.collider_offset[X] + self.collider_size[X];
            },
            .Circle => {
                return self.collider_offset[X] + self.collider_radius * 2;
            },
            .None => unreachable,
        }
    }

    pub fn spriteContainsPoint(
        self: *const Entity,
        point: Vector2,
        dest_rect: sdl.SDL_FRect,
        world_scale: f32,
        assets: *game.Assets,
    ) bool {
        var contains_point = false;
        var position: Vector2 = .{ 0, 0 };

        if (assets.getSpriteAsset(self)) |sprite_asset| {
            if (self.hasFlag(.has_transform)) {
                position = self.position;
            }
            if (self.hasFlag(.is_ui)) {
                position = self.getUIPosition(dest_rect, world_scale, assets);
            }

            const width: f32 = @floatFromInt(sprite_asset.document.header.width);
            const height: f32 = @floatFromInt(sprite_asset.document.header.height);

            if ((point[X] <= position[X] + width and point[X] >= position[X]) and
                (point[Y] <= position[Y] + height and point[Y] >= position[Y]))
            {
                contains_point = true;
            }
        }

        return contains_point;
    }

    pub fn getTexture(self: *const Entity, assets: *game.Assets) ?*sdl.SDL_Texture {
        var result: ?*sdl.SDL_Texture = null;

        if (assets.getSpriteAsset(self)) |sprite_asset| {
            if (self.frame_index < sprite_asset.frames.len) {
                result = sprite_asset.frames[self.frame_index];
            }
        }

        return result;
    }

    pub fn getUIPosition(
        self: *const Entity,
        dest_rect: sdl.SDL_FRect,
        world_scale: f32,
        assets: *game.Assets,
    ) Vector2 {
        var result: Vector2 = @splat(0);
        const half: Vector2 = @splat(0.5);
        const scale: Vector2 = @splat(world_scale);

        if (self.getTexture(assets)) |texture| {
            const size: Vector2 = .{
                (@as(f32, @floatFromInt(texture.w))),
                (@as(f32, @floatFromInt(texture.h))),
            };
            result = Vector2{ dest_rect.w, dest_rect.h } / scale - size;
            result *= half;
            result += self.position;
        }

        return result;
    }

    pub fn colliderCenter(self: *const Entity, transform: *const Entity) Vector2 {
        switch (self.collider_shape) {
            .Square => {
                return Vector2{
                    transform.position[X] + self.collider_offset[X] + self.collider_size[X] * 0.5,
                    transform.position[Y] + self.collider_offset[Y] + self.collider_size[Y] * 0.5,
                };
            },
            .Circle => {
                return Vector2{
                    transform.position[X] + self.collider_offset[X] + self.collider_radius,
                    transform.position[Y] + self.collider_offset[Y] + self.collider_radius,
                };
            },
            .None => unreachable,
        }
    }

    pub fn center(self: *const Entity) Vector2 {
        switch (self.collider_shape) {
            .Square => {
                return Vector2{
                    self.position[X] + self.collider_offset[X] + self.collider_size[X] * 0.5,
                    self.position[Y] + self.collider_offset[Y] + self.collider_size[Y] * 0.5,
                };
            },
            .Circle => {
                return Vector2{
                    self.position[X] + self.collider_offset[X] + self.collider_radius,
                    self.position[Y] + self.collider_offset[Y] + self.collider_radius,
                };
            },
            .None => unreachable,
        }
    }

    pub fn checkForCollisions(state: *State, delta_time: f32) CollisionResult {
        var result: CollisionResult = .{};

        for (&state.fat_entities) |*entity| {
            if (entity.is_in_use and entity.hasFlag(.has_collider) and entity.hasFlag(.has_transform)) {
                // Check in the Y direction.
                if (entity.velocity[Y] != 0) {
                    var next_entity = entity.*;
                    next_entity.position[Y] += next_entity.velocity[Y] * delta_time;
                    if (entity.collidesWithAnyAt(state, next_entity)) |other_entity| {
                        result.vertical = .{ .id = entity.id, .other_id = other_entity.id };
                    }
                }

                // Check in the X direction.
                if (entity.velocity[X] != 0) {
                    var next_entity = entity.*;
                    next_entity.position[X] += next_entity.velocity[X] * delta_time;
                    if (entity.collidesWithAnyAt(state, next_entity)) |other_entity| {
                        result.horizontal = .{ .id = entity.id, .other_id = other_entity.id };
                    }
                }
            }
        }

        return result;
    }

    fn collidesWithAnyAt(self: *Entity, state: *State, at: Entity) ?*Entity {
        var result: ?*Entity = null;

        for (&state.fat_entities) |*entity| {
            if (entity.is_in_use and entity.hasFlag(.has_collider)) {
                if (self != entity and self.collidesWithAt(entity, at)) {
                    result = entity;
                    break;
                }
            }
        }

        return result;
    }

    pub fn collidesWithAt(self: *Entity, other: *Entity, at: Entity) bool {
        var collides = false;

        if (self.collider_shape == other.collider_shape) {
            switch (self.collider_shape) {
                .Circle => unreachable,
                .Square => {
                    if (((at.position[X] + self.colliderLeft() >= other.position[X] + other.colliderLeft() and
                        at.position[X] + self.colliderLeft() <= other.position[X] + other.colliderRight()) or
                        (at.position[X] + self.colliderRight() >= other.position[X] + other.colliderLeft() and
                            at.position[X] + self.colliderRight() <= other.position[X] + other.colliderRight())) and
                        ((at.position[Y] + self.colliderBottom() >= other.position[Y] + other.colliderTop() and
                            at.position[Y] + self.colliderBottom() <= other.position[Y] + other.colliderBottom()) or
                            (at.position[Y] + self.colliderTop() <= other.position[Y] + other.colliderBottom() and
                                at.position[Y] + self.colliderTop() >= other.position[Y] + other.colliderTop())))
                    {
                        collides = true;
                    }
                },
                .None => unreachable,
            }
        } else {
            var circle_radius: f32 = 0;
            var circle_transform: ?*const Entity = null;
            var circle_collider: *const Entity = undefined;
            var square_transform: ?*const Entity = null;
            var square_collider: *const Entity = undefined;

            if (self.collider_shape == .Circle) {
                circle_collider = self;
                circle_transform = &at;
                circle_radius = self.collider_radius;
            } else {
                square_collider = self;
                square_transform = &at;
            }

            if (other.collider_shape == .Circle) {
                circle_collider = other;
                circle_transform = other;
                circle_radius = other.collider_radius;
            } else {
                square_collider = other;
                square_transform = other;
            }

            if (circle_transform) |circle| {
                if (square_transform) |square| {
                    const circle_position = circle_collider.colliderCenter(circle);
                    const closest_x: f32 = std.math.clamp(
                        circle_position[X],
                        square.position[X] + square_collider.colliderLeft(),
                        square.position[X] + square_collider.colliderRight(),
                    );
                    const closest_y: f32 = std.math.clamp(
                        circle_position[Y],
                        square.position[Y] + square_collider.colliderTop(),
                        square.position[Y] + square_collider.colliderBottom(),
                    );
                    const distance_x: f32 = circle_position[X] - closest_x;
                    const distance_y: f32 = circle_position[Y] - closest_y;
                    const distance: f32 = (distance_x * distance_x) + (distance_y * distance_y);

                    if (distance < circle_radius * circle_radius) {
                        collides = true;
                    }
                }
            }
        }

        return collides;
    }
};

const ColliderShape = enum {
    None,
    Square,
    Circle,
};

pub const CollisionResult = struct {
    vertical: ?Collision = null,
    horizontal: ?Collision = null,
};

pub const Collision = struct {
    id: EntityId,
    other_id: EntityId,
};

pub const ColorComponentValue = enum {
    None,
    Gray,
    Red,
    Blue,
};

pub const BlockType = enum {
    None,
    Wall,
    Deadly,
    ColorChange,
};

pub const TitleType = enum {
    NONE,
    PAUSED,
    GET_READY,
    CLEARED,
    DEATH,
    GAME_OVER,
};

pub const TweenedValue = union {
    f32: f32,
    color: Color,
};
