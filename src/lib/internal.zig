//! Exposes tools used in internal builds, things like inspectors, editors and information overlays.
//!
//! Note that importing this module without the INTERNAL build_option set to true will give an empty struct. The point
//! of this is to make it a compile time error to use any internal functions in a release version.
//! This is implemented in `flint.zig`.

const std = @import("std");
const imgui = @import("imgui.zig").c;

const DebugAllocator = @import("GameLib.zig").DebugAllocator;

/// This window displays a rolling average of frame times over the last 300 frames.
pub const FPSWindow = struct {
    current_frame_index: u32,
    performance_frequency: u64,
    frame_times: [MAX_FRAME_TIME_COUNT]u64,
    average: f32,
    display_mode: FPSDisplayMode,
    position: imgui.ImVec2,

    const MAX_FRAME_TIME_COUNT: u32 = 300;

    pub const FPSDisplayMode = enum {
        None,
        Number,
        NumberAndGraph,
    };

    pub fn init(self: *FPSWindow, frequency: u64) void {
        self.current_frame_index = 0;
        self.performance_frequency = frequency;
        self.frame_times = @splat(0);
        self.average = 0;
        self.display_mode = .Number;
        self.position = imgui.ImVec2{ .x = 5, .y = 5 };
    }

    /// Cycle through the display modes, see `FPSWindow.FPSDisplayMode`.
    pub fn cycleMode(self: *FPSWindow) void {
        var mode: u32 = @intFromEnum(self.display_mode) + 1;
        if (mode >= @typeInfo(FPSDisplayMode).@"enum".field_names.len) {
            mode = 0;
        }
        self.display_mode = @enumFromInt(mode);
    }

    fn getPreviousFrameIndex(frame_index: u32) u32 {
        var previous_frame_index: u32 = frame_index -% 1;
        if (previous_frame_index > MAX_FRAME_TIME_COUNT) {
            previous_frame_index = MAX_FRAME_TIME_COUNT - 1;
        }
        return previous_frame_index;
    }

    fn getFrameTime(self: *FPSWindow, frame_index: u32) f32 {
        var elapsed: u64 = 0;
        const previous_frame_index = getPreviousFrameIndex(frame_index);

        const current_frame = self.frame_times[frame_index];
        const previous_frame = self.frame_times[previous_frame_index];
        if (current_frame > 0 and previous_frame > 0 and current_frame > previous_frame) {
            elapsed = current_frame - previous_frame;
        }

        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.performance_frequency));
    }

    /// Call this on every frame with the current time from `SDL_GetPerformanceCounter`.
    pub fn addFrameTime(self: *FPSWindow, frame_time: u64) void {
        self.current_frame_index += 1;
        if (self.current_frame_index >= MAX_FRAME_TIME_COUNT) {
            self.current_frame_index = 0;
        }
        self.frame_times[self.current_frame_index] = frame_time;

        var average: f32 = 0;
        for (0..MAX_FRAME_TIME_COUNT) |i| {
            average += self.getFrameTime(@intCast(i));
        }
        self.average = 1 / (average / @as(f32, @floatFromInt(MAX_FRAME_TIME_COUNT)));
    }

    /// Display the FPS window, call this function along with any other imgui drawing code.
    pub fn draw(self: *FPSWindow) void {
        if (self.display_mode != .None) {
            imgui.ImGui_SetNextWindowPosEx(self.position, 0, imgui.ImVec2{ .x = 0, .y = 0 });
            imgui.ImGui_SetNextWindowSize(imgui.ImVec2{ .x = 300, .y = 160 }, 0);

            _ = imgui.ImGui_Begin(
                "FPS",
                null,
                imgui.ImGuiWindowFlags_NoFocusOnAppearing |
                    imgui.ImGuiWindowFlags_NoMove |
                    imgui.ImGuiWindowFlags_NoResize |
                    imgui.ImGuiWindowFlags_NoBackground |
                    imgui.ImGuiWindowFlags_NoTitleBar |
                    imgui.ImGuiWindowFlags_NoMouseInputs,
            );

            imgui.ImGui_TextColored(
                imgui.ImVec4{ .x = 0, .y = 1, .z = 0, .w = 1 },
                "FPS: %.0f",
                self.average,
            );

            if (self.display_mode == .NumberAndGraph) {
                var timings: [MAX_FRAME_TIME_COUNT]f32 = @splat(0);
                var max_value: f32 = 0;
                for (0..MAX_FRAME_TIME_COUNT) |i| {
                    timings[i] = self.getFrameTime(@intCast(i));
                    if (timings[i] > max_value) {
                        max_value = timings[i];
                    }
                }
                imgui.ImGui_PlotHistogramEx(
                    "##FPS_Graph",
                    &timings,
                    timings.len,
                    0,
                    "",
                    0,
                    max_value,
                    imgui.ImVec2{ .x = 300, .y = 100 },
                    @sizeOf(f32),
                );
            }

            imgui.ImGui_End();
        }
    }
};

