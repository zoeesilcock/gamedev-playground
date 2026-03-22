const std = @import("std");

const IGNORED_PATHS = [_][]const u8{
    ".git",
    ".DS_Store",
    ".zig-cache",
    "imgui.ini",
    "zig-out",
};

const FILES_WITH_SUBSTITUTIONS = [_][]const u8{
    "root.zig",
    "build.zig",
    "build.zig.zon",
};

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

        const new_name: []const u8 = std.fs.path.basename(target_path);

        // Copy template files to target directory.
        var source_dir = try std.fs.cwd().openDir(source_path, .{ .access_sub_paths = false, .iterate = true });
        defer source_dir.close();
        try copyDirectory(source_dir, target_dir.?, new_name, stdout, allocator, 0);

        try stdout.print("\nYou're all setup!\n\n", .{});
        try stdout.print("Run your new project:\n`cd {s} && zig build all && zig build run`\n\n", .{target_path});
    } else {
        try stdout.print("Flint received unexpected input.\n", .{});
        try stdout.print("Usage: {s} <new-project-path>\n", .{args[0]});
    }

    try stdout.flush(); // Don't forget to flush!
}

fn copyDirectory(
    source_dir: std.fs.Dir,
    target_dir: std.fs.Dir,
    new_name: []const u8,
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    level: u32,
) !void {
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    // TODO: This only looks nice up to one level deep. Rebuild this to support deeper levels when we need it.
    const prefix: []const u8 = if (level == 0) "├─ " else "│  ├─ ";
    const end_prefix: []const u8 = if (level == 0) "└─ " else "│  └─ ";

    while (try walker.next()) |entry| {
        if (!isPathIgnored(entry.path) and entry.dir.fd == source_dir.fd) {
            if (entry.kind == .file) {
                try stdout.print("{s}Copying file: {s}.\n", .{ prefix, entry.path });
                if (fileHasSubstitutions(entry.path)) {
                    try copyFileWithSubstitutions(source_dir, target_dir, entry.path, new_name);
                } else {
                    try entry.dir.copyFile(entry.path, target_dir, entry.path, .{});
                }
            } else if (entry.kind == .directory) {
                try stdout.print("{s}Creating directory: {s}.\n", .{ prefix, entry.path });
                try target_dir.makeDir(entry.path);

                var source_sub_dir: std.fs.Dir = try source_dir.openDir(entry.path, .{ .access_sub_paths = false });
                defer source_sub_dir.close();

                var target_sub_dir: std.fs.Dir = try target_dir.openDir(entry.path, .{ .access_sub_paths = false });
                defer target_sub_dir.close();

                try copyDirectory(source_sub_dir, target_sub_dir, new_name, stdout, allocator, level + 1);
            }
        }
    }

    try stdout.print("{s}Done.\n", .{end_prefix});
}

