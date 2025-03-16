const std = @import("std");
const game = @import("game.zig");
const ecs = @import("ecs.zig");
const math = @import("math.zig");
const imgui = @import("imgui.zig");

const c = game.c;
const State = game.State;
const SpriteAsset = game.SpriteAsset;

const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;
const Z = math.Z;

const Color = math.Color;
const R = math.R;
const G = math.G;
const B = math.B;
const A = math.A;

const PLATFORM = @import("builtin").os.tag;
const DOUBLE_CLICK_THRESHOLD: u64 = 300;
const MAX_FRAME_TIME_COUNT: u32 = 300;
const LEVEL_NAME_BUFFER_SIZE = game.LEVEL_NAME_BUFFER_SIZE;

pub const DebugState = struct {
    input: DebugInput,
    mode: enum {
        Select,
        Edit,
    },
    current_block_color: ecs.ColorComponentValue,
    current_block_type: ecs.BlockType,
    show_editor: bool,
    current_level_name: [:0]u8,

    show_colliders: bool,
    collisions: std.ArrayList(DebugCollision),

    last_left_click_time: u64,
    last_left_click_entity: ?*ecs.Entity,
    hovered_entity: ?*ecs.Entity,
    selected_entity: ?*ecs.Entity,

    current_frame_index: u32,
    frame_times: [MAX_FRAME_TIME_COUNT]u64 = [1]u64{0} ** MAX_FRAME_TIME_COUNT,
    fps_average: f32,
    fps_display_mode: FPSDisplayMode,

    pub fn init(self: *DebugState, allocator: std.mem.Allocator) !void {
        self.input = DebugInput{};

        self.mode = .Select;
        self.current_block_color = .Red;
        self.current_block_type = .Wall;
        self.show_editor = false;
        self.current_level_name = @ptrCast(try allocator.alloc(u8, LEVEL_NAME_BUFFER_SIZE));
        _ = try std.fmt.bufPrintZ(self.current_level_name, "level1", .{});

        self.show_colliders = false;
        self.collisions = std.ArrayList(DebugCollision).init(allocator);

        self.selected_entity = null;
        self.hovered_entity = null;
        self.last_left_click_time = 0;
        self.last_left_click_entity = null;

        self.fps_average = 0;
        self.fps_display_mode = .Number;
    }

    pub fn addCollision(self: *DebugState, collision: *const ecs.Collision, time: u64) void {
        self.collisions.append(.{
            .collision = collision.*,
            .time_added = time,
        }) catch unreachable;
    }

    pub fn getPreviousFrameIndex(frame_index: u32) u32 {
        var previous_frame_index: u32 = frame_index -% 1;
        if (previous_frame_index > MAX_FRAME_TIME_COUNT) {
            previous_frame_index = MAX_FRAME_TIME_COUNT - 1;
        }
        return previous_frame_index;
    }

    pub fn getFrameTime(self: *DebugState, frame_index: u32) f32 {
        var elapsed: u64 = 0;
        const previous_frame_index = getPreviousFrameIndex(frame_index);

        const current_frame = self.frame_times[frame_index];
        const previous_frame = self.frame_times[previous_frame_index];
        if (current_frame > 0 and previous_frame > 0 and current_frame > previous_frame) {
            elapsed = current_frame - previous_frame;
        }

        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(c.SDL_GetPerformanceFrequency()));
    }

    pub fn currentLevelName(self: *DebugState) []const u8 {
        return std.mem.span(self.current_level_name.ptr);
    }
};

const DebugInput = struct {
    left_mouse_down: bool = false,
    left_mouse_pressed: bool = false,
    alt_key_down: bool = false,
    mouse_position: Vector2 = @splat(0),

    pub fn reset(self: *DebugInput) void {
        self.left_mouse_pressed = false;
    }
};

const DebugCollision = struct {
    collision: ecs.Collision,
    time_added: u64,
};

const FPSDisplayMode = enum {
    None,
    Number,
    NumberAndGraph
};