/// This window shows a graph of the memory allocations in the game allocator.
pub const MemoryUsageWindow = struct {
    const MAX_MEMORY_USAGE_COUNT: u32 = 1000;
    const MEMORY_USAGE_RECORD_INTERVAL: u64 = 16;

    memory_usage: [MAX_MEMORY_USAGE_COUNT]u64,
    memory_usage_current_index: u32,
    memory_usage_last_collected_at: u64,
    visible: bool,
    position: imgui.ImVec2,

    pub fn init(self: *MemoryUsageWindow) void {
        self.* = .{
            .memory_usage = @splat(0),
            .memory_usage_current_index = 0,
            .memory_usage_last_collected_at = 0,
            .visible = false,
            .position = imgui.ImVec2{ .x = 5, .y = 40 },
        };
    }

    pub fn recordMemoryUsage(self: *MemoryUsageWindow, time: u64, allocator: *DebugAllocator) void {
        if (self.memory_usage_last_collected_at + MEMORY_USAGE_RECORD_INTERVAL < time) {
            self.memory_usage_last_collected_at = time;
            self.memory_usage_current_index += 1;
            if (self.memory_usage_current_index >= MAX_MEMORY_USAGE_COUNT) {
                self.memory_usage_current_index = 0;
            }
            self.memory_usage[self.memory_usage_current_index] = allocator.total_requested_bytes;
        }
    }

    pub fn draw(self: *MemoryUsageWindow) void {
        if (self.visible) {
            imgui.ImGui_SetNextWindowPosEx(
                self.position,
                imgui.ImGuiCond_FirstUseEver,
                imgui.ImVec2{ .x = 0, .y = 0 },
            );

            _ = imgui.ImGui_Begin(
                "MemoryUsage",
                null,
                imgui.ImGuiWindowFlags_NoFocusOnAppearing |
                    imgui.ImGuiWindowFlags_NoNavFocus |
                    imgui.ImGuiWindowFlags_NoNavInputs,
            );
            defer imgui.ImGui_End();

            _ = imgui.ImGui_Text(
                "Bytes: %d",
                self.memory_usage[self.memory_usage_current_index],
            );

            var memory_usage: [MAX_MEMORY_USAGE_COUNT]f32 = @splat(0);
            var max_value: f32 = 0;
            var min_value: f32 = std.math.floatMax(f32);
            for (0..MAX_MEMORY_USAGE_COUNT) |i| {
                memory_usage[i] = @floatFromInt(self.memory_usage[i]);
                if (memory_usage[i] > max_value) {
                    max_value = memory_usage[i];
                }
                if (memory_usage[i] < min_value and memory_usage[i] > 0) {
                    min_value = memory_usage[i];
                }
            }
            var buf: [100]u8 = undefined;
            const min_text = std.fmt.bufPrintZ(&buf, "min: {d}", .{min_value}) catch "";
            imgui.ImGui_PlotHistogramEx(
                "##MemoryUsageGraph",
                &memory_usage,
                memory_usage.len,
                @intCast(self.memory_usage_current_index + 1),
                min_text.ptr,
                min_value,
                max_value,
                imgui.ImVec2{ .x = 300, .y = 100 },
                @sizeOf(f32),
            );
        }
    }
};

