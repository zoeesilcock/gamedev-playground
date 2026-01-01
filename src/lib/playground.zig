//! This is the "playground" module that is exposed by gamedev-playground which contains various building blocks that
//! can be imported into your game to serve as a basis for your game engine.
//!
//! ## Integrating
//! * See the examples for complete integrations.
//! * Add gamedev_playground as a dependency in your `build.zig.zon` file.
//! * Add the following to your `build.zig` file (lib is your game library, module is the root module of that library):
//! ```
//! const playground_dep = b.dependency("gamedev_playground", .{
//!     .target = target,
//!     .optimize = optimize,
//! });
//! const playground_mod = playground_dep.module("playground");
//! module.addImport("playground", playground_mod);
//! gamedev_playground.linkSDL(playground_dep.builder, lib, target, optimize);
//!
//! if (!lib_only) {
//!     const exe = gamedev_playground.buildExecutable(
//!         playground_dep.builder,
//!         b,
//!         "YOUR_EXECUTABLE_NAME",
//!         build_options,
//!         target,
//!         optimize,
//!         playground_mod,
//!     );
//!     b.installArtifact(exe);
//! }
//! ```
const std = @import("std");

pub const sdl = @import("sdl.zig");
pub const imgui = @import("imgui.zig");
pub const internal = @import("internal.zig");
pub const aseprite = @import("aseprite.zig");

test {
    std.testing.refAllDecls(@This());
}
