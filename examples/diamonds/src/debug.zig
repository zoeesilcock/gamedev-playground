const std = @import("std");
const sdl = @import("sdl").c;
const internal = @import("internal");
const game = @import("root.zig");
const entities = @import("entities.zig");
const pool = @import("pool");
const math = @import("math");
const imgui = @import("imgui");

const State = game.State;
const Assets = game.Assets;
const SpriteAsset = game.SpriteAsset;
const Entity = entities.Entity;
const EntityIterator = entities.EntityIterator;
const EntityId = entities.EntityId;
const EntityType = entities.EntityType;
const Collision = entities.Collision;
const ColliderComponent = entities.ColliderComponent;
const ColorComponentValue = entities.ColorComponentValue;
const BlockType = entities.BlockType;
const PoolId = pool.PoolId;

const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;
const Z = math.Z;

const Color = math.Color;
const R = math.R;
const G = math.G;
const B = math.B;
const A = math.A;

// TODO: Remove once Zig has finished migrating to unmanaged-style containers.
const ArrayList = std.ArrayListUnmanaged;

const PLATFORM = @import("builtin").os.tag;
const DOUBLE_CLICK_THRESHOLD: u64 = 300;
const MAX_FRAME_TIME_COUNT: u32 = 300;
const MAX_MEMORY_USAGE_COUNT: u32 = 1000;
const MEMORY_USAGE_RECORD_INTERVAL: u64 = 16;
const LEVEL_NAME_BUFFER_SIZE = game.LEVEL_NAME_BUFFER_SIZE;

pub const DebugState = struct {
    input: DebugInput,
    mode: enum {
        Select,
        Edit,
    },
    show_editor: bool,
    testing_level: bool,
    current_level_name: [LEVEL_NAME_BUFFER_SIZE:0]u8,
    current_block_color: ColorComponentValue,
    current_block_type: BlockType,
    hovered_entity_id: ?EntityId,
    selected_entity_id: ?EntityId,

    show_state_inspector: bool,

    show_colliders: bool,
    collisions: ArrayList(DebugCollision),

    memory_usage: [MAX_MEMORY_USAGE_COUNT]u64,
    memory_usage_current_index: u32,
    memory_usage_last_collected_at: u64,
    memory_usage_display: bool,

    pub fn init(self: *DebugState) !void {
        self.* = .{
            .input = DebugInput{},

            .mode = .Select,
            .show_editor = false,
            .testing_level = false,
            .current_level_name = undefined,
            .current_block_color = .Red,
            .current_block_type = .Wall,
            .hovered_entity_id = null,
            .selected_entity_id = null,

            .show_state_inspector = false,

            .show_colliders = false,
            .collisions = .empty,

            .memory_usage = [1]u64{0} ** MAX_MEMORY_USAGE_COUNT,
            .memory_usage_current_index = 0,
            .memory_usage_last_collected_at = 0,
            .memory_usage_display = false,
        };

        _ = try std.fmt.bufPrintZ(&self.current_level_name, "level1", .{});
    }

    pub fn addCollision(
        self: *DebugState,
        allocator: std.mem.Allocator,
        collision: *const Collision,
        time: u64,
    ) void {
        self.collisions.append(allocator, .{
            .collision = collision.*,
            .time_added = time,
        }) catch unreachable;
    }

    pub fn currentLevelName(self: *DebugState) []const u8 {
        return std.mem.span(self.current_level_name[0..].ptr);
    }
};

const DebugInput = struct {
    left_mouse_down: bool = false,
    left_mouse_pressed: bool = false,
    left_mouse_last_time: u64 = 0,
    left_mouse_last_entity_id: ?EntityId = null,

    mouse_position: Vector2 = @splat(0),
    alt_key_down: bool = false,

    pub fn reset(self: *DebugInput) void {
        self.left_mouse_pressed = false;
    }
};

const DebugCollision = struct {
    collision: Collision,
    time_added: u64,
};

const FPSDisplayMode = enum {
    None,
    Number,
    NumberAndGraph,
};

