//! Exposes tools for loading Aseprite documents.
const std = @import("std");
const sdl = @import("sdl.zig").c;
const sdl_utils = @import("sdl.zig");

/// All data and metadata contained in an Aseprite document.
pub const AseDocument = struct {
    header: *const AseHeader,
    frames: []const AseFrame,

    pub fn deinit(self: *const AseDocument, allocator: std.mem.Allocator) void {
        for (self.frames) |frame| {
            frame.deinit(allocator);
        }

        allocator.free(self.frames);
        allocator.destroy(self.header);
    }
};

/// All data and matadata contained in an Aseprite frame.
const AseFrame = struct {
    header: *AseFrameHeader,
    cel_chunks: []*AseCelChunk,
    tags: []*AseTagsChunk,

    pub fn deinit(self: AseFrame, allocator: std.mem.Allocator) void {
        for (self.tags) |tag| {
            allocator.free(tag.tag_name);
            allocator.destroy(tag);
        }
        allocator.free(self.tags);

        for (self.cel_chunks) |cel_chunk| {
            allocator.free(cel_chunk.data.compressedImage.pixels);
            allocator.destroy(cel_chunk);
        }
        allocator.free(self.cel_chunks);

        allocator.destroy(self.header);
    }
};

/// Wrapper which loads an Aseprite document and generates textures that can be rendered with SDL.
pub const AsepriteAsset = struct {
    document: AseDocument,
    frames: []*sdl.SDL_Texture,
    path: []const u8,

    pub fn deinit(self: *AsepriteAsset, allocator: std.mem.Allocator) void {
        self.document.deinit(allocator);
        allocator.free(self.frames);
    }

    // Loads an Aseprite document from the specified path and generates SDL textures for each frame.
    pub fn load(
        path: []const u8,
        renderer: *sdl.SDL_Renderer,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) ?AsepriteAsset {
        var result: ?AsepriteAsset = null;

        std.log.info("loadSprite: {s}", .{path});

        const opt_doc = loadDocument(path, allocator, io) catch |err| blk: {
            std.log.err("Asperite loadDocument failed: {t}", .{err});
            break :blk null;
        };

        if (opt_doc) |doc| {
            var textures: std.ArrayList(*sdl.SDL_Texture) = .empty;

            for (doc.frames) |frame| {
                const surface = sdl_utils.panicIfNull(
                    sdl.SDL_CreateSurface(
                        doc.header.width,
                        doc.header.height,
                        sdl.SDL_PIXELFORMAT_RGBA32,
                    ),
                    "Failed to create a surface to blit sprite data into",
                );
                defer sdl.SDL_DestroySurface(surface);

                for (frame.cel_chunks) |cel_chunk| {
                    var dest_rect = sdl.SDL_Rect{
                        .x = cel_chunk.x,
                        .y = cel_chunk.y,
                        .w = cel_chunk.data.compressedImage.width,
                        .h = cel_chunk.data.compressedImage.height,
                    };
                    const cel_surface = sdl_utils.panicIfNull(
                        sdl.SDL_CreateSurfaceFrom(
                            cel_chunk.data.compressedImage.width,
                            cel_chunk.data.compressedImage.height,
                            sdl.SDL_PIXELFORMAT_RGBA32,
                            @ptrCast(@constCast(cel_chunk.data.compressedImage.pixels)),
                            cel_chunk.data.compressedImage.width * @sizeOf(u32),
                        ),
                        "Failed to create surface from data",
                    );
                    defer sdl.SDL_DestroySurface(cel_surface);

                    sdl_utils.panic(
                        sdl.SDL_BlitSurface(cel_surface, null, surface, &dest_rect),
                        "Failed to blit cel surface into sprite surface",
                    );
                }

                const texture = sdl_utils.panicIfNull(
                    sdl.SDL_CreateTextureFromSurface(renderer, surface),
                    "Failed to create texture from surface",
                );
                textures.append(allocator, texture.?) catch undefined;
            }

            std.log.info("loadSprite: {s}: {d}", .{ path, doc.frames.len });

            result = AsepriteAsset{
                .path = path,
                .document = doc,
                .frames = textures.toOwnedSlice(allocator) catch &.{},
            };
        } else {
            @panic("aseprite.loadDocument failed");
        }

        return result;
    }
};

