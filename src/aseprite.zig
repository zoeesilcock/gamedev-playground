const std = @import("std");

// Public API.
const AseDocument = struct {
    allocator: std.mem.Allocator,
    header: *const AseHeader,
    frames: []const AseFrame,

    pub fn deinit(self: AseDocument) void {
        for (self.frames) |frame| {
            frame.deinit(self.allocator);
        }

        self.allocator.free(self.frames);
        self.allocator.destroy(self.header);
    }
};

const AseFrame = struct {
    header: *AseFrameHeader,
    cel_chunk: *AseCelChunk,

    pub fn deinit(self: AseFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.cel_chunk.data.compressedImage.pixels);
        allocator.destroy(self.header);
        allocator.destroy(self.cel_chunk);
    }
};

pub fn loadDocument(path: []const u8, allocator: std.mem.Allocator) !?AseDocument {
    var result: ?AseDocument = null;

    if (std.fs.cwd().openFile(path, .{ .mode = .read_only })) |file| {
        defer file.close();

        const opt_header: ?*AseHeader = try parseHeader(&file, allocator);
        var frames: std.ArrayList(AseFrame) = std.ArrayList(AseFrame).init(allocator);
        defer frames.deinit();

        if (opt_header) |header| {
            std.debug.assert(header.magic_number == 0xA5E0);
            std.debug.print("Frame count: {d}\n", .{ header.frames });

            for (0..header.frames) |_| {
                if (try parseFrameHeader(&file, allocator)) |frame_header| {
                    std.debug.assert(frame_header.magic_number == 0xF1FA);
                    std.debug.print("Frame size: {d}, chunks: {d}\n", .{ frame_header.byte_count, frame_header.chunkCount() });

                    var opt_cel_chunk: ?*AseCelChunk = null;

                    for (0..frame_header.chunkCount()) |_| {
                        if (try parseChunkHeader(&file, allocator)) |chunk_header| {
                            defer allocator.destroy(chunk_header);
                            std.debug.print("Chunk size: {d}, chunk_type: {}\n", .{ chunk_header.chunkSize(), chunk_header.chunk_type });

                            switch (chunk_header.chunk_type) {
                                .Cel => {
                                    opt_cel_chunk = try parseCelChunk(&file, chunk_header, allocator);
                                },
                                else => {
                                    _ = try file.reader().skipBytes(chunk_header.chunkSize(), .{});
                                }
                            }
                        }
                    }

                    if (opt_cel_chunk) |cel_chunk| {
                        try frames.append(AseFrame{
                            .header = frame_header,
                            .cel_chunk = cel_chunk,
                        });
                    }
                }
            }

            if (frames.items.len > 0) {
                result = .{
                    .allocator = allocator,
                    .header = header,
                    .frames = try frames.toOwnedSlice(),
                };
            }
        }
    } else |err| {
        std.debug.print("Cannot find file '{s}': {s}", .{ path, @errorName(err) });
    }

    return result;
}

// File format structs.
const AseHeader = struct {
    file_size: u32,         // DWORD       File size
    magic_number: u16,      // WORD        Magic number (0xA5E0)
    frames: u16,            // WORD        Frames
    width: u16,             // WORD        Width in pixels
    height: u16,            // WORD        Height in pixels
    color_depth: u16,       // WORD        Color depth (bits per pixel)
                            // 32 bpp = RGBA
                            // 16 bpp = Grayscale
                            // 8 bpp = Indexed
    flags: u32,             // DWORD       Flags:
                            // 1 = Layer opacity has valid value
    speed: u16,             // WORD        Speed (milliseconds between frame, like in FLC files)
                            // DEPRECATED: You should use the frame duration field
                            // from each frame header
    padding1: u32,          // DWORD       Set be 0
    padding2: u32,          // DWORD       Set be 0
    palette_index: u8,      // BYTE        Palette entry (index) which represent transparent color
                            // in all non-background layers (only for Indexed sprites).
    //padding3: u24,        // BYTE[3]     Ignore these bytes
    color_count: u16,       // WORD        Number of colors (0 means 256 for old sprites)
    pixel_width: u8,        // BYTE        Pixel width (pixel ratio is "pixel width/pixel height").
                            // If this or pixel height field is zero, pixel ratio is 1:1
    pixel_height: u8,       // BYTE        Pixel height
    grid_y: i16,            // SHORT       X position of the grid
    grid_x: i16,            // SHORT       Y position of the grid
    grid_width: u16,        // WORD        Grid width (zero if there is no grid, grid size
                            //     is 16x16 on Aseprite by default)
    grid_height: u16,       // WORD        Grid height (zero if there is no grid)
    //reserved: u672,       // BYTE[84]    For future (set to zero)
};

