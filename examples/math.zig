const std = @import("std");
const sdl = @import("sdl").c;

pub const Vector2 = @Vector(2, f32);
pub const Vector3 = @Vector(3, f32);
pub const Vector4 = @Vector(4, f32);
pub const Color3 = @Vector(3, u8);
pub const Color = @Vector(4, u8);

pub const X = 0;
pub const Y = 1;
pub const Z = 2;
pub const W = 3;

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

    pub fn toSDL(self: *const Rect) sdl.SDL_FRect {
        return sdl.SDL_FRect{
            .x = self.position[X],
            .y = self.position[Y],
            .w = self.size[X],
            .h = self.size[Y],
        };
    }
};

pub fn normalizeV3(a: Vector3) Vector3 {
    const magnitude: f32 = @sqrt(a[X] * a[X] + a[Y] * a[Y] + a[Z] * a[Z]);
    return a / @as(Vector3, @splat(magnitude));
}

pub fn crossV3(a: Vector3, b: Vector3) Vector3 {
    return .{
        a[Y] * b[Z] - b[Y] * a[Z],
        -(a[X] * b[Z] - b[X] * a[Z]),
        a[X] * b[Y] - b[X] * a[Y],
    };
}

pub fn dotV3(a: Vector3, b: Vector3) f32 {
    return a[X] * b[X] + a[Y] * b[Y] + a[Z] * b[Z];
}

pub const Matrix4x4 = extern struct {
    values: [16]f32,

    pub fn new(
        row1col1: f32,
        row1col2: f32,
        row1col3: f32,
        row1col4: f32,
        row2col1: f32,
        row2col2: f32,
        row2col3: f32,
        row2col4: f32,
        row3col1: f32,
        row3col2: f32,
        row3col3: f32,
        row3col4: f32,
        row4col1: f32,
        row4col2: f32,
        row4col3: f32,
        row4col4: f32,
    ) Matrix4x4 {
        return .{
            .values = .{
                row1col1,
                row1col2,
                row1col3,
                row1col4,
                row2col1,
                row2col2,
                row2col3,
                row2col4,
                row3col1,
                row3col2,
                row3col3,
                row3col4,
                row4col1,
                row4col2,
                row4col3,
                row4col4,
            }
        };
    }

    pub fn zero() Matrix4x4 {
        return .new(
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0
        );
    }

    pub fn identity() Matrix4x4 {
        return .new(
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        );
    }

    pub fn multiply(a: Matrix4x4, b: Matrix4x4) Matrix4x4 {
        var result: Matrix4x4 = .zero();

        for (0..4) |c| {
            for (0..4) |r| {
                for (0..4) |i| {
                    result.values[r + c * 4] += a.values[c * 4 + i] * b.values[r + i * 4];
                }
            }
        }

        return result;
    }

    pub fn log(prefix: []const u8, a: Matrix4x4) void {
        std.log.info(
            "{s}:\n{d} {d} {d} {d}\n{d} {d} {d} {d}\n{d} {d} {d} {d}\n{d} {d} {d} {d}\n",
            .{
                prefix,
                a.values[0],
                a.values[1],
                a.values[2],
                a.values[3],
                a.values[4],
                a.values[5],
                a.values[6],
                a.values[7],
                a.values[8],
                a.values[9],
                a.values[10],
                a.values[11],
                a.values[12],
                a.values[13],
                a.values[14],
                a.values[15],
            },
        );
    }
};