pub fn processInputEvent(state: *State, event: c.SDL_Event) void {
    var input = &state.debug_state.input;

    // Keyboard.
    if (event.key.key == c.SDLK_LALT) {
        input.alt_key_down = event.type == c.SDL_EVENT_KEY_DOWN;
    }
    if (event.type == c.SDL_EVENT_KEY_DOWN) {
        switch (event.key.key) {
            c.SDLK_P => {
                state.is_paused = !state.is_paused;
            },
            c.SDLK_F1 => {
                var mode: u32 = @intFromEnum(state.debug_state.fps_display_mode) + 1;
                if (mode >= @typeInfo(FPSDisplayMode).@"enum".fields.len) {
                    mode = 0;
                }
                state.debug_state.fps_display_mode = @enumFromInt(mode);
            },
            c.SDLK_C => {
                state.debug_state.show_colliders = !state.debug_state.show_colliders;
            },
            c.SDLK_E => {
                state.debug_state.show_editor = !state.debug_state.show_editor;
                state.debug_state.mode = if (state.debug_state.show_editor) .Edit else .Select;
            },
            c.SDLK_S => {
                saveLevel(state, state.debug_state.currentLevelName()) catch unreachable;
            },
            c.SDLK_L => {
                game.loadLevel(state, state.debug_state.currentLevelName()) catch unreachable;
            },
            else => {},
        }
    }

    // Mouse.
    if (event.type == c.SDL_EVENT_MOUSE_MOTION) {
        input.mouse_position = Vector2{ event.motion.x - state.dest_rect.x, event.motion.y };
    } else if (event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN or event.type == c.SDL_EVENT_MOUSE_BUTTON_UP) {
        const is_down = event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN;

        switch (event.button.button) {
            1 => {
                input.left_mouse_pressed = (input.left_mouse_down and !is_down);
                input.left_mouse_down = is_down;
            },
            else => {},
        }
    }
}

pub fn handleInput(state: *State) void {
    state.debug_state.hovered_entity = getHoveredEntity(state);

    const input: *DebugInput = &state.debug_state.input;
    var block_color = state.debug_state.current_block_color;
    const block_type = state.debug_state.current_block_type;

    if (block_type == .Deadly) {
        block_color = .Gray;
    }

    if (state.debug_state.mode == .Edit and block_type == .ColorChange and block_color == .Gray) {
        return;
    }

    if (state.debug_state.hovered_entity) |hovered_entity| {
        if (input.left_mouse_pressed) {
            // Grab the color and type of the hovered entity when alt is held down.
            if (state.debug_state.input.alt_key_down)  {
                if (hovered_entity.block) |block| {
                    state.debug_state.current_block_type = block.type;
                }
                if (hovered_entity.color) |color| {
                    state.debug_state.current_block_color = color.color;
                }
            } else {
                if (state.debug_state.mode == .Edit) {
                    if (block_color == hovered_entity.color.?.color) {
                        game.removeEntity(state, hovered_entity);
                    } else {
                        game.removeEntity(state, hovered_entity);
                        const tiled_position = getTiledPosition(
                            input.mouse_position / @as(Vector2, @splat(state.world_scale)),
                            state.assets.getWall(block_color, block_type),
                        );
                        _ = game.addWall(state, block_color, block_type, tiled_position) catch undefined;
                    }
                } else {
                    if (state.time - state.debug_state.last_left_click_time < DOUBLE_CLICK_THRESHOLD and
                        state.debug_state.last_left_click_entity.? == hovered_entity)
                    {
                        openSprite(state, hovered_entity);
                    } else {
                        state.debug_state.selected_entity = hovered_entity;
                    }
                }
            }

            state.debug_state.last_left_click_time = state.time;
            state.debug_state.last_left_click_entity = hovered_entity;
        }
    } else {
        if (input.left_mouse_pressed) {
            if (state.debug_state.mode == .Edit) {
                const tiled_position = getTiledPosition(
                    input.mouse_position / @as(Vector2, @splat(state.world_scale)),
                    state.assets.getWall(block_color, block_type),
                );
                _ = game.addWall(state, block_color, block_type, tiled_position) catch undefined;
            } else {
                state.debug_state.selected_entity = null;
            }
        }
    }
}

