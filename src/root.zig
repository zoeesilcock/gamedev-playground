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
