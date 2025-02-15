const std = @import("std");
const ecs = @import("ecs.zig");
const math = @import("math.zig");
const game = @import("root.zig");
const zimgui = @import("zig_imgui");
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

const DebugCollision = struct {
    collision: ecs.Collision,
    time_added: u64,
};

pub const DebugState = struct {
    last_left_click_time: u64,
    last_left_click_entity: ?*ecs.Entity,
    hovered_entity: ?*ecs.Entity,
    selected_entity: ?*ecs.Entity,

    input: DebugInput,
    mode: enum {
        Select,
        Edit,
    },
    current_wall_color: ?ecs.ColorComponentValue,
    show_level_editor: bool,
    show_colliders: bool,

    collisions: std.ArrayList(DebugCollision),

    fps_counted_frames: u64,
    fps_since: u64,
    fps_average: f32,

    pub fn init(self: *DebugState, allocator: std.mem.Allocator) void {
        self.input = DebugInput{};
        self.mode = .Select;
        self.current_wall_color = .Red;
        self.collisions = std.ArrayList(DebugCollision).init(allocator);
        self.fps_counted_frames = 0;
        self.fps_since = 0;
        self.fps_average = 0;
        self.selected_entity = null;
        self.hovered_entity = null;
        self.last_left_click_time = 0;
        self.last_left_click_entity = null;
    }

    pub fn addCollision(self: *DebugState, collision: *const ecs.Collision) void {
        self.collisions.append(.{
            .collision = collision.*,
            // .time_added = r.GetTime(),
            .time_added = 0,
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

pub fn processInputEvent(state: *State, event: c.SDL_Event) void {
    var input = &state.debug_state.input;

    // Keyboard.
    if (event.type == c.SDL_EVENT_KEY_DOWN) {
        switch (event.key.key) {
            c.SDLK_P => {
                state.is_paused = !state.is_paused;
            },
            c.SDLK_E => {
                state.debug_state.show_level_editor = !state.debug_state.show_level_editor;
            },
            c.SDLK_F => {
                state.fullscreen = !state.fullscreen;
                _ = c.SDL_SetWindowFullscreen(state.window, state.fullscreen);
                game.setupRenderTexture(state);
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

    // Level editor.
    if (!state.debug_state.show_level_editor) {
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
                                &state.assets.getWall(editor_wall_color),
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
                            &state.assets.getWall(editor_wall_color),
                        );
                        _ = game.addWall(state, editor_wall_color, tiled_position) catch undefined;
                    }
                }
            }
        }
    }
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
    zimgui.SetNextWindowPos(zimgui.Vec2.init(5, 5));
    zimgui.SetNextWindowSize(zimgui.Vec2.init(100, 10));
    _ = zimgui.BeginExt(
        "FPS",
        &show_fps,
        .{ .NoMove = true, .NoResize = true, .NoBackground = true, .NoTitleBar = true },
    );
    zimgui.TextColored(zimgui.Vec4.init(0, 1, 0, 1), "FPS: %d", @as(u32, @intFromFloat(state.debug_state.fps_average)));
    zimgui.End();

    if (state.debug_state.show_level_editor) {
        _ = zimgui.Begin("Editor");
        defer zimgui.End();

        zimgui.Text("Mode:", .{});
        if (zimgui.RadioButton_Bool("Select", state.debug_state.mode == .Select)) {
            state.debug_state.mode = .Select;
        }
        zimgui.Spacing();
        if (zimgui.RadioButton_Bool("Gray", state.debug_state.mode == .Edit and state.debug_state.current_wall_color == .Gray)) {
            state.debug_state.mode = .Edit;
            state.debug_state.current_wall_color = .Gray;
        }
        if (zimgui.RadioButton_Bool("Red", state.debug_state.mode == .Edit and state.debug_state.current_wall_color == .Red)) {
            state.debug_state.mode = .Edit;
            state.debug_state.current_wall_color = .Red;
        }
        if (zimgui.RadioButton_Bool("Blue", state.debug_state.mode == .Edit and state.debug_state.current_wall_color == .Blue)) {
            state.debug_state.mode = .Edit;
            state.debug_state.current_wall_color = .Blue;
        }
    }

    imgui.render(state.renderer);
}

fn drawDebugCollider(
    renderer: *c.SDL_Renderer,
    collider: *ecs.ColliderComponent,
    color: Color,
    line_thickness: f32,
) void {
    _ = line_thickness;

    if (collider.entity.transform) |transform| {
        switch (collider.shape) {
            .Square => {
                const collider_rect = c.SDL_FRect{
                    .x = transform.position[X],
                    .y = transform.position[Y],
                    .w = transform.size[X],
                    .h = transform.size[Y],
                };
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                _ = c.SDL_RenderRect(renderer, &collider_rect);
            },
            .Circle => {
                // TODO: Make a simple circle drawing method.
                const collider_rect = c.SDL_FRect{
                    .x = transform.position[X],
                    .y = transform.position[Y],
                    .w = transform.size[X],
                    .h = transform.size[Y],
                };
                _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
                _ = c.SDL_RenderRect(renderer, &collider_rect);
            },
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
            const entity_rect = c.SDL_FRect{
                .x = transform.position[X],
                .y = transform.position[Y],
                .w = transform.size[X],
                .h = transform.size[Y],
            };
            _ = c.SDL_SetRenderDrawColor(renderer, color[R], color[G], color[B], color[A]);
            _ = c.SDL_RenderRect(renderer, &entity_rect);
        }
    }
}

pub fn drawDebugOverlay(state: *State) void {
    const line_thickness: f32 = 0.5;

    // Highlight colliders.
    if (state.debug_state.show_colliders) {
        for (state.colliders.items) |collider| {
            drawDebugCollider(state.renderer, collider, Color{ 0, 255, 0, 255 }, line_thickness);
        }

        // Highlight collisions.
        var index = state.debug_state.collisions.items.len;
        while (index > 0) {
            index -= 1;

            const show_time: u64 = 1;
            const collision = state.debug_state.collisions.items[index];
            if (state.time > collision.time_added + show_time) {
                _ = state.debug_state.collisions.swapRemove(index);
            } else {
                const time_remaining: u64 = ((collision.time_added + show_time) - state.time) / show_time;
                const color: Color = .{ 255, 128, 0, @intCast(255 * time_remaining) };
                drawDebugCollider(
                    state.renderer,
                    collision.collision.other,
                    color,
                    0.01 * @as(f32, @floatFromInt(time_remaining)),
                );
            }
        }
    }

    // Highlight the currently hovered entity.
    if (!state.debug_state.show_level_editor) {
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
        const process_args = if (PLATFORM == .windows) [_][]const u8{
            // "Aseprite.exe",
            "explorer.exe",
            sprite.asset.path,
            // ".\\assets\\test.aseprite",
        } else [_][]const u8{
            "open",
            sprite.asset.path,
        };

        var aseprite_process = std.process.Child.init(&process_args, state.allocator);
        aseprite_process.spawn() catch |err| {
            std.debug.print("Error spawning process: {}\n", .{err});
        };
    }
}

fn getHoveredEntity(state: *State) ?*ecs.Entity {
    var result: ?*ecs.Entity = null;

    for (state.transforms.items) |transform| {
        if (transform.containsPoint(state.debug_state.input.mouse_position / @as(Vector2, @splat(state.world_scale)))) {
            result = transform.entity;
            break;
        }
    }

    return result;
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

