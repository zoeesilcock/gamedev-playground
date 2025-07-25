const c_sdl = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

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
    position: Vector2 = @splat(0),
    size: Vector2 = @splat(0),

    pub fn scaled(self: *const Rect, scale: f32) Rect {
        return Rect{
            .position = self.position * @as(Vector2, @splat(scale)),
            .size = self.size * @as(Vector2, @splat(scale)),
        };
    }

    pub fn toSDL(self: *const Rect) c_sdl.SDL_FRect {
        return c_sdl.SDL_FRect{
            .x = self.position[X],
            .y = self.position[Y],
            .w = self.size[X],
            .h = self.size[Y],
        };
    }
};