/// This window is used to print out arbitrary data at any point. Use the `print` and `printStruct` functions to append
/// to the output and then call the `draw` function in your imgui draw function.
pub const DebugOutputWindow = struct {
    allocator: *const std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    data: std.ArrayList([]const u8),
    size: imgui.ImVec2,
    position: imgui.ImVec2,

    pub fn init(self: *DebugOutputWindow, allocator: *const std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator.*),
            .data = .empty,
            .size = .{ .x = 300, .y = 50 },
            .position = .{ .x = 10, .y = 40 },
        };
    }

    pub fn deinit(self: *DebugOutputWindow) void {
        self.data.clearRetainingCapacity();
        self.arena.deinit();
    }

    /// Display the debug output window, call this function along with any other imgui drawing code. The window will
    /// only be displayed if there is any data in the array. Data is cleared and memory is freed after every draw.
    pub fn draw(self: *DebugOutputWindow) void {
        if (self.data.items.len > 0) {
            imgui.ImGui_SetNextWindowPosEx(
                self.position,
                imgui.ImGuiCond_FirstUseEver,
                imgui.ImVec2{ .x = 0, .y = 0 },
            );
            imgui.ImGui_SetNextWindowSize(self.size, imgui.ImGuiCond_FirstUseEver);

            _ = imgui.ImGui_Begin("Debug output", null, imgui.ImGuiWindowFlags_NoFocusOnAppearing);
            defer imgui.ImGui_End();

            for (self.data.items) |line| {
                imgui.ImGui_TextWrapped("%s", @as([*:0]const u8, @ptrCast(line)));
            }
        }

        self.deinit();
        self.init(self.allocator);
    }

    /// Print out a string using the familiar fmt + args approach.
    pub fn print(
        self: *DebugOutputWindow,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.data.append(
            self.arena.allocator(),
            std.fmt.allocPrintSentinel(self.arena.allocator(), fmt, args, 0x0) catch "",
        ) catch undefined;
    }

    /// Print out the contents of a struct. Either pass some struct you are interested in looking at or construct an
    /// anonymous struct containing specific values if you only want certain parts of a struct or parts of multiple
    /// different structs.
    pub fn printStruct(
        self: *DebugOutputWindow,
        message: []const u8,
        value: anytype,
    ) void {
        var allocating_writer = std.Io.Writer.Allocating.init(self.arena.allocator());
        var writer = &allocating_writer.writer;
        defer allocating_writer.deinit();

        writer.print("{s} ", .{message}) catch return;
        self.writeValue(value, writer) catch return;

        self.data.append(self.arena.allocator(), allocating_writer.toOwnedSliceSentinel(0x0) catch "") catch undefined;
    }

    fn writeValue(
        self: *DebugOutputWindow,
        value: anytype,
        writer: *std.Io.Writer,
    ) !void {
        const type_info = @typeInfo(@TypeOf(value));

        switch (type_info) {
            .@"struct" => |struct_info| {
                inline for (struct_info.field_names, 0..) |struct_field_name, i| {
                    try writer.print("{s}: ", .{struct_field_name});
                    try self.writeValue(@field(value, struct_field_name), writer);

                    if (i < struct_info.field_names.len - 1) {
                        try writer.print(", ", .{});
                    }
                }
            },
            .array => {
                try writer.print("[", .{});
                for (value, 0..) |item, i| {
                    try self.writeValue(item, writer);

                    if (i < value.len - 1) {
                        try writer.print(", ", .{});
                    }
                }
                try writer.print("]", .{});
            },
            .optional => {
                if (value) |unwrapped| {
                    try self.writeValue(unwrapped, writer);
                } else {
                    try writer.print("null", .{});
                }
            },
            .pointer => |pointer_info| {
                switch (pointer_info.size) {
                    .one, .slice => {
                        try writer.print("{s}", .{value});
                    },
                    .many, .c => {
                        try writer.print("{s}", .{std.mem.span(value)});
                    },
                }
            },
            .int, .float, .comptime_int, .comptime_float => {
                try writer.print("{d}", .{value});
            },
            .bool => {
                try writer.print("{s}", .{if (value) "true" else "false"});
            },
            .enum_literal => {
                try writer.print("{s}", .{@tagName(value)});
            },
            .error_set => {
                try writer.print("error.{t}", .{value});
            },
            .vector => |vector_info| {
                try writer.print("{{", .{});
                const array: [vector_info.len]vector_info.child = value;
                for (&array, 0..) |elem, i| {
                    try writer.print("{d}", .{elem});

                    if (i < vector_info.len - 1) {
                        try writer.print(", ", .{});
                    }
                }
                try writer.print("}}", .{});
            },
            else => try writer.print("unhandled data type ({s})", .{@tagName(type_info)}),
        }
    }
};

