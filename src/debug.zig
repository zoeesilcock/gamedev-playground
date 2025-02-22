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

pub const DebugState = struct {
    input: DebugInput,
    mode: enum {
        Select,
        Edit,
    },
    current_wall_color: ?ecs.ColorComponentValue,
    show_editor: bool,

    show_colliders: bool,
    collisions: std.ArrayList(DebugCollision),

    last_left_click_time: u64,
    last_left_click_entity: ?*ecs.Entity,
    hovered_entity: ?*ecs.Entity,
    selected_entity: ?*ecs.Entity,

    fps_counted_frames: u64,
    fps_since: u64,
    fps_average: f32,

    pub fn init(self: *DebugState, allocator: std.mem.Allocator) void {
        self.input = DebugInput{};
        self.mode = .Select;
        self.current_wall_color = .Red;
        self.show_editor = false;

        self.show_colliders = false;
        self.collisions = std.ArrayList(DebugCollision).init(allocator);

        self.selected_entity = null;
        self.hovered_entity = null;
        self.last_left_click_time = 0;
        self.last_left_click_entity = null;

        self.fps_counted_frames = 0;
        self.fps_since = 0;
        self.fps_average = 0;
    }

    pub fn addCollision(self: *DebugState, collision: *const ecs.Collision, time: u64) void {
        self.collisions.append(.{
            .collision = collision.*,
            .time_added = time,
        }) catch unreachable;
    }
};

const DebugInput = struct {
    left_mouse_down: bool = false,
    left_mouse_pressed: bool = false,
    mouse_position: Vector2 = @splat(0),

    pub fn reset(self: *DebugInput) void {
        self.left_mouse_pressed = false;
    }
};

const DebugCollision = struct {
    collision: ecs.Collision,
    time_added: u64,
};

