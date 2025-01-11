const std = @import("std");
const r = @import("dependencies/raylib.zig");
const aseprite = @import("aseprite.zig");
const root = @import("root.zig");

pub const TransformComponent = struct {
    entity: *Entity,

    position: r.Vector2,
    size: r.Vector2,
    velocity: r.Vector2,
    next_velocity: r.Vector2,

    pub fn tick(transforms: []*TransformComponent, delta_time: f32) void {
        for (transforms) |transform| {
            transform.position.x += transform.velocity.x * delta_time;
            transform.position.y += transform.velocity.y * delta_time;
        }
    }

    pub fn top(self: *const TransformComponent) f32 {
        return self.position.y;
    }

    pub fn bottom(self: *const TransformComponent) f32 {
        return self.position.y + self.size.y;
    }

    pub fn left(self: *const TransformComponent) f32 {
        return self.position.x;
    }

    pub fn right(self: *const TransformComponent) f32 {
        return self.position.x + self.size.x;
    }

    pub fn center(self: *const TransformComponent) r.Vector2 {
        return r.Vector2{ .x = self.position.x + self.size.x * 0.5, .y = self.position.y + self.size.y * 0.5 };
    }

    pub fn containsPoint(self: *const TransformComponent, point: r.Vector2) bool {
        var contains_point = false;

        if ((point.x <= self.right() and point.x >= self.left()) and
            (point.y <= self.bottom() and point.y >= self.top()))
        {
            contains_point = true;
        }

        return contains_point;
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

const Collision = struct {
    self: *ColliderComponent,
    other: *ColliderComponent,
};

pub const ColliderComponent = struct {
    entity: *Entity,

    offset: r.Vector2,
    size: r.Vector2,
    shape: ColliderShape,

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
        _ = self;
        var collides = false;

        if (other.entity.transform) |other_at| {
            if (((at.left() >= other_at.left() and at.left() <= other_at.right()) or
                (at.right() >= other_at.left() and at.right() <= other_at.right())) and
                ((at.bottom() >= other_at.top() and at.bottom() <= other_at.bottom()) or
                (at.top() <= other_at.bottom() and at.top() >= other_at.top())))
            {
                collides = true;
            }
        }

        return collides;
    }

    pub fn checkForCollisions(colliders: []*ColliderComponent, delta_time: f32) CollisionResult {
        var result: CollisionResult = .{};

        for (colliders) |collider| {
            if (collider.entity.transform) |transform| {
                if (transform.velocity.x != 0 or transform.velocity.y != 0) {
                    var next_transform = transform.*;

                    // Check in the Y direction.
                    next_transform.position.y += next_transform.velocity.y * delta_time;
                    if (collider.collidesWithAnyAt(colliders, next_transform)) |other_entity| {
                        result.vertical = .{ .self = collider, .other = other_entity.collider.? };
                    }

                    // Check in the X direction.
                    next_transform = transform.*;
                    next_transform.position.x += next_transform.velocity.x * delta_time;
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

    asset: *const root.SpriteAsset,
    frame_index: u32,
    duration_shown: f64,
    loop_animation: bool,
    animation_completed: bool,
    current_animation: ?*aseprite.AseTagsChunk,

    pub fn tick(sprites: []*SpriteComponent, delta_time: f32) void {
        for (sprites) |sprite| {
            if (sprite.asset.document.frames.len > 1) {
                const current_frame = sprite.asset.document.frames[sprite.frame_index];
                var from_frame: u16 = 0;
                var to_frame: u16 = @intCast(sprite.asset.document.frames.len);

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

                    sprite.setFrame(next_frame);
                }
            }
        }
    }

    pub fn setFrame(self: *SpriteComponent, index: u32) void {
        if (index < self.asset.document.frames.len) {
            self.duration_shown = 0;
            self.frame_index = index;
        }
    }

    pub fn getTexture(self: *SpriteComponent) ?r.Texture2D {
        var result: ?r.Texture2D = null;

        if (self.frame_index < self.asset.frames.len) {
            result = self.asset.frames[self.frame_index];
        }

        return result;
    }

    pub fn getOffset(self: *SpriteComponent) r.Vector2 {
        var result: r.Vector2 = .{ .x = 0, .y = 0 };

        if (self.frame_index < self.asset.frames.len) {
            const cel_chunk = self.asset.document.frames[self.frame_index].cel_chunk;
            result.x = @floatFromInt(cel_chunk.x);
            result.y = @floatFromInt(cel_chunk.y);
        }

        return result;
    }

    pub fn startAnimation(self: *SpriteComponent, name: []const u8) void {
        var opt_tag: ?*aseprite.AseTagsChunk = null;

        outer: for (self.asset.document.frames) |frame| {
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
            self.setFrame(tag.from_frame);
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

pub const Entity = struct {
    transform: ?*TransformComponent,
    collider: ?*ColliderComponent,
    sprite: ?*SpriteComponent,
    color: ?*ColorComponent,
};
