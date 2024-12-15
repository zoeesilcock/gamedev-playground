const r = @import("dependencies/raylib.zig");
const aseprite = @import("aseprite.zig");

pub const TransformComponent = struct {
    entity: *Entity,

    position: r.Vector2,
    size: r.Vector2,
};

pub const SpriteComponent = struct {
    entity: *Entity,

    texture: r.Texture,
    document: aseprite.AseDocument,
};

pub const Entity = struct {
    transform: ?*TransformComponent,
    sprite: ?*SpriteComponent,
};
