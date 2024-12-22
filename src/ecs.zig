const std = @import("std");
const r = @import("dependencies/raylib.zig");
const aseprite = @import("aseprite.zig");

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

    texture: ?r.Texture = null,
    frame_index: u32,
    frame_start_time: f64,
    loop_animation: bool,
    animation_completed: bool,
    document: aseprite.AseDocument,

    pub fn setFrame(self: *SpriteComponent, index: u32) void {
        if (index < self.document.frames.len) {
            const cel = self.document.frames[index].cel_chunk;
            const image: r.Image = .{
                .data = @ptrCast(@constCast(cel.data.compressedImage.pixels)),
                .width = cel.data.compressedImage.width,
                .height = cel.data.compressedImage.height,
                .mipmaps = 1,
                .format = r.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
            };
            self.texture = r.LoadTextureFromImage(image);
            self.frame_index = index;
            self.frame_start_time = r.GetTime();
        }
    }
};

pub const Entity = struct {
    transform: ?*TransformComponent,
    sprite: ?*SpriteComponent,
};
