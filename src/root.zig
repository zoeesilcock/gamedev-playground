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
    state.assets.test_texture = r.LoadTexture("assets/test.png");
    loadAsepriteFile("assets/test.aseprite", state.allocator) catch undefined;
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

const AseChunk = extern struct {
    size: u32,              // DWORD       Chunk size
    chunk_type: u16,        // WORD        Chunk type
    bytes: []u8,            // BYTE[]      Chunk data
};

const AseChunkTypes = enum(u32) {
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

fn loadAsepriteFile(path: []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;

    if (std.fs.cwd().openFile(path, .{ .mode = .read_only })) |file| {
        defer file.close();

        std.debug.print("HeaderSize: {d}, FrameHeaderSize: {d}\n", .{ @sizeOf(AseHeader), @sizeOf(AseFrameHeader) });

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
        }
    } else |err| {
        std.debug.print("Cannot find file '{s}': {s}", .{ path, @errorName(err) });
    }
}
