const std = @import("std");
const sdl = @import("sdl").c;
const game = @import("root.zig");
const math = @import("math");
const aseprite = @import("aseprite");
const pool = @import("pool");

const Color = math.Color;
const Vector2 = math.Vector2;
const X = math.X;
const Y = math.Y;

// TODO: Remove once Zig has finished migrating to unmanaged-style containers.
const ArrayList = std.ArrayListUnmanaged;
const PoolId = pool.PoolId;

pub const EntityType = enum(u8) {
    Background,
    Ball,
    Wall,
};

pub const EntityId = struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub fn equals(self: EntityId, other: ?EntityId) bool {
        return other != null and
            self.index == other.?.index and
            self.generation == other.?.generation;
    }
};

pub const Entity = struct {
    id: EntityId = .{},
    is_in_use: bool = false,
    entity_type: EntityType = .Background,

    transform: ?*TransformComponent = null,
    collider: ?*ColliderComponent = null,
    sprite: ?*SpriteComponent = null,
    color: ?*ColorComponent = null,
    block: ?*BlockComponent = null,
    title: ?*TitleComponent = null,
    tween: ?*TweenComponent = null,

    pub fn init(allocator: std.mem.Allocator) !*Entity {
        var entity = try allocator.create(Entity);
        entity.* = .{};
        return entity;
    }
};

pub const EntityIterator = struct {
    entities: *ArrayList(*Entity),
    index: usize = 0,

    /// Iterate over entities that are in use and have all requested components.
    /// Example: iter.next(&.{ .transform, .collider })
    pub fn next(self: *EntityIterator, comptime with_components: []const @TypeOf(.EnumLiteral)) ?*Entity {
        const items = self.entities.items;
        while (self.index < items.len) : (self.index += 1) {
            const e = items[self.index];
            if (!e.is_in_use) continue;

            var ok = true;
            inline for (with_components) |component| {
                if (@field(e.*, @tagName(component)) == null) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                self.index += 1; // advance past current
                return e;
            }
        }
        return null;
    }

    pub fn reset(self: *EntityIterator) void {
        self.index = 0;
    }
};

pub const TransformComponent = struct {
    pool_id: PoolId,
    entity: *Entity,

    position: Vector2 = .{ 0, 0 },
    scale: Vector2 = .{ 1, 1 },
    velocity: Vector2 = .{ 0, 0 },
    next_velocity: Vector2 = .{ 0, 0 }, // optional staging if you use physics integrators

    pub fn tick(iter: *EntityIterator, delta_time: f32) void {
        const dt = @as(Vector2, @splat(delta_time));
        while (iter.next(&.{ .transform })) |e| {
            const t = e.transform.?;
            t.position += t.velocity * dt;
        }
    }
};

const ColliderShape = enum {
    Square,
    Circle,
};

pub const CollisionResult = struct {
    vertical: ?Collision = null,
    horizontal: ?Collision = null,
};

pub const Collision = struct {
    id: EntityId,
    other_id: EntityId,
};

