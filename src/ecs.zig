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

    pub fn top(self: *TransformComponent) f32 {
        return self.position.y;
    }

    pub fn bottom(self: *TransformComponent) f32 {
        return self.position.y + self.size.y;
    }

    pub fn left(self: *TransformComponent) f32 {
        return self.position.x;
    }

    pub fn right(self: *TransformComponent) f32 {
        return self.position.x + self.size.x;
    }

    pub fn center(self: *TransformComponent) r.Vector2 {
        return r.Vector2{ .x = self.position.x + self.size.x * 0.5, .y = self.position.y + self.size.y * 0.5 };
    }

    pub fn collidesWith(self: *TransformComponent, other: *TransformComponent) bool {
        var collides = false;

        if (
            ((self.left() >= other.left() and self.left() <= other.right()) or
             (self.right() >= other.left() and self.right() <= other.right())) and
            ((self.bottom() >= other.top() and self.bottom() <= other.bottom()) or
             (self.top() <= other.bottom() and self.top() >= other.top()))
        ) {
            collides = true;
        }

        return collides;
    }

    pub fn collidesWithPoint(self: *TransformComponent, point: r.Vector2) bool {
        var collides = false;

        if ((point.x <= self.right() and point.x >= self.left()) and 
            (point.y <= self.bottom() and point.y >= self.top())) {
            collides = true;
        }

        return collides;
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
    color: ColorComponentValue,
};

pub const Entity = struct {
    transform: ?*TransformComponent,
    sprite: ?*SpriteComponent,
    color: ?*ColorComponent,
};