const AseFrameHeader = struct {
    byte_count: u32,        // DWORD       Bytes in this frame
    magic_number: u16,      // WORD        Magic number (always 0xF1FA)
    old_chunk_count: u16,   // WORD        Old field which specifies the number of "chunks"
                            //             in this frame. If this value is 0xFFFF, we might
                            //             have more chunks to read in this frame
                            //             (so we have to use the new field)
    frame_duration: u16,    // WORD        Frame duration (in milliseconds)
    //reserved: u16,        // BYTE[2]     For future (set to zero)
    chunk_count: u32,       // DWORD       New field which specifies the number of "chunks"
                            //             in this frame (if this is 0, use the old field)

    pub fn chunkCount(self: *AseFrameHeader) u32 {
        var result: u32 = self.chunk_count;
        if (result == 0) {
            result = self.old_chunk_count;
        }
        return result;
    }
};

const AseChunkHeader = struct {
    size: u32 align(1),                  // DWORD       Chunk size
    chunk_type: AseChunkTypes align(1),  // WORD        Chunk type

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
    TileSet = 0x2023
};

const AseCelType = enum(u16) {
    rawImageData,               // (unused, compressed image is preferred)
    linkedCel,
    compressedImage,
    compressedTileMap,
};

const AseCelChunk = struct {
    layer_index: u16,           // WORD        Layer index (see NOTE.2)
    x: i16,                     // SHORT       X position
    y: i16,                     // SHORT       Y position
    opacity: u8,                // BYTE        Opacity level
    cel_type: AseCelType,       // WORD        Cel Type
                                //             0 - Raw Image Data (unused, compressed image is preferred)
                                //             1 - Linked Cel
                                //             2 - Compressed Image
                                //             3 - Compressed Tilemap
    z_index: i16,               // SHORT       Z-Index (see NOTE.5)
                                //             0 = default layer ordering
                                //             +N = show this cel N layers later
                                //             -N = show this cel N layers back
    //reserved: [5]u8           // BYTE[5]     For future (set to zero)
    data: union(AseCelType) {
        rawImageData: struct {
            width: u16,         //   WORD      Width in pixels
            height: u16,        //   WORD      Height in pixels
            pixels: []u8,       //   PIXEL[]   Raw pixel data: row by row from top to bottom,
                                //             for each scanline read pixels from left to right.
        },
        linkedCel: struct {
            link: u16           //   WORD      Frame position to link with
        },
        compressedImage: struct {
            width: u16,         //   WORD      Width in pixels
            height: u16,        //   WORD      Height in pixels
            pixels: []const u8  //   PIXEL[]   "Raw Cel" data compressed with ZLIB method (see NOTE.3)
        },
        compressedTileMap: struct {
            width: u16,         //   WORD      Width in number of tiles
            height: u16,        //   WORD      Height in number of tiles
            bits_per_tile: u16, //   WORD      Bits per tile (at the moment it's always 32-bit per tile)
            tile_id: u32,       //   DWORD     Bitmask for tile ID (e.g. 0x1fffffff for 32-bit tiles)
            x_flip: u32,        //   DWORD     Bitmask for X flip
            y_flip: u32,        //   DWORD     Bitmask for Y flip
            diagonal_flip: u32, //   DWORD     Bitmask for diagonal flip (swap X/Y axis)
                                //   BYTE[10]  Reserved
            tiles: []u8,        //   TILE[]    Row by row, from top to bottom tile by tile
                                //             compressed with ZLIB method (see NOTE.3)
        }
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

        result += switch(cel_type) {
            .compressedImage => @sizeOf(u16) + @sizeOf(u16),
            else => 0,
        };

        return result;
    }
};

fn parseHeader(file: *const std.fs.File, allocator: std.mem.Allocator) !?*AseHeader {
    const header: *AseHeader = try allocator.create(AseHeader);

    header.file_size = try file.reader().readInt(u32, .little);
    header.magic_number = try file.reader().readInt(u16, .little);
    header.frames = try file.reader().readInt(u16, .little);
    header.width = try file.reader().readInt(u16, .little);
    header.height = try file.reader().readInt(u16, .little);
    header.color_depth = try file.reader().readInt(u16, .little);
    header.flags = try file.reader().readInt(u32, .little);
    header.speed = try file.reader().readInt(u16, .little);
    header.padding1 = try file.reader().readInt(u32, .little);
    header.padding2 = try file.reader().readInt(u32, .little);
    header.palette_index = try file.reader().readInt(u8, .little);
    try file.reader().skipBytes(3, .{});
    header.color_count = try file.reader().readInt(u16, .little);
    header.pixel_width = try file.reader().readInt(u8, .little);
    header.pixel_height = try file.reader().readInt(u8, .little);
    header.grid_y = try file.reader().readInt(i16, .little);
    header.grid_x = try file.reader().readInt(i16, .little);
    header.grid_width = try file.reader().readInt(u16, .little);
    header.grid_height = try file.reader().readInt(u16, .little);
    try file.reader().skipBytes(84, .{});

    return header;
}