pub const ColliderComponent = struct {
    pool_id: PoolId,
    entity: *Entity,

    /// local-space offset from entity.transform.position
    offset: Vector2 = .{ 0, 0 },
    size: Vector2 = .{ 0, 0 }, // for squares
    radius: f32 = 0,           // for circles
    shape: ColliderShape = .Square,

    inline fn top(self: *const ColliderComponent) f32 { return self.offset[Y]; }
    inline fn left(self: *const ColliderComponent) f32 { return self.offset[X]; }

    inline fn bottom(self: *const ColliderComponent) f32 {
        return switch (self.shape) {
            .Square => self.offset[Y] + self.size[Y],
            .Circle => self.offset[Y] + self.radius * 2,
        };
    }

    inline fn right(self: *const ColliderComponent) f32 {
        return switch (self.shape) {
            .Square => self.offset[X] + self.size[X],
            .Circle => self.offset[X] + self.radius * 2,
        };
    }

    pub fn center(self: *const ColliderComponent, transform: *const TransformComponent) Vector2 {
        return switch (self.shape) {
            .Square => .{
                transform.position[X] + self.offset[X] + self.size[X] * 0.5,
                transform.position[Y] + self.offset[Y] + self.size[Y] * 0.5,
            },
            .Circle => .{
                transform.position[X] + self.offset[X] + self.radius,
                transform.position[Y] + self.offset[Y] + self.radius,
            },
        };
    }

    pub fn containsPoint(self: *const ColliderComponent, point: Vector2) bool {
        var pos: Vector2 = .{ 0, 0 };
        if (self.entity.transform) |t| pos = t.position;

        const l = pos[X] + self.left();
        const r = pos[X] + self.right();
        const t = pos[Y] + self.top();
        const b = pos[Y] + self.bottom();

        return point[X] >= l and point[X] <= r and point[Y] >= t and point[Y] <= b;
    }

    fn aabbOverlap(a_l: f32, a_r: f32, a_t: f32, a_b: f32, b_l: f32, b_r: f32, b_t: f32, b_b: f32) bool {
        // Canonical AABB overlap test
        return (a_l < b_r and a_r > b_l and a_t < b_b and a_b > b_t);
    }

    fn collidesWithAnyAt(self: *ColliderComponent, iter: *EntityIterator, at: TransformComponent) ?*Entity {
        var inner = iter.*;
        while (inner.next(&.{ .collider })) |other| {
            if (self.entity == other) continue;
            if (self.collidesWithAt(other.collider.?, at)) return other;
        }
        return null;
    }

    pub fn collidesWithAt(self: *ColliderComponent, other: *ColliderComponent, at: TransformComponent) bool {
        if (other.entity.transform == null) return false;

        const other_t = other.entity.transform.?;

        // Same-shape fast paths
        if (self.shape == other.shape) {
            switch (self.shape) {
                .Square => {
                    const a_l = at.position[X] + self.left();
                    const a_r = at.position[X] + self.right();
                    const a_t = at.position[Y] + self.top();
                    const a_b = at.position[Y] + self.bottom();

                    const b_l = other_t.position[X] + other.left();
                    const b_r = other_t.position[X] + other.right();
                    const b_t = other_t.position[Y] + other.top();
                    const b_b = other_t.position[Y] + other.bottom();

                    return aabbOverlap(a_l, a_r, a_t, a_b, b_l, b_r, b_t, b_b);
                },
                .Circle => {
                    // Circle–circle not currently used in your code; add if needed.
                    // Placeholder: treat as bounding squares
                    const a_l = at.position[X] + self.left();
                    const a_r = at.position[X] + self.right();
                    const a_t = at.position[Y] + self.top();
                    const a_b = at.position[Y] + self.bottom();

                    const b_l = other_t.position[X] + other.left();
                    const b_r = other_t.position[X] + other.right();
                    const b_t = other_t.position[Y] + other.top();
                    const b_b = other_t.position[Y] + other.bottom();

                    return aabbOverlap(a_l, a_r, a_t, a_b, b_l, b_r, b_t, b_b);
                },
            }
        }

        // Mixed circle–square
        var circle_col: *const ColliderComponent = undefined;
        var circle_t: *const TransformComponent = undefined;
        var r: f32 = 0;

        var square_col: *const ColliderComponent = undefined;
        var square_t: *const TransformComponent = undefined;

        if (self.shape == .Circle) {
            circle_col = self;
            circle_t = &at;
            r = self.radius;
            square_col = other;
            square_t = other_t;
        } else if (other.shape == .Circle) {
            circle_col = other;
            circle_t = other_t;
            r = other.radius;
            square_col = self;
            square_t = &at;
        } else unreachable;

        const c = circle_col.center(circle_t);
        const s_l = square_t.position[X] + square_col.left();
        const s_r = square_t.position[X] + square_col.right();
        const s_t = square_t.position[Y] + square_col.top();
        const s_b = square_t.position[Y] + square_col.bottom();

        const closest_x = std.math.clamp(c[X], s_l, s_r);
        const closest_y = std.math.clamp(c[Y], s_t, s_b);
        const dx = c[X] - closest_x;
        const dy = c[Y] - closest_y;
        const dist2 = dx * dx + dy * dy;

        return dist2 < r * r;
    }

    /// Returns at most one vertical and one horizontal collision for moving entities.
    pub fn checkForCollisions(iter: *EntityIterator, delta_time: f32) CollisionResult {
        var result: CollisionResult = .{};
        var inner_iter: EntityIterator = iter.*;

        while (iter.next(&.{ .collider, .transform })) |e| {
            const t = e.transform.?;

            // Y sweep
            if (t.velocity[Y] != 0) {
                var next_t = t.*;
                next_t.position[Y] += next_t.velocity[Y] * delta_time;
                inner_iter.reset();
                if (e.collider.?.collidesWithAnyAt(&inner_iter, next_t)) |o| {
                    result.vertical = .{ .id = e.id, .other_id = o.id };
                }
            }

            // X sweep
            if (t.velocity[X] != 0) {
                var next_t = t.*;
                next_t.position[X] += next_t.velocity[X] * delta_time;
                inner_iter.reset();
                if (e.collider.?.collidesWithAnyAt(&inner_iter, next_t)) |o| {
                    result.horizontal = .{ .id = e.id, .other_id = o.id };
                }
            }
        }

        return result;
    }
};

