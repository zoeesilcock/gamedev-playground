//! This is the "playground" module that is exposed by gamedev-playground which contains various building blocks that
//! can be imported into your game to serve as a basis for your game engine.
//!
//! ## Integrating
//! * Add gamedev_playground as a dependency in your `build.zig.zon` file.
//! * Add the following to your `build.zig` file:
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
//! * In this example `lib` is your game library, and `module` is the root module of that library.
//! * The `build_options` passed to `buildExecutable` need to include the following options:
//!     * **internal**: a boolean which decides if imgui will be included in the build.
//!     * **lib_base_name**: a string which decides the name of the dynamic library that the executable will look for.
//! * See the examples for complete integrations.
const std = @import("std");

pub const sdl = @import("sdl.zig");
pub const imgui = @import("imgui.zig");
pub const internal = @import("internal.zig");
pub const aseprite = @import("aseprite.zig");

pub const GameLib = @import("GameLib.zig");

test {
    std.testing.refAllDecls(@This());
}