fn getHoveredEntity(state: *State) ?*ecs.Entity {
    var result: ?*ecs.Entity = null;

    for (state.colliders.items) |colldier| {
        if (colldier.containsPoint(state.debug_state.input.mouse_position / @as(Vector2, @splat(state.world_scale)))) {
            result = colldier.entity;
            break;
        }
    }

    return result;
}

pub fn calculateFPS(state: *State) void {
    state.debug_state.current_frame_index += 1;
    if (state.debug_state.current_frame_index >= MAX_FRAME_TIME_COUNT) {
        state.debug_state.current_frame_index = 0;
    }
    state.debug_state.frame_times[state.debug_state.current_frame_index] = c.SDL_GetPerformanceCounter();

    var average: f32 = 0;
    for (0..MAX_FRAME_TIME_COUNT) |i| {
        average += state.debug_state.getFrameTime(@intCast(i));
    }
    state.debug_state.fps_average = 1 / (average / @as(f32, @floatFromInt(MAX_FRAME_TIME_COUNT)));
}

pub fn drawDebugUI(state: *State) void {
    imgui.newFrame();

    c.ImGui_SetNextWindowPosEx(c.ImVec2{ .x = 5, .y = 5 }, 0, c.ImVec2{ .x = 0, .y = 0 });
    c.ImGui_SetNextWindowSize(c.ImVec2{ .x = 300, .y = 160 }, 0);

    if (state.debug_state.fps_display_mode != .None) {
        _ = c.ImGui_Begin(
            "FPS",
            null,
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoBackground |
            c.ImGuiWindowFlags_NoTitleBar |
            c.ImGuiWindowFlags_NoMouseInputs,
        );

        c.ImGui_TextColored(c.ImVec4{ .x = 0, .y = 1, .z = 0, .w = 1 }, "FPS: %.0f", state.debug_state.fps_average);

        if (state.debug_state.fps_display_mode == .NumberAndGraph) {
            var timings: [MAX_FRAME_TIME_COUNT]f32 = [1]f32{0} ** MAX_FRAME_TIME_COUNT;
            var max_value: f32 = 0;
            for (0..MAX_FRAME_TIME_COUNT) |i| {
                timings[i] = state.debug_state.getFrameTime(@intCast(i));
                if (timings[i] > max_value) {
                    max_value = timings[i];
                }
            }
            c.ImGui_PlotHistogramEx(
                "##FPS_Graph",
                &timings,
                timings.len,
                0,
                "",
                0,
                max_value,
                c.ImVec2{ .x = 300, .y = 100 },
                @sizeOf(f32),
            );
        }
        c.ImGui_End();
    }

    if (state.debug_state.show_editor) {
        const button_size: c.ImVec2 = c.ImVec2{ .x = 140, .y = 20 };
        const half_button_size: c.ImVec2 = c.ImVec2{ .x = 65, .y = 20 };

        c.ImGui_SetNextWindowSize(c.ImVec2{ .x = 160, .y = 175 }, 0);

        _ = c.ImGui_Begin(
            "Editor",
            null,
            c.ImGuiWindowFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoNavFocus | c.ImGuiWindowFlags_NoNavInputs,
        );

        _ = c.ImGui_InputTextEx(
            "Name",
            @ptrCast(state.debug_state.current_level_name),
            state.debug_state.current_level_name.len,
            0,
            null,
            null,
        );

        if (c.ImGui_ButtonEx("Load", half_button_size)) {
            game.loadLevel(state, state.debug_state.currentLevelName()) catch unreachable;
        }
        c.ImGui_SameLineEx(0, 10);
        if (c.ImGui_ButtonEx("Save", half_button_size)) {
            saveLevel(state, state.debug_state.currentLevelName()) catch unreachable;
        }

        if (c.ImGui_ButtonEx("Restart", button_size)) {
            c.ImGui_End();

            game.restart(state);
            return;
        }

        inputEnum("Mode", &state.debug_state.mode);
        inputEnum("Type", &state.debug_state.current_block_type);
        inputEnum("Color", &state.debug_state.current_block_color);

        c.ImGui_End();
    }

    if (state.debug_state.selected_entity) |selected_entity| {
        c.ImGui_SetNextWindowPosEx(c.ImVec2{ .x = 30, .y = 30 }, c.ImGuiCond_FirstUseEver, c.ImVec2{ .x = 0, .y = 0 });
        c.ImGui_SetNextWindowSize(c.ImVec2{ .x = 300, .y = 460 }, c.ImGuiCond_FirstUseEver);

        _ = c.ImGui_Begin("Inspector", null, c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer c.ImGui_End();

        inspectEntity(selected_entity);
    }

    imgui.render(state.renderer);
}

fn runtimeFieldPointer(ptr: anytype, comptime field_name: []const u8) *@TypeOf(@field(ptr.*, field_name)) {
    const field_offset = @offsetOf(@TypeOf(ptr.*), field_name);
    const base_ptr: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(&base_ptr[field_offset]));
}