pub fn processInputEvent(state: *State, event: sdl.SDL_Event) void {
    var input = &state.debug_state.input;

    // Keyboard.
    if (event.key.key == sdl.SDLK_LALT) {
        input.alt_key_down = event.type == sdl.SDL_EVENT_KEY_DOWN;
    }
    if (event.type == sdl.SDL_EVENT_KEY_DOWN) {
        switch (event.key.key) {
            sdl.SDLK_F1 => {
                state.fps_state.?.toggleMode();
            },
            sdl.SDLK_F2 => {
                state.debug_state.memory_usage_display = !state.debug_state.memory_usage_display;
            },
            sdl.SDLK_C => {
                state.debug_state.show_colliders = !state.debug_state.show_colliders;
            },
            sdl.SDLK_G => {
                state.debug_state.show_state_inspector = !state.debug_state.show_state_inspector;
            },
            sdl.SDLK_E => {
                state.debug_state.show_editor = !state.debug_state.show_editor;
                state.debug_state.mode = if (state.debug_state.show_editor) .Edit else .Select;

                if (state.debug_state.show_editor) {
                    state.debug_state.testing_level = false;
                    state.paused = true;
                }
            },
            sdl.SDLK_S => {
                saveLevel(state, state.debug_state.currentLevelName()) catch unreachable;
            },
            sdl.SDLK_L => {
                game.loadLevel(state, state.debug_state.currentLevelName()) catch unreachable;
            },
            else => {},
        }
    }

    // Mouse.
    if (event.type == sdl.SDL_EVENT_MOUSE_MOTION) {
        input.mouse_position = Vector2{ event.motion.x - state.dest_rect.x, event.motion.y };
    } else if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN or event.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP) {
        const is_down = event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN;

        switch (event.button.button) {
            1 => {
                input.left_mouse_pressed = (input.left_mouse_down and !is_down);
                input.left_mouse_down = is_down;
            },
            else => {},
        }
    }
}

pub fn handleInput(state: *State, allocator: std.mem.Allocator) void {
    state.debug_state.hovered_entity_id = getHoveredEntity(state);

    const input: *DebugInput = &state.debug_state.input;
    var block_color = state.debug_state.current_block_color;
    const block_type = state.debug_state.current_block_type;

    if (block_type == .Deadly) {
        block_color = .Gray;
    }

    if (state.debug_state.mode == .Edit and block_type == .ColorChange and block_color == .Gray) {
        return;
    }

    if (state.getEntity(state.debug_state.hovered_entity_id)) |hovered_entity| {
        if (input.left_mouse_pressed) {
            // Grab the color and type of the hovered entity when alt is held down.
            if (state.debug_state.input.alt_key_down) {
                if (hovered_entity.block) |block| {
                    state.debug_state.current_block_type = block.type;
                }
                if (hovered_entity.color) |color| {
                    state.debug_state.current_block_color = color.color;
                }
            } else {
                if (state.debug_state.mode == .Edit) {
                    var should_add: bool = true;

                    if (hovered_entity.entity_type == .Wall) {
                        if (hovered_entity.color) |hovered_color| {
                            if (hovered_entity.block) |hovered_block_type| {
                                should_add =
                                    block_color != hovered_color.color or
                                    block_type != hovered_block_type.type;
                            }
                        }

                        state.removeEntity(hovered_entity);
                    }

                    if (should_add) {
                        const tiled_position = getTiledPosition(
                            input.mouse_position / @as(Vector2, @splat(state.world_scale)),
                            state.assets.getWall(block_color, block_type),
                        );
                        _ = game.addWall(state, block_color, block_type, tiled_position) catch undefined;
                    }
                } else {
                    if (hovered_entity.id.equals(state.debug_state.input.left_mouse_last_entity_id) and
                        state.time - state.debug_state.input.left_mouse_last_time < DOUBLE_CLICK_THRESHOLD)
                    {
                        openSprite(state, allocator, hovered_entity);
                    } else {
                        if (!hovered_entity.id.equals(state.debug_state.selected_entity_id) or
                            state.debug_state.selected_entity_id == null)
                        {
                            state.debug_state.selected_entity_id = hovered_entity.id;
                        } else {
                            state.debug_state.selected_entity_id = null;
                        }
                    }
                }
            }

            state.debug_state.input.left_mouse_last_time = state.time;
            state.debug_state.input.left_mouse_last_entity_id = state.debug_state.hovered_entity_id;
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
                state.debug_state.selected_entity_id = null;
            }
        }
    }
}

