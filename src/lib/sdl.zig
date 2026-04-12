//! Exposes the SDL 3 C API and some helper functions for handling errors from SDL.
const std = @import("std");

/// The SDL 3 C API.
pub const c = @import("sdl_c");

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

pub fn logError(result: bool, message: []const u8) void {
    if (result == false) {
        std.log.err("{s} SDL error: {s}", .{ message, c.SDL_GetError() });
    }
}
