//! Exposes some utilities for working with the file system.
const std = @import("std");

/// Opens a directory relative to the current working directory.
/// Falls back to the executable directory if the directory isn't found.
pub fn openDirRelative(sub_path: []const u8, args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (std.fs.cwd().openDir(sub_path, args)) |directory| {
        return directory;
    } else |_| {
        var buffer: [1024]u8 = undefined;
        const exe_path = try std.fs.selfExeDirPath(&buffer);

        var exe_dir = try std.fs.cwd().openDir(exe_path, .{});
        defer exe_dir.close();

        return try exe_dir.openDir(sub_path, args);
    }
}

/// Opens a file relative to the current working directory.
/// Falls back to the executable directory if the file isn't found.
pub fn openFileRelative(sub_path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.cwd().openFile(sub_path, flags)) |file| {
        return file;
    } else |_| {
        var buffer: [1024]u8 = undefined;
        const exe_path = try std.fs.selfExeDirPath(&buffer);

        var exe_dir = try std.fs.cwd().openDir(exe_path, .{});
        defer exe_dir.close();

        return try exe_dir.openFile(sub_path, flags);
    }
}

/// Returns the provided path if it exists relative to the current working directory, otherwise it returns the path
/// relative to the executable directory.
pub fn getFilePathRelative(sub_path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (fileExists(sub_path)) {
        return sub_path;
    } else {
        var buffer: [1024]u8 = undefined;
        const exe_path = try std.fs.selfExeDirPath(&buffer);
        return try std.fs.path.join(allocator, &.{ exe_path, sub_path });
    }
}

/// Checks if a file exists.
pub fn fileExists(file_name: []const u8) bool {
    var result: bool = false;

    const opt_file: ?std.fs.File = std.fs.cwd().openFile(file_name, .{ .mode = .read_only }) catch null;
    defer if (opt_file) |file| file.close();

    if (opt_file != null) {
        result = true;
    }

    return result;
}