pub fn processInputEvent(state: *State, event: c.SDL_Event) void {
    var input = &state.debug_state.input;

    // Keyboard.
    if (event.type == c.SDL_EVENT_KEY_DOWN) {
        switch (event.key.key) {
            c.SDLK_P => {
                state.is_paused = !state.is_paused;
            },
            c.SDLK_E => {
                state.debug_state.show_editor = !state.debug_state.show_editor;
            },
            c.SDLK_C => {
                state.debug_state.show_colliders = !state.debug_state.show_colliders;
            },
            c.SDLK_S => {
                saveLevel(state, "assets/level1.lvl") catch unreachable;
            },
            c.SDLK_L => {
                game.loadLevel(state, "assets/level1.lvl") catch unreachable;
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

    if (state.debug_state.hovered_entity) |hovered_entity| {
        if (input.left_mouse_pressed) {
            if (state.debug_state.mode == .Edit) {
                if (state.debug_state.current_wall_color) |editor_wall_color| {
                    if (editor_wall_color == hovered_entity.color.?.color) {
                        game.removeEntity(state, hovered_entity);
                    } else {
                        game.removeEntity(state, hovered_entity);
                        const tiled_position = getTiledPosition(
                            input.mouse_position / @as(Vector2, @splat(state.world_scale)),
                            state.assets.getWall(editor_wall_color),
                        );
                        _ = game.addWall(state, editor_wall_color, tiled_position) catch undefined;
                    }
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

            state.debug_state.last_left_click_time = state.time;
            state.debug_state.last_left_click_entity = hovered_entity;
        }
    } else {
        if (input.left_mouse_pressed) {
            if (state.debug_state.mode == .Edit) {
                if (state.debug_state.current_wall_color) |editor_wall_color| {
                    const tiled_position = getTiledPosition(
                        input.mouse_position / @as(Vector2, @splat(state.world_scale)),
                        state.assets.getWall(editor_wall_color),
                    );
                    _ = game.addWall(state, editor_wall_color, tiled_position) catch undefined;
                }
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
    if (state.debug_state.fps_counted_frames == 0) {
        state.debug_state.fps_since = state.time;
    }
    state.debug_state.fps_counted_frames += 1;
    const fps_time_passed = state.time - state.debug_state.fps_since;
    if (fps_time_passed > 1000) {
        state.debug_state.fps_average =
            @as(f32, @floatFromInt(state.debug_state.fps_counted_frames)) /
            (@as(f32, @floatFromInt(fps_time_passed)) / 1000);
    } else {
        state.debug_state.fps_average = 0;
    }
    if (state.debug_state.fps_counted_frames > 1000000) {
        state.debug_state.fps_counted_frames = 0;
    }
}

pub fn drawDebugUI(state: *State) void {
    imgui.newFrame();

    var show_fps = true;

    c.igSetNextWindowPos(c.ImVec2{ .x = 5, .y = 5 }, 0, c.ImVec2{ .x = 0, .y = 0 });
    c.igSetNextWindowSize(c.ImVec2{ .x = 100, .y = 10 }, 0);
    _ = c.igBegin(
        "FPS",
        &show_fps,
        c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoBackground |
            c.ImGuiWindowFlags_NoTitleBar,
    );
    c.igTextColored(
        c.ImVec4{ .x = 0, .y = 1, .z = 0, .w = 1 },
        "FPS: %d",
        @as(u32, @intFromFloat(state.debug_state.fps_average)),
    );
    c.igEnd();

    if (state.debug_state.show_editor) {
        _ = c.igBegin(
            "Editor",
            null,
            c.ImGuiViewportFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoNavFocus | c.ImGuiWindowFlags_NoNavInputs,
        );
        defer c.igEnd();

        c.igText("Mode:");
        if (c.igRadioButton_Bool("Select", state.debug_state.mode == .Select)) {
            state.debug_state.mode = .Select;
        }
        c.igSpacing();
        if (c.igRadioButton_Bool("Gray", state.debug_state.mode == .Edit and
            state.debug_state.current_wall_color == .Gray))
        {
            state.debug_state.mode = .Edit;
            state.debug_state.current_wall_color = .Gray;
        }
        if (c.igRadioButton_Bool("Red", state.debug_state.mode == .Edit and
            state.debug_state.current_wall_color == .Red))
        {
            state.debug_state.mode = .Edit;
            state.debug_state.current_wall_color = .Red;
        }
        if (c.igRadioButton_Bool("Blue", state.debug_state.mode == .Edit and
            state.debug_state.current_wall_color == .Blue))
        {
            state.debug_state.mode = .Edit;
            state.debug_state.current_wall_color = .Blue;
        }
    }

    if (state.debug_state.selected_entity) |selected_entity| {
        c.igSetNextWindowPos(c.ImVec2{ .x = 30, .y = 30 }, c.ImGuiCond_FirstUseEver, c.ImVec2{ .x = 0, .y = 0 });
        c.igSetNextWindowSize(c.ImVec2{ .x = 300, .y = 460 }, c.ImGuiCond_FirstUseEver);

        _ = c.igBegin("Inspector", null, c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer c.igEnd();

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
    inline for (entity_info.Struct.fields) |entity_field| {
        if (entity_field.type == ecs.EntityType) {
            const entity_type = runtimeFieldPointer(entity, entity_field.name);
            inline for (@typeInfo(ecs.EntityType).Enum.fields, 0..) |field, i| {
                if (@intFromEnum(entity_type.*) == i) {
                    c.igText("Type: " ++ field.name);
                }
            }
        } else if (runtimeFieldPointer(entity, entity_field.name).*) |component| {
            if (c.igCollapsingHeader_BoolPtr(entity_field.name, null, c.ImGuiTreeNodeFlags_DefaultOpen)) {
                const component_info = @typeInfo(@TypeOf(component.*));
                inline for (component_info.Struct.fields) |component_field| {
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
                            if (@typeInfo(field_type) == .Enum) {
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
    c.igPushID_Ptr(value);
    defer c.igPopID();

    _ = c.igCheckbox(heading, value);
}

fn inputF32(heading: ?[*:0]const u8, value: *f32) void {
    c.igPushID_Ptr(value);
    defer c.igPopID();

    _ = c.igInputFloat(heading, value, 0.1, 1, "%.2f", 0);
}

fn inputU32(heading: ?[*:0]const u8, value: *u32) void {
    c.igPushID_Ptr(value);
    defer c.igPopID();

    _ = c.igInputScalar(heading, c.ImGuiDataType_U32, @ptrCast(value), null, null, null, 0);
}

fn inputVector2(heading: ?[*:0]const u8, value: *Vector2) void {
    c.igPushID_Ptr(value);
    defer c.igPopID();

    _ = c.igInputFloat2(heading, @ptrCast(value), "%.2f", 0);
}

fn inputEnum(heading: ?[*:0]const u8, value: anytype) void {
    const field_info = @typeInfo(@TypeOf(value.*));
    const count: u32 = field_info.Enum.fields.len;
    var items: [count][*:0]const u8 = [1][*:0]const u8{undefined} ** count;
    inline for (field_info.Enum.fields, 0..) |enum_field, i| {
        items[i] = enum_field.name;
    }

    c.igPushID_Ptr(value);
    defer c.igPopID();

    var current_item: i32 = @intFromEnum(value.*);
    if (c.igCombo_Str_arr(heading, &current_item, &items, count, 0)) {
        value.* = @enumFromInt(current_item);
    }
}

pub fn drawDebugOverlay(state: *State) void {
    // Highlight colliders.
    if (state.debug_state.show_colliders) {
        for (state.colliders.items) |collider| {
            drawDebugCollider(state.renderer, collider, Color{ 0, 255, 0, 255 });
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
                drawDebugCollider(state.renderer, collision.collision.other, color);
            }
        }
    }

    // Highlight the currently hovered entity.
    drawEntityHighlight(state.renderer, state.debug_state.selected_entity, Color{ 255, 0, 0, 255 });
    drawEntityHighlight(state.renderer, state.debug_state.hovered_entity, Color{ 255, 150, 0, 255 });

    // Draw the current mouse position.
    const mouse_size: f32 = 8;
    const mouse_rect: c.SDL_FRect = .{
        .x = (state.debug_state.input.mouse_position[X] - (mouse_size / 2)) / state.world_scale,
        .y = (state.debug_state.input.mouse_position[Y] - (mouse_size / 2)) / state.world_scale,
        .w = mouse_size / state.world_scale,
        .h = mouse_size / state.world_scale,
    };
    _ = c.SDL_SetRenderDrawColor(state.renderer, 255, 255, 0, 255);
    _ = c.SDL_RenderFillRect(state.renderer, &mouse_rect);
}

fn drawDebugCollider(
    renderer: *c.SDL_Renderer,
    collider: *ecs.ColliderComponent,
    color: Color,
) void {
    if (collider.entity.transform) |transform| {
        const center = collider.center(transform);
        const center_rect = c.SDL_FRect{
            .x = center[X] - 0.5,
            .y = center[Y] - 0.5,
            .w = 1,
            .h = 1,
        };
        const collider_rect = c.SDL_FRect{
            .x = transform.position[X] + collider.left(),
            .y = transform.position[Y] + collider.top(),
            .w = collider.right() - collider.left(),
            .h = collider.bottom() - collider.top(),
        };

        switch (collider.shape) {
            .Square => {
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                _ = c.SDL_RenderRect(renderer, &collider_rect);
            },
            .Circle => {
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                drawDebugCircle(renderer, center, collider.radius);
            },
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 0, 255);
        _ = c.SDL_RenderRect(renderer, &center_rect);
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
) void {
    if (opt_entity) |entity| {
        if (entity.transform) |transform| {
            if (entity.collider) |collider| {
                const entity_rect = c.SDL_FRect{
                    .x = transform.position[X] + collider.left(),
                    .y = transform.position[Y] + collider.top(),
                    .w = collider.right() - collider.left(),
                    .h = collider.bottom() - collider.top(),
                };
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                _ = c.SDL_RenderRect(renderer, &entity_rect);
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

fn saveLevel(state: *State, path: []const u8) !void {
    if (std.fs.cwd().createFile(path, .{ .truncate = true }) catch null) |file| {
        defer file.close();

        try file.writer().writeInt(u32, @intCast(state.walls.items.len), .little);

        for (state.walls.items) |wall| {
            if (wall.color) |color| {
                if (wall.transform) |transform| {
                    try file.writer().writeInt(u32, @intFromEnum(color.color), .little);
                    try file.writer().writeInt(i32, @intFromFloat(@round(transform.position[X])), .little);
                    try file.writer().writeInt(i32, @intFromFloat(@round(transform.position[Y])), .little);
                }
            }
        }
    }
}