fn entityContainsPoint(state: *State, mouse_position: Vector2, entity: *Entity) ?EntityId {
    var result: ?EntityId = null;
    if (entity.sprite.?.containsPoint(
        mouse_position,
        state.dest_rect,
        state.world_scale,
        &state.assets,
    )) {
        result = entity.id;
    }
    return result;
}

fn getHoveredEntity(state: *State) ?EntityId {
    var result: ?EntityId = null;
    const mouse_position = state.debug_state.input.mouse_position / @as(Vector2, @splat(state.world_scale));

    var iter: EntityIterator = .{ .entities = &state.entities };
    while (iter.next(&.{ .title, .sprite })) |entity| {
        if (entityContainsPoint(state, mouse_position, entity)) |id| {
            result = id;
            break;
        }
    }

    if (result == null) {
        iter.reset();
        while (iter.next(&.{ .collider, .sprite })) |entity| {
            if (entityContainsPoint(state, mouse_position, entity)) |id| {
                result = id;
                break;
            }
        }
    }

    if (result == null) {
        iter.reset();
        while (iter.next(&.{.sprite})) |entity| {
            if (entityContainsPoint(state, mouse_position, entity)) |id| {
                result = id;
                break;
            }
        }
    }

    return result;
}

pub fn calculateFPS(state: *State) void {
    state.debug_state.current_frame_index += 1;
    if (state.debug_state.current_frame_index >= MAX_FRAME_TIME_COUNT) {
        state.debug_state.current_frame_index = 0;
    }
    state.debug_state.frame_times[state.debug_state.current_frame_index] = sdl.SDL_GetPerformanceCounter();

    var average: f32 = 0;
    for (0..MAX_FRAME_TIME_COUNT) |i| {
        average += state.debug_state.getFrameTime(@intCast(i));
    }
    state.debug_state.fps_average = 1 / (average / @as(f32, @floatFromInt(MAX_FRAME_TIME_COUNT)));
}

pub fn recordMemoryUsage(state: *State) void {
    if (state.debug_state.memory_usage_last_collected_at + MEMORY_USAGE_RECORD_INTERVAL < state.time) {
        state.debug_state.memory_usage_last_collected_at = state.time;
        state.debug_state.memory_usage_current_index += 1;
        if (state.debug_state.memory_usage_current_index >= MAX_MEMORY_USAGE_COUNT) {
            state.debug_state.memory_usage_current_index = 0;
        }
        state.debug_state.memory_usage[state.debug_state.memory_usage_current_index] =
            state.game_allocator.total_requested_bytes;
    }
}

