const std = @import("std");
const game = @import("game.zig");
const math = @import("math.zig");
const aseprite = @import("aseprite.zig");

const c = game.c;

const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;
const Z = math.Z;

pub const EntityType = enum(u8) {
    Background,
    Ball,
    Wall,
};

pub const Entity = struct {
    entity_type: EntityType,
    transform: ?*TransformComponent,
    collider: ?*ColliderComponent,
    sprite: ?*SpriteComponent,
    color: ?*ColorComponent,
    block: ?*BlockComponent,

    pub fn init(allocator: std.mem.Allocator) !*Entity {
        var entity: *Entity = try allocator.create(Entity);
        entity.transform = null;
        entity.collider = null;
        entity.sprite = null;
        entity.color = null;
        entity.block = null;
        return entity;
    }

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        if (self.transform) |transform| {
            allocator.destroy(transform);
        }
        if (self.collider) |collider| {
            allocator.destroy(collider);
        }
        if (self.sprite) |sprite| {
            allocator.destroy(sprite);
        }
        if (self.color) |color| {
            allocator.destroy(color);
        }
        if (self.block) |block| {
            allocator.destroy(block);
        }
        allocator.destroy(self);
    }
};

pub const TransformComponent = struct {
    entity: *Entity,

    position: Vector2,
    velocity: Vector2,
    next_velocity: Vector2,

    pub fn tick(transforms: []*TransformComponent, delta_time: f32) void {
        for (transforms) |transform| {
            transform.position += transform.velocity * @as(Vector2, @splat(delta_time));
        }
    }
};

const ColliderShape = enum {
    Square,
    Circle,
};

pub const CollisionResult = struct {
    vertical: ?Collision = null,
    horizontal: ?Collision = null,
};

pub const Collision = struct {
    self: *ColliderComponent,
    other: *ColliderComponent,
};

