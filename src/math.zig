const game = @import("game.zig");
const c = game.c;

pub const Vector2 = @Vector(2, f32);
pub const Color3 = @Vector(3, u8);
pub const Color = @Vector(4, u8);

pub const X = 0;
pub const Y = 1;
pub const Z = 2;

pub const R = 0;
pub const G = 1;
pub const B = 2;
pub const A = 3;

pub const Rect = struct {
    position: Vector2,
    size: Vector2,

    pub fn scaled(self: *const Rect, scale: f32) Rect {
        return Rect{
            .position = self.position * @as(Vector2, @splat(scale)),
            .size = self.size * @as(Vector2, @splat(scale)),
        };
    }

    pub fn toSDL(self: *const Rect) c.SDL_FRect {
        return c.SDL_FRect{
            .x = self.position[X],
            .y = self.position[Y],
            .w = self.size[X],
            .h = self.size[Y],
        };
    }
};
