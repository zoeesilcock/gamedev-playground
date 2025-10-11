const std = @import("std");
pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

pub fn panicIfNull(result: anytype, message: []const u8) @TypeOf(result) {
    if (result == null) {
        std.log.err("{s} SDL error: {s}", .{ message, c.SDL_GetError() });
        @panic(message);
    }

    return result;
}

pub fn panic(result: bool, message: []const u8) void {
    if (result == false) {
        std.log.err("{s} SDL error: {s}", .{ message, c.SDL_GetError() });
        @panic(message);
    }
}