/// Load an Aseprite document from the specified path.
pub fn loadDocument(path: []const u8, allocator: std.mem.Allocator, io: std.Io) !?AseDocument {
    var result: ?AseDocument = null;

    if (std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only })) |file| {
        defer file.close(io);

        var buf: [1024 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &buf);

        const opt_header: ?*AseHeader = try parseHeader(&file_reader.interface, allocator);
        var frames: std.ArrayList(AseFrame) = .empty;
        defer frames.deinit(allocator);

        std.log.info("loadDocument: {s}", .{path});

        if (opt_header) |header| {
            std.debug.assert(header.magic_number == 0xA5E0);
            std.log.info("Frame count: {d}", .{header.frames});

            for (0..header.frames) |_| {
                if (try parseFrameHeader(&file_reader.interface, allocator)) |frame_header| {
                    std.debug.assert(frame_header.magic_number == 0xF1FA);
                    std.log.info(
                        "Frame size: {d}, chunks: {d}",
                        .{ frame_header.byte_count, frame_header.chunkCount() },
                    );

                    var cel_chunks: std.ArrayList(*AseCelChunk) = .empty;
                    var opt_tags: ?[]*AseTagsChunk = null;

                    for (0..frame_header.chunkCount()) |_| {
                        if (try parseChunkHeader(&file_reader.interface, allocator)) |chunk_header| {
                            defer allocator.destroy(chunk_header);
                            std.log.info(
                                "Chunk size: {d}, chunk_type: {}",
                                .{ chunk_header.chunkSize(), chunk_header.chunk_type },
                            );

                            switch (chunk_header.chunk_type) {
                                .Cel => {
                                    if (try parseCelChunk(&file_reader.interface, chunk_header, allocator)) |cel_chunk| {
                                        try cel_chunks.append(allocator, cel_chunk);
                                    }
                                },
                                .Tags => {
                                    opt_tags = try parseTagsChunks(&file_reader.interface, allocator);
                                },
                                else => {
                                    file_reader.interface.toss(chunk_header.chunkSize());
                                },
                            }
                        }
                    }

                    if (cel_chunks.items.len > 0) {
                        try frames.append(allocator, AseFrame{
                            .header = frame_header,
                            .cel_chunks = try cel_chunks.toOwnedSlice(allocator),
                            .tags = opt_tags orelse &.{},
                        });
                    }
                }
            }

            if (frames.items.len > 0) {
                result = .{
                    .header = header,
                    .frames = try frames.toOwnedSlice(allocator),
                };
            } else {
                std.log.err("No frames found in aseprite file.", .{});
            }
        } else {
            std.log.err("Failed to parse aseprite header.", .{});
        }
    } else |err| {
        std.log.info("Cannot find file '{s}': {s}", .{ path, @errorName(err) });
    }

    return result;
}

// File format structs.
const AseHeader = struct {
    file_size: u32, // DWORD File size
    magic_number: u16, // WORD Magic number (0xA5E0)
    frames: u16, // WORD Frames
    width: u16, // WORD Width in pixels
    height: u16, // WORD Height in pixels
    color_depth: u16, // WORD Color depth (bits per pixel)
    // 32 bpp = RGBA
    // 16 bpp = Grayscale
    // 8 bpp = Indexed
    flags: u32, // DWORD Flags:
    // 1 = Layer opacity has valid value
    speed: u16, // WORD Speed (milliseconds between frame, like in FLC files)
    // DEPRECATED: You should use the frame duration field
    // from each frame header
    padding1: u32, // DWORD Set be 0
    padding2: u32, // DWORD Set be 0
    palette_index: u8, // BYTE Palette entry (index) which represent transparent color
    // in all non-background layers (only for Indexed sprites).
    //padding3: u24, // BYTE[3] Ignore these bytes
    color_count: u16, // WORD Number of colors (0 means 256 for old sprites)
    pixel_width: u8, // BYTE Pixel width (pixel ratio is "pixel width/pixel height").
    // If this or pixel height field is zero, pixel ratio is 1:1
    pixel_height: u8, // BYTE Pixel height
    grid_y: i16, // SHORT X position of the grid
    grid_x: i16, // SHORT Y position of the grid
    grid_width: u16, // WORD Grid width (zero if there is no grid, grid size
    //     is 16x16 on Aseprite by default)
    grid_height: u16, // WORD Grid height (zero if there is no grid)
    //reserved: u672, // BYTE[84] For future (set to zero)
};

