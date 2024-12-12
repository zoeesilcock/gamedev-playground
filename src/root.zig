const std = @import("std");
const r = @import("dependencies/raylib.zig");

pub const State = struct {
    allocator: std.mem.Allocator,

    window_width: u32,
    window_height: u32,

    world_scale: f32,
    world_width: u32,
    world_height: u32,

    render_texture: ?r.RenderTexture2D,
    source_rect: ?r.Rectangle,
    dest_rect: ?r.Rectangle,

    assets: Assets,
};

const Assets = struct {
    test_texture: ?r.Texture2D,
};

export fn init(window_width: u32, window_height: u32) *anyopaque {
    var allocator = std.heap.c_allocator;
    var state: *State = allocator.create(State) catch @panic("Out of memory");

    state.allocator = allocator;

    state.window_width = window_width;
    state.window_height = window_height;
    state.render_texture = null;
    state.source_rect = null;
    state.dest_rect = null;
    state.world_scale = 4;

    loadAssets(state);

    return state;
}

export fn reload(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    loadAssets(state);
}

export fn tick(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

export fn draw(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (state.render_texture == null) {
        initializeRenderTexture(state);
    }

    if (state.render_texture) |render_texture| {
        r.BeginTextureMode(render_texture);
        {
            r.ClearBackground(r.BLACK);
            drawWorld(state);
        }
        r.EndTextureMode();

        {
            r.ClearBackground(r.DARKGRAY);
            r.DrawTexturePro(render_texture.texture, state.source_rect.?, state.dest_rect.?, r.Vector2{}, 0, r.WHITE);
        }
    }
}

fn initializeRenderTexture(state: *State) void {
    state.world_width = @intFromFloat(@divFloor(@as(f32, @floatFromInt(state.window_width)), state.world_scale));
    state.world_height = @intFromFloat(@divFloor(@as(f32, @floatFromInt(state.window_height)), state.world_scale));
    state.render_texture = r.LoadRenderTexture(@intCast(state.world_width), @intCast(state.world_height));
    state.source_rect = r.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(state.render_texture.?.texture.width),
        .height = -@as(f32, @floatFromInt(state.render_texture.?.texture.height)),
    };
    state.dest_rect = r.Rectangle{ 
        .x = @as(f32, @floatFromInt(state.window_width)) - state.source_rect.?.width * state.world_scale,
        .y = 0,
        .width = state.source_rect.?.width * state.world_scale,
        .height = state.source_rect.?.height * state.world_scale,
    };
}

fn loadAssets(state: *State) void {
    // state.assets.test_texture = r.LoadTexture("assets/test.png");

    if (loadAsepriteFile("assets/test.aseprite", state.allocator) catch undefined) |cel| {
        const image: r.Image = .{
            .data = @ptrCast(@constCast(cel.data.compressedImage.pixels)),
            .width = cel.data.compressedImage.width,
            .height = cel.data.compressedImage.height,
            .mipmaps = 1,
            .format = r.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        };
        state.assets.test_texture = r.LoadTextureFromImage(image);
    }
}

fn drawWorld(state: *State) void {
    if (state.assets.test_texture) |sprite| {
        const size = r.Vector2{ .x = @floatFromInt(sprite.width), .y = @floatFromInt(sprite.height) };
        const position = r.Vector2{
            .x = @as(f32, @floatFromInt(state.world_width)) / 2 - size.x / 2,
            .y = @as(f32, @floatFromInt(state.world_height)) / 2 - size.y / 2,
        };

        r.DrawTextureV(sprite, position, r.WHITE);
    }
}

const AseHeader = packed struct {
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
    padding3: u24,          // BYTE[3]     Ignore these bytes
    color_count: u16,       // WORD        Number of colors (0 means 256 for old sprites)
    pixel_width: u8,        // BYTE        Pixel width (pixel ratio is "pixel width/pixel height").
                            // If this or pixel height field is zero, pixel ratio is 1:1
    pixel_height: u8,       // BYTE        Pixel height
    grid_y: i16,            // SHORT       X position of the grid
    grid_x: i16,            // SHORT       Y position of the grid
    grid_width: u16,        // WORD        Grid width (zero if there is no grid, grid size
                            //     is 16x16 on Aseprite by default)
    grid_height: u16,       // WORD        Grid height (zero if there is no grid)
    reserved: u672,         // BYTE[84]    For future (set to zero)
};

const AseFrameHeader = packed struct {
    byte_count: u32,        // DWORD       Bytes in this frame
    magic_number: u16,      // WORD        Magic number (always 0xF1FA)
    old_chunk_count: u16,   // WORD        Old field which specifies the number of "chunks"
                            //             in this frame. If this value is 0xFFFF, we might
                            //             have more chunks to read in this frame
                            //             (so we have to use the new field)
    frame_duration: u16,    // WORD        Frame duration (in milliseconds)
    reserved: u16,          // BYTE[2]     For future (set to zero)
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

const AseChunkHeader = extern struct {
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

fn loadAsepriteFile(path: []const u8, allocator: std.mem.Allocator) !?*AseCelChunk {
    var result: ?*AseCelChunk = null;

    std.debug.assert(@sizeOf(AseHeader) == 128);
    std.debug.assert(@sizeOf(AseFrameHeader) == 16);
    std.debug.assert(@sizeOf(AseChunkHeader) == 6);

    if (std.fs.cwd().openFile(path, .{ .mode = .read_only })) |file| {
        defer file.close();

        var main_buffer: [@sizeOf(AseHeader)]u8 align(@alignOf(AseHeader)) = undefined;
        _ = try file.read(&main_buffer);
        const header: *const AseHeader = @ptrCast(&main_buffer);

        std.debug.assert(header.magic_number == 0xA5E0);
        std.debug.print("Frame count: {d}\n", .{ header.frames });

        for (0..header.frames) |_| {
            var buffer: [@sizeOf(AseFrameHeader)]u8 align(@alignOf(AseFrameHeader)) = undefined;
            _ = try file.read(&buffer);
            const frame_header: *AseFrameHeader = @ptrCast(&buffer);

            std.debug.assert(frame_header.magic_number == 0xF1FA);
            std.debug.print("Frame size: {d}, chunks: {d}\n", .{ frame_header.byte_count, frame_header.chunkCount() });

            for (0..frame_header.chunkCount()) |_| {
                var chunk_header_buffer: [@sizeOf(AseChunkHeader)]u8 align(@alignOf(AseChunkHeader)) = undefined;
                _ = try file.read(&chunk_header_buffer);
                const chunk_header: *AseChunkHeader = @ptrCast(&chunk_header_buffer);

                std.debug.print("Chunk size: {d}, chunk_type: {}\n", .{ chunk_header.chunkSize(), chunk_header.chunk_type });

                switch (chunk_header.chunk_type) {
                    .Cel => {
                        result = try parseCelChunk(&file, chunk_header, allocator);
                    },
                    else => {
                        _ = try file.reader().skipBytes(chunk_header.chunkSize(), .{});
                    }
                }
            }
        }
    } else |err| {
        std.debug.print("Cannot find file '{s}': {s}", .{ path, @errorName(err) });
    }

    return result;
}

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