fn inspectEntity(entity: *ecs.Entity) void {
    const entity_info = @typeInfo(@TypeOf(entity.*));
    inline for (entity_info.@"struct".fields) |entity_field| {
        if (entity_field.type == ecs.EntityType) {
            const entity_type = runtimeFieldPointer(entity, entity_field.name);
            inline for (@typeInfo(ecs.EntityType).@"enum".fields, 0..) |field, i| {
                if (@intFromEnum(entity_type.*) == i) {
                    c.ImGui_Text("Type: " ++ field.name);
                }
            }
        } else if (runtimeFieldPointer(entity, entity_field.name).*) |component| {
            if (c.ImGui_CollapsingHeaderBoolPtr(entity_field.name, null, c.ImGuiTreeNodeFlags_DefaultOpen)) {
                const component_info = @typeInfo(@TypeOf(component.*));
                inline for (component_info.@"struct".fields) |component_field| {
                    const field_ptr = runtimeFieldPointer(component, component_field.name);
                    switch (@TypeOf(field_ptr.*)) {
                        bool => {
                            inputBool(component_field.name, field_ptr);
                        },
                        f32 => {
                            inputF32(component_field.name, field_ptr);
                        },
                        u32 => {
                            inputU32(component_field.name, field_ptr);
                        },
                        Vector2 => {
                            inputVector2(component_field.name, field_ptr);
                        },
                        else => |field_type| {
                            if (@typeInfo(field_type) == .@"enum") {
                                inputEnum(component_field.name, field_ptr);
                            }
                        },
                    }
                }
            }
        }
    }
}

fn inputBool(heading: ?[*:0]const u8, value: *bool) void {
    c.ImGui_PushIDPtr(value);
    defer c.ImGui_PopID();

    _ = c.ImGui_Checkbox(heading, value);
}

fn inputF32(heading: ?[*:0]const u8, value: *f32) void {
    c.ImGui_PushIDPtr(value);
    defer c.ImGui_PopID();

    _ = c.ImGui_InputFloatEx(heading, value, 0.1, 1, "%.2f", 0);
}

fn inputU32(heading: ?[*:0]const u8, value: *u32) void {
    c.ImGui_PushIDPtr(value);
    defer c.ImGui_PopID();

    _ = c.ImGui_InputScalarEx(heading, c.ImGuiDataType_U32, @ptrCast(value), null, null, null, 0);
}

fn inputVector2(heading: ?[*:0]const u8, value: *Vector2) void {
    c.ImGui_PushIDPtr(value);
    defer c.ImGui_PopID();

    _ = c.ImGui_InputFloat2Ex(heading, @ptrCast(value), "%.2f", 0);
}

