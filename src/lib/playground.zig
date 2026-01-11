const INTERNAL: bool = @import("build_options").internal;

pub const sdl = @import("sdl.zig");
pub const imgui = @import("imgui.zig");
pub const aseprite = @import("aseprite.zig");
pub const internal = if (INTERNAL) @import("internal.zig") else {};

pub const GameLib = @import("GameLib.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
