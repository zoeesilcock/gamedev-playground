//! This is the "flint" module that is exposed by flint which contains various building blocks that
//! can be imported into your game to serve as a basis for your game engine.
//!
//! ## Integrating
//! * Add flint as a dependency in your `build.zig.zon` file by running:
//! ```
//! zig fetch --save git+https://github.com/zoeesilcock/flint.git#v0.10.0
//! ```
//! * Add the following to your `build.zig` file:
//! ```
//! const flint = @import("flint");
//!
//! const target = b.standardTargetOptions(.{});
//! const optimize = b.standardOptimizeOption(.{});
//! const internal = b.option(bool, "internal", "include debug interface") orelse true;
//! const lib_base_name = b.option([]const u8, "lib_base_name", "name of the shared library") orelse "diamonds";
//! const lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false;
//!
//! const build_options = b.addOptions();
//! build_options.addOption(bool, "internal", internal);
//! build_options.addOption([]const u8, "lib_base_name", lib_base_name);
//! const build_options_mod = build_options.createModule();
//!
//! // Game library.
//! // Build your game library here...
//!
//! // Integrate Flint.
//! const flint_dep = b.dependency("flint", .{
//!     .target = target,
//!     .optimize = optimize,
//! });
//! const flint_mod = flint_dep.module("flint");
//! flint_mod.addImport("build_options", build_options_mod);
//! module.addImport("flint", flint_mod);
//! flint.linkSDL(flint_dep.builder, b, lib, target, optimize, b.getInstallStep());
//!
//! if (!lib_only) {
//!     const exe = flint.buildExecutable(
//!         flint_dep.builder,
//!         b,
//!         "template",
//!         build_options_mod,
//!         target,
//!         optimize,
//!         flint_mod,
//!         b.getInstallStep(),
//!     );
//!     b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
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
//! * See `src/examples/template/build.zig` for a complete example.
pub const sdl = @import("sdl.zig");
pub const imgui = @import("imgui.zig");
pub const aseprite = @import("aseprite.zig");
pub const internal = @import("internal.zig");

pub const GameLib = @import("GameLib.zig");