const AseFrameHeader = struct {
    byte_count: u32, // DWORD Bytes in this frame
    magic_number: u16, // WORD Magic number (always 0xF1FA)
    old_chunk_count: u16, // WORD Old field which specifies the number of "chunks"
    // in this frame. If this value is 0xFFFF, we might
    // have more chunks to read in this frame
    // (so we have to use the new field)
    frame_duration: u16, // WORD Frame duration (in milliseconds)
    //reserved: u16, // BYTE[2] For future (set to zero)
    chunk_count: u32, // DWORD New field which specifies the number of "chunks"
    // in this frame (if this is 0, use the old field)

    pub fn chunkCount(self: *AseFrameHeader) u32 {
        var result: u32 = self.chunk_count;
        if (result == 0) {
            result = self.old_chunk_count;
        }
        return result;
    }
};

const AseChunkHeader = struct {
    size: u32 align(1), // DWORD Chunk size
    chunk_type: AseChunkTypes align(1), // WORD Chunk type

    pub fn chunkSize(self: *AseChunkHeader) u32 {
        return self.size - @sizeOf(AseChunkHeader);
    }
};

const AseChunkTypes = enum(u16) {
    OldPalette1 = 0x0004,
    OldPalette2 = 0x0011,
    Layer = 0x2004,
    Cel = 0x2005,
    CelExtra = 0x2006,
    ColorProfile = 0x2007,
    ExternalFile = 0x2008,
    Mask = 0x2016, // Deprecated.
    Path = 0x2017, // Never used.
    Tags = 0x2018,
    Palette = 0x2019,
    UserData = 0x2020,
    Slice = 0x2022,
    TileSet = 0x2023,
};

const AseCelType = enum(u16) {
    rawImageData, // (unused, compressed image is preferred)
    linkedCel,
    compressedImage,
    compressedTileMap,
};

const AseCelChunk = struct {
    layer_index: u16, // WORD Layer index (see NOTE.2)
    x: i16, // SHORT X position
    y: i16, // SHORT Y position
    opacity: u8, // BYTE Opacity level
    cel_type: AseCelType, // WORD Cel Type
    // 0 - Raw Image Data (unused, compressed image is preferred)
    // 1 - Linked Cel
    // 2 - Compressed Image
    // 3 - Compressed Tilemap
    z_index: i16, // SHORT Z-Index (see NOTE.5)
    // 0 = default layer ordering
    // +N = show this cel N layers later
    // -N = show this cel N layers back
    //reserved: [5]u8 // BYTE[5] For future (set to zero)
    data: union(AseCelType) {
        rawImageData: struct {
            width: u16, // WORD Width in pixels
            height: u16, // WORD Height in pixels
            pixels: []u8, // PIXEL[] Raw pixel data: row by row from top to bottom,
            // for each scanline read pixels from left to right.
        },
        linkedCel: struct {
            link: u16, // WORD Frame position to link with
        },
        compressedImage: struct {
            width: u16, // WORD Width in pixels
            height: u16, // WORD Height in pixels
            pixels: []const u8, // PIXEL[] "Raw Cel" data compressed with ZLIB method (see NOTE.3)
        },
        compressedTileMap: struct {
            width: u16, // WORD Width in number of tiles
            height: u16, // WORD Height in number of tiles
            bits_per_tile: u16, // WORD Bits per tile (at the moment it's always 32-bit per tile)
            tile_id: u32, // DWORD Bitmask for tile ID (e.g. 0x1fffffff for 32-bit tiles)
            x_flip: u32, // DWORD Bitmask for X flip
            y_flip: u32, // DWORD Bitmask for Y flip
            diagonal_flip: u32, // DWORD Bitmask for diagonal flip (swap X/Y axis)
            // BYTE[10]  Reserved
            tiles: []u8, // TILE[] Row by row, from top to bottom tile by tile
            // compressed with ZLIB method (see NOTE.3)
        },
    },

    pub fn headerSize(cel_type: AseCelType) u32 {
        var result: u32 =
            @sizeOf(u16) +
            @sizeOf(i16) +
            @sizeOf(i16) +
            @sizeOf(u8) +
            @sizeOf(u16) +
            @sizeOf(i16) +
            5;

        result += switch (cel_type) {
            .compressedImage => @sizeOf(u16) + @sizeOf(u16),
            else => 0,
        };

        return result;
    }
};

const AseTagsChunkHeader = struct {
    count: u16, // WORD Number of tags
    //reserved: [8]u8, // BYTE[8] For future (set to zero)
};