pub const SpriteComponent = struct {
    pool_id: PoolId,
    entity: *Entity,

    frame_index: u32 = 0,
    tint: Color = .{ 255, 255, 255, 255 },
    duration_shown: f32 = 0,
    loop_animation: bool = true,
    animation_completed: bool = false,
    current_animation: ?*aseprite.AseTagsChunk = null,

    pub fn tick(assets: *game.Assets, iter: *EntityIterator, delta_time: f32) void {
        while (iter.next(&.{ .sprite })) |e| {
            const s = e.sprite.?;
            if (assets.getSpriteAsset(s)) |sprite_asset| {
                const frames_len = sprite_asset.document.frames.len;
                if (frames_len <= 1) continue;

                const current_frame = sprite_asset.document.frames[s.frame_index];

                var from_frame: u16 = 0;
                var to_frame: u16 = @intCast(frames_len - 1);
                if (s.current_animation) |tag| {
                    from_frame = tag.from_frame;
                    to_frame = tag.to_frame;
                }

                s.duration_shown += delta_time;

                // frame_duration is in milliseconds
                const need_ms = @as(f32, @floatFromInt(current_frame.header.frame_duration));
                const have_ms = s.duration_shown * 1000.0;
                if (have_ms >= need_ms) {
                    s.duration_shown = 0;
                    var next_frame = s.frame_index + 1;

                    if (next_frame > to_frame) {
                        if (s.loop_animation) {
                            next_frame = from_frame;
                        } else {
                            s.animation_completed = true;
                            next_frame = to_frame;
                        }
                    }

                    s.setFrame(next_frame, sprite_asset);
                }
            }
        }
    }

    pub fn setFrame(self: *SpriteComponent, index: u32, sprite_asset: *game.SpriteAsset) void {
        if (index < sprite_asset.document.frames.len) {
            self.frame_index = index;
            self.duration_shown = 0;
        }
    }

    pub fn getTexture(self: *SpriteComponent, assets: *game.Assets) ?*sdl.SDL_Texture {
        if (assets.getSpriteAsset(self)) |sa| {
            if (self.frame_index < sa.frames.len) return sa.frames[self.frame_index];
        }
        return null;
    }

    pub fn startAnimation(self: *SpriteComponent, name: []const u8, assets: *game.Assets) void {
        var found: ?*aseprite.AseTagsChunk = null;

        if (assets.getSpriteAsset(self)) |sa| {
            // NOTE: If your aseprite binding exposes tags separate from frames,
            // prefer iterating that table. This loop stays backward compatible.
            outer: for (sa.document.frames) |frame| {
                for (frame.tags) |tag| {
                    if (std.mem.eql(u8, tag.tag_name, name)) {
                        found = tag;
                        break :outer;
                    }
                }
            }

            if (found) |tag| {
                self.current_animation = tag;
                self.loop_animation = false;
                self.animation_completed = false;
                self.setFrame(tag.from_frame, sa);
            }
        }
    }

    pub fn isAnimating(self: *SpriteComponent, name: []const u8) bool {
        return if (self.current_animation) |tag| std.mem.eql(u8, name, tag.tag_name) else false;
    }

    pub fn containsPoint(
        self: *const SpriteComponent,
        point: Vector2,
        dest_rect: sdl.SDL_FRect,
        world_scale: f32,
        assets: *game.Assets,
    ) bool {
        if (assets.getSpriteAsset(self)) |sa| {
            var pos: Vector2 = .{ 0, 0 };
            if (self.entity.title) |title| {
                pos = title.getPosition(dest_rect, world_scale, assets);
            } else if (self.entity.transform) |t| {
                pos = t.position;
            }

            const width: f32 = @floatFromInt(sa.document.header.width);
            const height: f32 = @floatFromInt(sa.document.header.height);

            return point[X] >= pos[X] and point[X] <= pos[X] + width and
                   point[Y] >= pos[Y] and point[Y] <= pos[Y] + height;
        }
        return false;
    }
};

