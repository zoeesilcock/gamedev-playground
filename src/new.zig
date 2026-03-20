const std = @import("std");

const IGNORED_PATHS = [_][]const u8{
    ".git",
    ".DS_Store",
    ".zig-cache",
    "imgui.ini",
    "zig-out",
};

fn isPathIgnored(path: []const u8) bool {
    var result: bool = false;
    for (IGNORED_PATHS) |ignored_path| {
        if (std.mem.eql(u8, path, ignored_path)) {
            result = true;
            break;
        }
    }
    return result;
}

fn copyDirectory(
    source_dir: std.fs.Dir,
    target_dir: std.fs.Dir,
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    level: u32,
) !void {
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    // TODO: This only looks nice up to one level deep. Rebuild this to support deeper levels when we need it.
    const prefix: []const u8 = if (level == 0) "├─ " else "│  ├─";
    const end_prefix: []const u8 = if (level == 0) "└─ " else "│  └─ ";

    while (try walker.next()) |entry| {
        if (!isPathIgnored(entry.path) and entry.dir.fd == source_dir.fd) {
            if (entry.kind == .file) {
                try stdout.print("{s}Copying file: {s}.\n", .{ prefix, entry.path });
                try entry.dir.copyFile(entry.path, target_dir, entry.path, .{});
            } else if (entry.kind == .directory) {
                try stdout.print("{s}Creating directory: {s}.\n", .{ prefix, entry.path });
                try target_dir.makeDir(entry.path);

                var source_sub_dir: std.fs.Dir = try source_dir.openDir(entry.path, .{ .access_sub_paths = false });
                defer source_sub_dir.close();

                var target_sub_dir: std.fs.Dir = try target_dir.openDir(entry.path, .{ .access_sub_paths = false });
                defer target_sub_dir.close();

                try copyDirectory(source_sub_dir, target_sub_dir, stdout, allocator, level + 1);
            }
        }
    }

    try stdout.print("{s}Done.\n", .{end_prefix});
}

pub fn main() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    errdefer stdout.flush() catch undefined;

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena_allocator.allocator();
    defer arena_allocator.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 2) {
        const target_path = args[1];
        const source_path = try std.fs.cwd().realpathAlloc(allocator, "examples/template");

        try stdout.print("\nWelcome to Flint! Let's get you started.\n\n", .{});
        try stdout.print("Generating new project in: {s}, based on: {s}.\n", .{ target_path, source_path });

        // Make sure that the target directory doesn't exist.
        var target_dir: ?std.fs.Dir =
            std.fs.cwd().openDir(target_path, .{ .access_sub_paths = false }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return error.UnexpectedError,
            };
        if (target_dir) |*dir| {
            dir.close();
            try stdout.print("ERROR: Target path already exists, please use a path that doesn't exist.\n", .{});
            try stdout.flush();
            return;
        }

        // Create the target directory.
        try stdout.print("├─ Creating target directory: {s}.\n", .{target_path});
        try std.fs.cwd().makePath(target_path);
        target_dir = try std.fs.cwd().openDir(target_path, .{ .access_sub_paths = false });

        // Copy template files to target directory.
        var source_dir = try std.fs.cwd().openDir(source_path, .{ .access_sub_paths = false, .iterate = true });
        defer source_dir.close();
        try copyDirectory(source_dir, target_dir.?, stdout, allocator, 0);

        try stdout.print("\nYou're all setup!\n\n", .{});
        try stdout.print("Run your new project:\n`cd {s} && zig build run`\n\n", .{target_path});
    } else {
        try stdout.print("Flint received unexpected input.\n", .{});
        try stdout.print("Usage: {s} <new-project-path>\n", .{args[0]});
    }

    try stdout.flush(); // Don't forget to flush!
}