pub const ColliderComponent = struct {
    entity: *Entity,

    offset: Vector2,
    size: Vector2,
    radius: f32,
    shape: ColliderShape,

    pub fn top(self: *const ColliderComponent) f32 {
        return self.offset[Y];
    }

    pub fn bottom(self: *const ColliderComponent) f32 {
        switch (self.shape) {
            .Square => {
                return self.offset[Y] + self.size[Y];
            },
            .Circle => {
                return self.offset[Y] + self.radius * 2;
            },
        }
    }

    pub fn left(self: *const ColliderComponent) f32 {
        return self.offset[X];
    }

    pub fn right(self: *const ColliderComponent) f32 {
        switch (self.shape) {
            .Square => {
                return self.offset[X] + self.size[X];
            },
            .Circle => {
                return self.offset[X] + self.radius * 2;
            },
        }
    }

    pub fn center(self: *const ColliderComponent, transform: *const TransformComponent) Vector2 {
        switch (self.shape) {
            .Square => {
                return Vector2{
                    transform.position[X] + self.offset[X] + self.size[X] * 0.5,
                    transform.position[Y] + self.offset[Y] + self.size[Y] * 0.5,
                };
            },
            .Circle => {
                return Vector2{
                    transform.position[X] + self.offset[X] + self.radius,
                    transform.position[Y] + self.offset[Y] + self.radius,
                };
            },
        }
    }

    pub fn containsPoint(self: *const ColliderComponent, point: Vector2) bool {
        var contains_point = false;
        var position: Vector2 = .{ 0, 0 };

        if (self.entity.transform) |transform| {
            position = transform.position;
        }

        if ((point[X] <= position[X] + self.right() and point[X] >= position[X] + self.left()) and
            (point[Y] <= position[Y] + self.bottom() and point[Y] >= position[Y] + self.top()))
        {
            contains_point = true;
        }

        return contains_point;
    }

    fn collidesWithAnyAt(self: *ColliderComponent, others: []*ColliderComponent, at: TransformComponent) ?*Entity {
        var result: ?*Entity = null;

        for (others) |other| {
            if (self.entity != other.entity and self.collidesWithAt(other, at)) {
                result = other.entity;
                break;
            }
        }

        return result;
    }

    pub fn collidesWithAt(self: *ColliderComponent, other: *ColliderComponent, at: TransformComponent) bool {
        var collides = false;

        if (other.entity.transform) |other_at| {
            if (self.shape == other.shape) {
                switch (self.shape) {
                    .Circle => unreachable,
                    .Square => {
                        if (((at.position[X] + self.left() >= other_at.position[X] + other.left() and at.position[X] + self.left() <= other_at.position[X] + other.right()) or
                            (at.position[X] + self.right() >= other_at.position[X] + other.left() and at.position[X] + self.right() <= other_at.position[X] + other.right())) and
                            ((at.position[Y] + self.bottom() >= other_at.position[Y] + other.top() and at.position[Y] + self.bottom() <= other_at.position[Y] + other.bottom()) or
                            (at.position[Y] + self.top() <= other_at.position[Y] + other.bottom() and at.position[Y] + self.top() >= other_at.position[Y] + other.top())))
                        {
                            collides = true;
                        }
                    },
                }
            } else {
                var circle_radius: f32 = 0;
                var circle_transform: ?*const TransformComponent = null;
                var circle_collider: *const ColliderComponent = undefined;
                var square_transform: ?*const TransformComponent = null;
                var square_collider: *const ColliderComponent = undefined;

                if (self.shape == .Circle) {
                    circle_collider = self;
                    circle_transform = &at;
                    circle_radius = self.radius;
                } else {
                    square_collider = self;
                    square_transform = &at;
                }

                if (other.shape == .Circle) {
                    circle_collider = other;
                    circle_transform = other.entity.transform;
                    circle_radius = other.radius;
                } else {
                    square_collider = other;
                    square_transform = other.entity.transform;
                }

                if (circle_transform) |circle| {
                    if (square_transform) |square| {
                        const circle_position = circle_collider.center(circle);
                        const closest_x: f32 = std.math.clamp(
                            circle_position[X],
                            square.position[X] + square_collider.left(),
                            square.position[X] + square_collider.right(),
                        );
                        const closest_y: f32 = std.math.clamp(
                            circle_position[Y],
                            square.position[Y] + square_collider.top(),
                            square.position[Y] + square_collider.bottom(),
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
        }

        return collides;
    }

    pub fn checkForCollisions(colliders: []*ColliderComponent, delta_time: f32) CollisionResult {
        var result: CollisionResult = .{};

        for (colliders) |collider| {
            if (collider.entity.transform) |transform| {
                // Check in the Y direction.
                if (transform.velocity[Y] != 0) {
                    var next_transform = transform.*;
                    next_transform.position[Y] += next_transform.velocity[Y] * delta_time;
                    if (collider.collidesWithAnyAt(colliders, next_transform)) |other_entity| {
                        result.vertical = .{ .self = collider, .other = other_entity.collider.? };
                    }
                }

                // Check in the X direction.
                if (transform.velocity[X] != 0) {
                    var next_transform = transform.*;
                    next_transform.position[X] += next_transform.velocity[X] * delta_time;
                    if (collider.collidesWithAnyAt(colliders, next_transform)) |other_entity| {
                        result.horizontal = .{ .self = collider, .other = other_entity.collider.? };
                    }
                }
            }
        }

        return result;
    }
};

pub const SpriteComponent = struct {
    entity: *Entity,

    frame_index: u32,
    duration_shown: f32,
    loop_animation: bool,
    animation_completed: bool,
    current_animation: ?*aseprite.AseTagsChunk,

    pub fn tick(assets: *game.Assets, sprites: []*SpriteComponent, delta_time: f32) void {
        for (sprites) |sprite| {
            if (assets.getSpriteAsset(sprite)) |sprite_asset| {
                if (sprite_asset.document.frames.len > 1) {
                    const current_frame = sprite_asset.document.frames[sprite.frame_index];
                    var from_frame: u16 = 0;
                    var to_frame: u16 = @intCast(sprite_asset.document.frames.len);

                    if (sprite.current_animation) |tag| {
                        from_frame = tag.from_frame;
                        to_frame = tag.to_frame;
                    }

                    sprite.duration_shown += delta_time;

                    if (sprite.duration_shown * 1000 >= @as(f64, @floatFromInt(current_frame.header.frame_duration))) {
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

                        sprite.setFrame(next_frame, sprite_asset);
                    }
                }
            }
        }
    }

    pub fn setFrame(self: *SpriteComponent, index: u32, sprite_asset: *game.SpriteAsset) void {
        if (index < sprite_asset.document.frames.len) {
            self.duration_shown = 0;
            self.frame_index = index;
        }
    }

    pub fn getTexture(self: *SpriteComponent, assets: *game.Assets) ?*c.SDL_Texture {
        var result: ?*c.SDL_Texture = null;

        if (assets.getSpriteAsset(self)) |sprite_asset| {
            if (self.frame_index < sprite_asset.frames.len) {
                result = sprite_asset.frames[self.frame_index];
            }
        }

        return result;
    }

    pub fn getOffset(self: *SpriteComponent, assets: *game.Assets) Vector2 {
        var result: Vector2 = .{ 0, 0 };

        if (assets.getSpriteAsset(self)) |sprite_asset| {
            if (self.frame_index < sprite_asset.frames.len) {
                const cel_chunk = sprite_asset.document.frames[self.frame_index].cel_chunk;
                result[0] = @floatFromInt(cel_chunk.x);
                result[1] = @floatFromInt(cel_chunk.y);
            }
        }

        return result;
    }

    pub fn startAnimation(self: *SpriteComponent, name: []const u8, assets: *game.Assets) void {
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

    pub fn isAnimating(self: *SpriteComponent, name: []const u8) bool {
        var result = false;

        if (self.current_animation) |tag| {
            if (std.mem.eql(u8, name, tag.tag_name)) {
                result = true;
            }
        }

        return result;
    }

    pub fn containsPoint(self: *const SpriteComponent, point: Vector2, assets: *game.Assets) bool {
        var contains_point = false;
        var position: Vector2 = .{ 0, 0 };

        if (assets.getSpriteAsset(self)) |sprite_asset| {
            if (self.entity.transform) |transform| {
                position = transform.position;
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
};

pub const ColorComponentValue = enum {
    Gray,
    Red,
    Blue,
};

pub const ColorComponent = struct {
    entity: *Entity,

    color: ColorComponentValue,
};

pub const BlockType = enum {
    Wall,
    Deadly,
    ColorChange,
};

pub const BlockComponent = struct {
    entity: *Entity,

    type: BlockType,
};