fn copyFileWithSubstitutions(
    source_dir: std.fs.Dir,
    target_dir: std.fs.Dir,
    file_name: []const u8,
    new_name: []const u8,
) !void {
    const source_file: std.fs.File = try source_dir.openFile(file_name, .{ .mode = .read_only });
    defer source_file.close();
    var read_buffer: [1024]u8 = undefined;
    var file_reader = source_file.reader(&read_buffer);
    const reader: *std.Io.Reader = &file_reader.interface;

    const dest_file: std.fs.File = try target_dir.createFile(file_name, .{});
    defer dest_file.close();
    var write_buffer: [1024]u8 = undefined;
    var file_writer = dest_file.writer(&write_buffer);
    const writer = &file_writer.interface;

    var string_buffer: [1024]u8 = undefined;
    var string_length: u32 = 0;
    var string_discarding_writer: std.Io.Writer.Discarding = .init(&string_buffer);
    const string_writer = &string_discarding_writer.writer;

    while (true) {
        const next_character = reader.take(1) catch break;
        try writer.print("{s}", .{next_character});

        if (std.mem.eql(u8, next_character, "\"")) { // Match strings.
            string_length = 0;
            try string_writer.flush();

            while (true) {
                const peek = reader.peek(1) catch break;

                if (std.mem.eql(u8, peek, "\"")) {
                    const string = string_buffer[0..string_length];
                    try printStringOrSubstitute(string, writer, new_name);
                    break;
                } else {
                    reader.toss(1);
                    try string_writer.print("{s}", .{peek});
                    string_length += 1;
                }
            }

            _ = reader.stream(writer, .limited(1)) catch break;
        } else if (std.mem.eql(u8, next_character, ".")) { // Match enum literals.
            string_length = 0;
            try string_writer.flush();

            while (true) {
                const peek = reader.peek(1) catch break;

                if (std.mem.eql(u8, peek, " ") or
                    std.mem.eql(u8, peek, ".") or
                    std.mem.eql(u8, peek, "(") or
                    std.mem.eql(u8, peek, ")") or
                    std.mem.eql(u8, peek, ",") or
                    std.mem.eql(u8, peek, "{"))
                {
                    const string = string_buffer[0..string_length];
                    try printStringOrSubstitute(string, writer, new_name);
                    break;
                } else {
                    reader.toss(1);
                    try string_writer.print("{s}", .{peek});
                    string_length += 1;
                }
            }

            _ = reader.stream(writer, .limited(1)) catch break;
        } else if (std.mem.eql(u8, reader.peek(2) catch break, "0x")) { // Match hex numbers.
            string_length = 0;
            try string_writer.flush();

            while (true) {
                const peek = reader.peek(1) catch break;

                if (std.mem.eql(u8, peek, " ") or
                    std.mem.eql(u8, peek, ",") or
                    std.mem.eql(u8, peek, ")"))
                {
                    const string = string_buffer[0..string_length];
                    std.log.info("hex: '{s}'", .{string});
                    try printStringOrSubstitute(string, writer, new_name);
                    break;
                } else {
                    reader.toss(1);
                    try string_writer.print("{s}", .{peek});
                    string_length += 1;
                }
            }
        }
    }

    try writer.flush();
}

fn printStringOrSubstitute(
    string: []const u8,
    writer: *std.Io.Writer,
    new_name: []const u8,
) !void {
    if (std.mem.eql(u8, string, "template")) {
        try writer.print("{s}", .{new_name});
    } else if (std.mem.eql(u8, string, "Template")) {
        try printCapitalizedName(new_name, writer);
    } else if (std.mem.eql(u8, string, "0x3d54e0a673bba291")) {
        try printNewFingerprint(new_name, writer);
    } else {
        try writer.print("{s}", .{string});
    }
}

fn printCapitalizedName(name: []const u8, writer: *std.Io.Writer) !void {
    var reader: std.Io.Reader = std.Io.Reader.fixed(name);
    var capitalize: bool = true;

    while (true) {
        var next_character = reader.take(1) catch break;

        if (capitalize) {
            capitalize = false;
            next_character[0] = std.ascii.toUpper(next_character[0]);
        }

        if (std.mem.eql(u8, next_character, "-") or std.mem.eql(u8, next_character, "_")) {
            next_character[0] = ' ';
            capitalize = true;
        }

        try writer.print("{s}", .{next_character});
    }
}

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

fn fileHasSubstitutions(path: []const u8) bool {
    var result: bool = false;
    for (FILES_WITH_SUBSTITUTIONS) |with_subs| {
        if (std.mem.eql(u8, path, with_subs)) {
            result = true;
            break;
        }
    }
    return result;
}

/// This is borrowed from `src/Package.zig` in the zig codebase since it isn't exposed in the standard library.
/// If the fingerprint starts to fail the original code may have changed.
pub const Fingerprint = packed struct(u64) {
    id: u32,
    checksum: u32,

    pub fn generate(rng: std.Random, name: []const u8) Fingerprint {
        return .{
            .id = rng.intRangeLessThan(u32, 1, 0xffffffff),
            .checksum = std.hash.Crc32.hash(name),
        };
    }

    pub fn validate(n: Fingerprint, name: []const u8) bool {
        switch (n.id) {
            0x00000000, 0xffffffff => return false,
            else => return std.hash.Crc32.hash(name) == n.checksum,
        }
    }

    pub fn int(n: Fingerprint) u64 {
        return @bitCast(n);
    }
};

fn printNewFingerprint(new_name: []const u8, writer: *std.Io.Writer) !void {
    var ptr: std.Random.Xoshiro256 = .init(1);
    const rng: std.Random = std.Random.DefaultPrng.random(&ptr);
    const fingerprint: Fingerprint = .generate(rng, new_name);
    try writer.print("0x{x}", .{fingerprint.int()});
}
