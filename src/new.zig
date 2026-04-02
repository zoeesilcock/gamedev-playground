const std = @import("std");

const PLATFORM = @import("builtin").os.tag;

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
    "README.md",
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

    if (args.len == 2 and args[1][0] != '-' and args[1][1] != '-') {
        const target_path = args[1];
        const source_path = try std.fs.cwd().realpathAlloc(allocator, "examples/template");

        try stdout.print("\nWelcome to Flint! Let's get you started.\n\n", .{});
        try stdout.print("Generating new project in: {s}, based on: {s}.\n", .{ target_path, source_path });
        try stdout.flush();

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
        var buffer: [64]u8 = undefined;
        try stdout.print("{s}Creating target directory: {s}.\n", .{ getDecoration(0, .Middle, &buffer), target_path });
        try stdout.flush();
        try std.fs.cwd().makePath(target_path);
        target_dir = try std.fs.cwd().openDir(target_path, .{ .access_sub_paths = false });

        const new_name: []const u8 = std.fs.path.basename(target_path);

        // Copy template files to target directory.
        var source_dir = try std.fs.cwd().openDir(source_path, .{ .access_sub_paths = false, .iterate = true });
        defer source_dir.close();
        try copyDirectory(source_dir, target_dir.?, new_name, stdout, allocator, 0);

        // Add the Flint dependency using `zig fetch`.
        try stdout.print("\nAdding Flint dependency.\n", .{});
        try stdout.flush();

        var zig_fetch_process = initChildProcess(&.{
            "zig",
            "fetch",
            "--save",
            "git+https://github.com/zoeesilcock/flint.git",
        }, target_path, target_dir, allocator);
        if (zig_fetch_process.spawnAndWait()) |_| {} else |err| {
            try stdout.print(
                "ERROR: Failed to run `zig fetch` (error: {s}), make sure Zig is on the path.\n",
                .{@errorName(err)},
            );
        }

        // Initialize git repo.
        try stdout.print("\nInitializing git repo.\n", .{});
        try stdout.flush();

        var git_init_proccess = initChildProcess(&.{ "git", "init" }, target_path, target_dir, allocator);
        if (git_init_proccess.spawnAndWait()) |_| {
            git_init_proccess = initChildProcess(&.{ "git", "add", "." }, target_path, target_dir, allocator);
            if (git_init_proccess.spawnAndWait()) |_| {} else |err| {
                try stdout.print("ERROR: Failed to run `git add .` (error: {s}).", .{@errorName(err)});
            }

            git_init_proccess =
                initChildProcess(&.{ "git", "commit", "-m", "Initial commit" }, target_path, target_dir, allocator);
            if (git_init_proccess.spawnAndWait()) |_| {} else |err| {
                try stdout.print("ERROR: Failed to run `git commit` (error: {s}).", .{@errorName(err)});
            }
        } else |err| {
            try stdout.print("ERROR: Failed to run `git init` (error: {s}).\n", .{@errorName(err)});
        }

        try stdout.print("\nYou're all setup!\n\n", .{});
        try stdout.print("Run your new project:\n`cd {s} && zig build run`\n\n", .{target_path});
    } else {
        if (args.len != 2 or !std.mem.eql(u8, args[1], "--help")) {
            try stdout.print("Flint received unexpected input.\n", .{});
        }
        try stdout.print("Usage: {s} <new-project-path>\n", .{args[0]});
    }

    try stdout.flush(); // Don't forget to flush!
}

fn initChildProcess(
    command: []const []const u8,
    target_path: []const u8,
    target_dir: ?std.fs.Dir,
    allocator: std.mem.Allocator,
) std.process.Child {
    var process = std.process.Child.init(command, allocator);
    if (PLATFORM == .windows) {
        process.cwd = target_path;
    } else {
        process.cwd_dir = target_dir;
    }
    return process;
}