test "DebugOutputWindow can output a formatted string using the print function" {
    var output: DebugOutputWindow = undefined;
    output.init(&std.testing.allocator);

    output.print("This is a {s} that supports formatting: {d}", .{ "test", 0.5 });

    try std.testing.expectEqual(1, output.data.items.len);
    try std.testing.expectEqualSlices(u8, "This is a test that supports formatting: 0.5", output.data.items[0]);

    output.deinit();
    try std.testing.expectEqual(0, output.data.items.len);
}

test "DebugOutputWindow can output a text representation of an arbitrary struct using the printStruct function" {
    var output: DebugOutputWindow = undefined;
    output.init(&std.testing.allocator);

    output.printStruct("Title:", .{
        .string = "test",
        .number = 0.5,
        .vector = @as(@Vector(2, f32), .{ 1, 23 }),
        .boolean = true,
        .array = @as([2][]const u8, .{ "foo", "bar" }),
        .nested = .{ .hello = "world", .number = 3 },
        .enum_literal = .oh_hai,
        .err = error.ExampleError,
    });

    try std.testing.expectEqual(1, output.data.items.len);
    try std.testing.expectEqualSlices(
        u8,
        "Title: string: test, number: 0.5, vector: {1, 23}, boolean: true, array: [foo, bar], nested: hello: world, number: 3, enum_literal: oh_hai, err: error.ExampleError",
        output.data.items[0],
    );

    output.deinit();
    try std.testing.expectEqual(0, output.data.items.len);
}

test "DebugOutputWindow.printStruct handles optional types" {
    var output: DebugOutputWindow = undefined;
    output.init(&std.testing.allocator);

    const ExampleStruct = struct {
        optional_string: ?[]const u8,
        optional_number: ?f32,
    };

    output.printStruct("Null:", ExampleStruct{
        .optional_string = null,
        .optional_number = null,
    });
    output.printStruct("Values:", ExampleStruct{
        .optional_string = "Hello!",
        .optional_number = 42,
    });

    try std.testing.expectEqual(2, output.data.items.len);
    try std.testing.expectEqualSlices(
        u8,
        "Null: optional_string: null, optional_number: null",
        output.data.items[0],
    );
    try std.testing.expectEqualSlices(
        u8,
        "Values: optional_string: Hello!, optional_number: 42",
        output.data.items[1],
    );

    output.deinit();
    try std.testing.expectEqual(0, output.data.items.len);
}

/// Configuration for the field inputs generated by `inputStruct`. Use the helper functions to generate configs, making
/// them manually is pretty verbose.
const FieldConfig = struct {
    // This needs to match the name of the field in the struct being inspected.
    field_name: []const u8,
    // The configuration for the input used to edit the field.
    config: InputConfig,

    /// Generate a config that leads to an input field with +/- buttons for stepping.
    pub fn input(T: type, field_name: []const u8, step: T, step_fast: T) FieldConfig {
        return .{
            .field_name = field_name,
            .config = @unionInit(InputConfig, @typeName(T), .input(step, step_fast)),
        };
    }

    /// Generate a config that leads to a draggable field.
    pub fn drag(T: type, field_name: []const u8, step: T, min: T, max: T) FieldConfig {
        return .{
            .field_name = field_name,
            .config = @unionInit(InputConfig, @typeName(T), .drag(step, min, max)),
        };
    }

    /// Generate a config that leads to a slider between min/max.
    pub fn slider(T: type, field_name: []const u8, min: T, max: T) FieldConfig {
        return .{
            .field_name = field_name,
            .config = @unionInit(InputConfig, @typeName(T), .slider(min, max)),
        };
    }
};