fn inputEnum(heading: ?[*:0]const u8, value: anytype) void {
    const field_info = @typeInfo(@TypeOf(value.*));
    const count: u32 = field_info.@"enum".fields.len;
    var items: [count][*:0]const u8 = [1][*:0]const u8{undefined} ** count;
    inline for (field_info.@"enum".fields, 0..) |enum_field, i| {
        items[i] = enum_field.name;
    }

    c.ImGui_PushIDPtr(value);
    defer c.ImGui_PopID();

    var current_item: i32 = @intFromEnum(value.*);
    if (c.ImGui_ComboCharEx(heading, &current_item, &items, count, 0)) {
        value.* = @enumFromInt(current_item);
    }
}

pub fn drawDebugOverlay(state: *State) void {
    // Highlight colliders.
    const scale = state.world_scale;
    const offset = Vector2{
        state.dest_rect.x / state.world_scale,
        state.dest_rect.y / state.world_scale,
    };

    if (state.debug_state.show_colliders) {
        for (state.colliders.items) |collider| {
            drawDebugCollider(state.renderer, collider, Color{ 0, 255, 0, 255 }, scale, offset);
        }

        // Highlight collisions.
        var index = state.debug_state.collisions.items.len;
        while (index > 0) {
            index -= 1;

            const show_time: u64 = 500;
            const collision = state.debug_state.collisions.items[index];
            if (state.time > collision.time_added + show_time) {
                _ = state.debug_state.collisions.swapRemove(index);
            } else {
                const time_remaining: f32 =
                    @as(f32, @floatFromInt(((collision.time_added + show_time) - state.time))) /
                    @as(f32, @floatFromInt(show_time));
                const color: Color = .{ 255, 128, 0, @intFromFloat(255 * time_remaining) };
                drawDebugCollider(state.renderer, collision.collision.other, color, scale, offset);
            }
        }
    }

    // Highlight the currently hovered entity.
    drawEntityHighlight(state.renderer, state.debug_state.selected_entity, Color{ 255, 0, 0, 255 }, scale, offset);
    drawEntityHighlight(state.renderer, state.debug_state.hovered_entity, Color{ 255, 150, 0, 255 }, scale, offset);

    // Draw the current mouse position.
    if (false) {
        const mouse_size: f32 = 8;
        const mouse_rect: math.Rect = .{
            .position = Vector2{
                (state.debug_state.input.mouse_position[X] - (mouse_size / 2)) / scale,
                (state.debug_state.input.mouse_position[Y] - (mouse_size / 2)) / scale,
            } + offset,
            .size = Vector2{
                mouse_size / scale,
                mouse_size / scale,
            },
        };
        _ = c.SDL_SetRenderDrawColor(state.renderer, 255, 255, 0, 255);
        _ = c.SDL_RenderFillRect(state.renderer, &mouse_rect.scaled(scale).toSDL());
    }
}

fn drawDebugCollider(
    renderer: *c.SDL_Renderer,
    collider: *ecs.ColliderComponent,
    color: Color,
    scale: f32,
    offset: Vector2,
) void {
    if (collider.entity.transform) |transform| {
        const center = collider.center(transform) + offset;
        const center_rect: math.Rect = .{
            .position = Vector2{ center[X] - 0.5, center[Y] - 0.5 },
            .size = Vector2{ 1, 1 },
        };
        const collider_rect: math.Rect = .{
            .position = Vector2{
                (transform.position[X] + collider.left()),
                (transform.position[Y] + collider.top()),
            } + offset,
            .size = Vector2{
                (collider.right() - collider.left()),
                (collider.bottom() - collider.top()),
            },
        };

        switch (collider.shape) {
            .Square => {
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                _ = c.SDL_RenderRect(renderer, &collider_rect.scaled(scale).toSDL());
            },
            .Circle => {
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                const scale2: Vector2 = @splat(scale);
                drawDebugCircle(renderer, center * scale2, collider.radius * scale);
            },
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 0, 255);
        _ = c.SDL_RenderFillRect(renderer, &center_rect.scaled(scale).toSDL());
    }
}