const AseTagsLoop = enum(u8) {
    Forward,
    Reverse,
    PingPong,
    PingPongReverse,
};

const AseString = struct {
    length: u16, // WORD: string length (number of bytes)
    characters: []u8, // BYTE[length]: characters (in UTF-8) The '\0' character is not included.
};

pub const AseTagsChunk = struct {
    from_frame: u16, // WORD From frame
    to_frame: u16, // WORD To frame
    loop_direction: AseTagsLoop, // BYTE Loop animation direction
    repeat_count: u16, // WORD Repeat N times. Play this animation section N times:
    // 0 = Doesn't specify (plays infinite in UI, once on export,
    // for ping-pong it plays once in each direction)
    // 1 = Plays once (for ping-pong, it plays just in one direction)
    // 2 = Plays twice (for ping-pong, it plays once in one direction,
    // and once in reverse)
    // n = Plays N times
    //reserved: [6]u8, // BYTE[6] For future (set to zero)
    //deprecated: [4]u8, // BYTE[3] RGB values of the tag color
    // Deprecated, used only for backward compatibility with Aseprite v1.2.x
    // The color of the tag is the one in the user data field following
    // the tags chunk
    //extra: u8, // BYTE Extra byte (zero)
    tag_name: []const u8, // STRING Tag name
};

fn parseHeader(reader: *std.Io.Reader, allocator: std.mem.Allocator) !?*AseHeader {
    const header: *AseHeader = try allocator.create(AseHeader);

    header.file_size = try reader.takeInt(u32, .little);
    header.magic_number = try reader.takeInt(u16, .little);
    header.frames = try reader.takeInt(u16, .little);
    header.width = try reader.takeInt(u16, .little);
    header.height = try reader.takeInt(u16, .little);
    header.color_depth = try reader.takeInt(u16, .little);
    header.flags = try reader.takeInt(u32, .little);
    header.speed = try reader.takeInt(u16, .little);
    header.padding1 = try reader.takeInt(u32, .little);
    header.padding2 = try reader.takeInt(u32, .little);
    header.palette_index = try reader.takeInt(u8, .little);
    reader.toss(3);
    header.color_count = try reader.takeInt(u16, .little);
    header.pixel_width = try reader.takeInt(u8, .little);
    header.pixel_height = try reader.takeInt(u8, .little);
    header.grid_y = try reader.takeInt(i16, .little);
    header.grid_x = try reader.takeInt(i16, .little);
    header.grid_width = try reader.takeInt(u16, .little);
    header.grid_height = try reader.takeInt(u16, .little);
    reader.toss(84);

    return header;
}

fn parseFrameHeader(reader: *std.Io.Reader, allocator: std.mem.Allocator) !?*AseFrameHeader {
    const header: *AseFrameHeader = try allocator.create(AseFrameHeader);

    header.byte_count = try reader.takeInt(u32, .little);
    header.magic_number = try reader.takeInt(u16, .little);
    header.old_chunk_count = try reader.takeInt(u16, .little);
    header.frame_duration = try reader.takeInt(u16, .little);
    reader.toss(2);
    header.chunk_count = try reader.takeInt(u32, .little);

    return header;
}

fn parseChunkHeader(reader: *std.Io.Reader, allocator: std.mem.Allocator) !?*AseChunkHeader {
    const header: *AseChunkHeader = try allocator.create(AseChunkHeader);

    header.size = try reader.takeInt(u32, .little);
    header.chunk_type = @enumFromInt(try reader.takeInt(u16, .little));

    return header;
}