const FieldDataTypes = enum {
    f32,
    f64,
    u32,
    i32,
    u64,
};

const InputConfig = union(FieldDataTypes) {
    f32: InputConfigType(f32),
    f64: InputConfigType(f64),
    u32: InputConfigType(u32),
    i32: InputConfigType(i32),
    u64: InputConfigType(u64),
};

const InputType = enum(u32) {
    Input,
    Drag,
    Slider,
};

/// Configuration for the field inputs generated by the `input**` functions. Use the helper functions to generate
/// configs, making them manually is pretty verbose.
fn InputConfigType(T: type) type {
    return struct {
        const Self = @This();

        input_type: InputType = .Input,
        step: T = switch (@typeInfo(T)) {
            .float => 0.1,
            .int => 1,
            else => @panic("Type must be int or float"),
        },
        step_fast: T = switch (@typeInfo(T)) {
            .float => 1,
            .int => 5,
            else => @panic("Type must be int or float"),
        },
        min: T = switch (@typeInfo(T)) {
            .float => std.math.floatMin(T),
            .int => std.math.minInt(T),
            else => @panic("Type must be int or float"),
        },
        max: T = switch (@typeInfo(T)) {
            .float => std.math.floatMax(T),
            .int => std.math.maxInt(T),
            else => @panic("Type must be int or float"),
        },

        /// Generate a config that leads to an input field with +/- buttons for stepping.
        pub fn input(step: T, step_fast: T) Self {
            return .{
                .input_type = .Input,
                .step = step,
                .step_fast = step_fast,
            };
        }

        /// Generate a config that leads to a draggable field.
        pub fn drag(step: T, min: T, max: T) Self {
            return .{
                .input_type = .Drag,
                .step = step,
                .min = min,
                .max = max,
            };
        }

        /// Generate a config that leads to a slider between min/max.
        pub fn slider(min: T, max: T) Self {
            return .{
                .input_type = .Slider,
                .min = min,
                .max = max,
            };
        }
    };
}

fn getFieldConfig(
    comptime inner_type: type,
    comptime field_configs: []const FieldConfig,
    comptime field_name: []const u8,
) InputConfig {
    comptime var result: InputConfig = @unionInit(InputConfig, @typeName(inner_type), .{});
    comptime {
        for (field_configs) |field_config| {
            if (std.mem.eql(u8, field_config.field_name, field_name)) {
                result = field_config.config;
                break;
            }
        }
    }
    return result;
}

/// Allows you to generate custom imgui inputs for any types or fields. If you return true from this function the
/// inspector won't generate it's own input for the field.
pub const handleCustomTypesFn = ?*const fn (
    struct_field_name: [:0]const u8,
    field_ptr: anytype,
) bool;

/// Generates imgui inputs for all fields on a struct.
pub fn inspectStruct(
    struct_ptr: anytype,
    comptime ignored_fields: []const []const u8,
    expand_sections: bool,
    comptime field_configs: []const FieldConfig,
    /// Function pointer which allows you to handle specific fields manually, see `handleCustomTypesFn`.
    comptime opt_handle_custom_types: handleCustomTypesFn,
) void {
    switch (@typeInfo(@TypeOf(struct_ptr))) {
        .optional => {
            if (struct_ptr) |ptr| {
                inspectStructInternal(ptr, ignored_fields, expand_sections, field_configs, opt_handle_custom_types);
            }
        },
        else => {
            inspectStructInternal(struct_ptr, ignored_fields, expand_sections, field_configs, opt_handle_custom_types);
        },
    }
}

