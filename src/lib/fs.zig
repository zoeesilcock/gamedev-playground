//! Exposes some utilities for working with the file system.
const std = @import("std");

/// Opens a directory relative to the current working directory.
/// Falls back to the executable directory if the directory isn't found in the current working directory.
pub fn openDirRelative(io: std.Io, sub_path: []const u8, args: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.Io.Dir.cwd().openDir(io, sub_path, args)) |directory| {
        return directory;
    } else |_| {
        var buffer: [1024]u8 = undefined;
        const path_length = try std.process.executableDirPath(io, &buffer);
        const exe_path = buffer[0..path_length];

        var exe_dir = try std.Io.Dir.cwd().openDir(io, exe_path, .{});
        defer exe_dir.close(io);

        return try exe_dir.openDir(io, sub_path, args);
    }
}

/// Opens a file relative to the current working directory.
/// Falls back to the executable directory if the file isn't found in the current working directory.
pub fn openFileRelative(io: std.Io, sub_path: []const u8, flags: std.Io.File.OpenFlags) !std.Io.File {
    if (std.Io.Dir.cwd().openFile(io, sub_path, flags)) |file| {
        return file;
    } else |_| {
        var buffer: [1024]u8 = undefined;
        const path_length = try std.process.executableDirPath(io, &buffer);
        const exe_path = buffer[0..path_length];

        var exe_dir = try std.Io.Dir.cwd().openDir(io, exe_path, .{});
        defer exe_dir.close(io);

        return try exe_dir.openFile(io, sub_path, flags);
    }
}

/// Returns the provided path if it exists relative to the current working directory, otherwise it returns the path
/// relative to the executable directory. Allocates memory for the result, which must be freed by the caller.
pub fn getFilePathRelative(io: std.Io, sub_path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (fileExists(io, sub_path)) {
        return try std.fmt.allocPrint(allocator, "{s}", .{sub_path});
    } else {
        var buffer: [1024]u8 = undefined;
        const path_length = try std.process.executableDirPath(io, &buffer);
        const exe_path = buffer[0..path_length];
        return try std.fs.path.join(allocator, &.{ exe_path, sub_path });
    }
}

/// Checks if a file exists.
pub fn fileExists(io: std.Io, file_name: []const u8) bool {
    var result: bool = false;

    const opt_file: ?std.Io.File = std.Io.Dir.cwd().openFile(io, file_name, .{ .mode = .read_only }) catch null;
    defer if (opt_file) |file| file.close(io);

    if (opt_file != null) {
        result = true;
    }

    return result;
}