const Decoration = enum {
    Middle,
    Indent,
    End,

    pub fn getString(self: Decoration) []const u8 {
        if (PLATFORM == .windows) {
            return switch (self) {
                .Middle => "\xC3\xC4 ",
                .Indent => "\xB3  ",
                .End => "\xC0\xC4 ",
            };
        } else {
            return switch (self) {
                .Middle => "├─ ",
                .Indent => "│  ",
                .End => "└─ ",
            };
        }
    }
};

fn getDecoration(level: u32, decoration_type: Decoration, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    for (0..level) |_| {
        writer.print("{s}", .{Decoration.Indent.getString()}) catch undefined;
    }
    writer.print("{s}", .{decoration_type.getString()}) catch undefined;

    return writer.buffered();
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

    var buffer: [64]u8 = undefined;
    while (try walker.next()) |entry| {
        if (!isPathIgnored(entry.path) and entry.dir.fd == source_dir.fd) {
            if (entry.kind == .file) {
                try stdout.print(
                    "{s}Copying file: {s}.\n",
                    .{ getDecoration(level, .Middle, &buffer), entry.path },
                );
                try stdout.flush();
                if (fileHasSubstitutions(entry.path)) {
                    try copyFileWithSubstitutions(source_dir, target_dir, entry.path, new_name);
                } else {
                    try entry.dir.copyFile(entry.path, target_dir, entry.path, .{});
                }
            } else if (entry.kind == .directory) {
                try stdout.print(
                    "{s}Creating directory: {s}.\n",
                    .{ getDecoration(level, .Middle, &buffer), entry.path },
                );
                try stdout.flush();
                try target_dir.makeDir(entry.path);

                var source_sub_dir: std.fs.Dir =
                    try source_dir.openDir(entry.path, .{ .access_sub_paths = false, .iterate = true });
                defer source_sub_dir.close();

                var target_sub_dir: std.fs.Dir = try target_dir.openDir(entry.path, .{ .access_sub_paths = false });
                defer target_sub_dir.close();

                try copyDirectory(source_sub_dir, target_sub_dir, new_name, stdout, allocator, level + 1);
            }
        }
    }

    try stdout.print("{s}Done.\n", .{getDecoration(level, .End, &buffer)});
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

    const is_build_zig_zon_file: bool = std.mem.eql(u8, file_name, "build.zig.zon");
    const is_readme_file: bool = std.mem.eql(u8, file_name, "README.md");

    while (true) {
        // Replace the title in the README.md file.
        if (is_readme_file and std.mem.eql(u8, reader.peek(10) catch "", "# Template")) {
            _ = reader.stream(writer, .limited(2)) catch break;

            const title: []const u8 = try reader.takeDelimiterExclusive('\n');
            try printStringOrSubstitute(title, writer, new_name);
        }

        // Strip out the Flint dependency since `zig fetch` puts the URL in the `.path` if a path entry exists.
        if (is_build_zig_zon_file and std.mem.eql(u8, reader.peek(6) catch "", ".flint")) {
            while (true) {
                const peek = reader.peek(1) catch break;
                if (std.mem.eql(u8, peek, "}")) {
                    reader.toss(2);
                    break;
                } else {
                    reader.toss(1);
                }
            }
            continue;
        }

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
    } else if (std.mem.eql(u8, string, "0x97601f8306db8023")) {
        try printNewFingerprint(new_name, writer);
    } else {
        try writer.print("{s}", .{string});
    }
}

fn printCapitalizedName(name: []const u8, writer: *std.Io.Writer) !void {
    var reader: std.Io.Reader = std.Io.Reader.fixed(name);
    var capitalize: bool = true;

    while (true) {
        var next_character = (reader.take(1) catch break)[0];

        if (capitalize) {
            capitalize = false;
            next_character = std.ascii.toUpper(next_character);
        }

        if (next_character == '-' or next_character == '_') {
            next_character = ' ';
            capitalize = true;
        }

        try writer.print("{c}", .{next_character});
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