fn inspectStructInternal(
    struct_ptr: anytype,
    comptime ignored_fields: []const []const u8,
    expand_sections: bool,
    comptime field_configs: []const FieldConfig,
    comptime opt_handle_custom_types: handleCustomTypesFn,
) void {
    const struct_info = @typeInfo(@TypeOf(struct_ptr.*));
    switch (struct_info) {
        .@"struct" => {
            inline for (struct_info.@"struct".field_names) |struct_field_name| {
                comptime var skip_field = false;
                comptime {
                    for (ignored_fields) |ignored| {
                        if (std.mem.eql(u8, ignored, struct_field_name)) {
                            skip_field = true;
                            break;
                        }
                    }
                }

                if (!skip_field) {
                    const field_ptr = &@field(struct_ptr, struct_field_name);
                    const field_ptr_info = @typeInfo(@TypeOf(field_ptr.*));
                    switch (field_ptr_info) {
                        .pointer => |p| {
                            if (p.attrs.@"const") {
                                displayConst(struct_field_name, field_ptr);
                            } else {
                                inputStruct(
                                    struct_field_name,
                                    field_ptr,
                                    ignored_fields,
                                    expand_sections,
                                    field_configs,
                                    opt_handle_custom_types,
                                );
                            }
                        },
                        else => {
                            inputStruct(
                                struct_field_name,
                                field_ptr,
                                ignored_fields,
                                expand_sections,
                                field_configs,
                                opt_handle_custom_types,
                            );
                        },
                    }
                }
            }
        },
        else => {},
    }
}

fn inputStruct(
    comptime struct_field_name: [:0]const u8,
    field_ptr: anytype,
    comptime ignored_fields: []const []const u8,
    expand_sections: bool,
    comptime field_configs: []const FieldConfig,
    comptime opt_handle_custom_types: handleCustomTypesFn,
) void {
    var handled: bool = false;
    if (opt_handle_custom_types) |handleCustomTypes| {
        handled = handleCustomTypes(struct_field_name, field_ptr);
    }
    if (!handled) {
        switch (@TypeOf(field_ptr.*)) {
            bool => {
                inputBool(struct_field_name, field_ptr);
            },
            f32 => {
                inputF32(struct_field_name, field_ptr, getFieldConfig(f32, field_configs, struct_field_name));
            },
            f64 => {
                inputF32(struct_field_name, field_ptr, getFieldConfig(f64, field_configs, struct_field_name));
            },
            u32 => {
                inputU32(struct_field_name, field_ptr, getFieldConfig(u32, field_configs, struct_field_name));
            },
            i32 => {
                inputI32(struct_field_name, field_ptr, getFieldConfig(i32, field_configs, struct_field_name));
            },
            u64 => {
                inputU64(struct_field_name, field_ptr, getFieldConfig(u64, field_configs, struct_field_name));
            },
            else => {
                const field_info = @typeInfo(@TypeOf(field_ptr.*));
                switch (field_info) {
                    .optional => |o| {
                        const child_info = @typeInfo(o.child);
                        switch (child_info) {
                            .pointer => |p| {
                                if (p.size == .one) {
                                    if (field_ptr.*) |inner| {
                                        inputStructSection(
                                            inner,
                                            struct_field_name,
                                            ignored_fields,
                                            expand_sections,
                                            field_configs,
                                            opt_handle_custom_types,
                                        );
                                    } else {
                                        displayNull(struct_field_name);
                                    }
                                }
                            },
                            else => {
                                if (field_ptr.*) |inner| {
                                    var mutable_inner = inner;
                                    inputStructSection(
                                        &mutable_inner,
                                        struct_field_name,
                                        ignored_fields,
                                        expand_sections,
                                        field_configs,
                                        opt_handle_custom_types,
                                    );
                                } else {
                                    displayNull(struct_field_name);
                                }
                            },
                        }
                    },
                    .pointer => |p| {
                        const inner_info = @typeInfo(p.child);
                        if (p.size == .one) {
                            switch (inner_info) {
                                .@"struct" => {
                                    inputStructSection(
                                        field_ptr.*,
                                        struct_field_name,
                                        ignored_fields,
                                        expand_sections,
                                        field_configs,
                                        opt_handle_custom_types,
                                    );
                                },
                                else => {},
                            }
                        }
                    },
                    .@"enum" => {
                        inputEnum(struct_field_name, field_ptr);
                    },
                    .@"struct" => {
                        inputStructSection(
                            field_ptr,
                            struct_field_name,
                            ignored_fields,
                            expand_sections,
                            field_configs,
                            opt_handle_custom_types,
                        );
                    },
                    else => {},
                }
            },
        }
    }
}