pub const ColorComponentValue = enum {
    Gray,
    Red,
    Blue,
};

pub const ColorComponent = struct {
    pool_id: PoolId,
    entity: *Entity,

    color: ColorComponentValue = .Gray,
};

pub const BlockType = enum {
    Wall,
    Deadly,
    ColorChange,
};

pub const BlockComponent = struct {
    pool_id: PoolId,
    entity: *Entity,

    type: BlockType = .Wall,
};

pub const TitleType = enum {
    PAUSED,
    GET_READY,
    CLEARED,
    DEATH,
    GAME_OVER,
};

pub const TitleComponent = struct {
    pool_id: PoolId,
    entity: *Entity,

    type: TitleType = .GET_READY,
    has_duration: bool = false,
    duration_remaining: u64 = 0,

    pub fn getPosition(
        self: *const TitleComponent,
        dest_rect: sdl.SDL_FRect,
        world_scale: f32,
        assets: *game.Assets,
    ) Vector2 {
        var result: Vector2 = @splat(0);
        const half: Vector2 = @splat(0.5);
        const scale: Vector2 = @splat(world_scale);

        if (self.entity.sprite) |sprite| {
            if (sprite.getTexture(assets)) |texture| {
                // If your SDL binding requires SDL_QueryTexture, adapt here.
                const size: Vector2 = .{ @as(f32, @floatFromInt(texture.w)), @as(f32, @floatFromInt(texture.h)) };
                result = Vector2{ dest_rect.w, dest_rect.h } / scale - size;
                result *= half;
                if (self.entity.transform) |t| result += t.position;
            }
        }
        return result;
    }
};

pub const TweenEasing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,

    fn apply(e: TweenEasing, t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        return switch (e) {
            .linear => clamped,
            .ease_in => clamped * clamped,
            .ease_out => 1.0 - (1.0 - clamped) * (1.0 - clamped),
            .ease_in_out => if (clamped < 0.5)
                2.0 * clamped * clamped
            else
                1.0 - std.math.pow(f32, -2.0 * clamped + 2.0, 2.0) / 2.0,
        };
    }
};

pub const TweenedValue = union(enum) {
    f32: f32,
    color: Color,
};