pub fn drawDebugUI(state: *State) void {
    imgui.newFrame();

    state.fps_state.?.draw();

    if (state.debug_state.memory_usage_display) {
        _ = imgui.c.ImGui_Begin(
            "MemoryUsage",
            null,
            imgui.c.ImGuiWindowFlags_NoFocusOnAppearing |
                imgui.c.ImGuiWindowFlags_NoNavFocus |
                imgui.c.ImGuiWindowFlags_NoNavInputs,
        );

        _ = imgui.c.ImGui_Text(
            "Bytes: %d",
            state.debug_state.memory_usage[state.debug_state.memory_usage_current_index],
        );

        var memory_usage: [MAX_MEMORY_USAGE_COUNT]f32 = [1]f32{0} ** MAX_MEMORY_USAGE_COUNT;
        var max_value: f32 = 0;
        var min_value: f32 = std.math.floatMax(f32);
        for (0..MAX_MEMORY_USAGE_COUNT) |i| {
            memory_usage[i] = @floatFromInt(state.debug_state.memory_usage[i]);
            if (memory_usage[i] > max_value) {
                max_value = memory_usage[i];
            }
            if (memory_usage[i] < min_value and memory_usage[i] > 0) {
                min_value = memory_usage[i];
            }
        }
        var buf: [100]u8 = undefined;
        const min_text = std.fmt.bufPrintZ(&buf, "min: {d}", .{min_value}) catch "";
        imgui.c.ImGui_PlotHistogramEx(
            "##MemoryUsageGraph",
            &memory_usage,
            memory_usage.len,
            @intCast(state.debug_state.memory_usage_current_index + 1),
            min_text.ptr,
            min_value,
            max_value,
            imgui.c.ImVec2{ .x = 300, .y = 100 },
            @sizeOf(f32),
        );

        imgui.c.ImGui_End();
    }

    if (state.debug_state.show_editor) {
        const button_size: imgui.c.ImVec2 = imgui.c.ImVec2{ .x = 140, .y = 20 };
        const half_button_size: imgui.c.ImVec2 = imgui.c.ImVec2{ .x = 65, .y = 20 };

        imgui.c.ImGui_SetNextWindowSize(imgui.c.ImVec2{ .x = 160, .y = 200 }, 0);

        _ = imgui.c.ImGui_Begin(
            "Editor",
            null,
            imgui.c.ImGuiWindowFlags_NoFocusOnAppearing |
                imgui.c.ImGuiWindowFlags_NoNavFocus |
                imgui.c.ImGuiWindowFlags_NoNavInputs,
        );

        _ = imgui.c.ImGui_InputTextEx(
            "Name",
            @ptrCast(&state.debug_state.current_level_name),
            state.debug_state.current_level_name.len,
            0,
            null,
            null,
        );

        if (imgui.c.ImGui_ButtonEx("Load", half_button_size)) {
            game.loadLevel(state, state.debug_state.currentLevelName()) catch unreachable;
        }
        imgui.c.ImGui_SameLineEx(0, 10);
        if (imgui.c.ImGui_ButtonEx("Save", half_button_size)) {
            saveLevel(state, state.debug_state.currentLevelName()) catch unreachable;
        }

        if (imgui.c.ImGui_ButtonEx("Test level", button_size)) {
            state.debug_state.show_editor = false;
            state.debug_state.testing_level = true;
            state.paused = false;

            game.loadLevel(state, state.debug_state.currentLevelName()) catch unreachable;
        }

        if (imgui.c.ImGui_ButtonEx("Restart", button_size)) {
            imgui.c.ImGui_End();

            game.restart(state);
            return;
        }

        internal.inputEnum("Mode", &state.debug_state.mode);
        internal.inputEnum("Type", &state.debug_state.current_block_type);
        internal.inputEnum("Color", &state.debug_state.current_block_color);

        imgui.c.ImGui_End();
    }

    if (state.getEntity(state.debug_state.selected_entity_id)) |selected_entity| {
        imgui.c.ImGui_SetNextWindowPosEx(
            imgui.c.ImVec2{ .x = 30, .y = 30 },
            imgui.c.ImGuiCond_FirstUseEver,
            imgui.c.ImVec2{ .x = 0, .y = 0 },
        );
        imgui.c.ImGui_SetNextWindowSize(imgui.c.ImVec2{ .x = 300, .y = 540 }, imgui.c.ImGuiCond_FirstUseEver);

        _ = imgui.c.ImGui_Begin("Inspector", null, imgui.c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer imgui.c.ImGui_End();

        internal.inspectStruct(selected_entity, &.{ "entity", "is_in_use" }, true, &inputCustomTypes);
    }

    if (state.debug_state.show_state_inspector) {
        imgui.c.ImGui_SetNextWindowPosEx(
            imgui.c.ImVec2{ .x = 350, .y = 30 },
            imgui.c.ImGuiCond_FirstUseEver,
            imgui.c.ImVec2{ .x = 0, .y = 0 },
        );
        imgui.c.ImGui_SetNextWindowSize(imgui.c.ImVec2{ .x = 300, .y = 540 }, imgui.c.ImGuiCond_FirstUseEver);

        _ = imgui.c.ImGui_Begin("Game state", null, imgui.c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer imgui.c.ImGui_End();

        internal.inspectStruct(state, &.{"entity"}, false, &inputCustomTypes);
    }

    imgui.render(state.renderer);
}

fn inputCustomTypes(
    struct_field: std.builtin.Type.StructField,
    field_ptr: anytype,
) bool {
    var handled: bool = true;

    switch (@TypeOf(field_ptr.*)) {
        Vector2 => {
            imgui.c.ImGui_PushIDPtr(field_ptr);
            defer imgui.c.ImGui_PopID();

            _ = imgui.c.ImGui_InputFloat2Ex(struct_field.name, @ptrCast(field_ptr), "%.2f", 0);
        },
        Color => {
            imgui.c.ImGui_PushIDPtr(field_ptr);
            defer imgui.c.ImGui_PopID();

            _ = imgui.c.ImGui_InputScalarNEx(
                struct_field.name,
                imgui.c.ImGuiDataType_U8,
                @ptrCast(field_ptr),
                4,
                null,
                null,
                null,
                0,
            );
        },
        EntityId => {
            const entity_id: *EntityId = @ptrCast(field_ptr);
            var buf: [64]u8 = undefined;
            const id = std.fmt.bufPrintZ(
                &buf,
                "{d} ({d})",
                .{ entity_id.index, entity_id.generation },
            ) catch "";
            imgui.c.ImGui_LabelText("EntityId", id);
        },
        PoolId => {
            const pool_id: *PoolId = @ptrCast(field_ptr);
            var buf: [64]u8 = undefined;
            const id = std.fmt.bufPrintZ(&buf, "pool index: {d}", .{pool_id.index}) catch "";
            imgui.c.ImGui_Text(id.ptr);
        },
        EntityType => {
            inline for (@typeInfo(EntityType).@"enum".fields, 0..) |field, i| {
                if (@intFromEnum(field_ptr.*) == i) {
                    imgui.c.ImGui_LabelText("Type", field.name);
                }
            }
        },
        else => handled = false,
    }

    return handled;
}

pub fn drawDebugOverlay(state: *State) void {
    // Highlight colliders.
    const scale = state.world_scale;
    const offset = Vector2{
        state.dest_rect.x / state.world_scale,
        state.dest_rect.y / state.world_scale,
    };

    if (state.debug_state.show_colliders) {
        var iter: EntityIterator = .{ .entities = &state.entities };
        while (iter.next(&.{.collider})) |entity| {
            drawDebugCollider(state.renderer, entity, Color{ 0, 255, 0, 255 }, scale, offset);
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
                if (state.getEntity(collision.collision.other_id)) |other_entity| {
                    drawDebugCollider(state.renderer, other_entity, color, scale, offset);
                }
            }
        }
    }

    // Highlight the currently hovered entity.
    drawEntityHighlight(
        state,
        state.renderer,
        &state.assets,
        state.debug_state.selected_entity_id,
        Color{ 255, 0, 0, 255 },
        scale,
        offset,
    );
    drawEntityHighlight(
        state,
        state.renderer,
        &state.assets,
        state.debug_state.hovered_entity_id,
        Color{ 255, 150, 0, 255 },
        scale,
        offset,
    );

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
        _ = sdl.SDL_SetRenderDrawColor(state.renderer, 255, 255, 0, 255);
        _ = sdl.SDL_RenderFillRect(state.renderer, &mouse_rect.scaled(scale).toSDL());
    }
}