fn inputStructSection(
    target: anytype,
    heading: ?[*:0]const u8,
    comptime ignored_fields: []const []const u8,
    expand_sections: bool,
    comptime field_configs: []const FieldConfig,
    comptime opt_handle_custom_types: handleCustomTypesFn,
) void {
    imgui.ImGui_PushIDPtr(@ptrCast(heading));
    defer imgui.ImGui_PopID();

    const section_flags =
        if (expand_sections) imgui.ImGuiTreeNodeFlags_DefaultOpen else imgui.ImGuiTreeNodeFlags_None;
    if (imgui.ImGui_CollapsingHeaderBoolPtr(heading, null, section_flags)) {
        imgui.ImGui_Indent();
        switch (@typeInfo(@TypeOf(target))) {
            .pointer => |ptr_info| {
                if (@typeInfo(ptr_info.child) != .@"opaque" and ptr_info.size == .one) {
                    inspectStruct(target, ignored_fields, expand_sections, field_configs, opt_handle_custom_types);
                }
            },
            else => {
                inspectStruct(target, ignored_fields, expand_sections, field_configs, opt_handle_custom_types);
            },
        }
        imgui.ImGui_Unindent();
    }
}

/// Generate an imgui checkbox based on a bool pointer.
pub fn inputBool(heading: ?[*:0]const u8, value: *bool) void {
    imgui.ImGui_PushIDPtr(value);
    defer imgui.ImGui_PopID();

    _ = imgui.ImGui_Checkbox(heading, value);
}

/// Generate an imgui input field based on a f32 pointer.
pub fn inputF32(heading: ?[*:0]const u8, value: *f32, config: InputConfig) void {
    imgui.ImGui_PushIDPtr(value);
    defer imgui.ImGui_PopID();

    switch (config.f32.input_type) {
        .Input => {
            _ = imgui.ImGui_InputFloatEx(heading, value, config.f32.step, config.f32.step_fast, "%.2f", 0);
        },
        .Drag => {
            _ = imgui.ImGui_DragFloatEx(heading, value, config.f32.step, config.f32.min, config.f32.max, "%.2f", 0);
        },
        .Slider => {
            _ = imgui.ImGui_SliderFloatEx(heading, value, config.f32.min, config.f32.max, "%.2f", 0);
        },
    }
}

/// Generate an imgui input field based on a f64 pointer.
pub fn inputF64(heading: ?[*:0]const u8, value: *f64, config: InputConfig) void {
    imgui.ImGui_PushIDPtr(value);
    defer imgui.ImGui_PopID();

    switch (config.f64.input_type) {
        .Input => {
            _ = imgui.ImGui_InputDoubleEx(heading, value, config.f64.step, config.f64.step_fast, "%.2f", 0);
        },
        .Drag => {
            _ = imgui.ImGui_DragDoubleEx(heading, value, config.f64.step, config.f64.min, config.f64.max, "%.2f", 0);
        },
        .Slider => {
            _ = imgui.ImGui_SliderDoubleEx(heading, value, config.f64.min, config.f64.max, "%.2f", 0);
        },
    }
}

/// Generate an imgui input field based on a u32 pointer.
pub fn inputU32(heading: ?[*:0]const u8, value: *u32, config: InputConfig) void {
    imgui.ImGui_PushIDPtr(value);
    defer imgui.ImGui_PopID();

    switch (config.u32.input_type) {
        .Input => {
            _ = imgui.ImGui_InputScalarEx(
                heading,
                imgui.ImGuiDataType_U32,
                value,
                &config.u32.step,
                &config.u32.step_fast,
                null,
                0,
            );
        },
        .Drag => {
            _ = imgui.ImGui_DragScalarEx(
                heading,
                imgui.ImGuiDataType_U32,
                value,
                @floatFromInt(config.u32.step),
                &config.u32.min,
                &config.u32.max,
                null,
                0,
            );
        },
        .Slider => {
            _ = imgui.ImGui_SliderScalarEx(
                heading,
                imgui.ImGuiDataType_U32,
                value,
                &config.u32.min,
                &config.u32.max,
                null,
                0,
            );
        },
    }
}

