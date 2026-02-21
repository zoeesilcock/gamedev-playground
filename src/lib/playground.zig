const INTERNAL: bool = @import("build_options").internal;

pub const sdl = @import("sdl.zig");
pub const aseprite = @import("aseprite.zig");
pub const imgui = if (INTERNAL) @import("imgui.zig") else struct {
    pub const ImGuiContext: type = anyopaque;
};
pub const internal = if (INTERNAL) @import("internal.zig") else {};

pub const GameLib = @import("GameLib.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