fn parseFrameHeader(file: *const std.fs.File, allocator: std.mem.Allocator) !?*AseFrameHeader {
    const header: *AseFrameHeader = try allocator.create(AseFrameHeader);

    header.byte_count = try file.reader().readInt(u32, .little);
    header.magic_number = try file.reader().readInt(u16, .little);
    header.old_chunk_count = try file.reader().readInt(u16, .little);
    header.frame_duration = try file.reader().readInt(u16, .little);
    try file.reader().skipBytes(2, .{});
    header.chunk_count = try file.reader().readInt(u32, .little);

    return header;
}

fn parseChunkHeader(file: *const std.fs.File, allocator: std.mem.Allocator) !?*AseChunkHeader {
    const header: *AseChunkHeader = try allocator.create(AseChunkHeader);

    header.size = try file.reader().readInt(u32, .little);
    header.chunk_type = @enumFromInt(try file.reader().readInt(u16, .little));

    return header;
}

fn parseCelChunk(file: *const std.fs.File, header: *AseChunkHeader, allocator: std.mem.Allocator) !?*AseCelChunk {
    const chunk: *AseCelChunk = try allocator.create(AseCelChunk);

    chunk.layer_index = try file.reader().readInt(u16, .little);
    chunk.x = try file.reader().readInt(i16, .little);
    chunk.y = try file.reader().readInt(i16, .little);
    chunk.opacity = try file.reader().readInt(u8, .little);
    chunk.cel_type = @enumFromInt(try file.reader().readInt(u16, .little));
    chunk.z_index = try file.reader().readInt(i16, .little);

    std.debug.print("Cel x: {d}, y: {d}, type: {}\n", .{ chunk.x, chunk.y, chunk.cel_type });

    _ = try file.reader().skipBytes(5, .{});

    switch (chunk.cel_type) {
        .compressedImage => {
            chunk.data = .{
                .compressedImage = .{
                    .width = try file.reader().readInt(u16, .little),
                    .height = try file.reader().readInt(u16, .little),
                    .pixels = undefined,
                }
            };

            std.debug.print("Cel width: {d}, height: {d}\n", .{ chunk.data.compressedImage.width, chunk.data.compressedImage.height });

            const data_size = header.chunkSize() - AseCelChunk.headerSize(chunk.cel_type);
            std.debug.print("Data size: {d}, chunk size: {d}, header size: {d}\n", .{ data_size, header.chunkSize(), AseCelChunk.headerSize(chunk.cel_type) });

            const compressed_data: []u8 = try allocator.alloc(u8, data_size);
            defer allocator.free(compressed_data);
            const bytes_read = try file.reader().read(compressed_data);

            std.debug.print("Read: {d}, expected: {d}\n", .{ bytes_read, data_size });
            std.debug.assert(bytes_read == data_size);

            var compressed_stream = std.io.fixedBufferStream(compressed_data);
            var decompress_stream = std.compress.zlib.decompressor(compressed_stream.reader());
            chunk.data.compressedImage.pixels = try decompress_stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));

            std.debug.print("Decompressed: {d}\n", .{ chunk.data.compressedImage.pixels.len });
        },
        else => {
            _ = try file.reader().skipBytes(AseCelChunk.headerSize(chunk.cel_type), .{});
        },
    }

    return chunk;
}

test "single frame" {
    const aseprite_doc: ?AseDocument = try loadDocument("assets/test.aseprite", std.testing.allocator);

    try std.testing.expect(aseprite_doc != null);

    if (aseprite_doc) |doc| {
        defer doc.deinit();

        try std.testing.expectEqual(0xA5E0, doc.header.magic_number);
        try std.testing.expectEqual(0xF1FA, doc.frames[0].header.magic_number);

        try std.testing.expectEqual(1, doc.header.frames);

        const cel_chunk = doc.frames[0].cel_chunk;

        try std.testing.expectEqual(0, cel_chunk.x);
        try std.testing.expectEqual(0, cel_chunk.y);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.width);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.height);
    }
}

test "multple frames" {
    const aseprite_doc: ?AseDocument = try loadDocument("assets/test_animation.aseprite", std.testing.allocator);

    try std.testing.expect(aseprite_doc != null);

    if (aseprite_doc) |doc| {
        defer doc.deinit();

        try std.testing.expectEqual(0xA5E0, doc.header.magic_number);
        try std.testing.expectEqual(0xF1FA, doc.frames[0].header.magic_number);

        try std.testing.expectEqual(12, doc.header.frames);

        const cel_chunk = doc.frames[0].cel_chunk;

        try std.testing.expectEqual(0, cel_chunk.x);
        try std.testing.expectEqual(0, cel_chunk.y);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.width);
        try std.testing.expectEqual(32, cel_chunk.data.compressedImage.height);
    }
}