/// Generate an imgui input field based on a i32 pointer.
pub fn inputI32(heading: ?[*:0]const u8, value: *i32, config: InputConfig) void {
    imgui.ImGui_PushIDPtr(value);
    defer imgui.ImGui_PopID();

    switch (config.i32.input_type) {
        .Input => {
            _ = imgui.ImGui_InputScalarEx(
                heading,
                imgui.ImGuiDataType_S32,
                value,
                &config.i32.step,
                &config.i32.step_fast,
                null,
                0,
            );
        },
        .Drag => {
            _ = imgui.ImGui_DragScalarEx(
                heading,
                imgui.ImGuiDataType_S32,
                value,
                @floatFromInt(config.i32.step),
                &config.i32.min,
                &config.i32.max,
                null,
                0,
            );
        },
        .Slider => {
            _ = imgui.ImGui_SliderScalarEx(
                heading,
                imgui.ImGuiDataType_S32,
                value,
                &config.i32.min,
                &config.i32.max,
                null,
                0,
            );
        },
    }
}

/// Generate an imgui input field based on a u64 pointer.
pub fn inputU64(heading: ?[*:0]const u8, value: *u64, config: InputConfig) void {
    imgui.ImGui_PushIDPtr(value);
    defer imgui.ImGui_PopID();

    switch (config.u64.input_type) {
        .Input => {
            _ = imgui.ImGui_InputScalarEx(
                heading,
                imgui.ImGuiDataType_U64,
                value,
                &config.u64.step,
                &config.u64.step_fast,
                null,
                0,
            );
        },
        .Drag => {
            _ = imgui.ImGui_DragScalarEx(
                heading,
                imgui.ImGuiDataType_U64,
                value,
                @floatFromInt(config.u64.step),
                &config.u64.min,
                &config.u64.max,
                null,
                0,
            );
        },
        .Slider => {
            _ = imgui.ImGui_SliderScalarEx(
                heading,
                imgui.ImGuiDataType_U64,
                value,
                &config.u64.min,
                &config.u64.max,
                null,
                0,
            );
        },
    }
}

/// Generate an imgui dropdown field based on an enum pointer.
pub fn inputEnum(heading: ?[*:0]const u8, value: anytype) void {
    const field_info = @typeInfo(@TypeOf(value.*));
    const count: u32 = field_info.@"enum".field_names.len;
    var items: [count][*:0]const u8 = undefined;
    inline for (field_info.@"enum".field_names, 0..) |enum_field_name, i| {
        items[i] = enum_field_name;
    }

    imgui.ImGui_PushIDPtr(value);
    defer imgui.ImGui_PopID();

    var current_item: i32 = @intCast(@intFromEnum(value.*));
    if (imgui.ImGui_ComboCharEx(heading, &current_item, &items, count, 0)) {
        value.* = @enumFromInt(current_item);
    }
}

/// Generate a set of imgui checkboxes based on a u32 pointer and an enum type which describes the flags.
pub fn inputFlagsU32(heading: ?[*:0]const u8, value: *u32, FlagsEnumType: type) void {
    if (imgui.ImGui_CollapsingHeaderBoolPtr(heading, null, imgui.ImGuiTreeNodeFlags_None)) {
        inline for (@typeInfo(FlagsEnumType).@"enum".field_names, 0..) |flag_name, i| {
            const flag_value = @typeInfo(FlagsEnumType).@"enum".field_values[i];
            var bool_value: bool = (value.* & flag_value) != 0;

            imgui.ImGui_PushIDPtr(&bool_value);
            defer imgui.ImGui_PopID();

            if (imgui.ImGui_Checkbox(flag_name, &bool_value)) {
                value.* ^= flag_value;
            }
        }
    }
}

fn displayConst(
    struct_field_name: [:0]const u8,
    field_ptr: anytype,
) void {
    switch (@TypeOf(field_ptr.*)) {
        []const u8 => {
            imgui.ImGui_LabelText(struct_field_name, field_ptr.ptr);
        },
        else => {
            imgui.ImGui_LabelText(struct_field_name, "unknown const");
        },
    }
}

fn displayNull(comptime heading: [:0]const u8) void {
    imgui.ImGui_PushIDPtr(@ptrCast(heading));
    defer imgui.ImGui_PopID();

    imgui.ImGui_LabelText(heading, "null");
}