pub const TweenComponent = struct {
    pool_id: PoolId,
    entity: *Entity,

    delay: u64 = 0,      // ms
    duration: u64 = 0,   // ms
    time_passed: u64 = 0,

    easing: TweenEasing = .linear,

    target: EntityId = .{},
    target_component: []const u8 = "",
    target_field: []const u8 = "",

    start_value: TweenedValue = .{ .f32 = 0 },
    end_value: TweenedValue = .{ .f32 = 1 },

    // --- Bound target (resolved once) ---
    bound_f32: ?*f32 = null,
    bound_color: ?*Color = null,
    bound_ready: bool = false,

    pub fn tick(state: *game.State, iter: *EntityIterator, delta_time: f32) void {
        while (iter.next(&.{ .tween })) |e| {
            const tw = e.tween.?;

            // One-time bind of the target pointer (no per-frame reflection scans).
            if (!tw.bound_ready) {
                tw.bound_ready = tw.bind(state);
            }
            if (!tw.bound_ready) continue;

            // Advance time with saturation
            const add_ms: u64 = @intFromFloat(std.math.max(0.0, delta_time) * 1000.0);
            if (std.math.addo(u64, tw.time_passed, add_ms)) |_| {
                tw.time_passed = std.math.maxInt(u64); // saturate
            } else {
                tw.time_passed += add_ms;
            }

            const total = tw.delay + tw.duration;
            if (total == 0) continue;

            if (tw.time_passed < tw.delay) continue;

            const raw_t = @as(f32, @floatFromInt(tw.time_passed - tw.delay)) /
                          @as(f32, @floatFromInt(tw.duration));
            const t = tw.easing.apply(raw_t);

            switch (tw.start_value) {
                .f32 => {
                    const a = tw.start_value.f32;
                    const b = tw.end_value.f32;
                    if (tw.bound_f32) |p| p.* = lerpf(a, b, t);
                },
                .color => {
                    const a = tw.start_value.color;
                    const b = tw.end_value.color;
                    if (tw.bound_color) |p| {
                        p.* = .{
                            lerpU8(a[0], b[0], t),
                            lerpU8(a[1], b[1], t),
                            lerpU8(a[2], b[2], t),
                            lerpU8(a[3], b[3], t),
                        };
                    }
                },
            }
        }
    }

    /// Resolve the target pointer once using your field names.
    fn bind(self: *TweenComponent, state: *game.State) bool {
        if (state.getEntity(self.target)) |target| {
            const ent_info = @typeInfo(Entity);
            inline for (ent_info.@"struct".fields) |entity_field_info| {
                if (!std.mem.eql(u8, entity_field_info.name, self.target_component)) continue;

                const entity_field = @field(target, entity_field_info.name);
                if (@typeInfo(@TypeOf(entity_field)) != .optional) break;

                if (entity_field) |component| {
                    const comp_info = @typeInfo(@TypeOf(component.*));
                    inline for (comp_info.@"struct".fields) |comp_field_info| {
                        if (!std.mem.eql(u8, comp_field_info.name, self.target_field)) continue;

                        // Type-directed binding
                        const ptr_any = &@field(component, comp_field_info.name);
                        switch (@TypeOf(ptr_any)) {
                            *f32 => {
                                self.bound_f32 = ptr_any;
                                self.bound_color = null;
                                return true;
                            },
                            *Color => {
                                self.bound_color = ptr_any;
                                self.bound_f32 = null;
                                return true;
                            },
                            else => return false,
                        }
                    }
                }
            }
        }
        return false;
    }
};

inline fn lerpf(a: f32, b: f32, t: f32) f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return (1.0 - clamped) * a + clamped * b;
}

inline fn lerpU8(min: u8, max: u8, t: f32) u8 {
    return @intFromFloat(lerpf(@floatFromInt(min), @floatFromInt(max), t));
}
