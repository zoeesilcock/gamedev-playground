const std = @import("std");
const r = @import("dependencies/raylib.zig");
const aseprite = @import("aseprite.zig");
const root = @import("root.zig");

pub const TransformComponent = struct {
    entity: *Entity,

    position: r.Vector2,
    size: r.Vector2,
    velocity: r.Vector2,

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
};

pub const SpriteComponent = struct {
    entity: *Entity,

    asset: *const root.SpriteAsset,
    frame_index: u32,
    frame_start_time: f64,
    loop_animation: bool,
    animation_completed: bool,

    pub fn setFrame(self: *SpriteComponent, index: u32) void {
        if (index < self.asset.document.frames.len) {
            self.frame_index = index;
            self.frame_start_time = r.GetTime();
        }
    }

    pub fn getTexture(self: *SpriteComponent) r.Texture2D {
        return self.asset.frames[self.frame_index];
    }
};

pub const Entity = struct {
    transform: ?*TransformComponent,
    sprite: ?*SpriteComponent,
};