fn drawDebugCircle(renderer: *c.SDL_Renderer, center: Vector2, radius: f32) void {
    const diameter: f32 = radius * 2;
    var x: f32 = (radius - 1);
    var y: f32 = 0;
    var dx: f32 = 1;
    var dy: f32 = 1;
    var err: f32 = (dx - diameter);

    while (x >= y) {
        _ = c.SDL_RenderPoint(renderer, center[X] + x, center[Y] - y);
        _ = c.SDL_RenderPoint(renderer, center[X] + x, center[Y] + y);
        _ = c.SDL_RenderPoint(renderer, center[X] - x, center[Y] - y);
        _ = c.SDL_RenderPoint(renderer, center[X] - x, center[Y] + y);
        _ = c.SDL_RenderPoint(renderer, center[X] + y, center[Y] - x);
        _ = c.SDL_RenderPoint(renderer, center[X] + y, center[Y] + x);
        _ = c.SDL_RenderPoint(renderer, center[X] - y, center[Y] - x);
        _ = c.SDL_RenderPoint(renderer, center[X] - y, center[Y] + x);

        if (err <= 0) {
            y += 1;
            err += dy;
            dy += 2;
        }

        if (err > 0) {
            x -= 1;
            dx += 2;
            err += (dx - diameter);
        }
    }
}

fn drawEntityHighlight(
    renderer: *c.SDL_Renderer,
    opt_entity: ?*ecs.Entity,
    color: Color,
    scale: f32,
    offset: Vector2,
) void {
    if (opt_entity) |entity| {
        if (entity.transform) |transform| {
            if (entity.collider) |collider| {
                const entity_rect: math.Rect = .{
                    .position = Vector2{
                        transform.position[X] + collider.left(),
                        transform.position[Y] + collider.top(),
                    } + offset,
                    .size = Vector2{
                        collider.right() - collider.left(),
                        collider.bottom() - collider.top(),
                    },
                };
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                _ = c.SDL_RenderRect(renderer, &entity_rect.scaled(scale).toSDL());
            }
        }
    }
}

fn getTiledPosition(position: Vector2, asset: *const SpriteAsset) Vector2 {
    const tile_x = @divFloor(position[X], @as(f32, @floatFromInt(asset.document.header.width)));
    const tile_y = @divFloor(position[Y], @as(f32, @floatFromInt(asset.document.header.height)));
    return Vector2{
        tile_x * @as(f32, @floatFromInt(asset.document.header.width)),
        tile_y * @as(f32, @floatFromInt(asset.document.header.height)),
    };
}

fn openSprite(state: *State, entity: *ecs.Entity) void {
    if (entity.sprite) |sprite| {
        if (state.assets.getSpriteAsset(sprite)) |sprite_asset| {
            const process_args = if (PLATFORM == .windows) [_][]const u8{
                "Aseprite.exe",
                sprite_asset.path,
            } else [_][]const u8{
                "open",
                sprite_asset.path,
            };

            var aseprite_process = std.process.Child.init(&process_args, state.allocator);
            aseprite_process.spawn() catch |err| {
                std.debug.print("Error spawning process: {}\n", .{err});
            };
        }
    }
}

fn saveLevel(state: *State, name: []const u8) !void {
    var buf: [LEVEL_NAME_BUFFER_SIZE * 2]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "assets/{s}.lvl", .{name});
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writer().writeInt(u32, @intCast(state.walls.items.len), .little);

    for (state.walls.items) |wall| {
        if (wall.color) |color| {
            if (wall.block) |block| {
                if (wall.transform) |transform| {
                    try file.writer().writeInt(u32, @intFromEnum(color.color), .little);
                    try file.writer().writeInt(u32, @intFromEnum(block.type), .little);
                    try file.writer().writeInt(i32, @intFromFloat(@round(transform.position[X])), .little);
                    try file.writer().writeInt(i32, @intFromFloat(@round(transform.position[Y])), .little);
                }
            }
        }
    }
}