fn parseCelChunk(reader: *std.Io.Reader, header: *AseChunkHeader, allocator: std.mem.Allocator) !?*AseCelChunk {
    const chunk: *AseCelChunk = try allocator.create(AseCelChunk);

    chunk.layer_index = try reader.takeInt(u16, .little);
    chunk.x = try reader.takeInt(i16, .little);
    chunk.y = try reader.takeInt(i16, .little);
    chunk.opacity = try reader.takeInt(u8, .little);
    chunk.cel_type = @enumFromInt(try reader.takeInt(u16, .little));
    chunk.z_index = try reader.takeInt(i16, .little);

    std.log.info("Cel x: {d}, y: {d}, type: {}", .{ chunk.x, chunk.y, chunk.cel_type });

    reader.toss(5);

    switch (chunk.cel_type) {
        .compressedImage => {
            chunk.data = .{ .compressedImage = .{
                .width = try reader.takeInt(u16, .little),
                .height = try reader.takeInt(u16, .little),
                .pixels = undefined,
            } };

            std.log.info(
                "Cel width: {d}, height: {d}",
                .{ chunk.data.compressedImage.width, chunk.data.compressedImage.height },
            );

            const data_size = header.chunkSize() - AseCelChunk.headerSize(chunk.cel_type);
            std.log.info(
                "Data size: {d}, chunk size: {d}, header size: {d}",
                .{ data_size, header.chunkSize(), AseCelChunk.headerSize(chunk.cel_type) },
            );

            var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(reader, .zlib, &decompress_buffer);
            const decompress_reader: *std.Io.Reader = &decompress.reader;
            chunk.data.compressedImage.pixels = try decompress_reader.allocRemaining(allocator, .unlimited);

            std.log.info("Decompressed: {d}", .{chunk.data.compressedImage.pixels.len});
        },
        else => {
            reader.toss(AseCelChunk.headerSize(chunk.cel_type));
        },
    }

    return chunk;
}

fn parseTagsChunks(reader: *std.Io.Reader, allocator: std.mem.Allocator) !?[]*AseTagsChunk {
    var tag_chunks: std.ArrayList(*AseTagsChunk) = .empty;

    const header: AseTagsChunkHeader = .{
        .count = try reader.takeInt(u16, .little),
    };

    reader.toss(8);

    for (0..header.count) |_| {
        const chunk: *AseTagsChunk = try allocator.create(AseTagsChunk);

        chunk.from_frame = try reader.takeInt(u16, .little);
        chunk.to_frame = try reader.takeInt(u16, .little);
        chunk.loop_direction = @enumFromInt(try reader.takeInt(u8, .little));
        chunk.repeat_count = try reader.takeInt(u16, .little);

        reader.toss(6 + 3 + 1);

        const tag_name_length = try reader.takeInt(u16, .little);
        var buffer: std.ArrayList(u8) = .empty;
        for (0..tag_name_length) |_| {
            try buffer.append(allocator, try reader.takeByte());
        }
        chunk.tag_name = try buffer.toOwnedSlice(allocator);

        try tag_chunks.append(allocator, chunk);
    }

    return try tag_chunks.toOwnedSlice(allocator);
}

test "single frame" {
    const aseprite_doc: ?AseDocument = try loadDocument("fixtures/test.aseprite", std.testing.allocator);

    try std.testing.expect(aseprite_doc != null);

    if (aseprite_doc) |doc| {
        defer doc.deinit(std.testing.allocator);

        try std.testing.expectEqual(0xA5E0, doc.header.magic_number);
        try std.testing.expectEqual(0xF1FA, doc.frames[0].header.magic_number);

        try std.testing.expectEqual(1, doc.header.frames);
        try std.testing.expectEqual(2, doc.frames[0].cel_chunks.len);

        const cel_chunk = doc.frames[0].cel_chunks[0];

        try std.testing.expectEqual(0, cel_chunk.x);
        try std.testing.expectEqual(0, cel_chunk.y);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.width);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.height);
    }
}

test "multiple frames" {
    const aseprite_doc: ?AseDocument = try loadDocument("fixtures/test_animation.aseprite", std.testing.allocator);

    try std.testing.expect(aseprite_doc != null);

    if (aseprite_doc) |doc| {
        defer doc.deinit(std.testing.allocator);

        try std.testing.expectEqual(0xA5E0, doc.header.magic_number);
        try std.testing.expectEqual(0xF1FA, doc.frames[0].header.magic_number);

        try std.testing.expectEqual(12, doc.header.frames);

        const cel_chunk = doc.frames[0].cel_chunks[0];

        try std.testing.expectEqual(0, cel_chunk.x);
        try std.testing.expectEqual(0, cel_chunk.y);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.width);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.height);

        try std.testing.expectEqual(1, doc.frames[0].tags.len);

        const tags_chunk = doc.frames[0].tags[0];
        try std.testing.expectEqual(0, tags_chunk.from_frame);
        try std.testing.expectEqual(11, tags_chunk.to_frame);
        try std.testing.expectEqual(AseTagsLoop.Forward, tags_chunk.loop_direction);
        try std.testing.expectEqual(0, tags_chunk.repeat_count);
        try std.testing.expectEqualSlices(u8, "idle", tags_chunk.tag_name);
    }
}
