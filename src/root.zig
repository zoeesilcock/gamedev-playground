const std = @import("std");
const r = @import("dependencies/raylib.zig");

pub const State = struct {
    allocator: std.mem.Allocator,

    window_width: u32,
    window_height: u32,

    world_scale: f32,
    world_width: u32,
    world_height: u32,

    render_texture: ?r.RenderTexture2D = null,
    source_rect: ?r.Rectangle = null,
    dest_rect: ?r.Rectangle = null,

    pub fn initializeRenderTexture(self: *State) void {
        self.world_width = @intFromFloat(@divFloor(@as(f32, @floatFromInt(self.window_width)), self.world_scale));
        self.world_height = @intFromFloat(@divFloor(@as(f32, @floatFromInt(self.window_height)), self.world_scale));
        self.render_texture = r.LoadRenderTexture(@intCast(self.world_width), @intCast(self.world_height));
        self.source_rect = r.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.render_texture.?.texture.width),
            .height = @floatFromInt(self.render_texture.?.texture.height),
        };
        self.dest_rect = r.Rectangle{ 
            .x = @as(f32, @floatFromInt(self.window_width)) - self.source_rect.?.width * self.world_scale,
            .y = 0,
            .width = self.source_rect.?.width * self.world_scale,
            .height = self.source_rect.?.height * self.world_scale,
        };
    }
};

export fn init(window_width: u32, window_height: u32) *anyopaque {
    var allocator = std.heap.c_allocator;
    var state: *State = allocator.create(State) catch @panic("Out of memory");

    state.allocator = allocator;
    state.window_width = window_width;
    state.window_height = window_height;
    state.world_scale = 4;

    return state;
}

export fn reload(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

export fn tick(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

export fn draw(state_ptr: *anyopaque) void {
    var state: *State = @ptrCast(@alignCast(state_ptr));

    if (state.render_texture == null) {
        state.initializeRenderTexture();
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

fn drawWorld(state: *State) void {
    const size = r.Vector2{ .x = 30, .y = 20 };
    const position = r.Vector2{
        .x = @as(f32, @floatFromInt(state.world_width)) / 2 - size.x / 2,
        .y = @as(f32, @floatFromInt(state.world_height)) / 2 - size.y / 2,
    };
    r.DrawRectangleV(position, size, r.RED);
}
