//! This is the "playground" module that is exposed by gamedev-playground which contains various building blocks that
//! can be imported into your game to serve as a basis for your game engine.
//!
//! ## Integrating
//! * Add gamedev-playground as a dependency in your `build.zig.zon` file by running:
//! ```
//! zig fetch --save git+https://github.com/zoeesilcock/gamedev-playground.git
//! ```
//! * Add the following to your `build.zig` file:
//! ```
//! const target = b.standardTargetOptions(.{});
//! const optimize = b.standardOptimizeOption(.{});
//! const internal = b.option(bool, "internal", "include debug interface") orelse true;
//! const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "diamonds";
//! const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
//!
//! const build_options = b.addOptions();
//! build_options.addOption(bool, "internal", internal);
//! build_options.addOption([]const u8, "lib_base_name", lib_base_name);
//!
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
//!     * **internal**: a boolean that decides if things like inspectors, editors, debug visualizations, and such will
//!     be included in the build. This aims to be the main way of defining whether a build is meant for internal
//!     testing or for release. Import it into your own code like this:
//!     ```
//!     const INTERNAL: bool = @import("build_options").internal;
//!     ```
//!     * **lib_base_name**: a string which decides the name of the dynamic library that the executable will look for.
//! * See the examples for complete integrations.
pub const sdl = @import("sdl.zig");
pub const imgui = @import("imgui.zig");
pub const aseprite = @import("aseprite.zig");
pub const internal = @import("internal.zig");

pub const GameLib = @import("GameLib.zig");
