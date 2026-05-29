//! These structs are used for the build integration.
const std = @import("std");

/// This struct defines the options that need to be passed to the `integrate` function.
pub const IntegrateOptions = struct {
    dependency: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
    internal: bool = true,
    name: []const u8 = "game",
    lib_only: bool = false,
    skip_run_step: bool = false,
    install_step: *std.Build.Step,
    dest_dir: std.Build.Step.InstallArtifact.Options.Dir = .default,
};

/// This struct contains the results of the `integrate` function.
pub const IntegrateResult = struct {
    flint_mod: *std.Build.Module,
    exe: ?*std.Build.Step.Compile,
    build_options_mod: *std.Build.Module,
};