fn drawDebugCollider(
    renderer: *sdl.SDL_Renderer,
    entity: *Entity,
    color: Color,
    scale: f32,
    offset: Vector2,
) void {
    if (entity.collider) |collider| {
        if (entity.transform) |transform| {
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
                    _ = sdl.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                    _ = sdl.SDL_RenderRect(renderer, &collider_rect.scaled(scale).toSDL());
                },
                .Circle => {
                    _ = sdl.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                    const scale2: Vector2 = @splat(scale);
                    drawDebugCircle(renderer, center * scale2, collider.radius * scale);
                },
            }

            _ = sdl.SDL_SetRenderDrawColor(renderer, 255, 255, 0, 255);
            _ = sdl.SDL_RenderFillRect(renderer, &center_rect.scaled(scale).toSDL());
        }
    }
}

fn drawDebugCircle(renderer: *sdl.SDL_Renderer, center: Vector2, radius: f32) void {
    const diameter: f32 = radius * 2;
    var x: f32 = (radius - 1);
    var y: f32 = 0;
    var dx: f32 = 1;
    var dy: f32 = 1;
    var err: f32 = (dx - diameter);

    while (x >= y) {
        _ = sdl.SDL_RenderPoint(renderer, center[X] + x, center[Y] - y);
        _ = sdl.SDL_RenderPoint(renderer, center[X] + x, center[Y] + y);
        _ = sdl.SDL_RenderPoint(renderer, center[X] - x, center[Y] - y);
        _ = sdl.SDL_RenderPoint(renderer, center[X] - x, center[Y] + y);
        _ = sdl.SDL_RenderPoint(renderer, center[X] + y, center[Y] - x);
        _ = sdl.SDL_RenderPoint(renderer, center[X] + y, center[Y] + x);
        _ = sdl.SDL_RenderPoint(renderer, center[X] - y, center[Y] - x);
        _ = sdl.SDL_RenderPoint(renderer, center[X] - y, center[Y] + x);

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
    state: *State,
    renderer: *sdl.SDL_Renderer,
    assets: *Assets,
    entity_id: ?EntityId,
    color: Color,
    scale: f32,
    offset: Vector2,
) void {
    if (state.getEntity(entity_id)) |entity| {
        if (entity.transform) |transform| {
            var entity_rect: math.Rect = .{};
            if (entity.collider) |collider| {
                entity_rect = .{
                    .position = Vector2{
                        transform.position[X] + collider.left(),
                        transform.position[Y] + collider.top(),
                    } + offset,
                    .size = Vector2{
                        collider.right() - collider.left(),
                        collider.bottom() - collider.top(),
                    },
                };
            } else if (entity.sprite) |sprite| {
                if (assets.getSpriteAsset(sprite)) |sprite_asset| {
                    entity_rect = .{
                        .position = Vector2{ transform.position[X], transform.position[Y] } + offset,
                        .size = Vector2{
                            @floatFromInt(sprite_asset.document.header.width),
                            @floatFromInt(sprite_asset.document.header.height),
                        },
                    };
                }
            }

            if (entity.title) |title| {
                const title_position: Vector2 = title.getPosition(state.dest_rect, state.world_scale, &state.assets);
                entity_rect.position = title_position + offset;
            }

            _ = sdl.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
            _ = sdl.SDL_RenderRect(renderer, &entity_rect.scaled(scale).toSDL());
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

fn openSprite(state: *State, allocator: std.mem.Allocator, entity: *Entity) void {
    if (entity.sprite) |sprite| {
        if (state.assets.getSpriteAsset(sprite)) |sprite_asset| {
            const process_args = if (PLATFORM == .windows) [_][]const u8{
                "Aseprite.exe",
                sprite_asset.path,
            } else [_][]const u8{
                "open",
                sprite_asset.path,
            };

            var aseprite_process = std.process.Child.init(&process_args, allocator);
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

    var writer_buf: [10 * 1024]u8 = undefined;
    var file_writer = file.writer(&writer_buf);
    var writer: *std.Io.Writer = &file_writer.interface;

    var walls_count: u32 = 0;
    var iter: EntityIterator = .{ .entities = &state.entities };
    while (iter.next(&.{ .block, .color, .transform })) |_| {
        walls_count += 1;
    }
    try writer.writeInt(u32, walls_count, .little);

    iter.reset();
    while (iter.next(&.{ .block, .color, .transform })) |entity| {
        try writer.writeInt(u32, @intFromEnum(entity.color.?.color), .little);
        try writer.writeInt(u32, @intFromEnum(entity.block.?.type), .little);
        try writer.writeInt(i32, @intFromFloat(@round(entity.transform.?.position[X])), .little);
        try writer.writeInt(i32, @intFromFloat(@round(entity.transform.?.position[Y])), .little);
    }

    try writer.flush();
}
