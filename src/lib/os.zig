//! Exposes platform specific functionality.
const std = @import("std");

pub const windows = @import("os/windows.zig");

// Build options.
const PLATFORM = @import("builtin").os.tag;

pub const LoadedLibrary = if (PLATFORM == .windows) windows.HMODULE else std.DynLib;

/// A wrapper which uses kernel32 on Windows and the standard library on other platforms.
pub fn loadLibrary(path: []const u8, allocator: std.mem.Allocator) !?LoadedLibrary {
    var result: ?LoadedLibrary = null;
    if (PLATFORM == .windows) {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);

        result = windows.LoadLibraryExW(path_w, null, 0);
    } else {
        result = try std.DynLib.open(path);
    }
    return result;
}

/// A wrapper which uses kernel32 on Windows and the standard library on other platforms.
pub fn unloadLibrary(library: *LoadedLibrary) void {
    if (PLATFORM == .windows) {
        _ = windows.FreeLibrary(library.*);
    } else {
        library.close();
    }
}
