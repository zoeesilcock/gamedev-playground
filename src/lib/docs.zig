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
//!
//! // Integrate Flint.
//! const result = flint.integrate(b, .{
//!     .dependency = b.dependency("flint", .{ .target = target, .optimize = optimize }),
//!     .target = target,
//!     .optimize = optimize,
//!     .build_options = b.addOptions(),
//!     .name = b.option([]const u8, "name", "name of the shared library") orelse "your_lib_name",
//!     .internal = b.option(bool, "internal", "include debug interface") orelse true,
//!     .lib_only = b.option(bool, "lib_only", "only build the shared library") orelse false,
//! });
//!
//! // Game library.
//! const module = b.createModule(.{
//!     .root_source_file = b.path("src/root.zig"),
//!     .target = target,
//!     .optimize = optimize,
//! });
//! module.addImport("build_options", result.build_options_mod);
//! module.addImport("flint", result.flint_mod);
//!
//! // Build the game as a dynamic library.
//! const lib = b.addLibrary(.{
//!     .name = "your_lib_name",
//!     .linkage = .dynamic,
//!     .root_module = module,
//! });
//! b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);
//!
//! if (result.exe) |exe| {
//!     b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
//! }
//! ```
//! * The `build_options` field accepts a `*std.Build.Step.Options`. You can add your own
//!   custom options to it before passing it to `integrate`. Flint will add its required
//!   options (`internal` and `name`) and create the module for you:
//! ```
//! const build_options = b.addOptions();
//! build_options.addOption(bool, "my_custom_flag", true);
//!
//! const result = flint.integrate(b, .{
//!     // ...
//!     .build_options = build_options,
//! });
//! ```
//! * The `internal` option decides if things like inspectors, editors, debug visualizations,
//!   and such will be included in the build. This aims to be the main way of defining whether
//!   a build is meant for internal testing or for release. Import it into your own code like this:
//!     ```
//!     const INTERNAL: bool = @import("build_options").internal;
//!     ```
//! * See `src/examples/template/build.zig` for a complete example.
pub const sdl = @import("sdl.zig");
pub const fs = @import("fs.zig");
pub const aseprite = @import("aseprite.zig");
pub const imgui = @import("imgui.zig");
pub const internal = @import("internal.zig");

pub const GameLib = @import("GameLib.zig");
