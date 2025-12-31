const std = @import("std");
const imgui = @import("imgui");

const c_imgui = imgui.c;

const MAX_FRAME_TIME_COUNT: u32 = 300;

const FPSDisplayMode = enum {
    None,
    Number,
    NumberAndGraph,
};

pub const FPSState = struct {
    current_frame_index: u32,
    performance_frequency: u64,
    frame_times: [MAX_FRAME_TIME_COUNT]u64,
    average: f32,
    display_mode: FPSDisplayMode,
    position: c_imgui.ImVec2,

    pub fn init(self: *FPSState, frequency: u64) void {
        self.current_frame_index = 0;
        self.performance_frequency = frequency;
        self.frame_times = [1]u64{0} ** MAX_FRAME_TIME_COUNT;
        self.average = 0;
        self.display_mode = .Number;
        self.position = c_imgui.ImVec2{ .x = 5, .y = 5 };
    }

    pub fn toggleMode(self: *FPSState) void {
        var mode: u32 = @intFromEnum(self.display_mode) + 1;
        if (mode >= @typeInfo(FPSDisplayMode).@"enum".fields.len) {
            mode = 0;
        }
        self.display_mode = @enumFromInt(mode);
    }

    pub fn getPreviousFrameIndex(frame_index: u32) u32 {
        var previous_frame_index: u32 = frame_index -% 1;
        if (previous_frame_index > MAX_FRAME_TIME_COUNT) {
            previous_frame_index = MAX_FRAME_TIME_COUNT - 1;
        }
        return previous_frame_index;
    }

    pub fn getFrameTime(self: *FPSState, frame_index: u32) f32 {
        var elapsed: u64 = 0;
        const previous_frame_index = getPreviousFrameIndex(frame_index);

        const current_frame = self.frame_times[frame_index];
        const previous_frame = self.frame_times[previous_frame_index];
        if (current_frame > 0 and previous_frame > 0 and current_frame > previous_frame) {
            elapsed = current_frame - previous_frame;
        }

        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.performance_frequency));
    }

    pub fn addFrameTime(self: *FPSState, frame_time: u64) void {
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

    pub fn draw(self: *FPSState) void {
        if (self.display_mode != .None) {
            c_imgui.ImGui_SetNextWindowPosEx(self.position, 0, c_imgui.ImVec2{ .x = 0, .y = 0 });
            c_imgui.ImGui_SetNextWindowSize(c_imgui.ImVec2{ .x = 300, .y = 160 }, 0);

            _ = c_imgui.ImGui_Begin(
                "FPS",
                null,
                c_imgui.ImGuiWindowFlags_NoMove |
                    c_imgui.ImGuiWindowFlags_NoResize |
                    c_imgui.ImGuiWindowFlags_NoBackground |
                    c_imgui.ImGuiWindowFlags_NoTitleBar |
                    c_imgui.ImGuiWindowFlags_NoMouseInputs,
            );

            c_imgui.ImGui_TextColored(
                c_imgui.ImVec4{ .x = 0, .y = 1, .z = 0, .w = 1 },
                "FPS: %.0f",
                self.average,
            );

            if (self.display_mode == .NumberAndGraph) {
                var timings: [MAX_FRAME_TIME_COUNT]f32 = [1]f32{0} ** MAX_FRAME_TIME_COUNT;
                var max_value: f32 = 0;
                for (0..MAX_FRAME_TIME_COUNT) |i| {
                    timings[i] = self.getFrameTime(@intCast(i));
                    if (timings[i] > max_value) {
                        max_value = timings[i];
                    }
                }
                c_imgui.ImGui_PlotHistogramEx(
                    "##FPS_Graph",
                    &timings,
                    timings.len,
                    0,
                    "",
                    0,
                    max_value,
                    c_imgui.ImVec2{ .x = 300, .y = 100 },
                    @sizeOf(f32),
                );
            }

            c_imgui.ImGui_End();
        }
    }
};

/// This window is used to print out arbitrary data at any point. Use the `print` and `printStruct` functions to append
/// to the output and then call the `draw` function in your imgui draw function.
pub const DebugOutput = struct {
    arena: std.heap.ArenaAllocator,
    data: std.ArrayList([]const u8),

    pub fn init(self: *DebugOutput) void {
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .data = .empty,
        };
    }

    pub fn deinit(self: *DebugOutput) void {
        self.data.clearRetainingCapacity();
        self.arena.deinit();
    }

    /// Call this function along with any other imgui drawing code. The window will only be displayed if there is
    /// any data in the array. Data is cleared and memory is freed after every draw.
    pub fn draw(self: *DebugOutput) void {
        if (self.data.items.len > 0) {
            imgui.c.ImGui_SetNextWindowPosEx(
                imgui.c.ImVec2{ .x = 350, .y = 30 },
                imgui.c.ImGuiCond_FirstUseEver,
                imgui.c.ImVec2{ .x = 0, .y = 0 },
            );
            imgui.c.ImGui_SetNextWindowSize(imgui.c.ImVec2{ .x = 300, .y = 540 }, imgui.c.ImGuiCond_FirstUseEver);

            _ = imgui.c.ImGui_Begin("Debug output", null, imgui.c.ImGuiWindowFlags_NoFocusOnAppearing);
            defer imgui.c.ImGui_End();

            for (self.data.items) |line| {
                imgui.c.ImGui_TextWrapped("%s", @as([*:0]const u8, @ptrCast(line)));
            }
        }

        self.deinit();
        self.init();
    }

    /// Print out a string using the familiar fmt + args approach.
    pub fn print(
        self: *DebugOutput,
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
        self: *DebugOutput,
        message: []const u8,
        value: anytype,
    ) void {
        self.data.append(
            self.arena.allocator(),
            std.fmt.allocPrintSentinel(
                self.arena.allocator(),
                "{s} {s}",
                .{ message, self.structToString(value) },
                0x0,
            ) catch "",
        ) catch undefined;
    }

    fn structToString(self: *DebugOutput, value: anytype) []const u8 {
        var value_string: []u8 = "";

        const struct_info = @typeInfo(@TypeOf(value));
        switch (struct_info) {
            .@"struct" => {
                inline for (struct_info.@"struct".fields, 0..) |struct_field, i| {
                    value_string = std.fmt.allocPrintSentinel(
                        self.arena.allocator(),
                        "{s}{s}",
                        .{ value_string, self.structFieldToString(@field(value, struct_field.name), struct_field.name) },
                        0x0,
                    ) catch "";

                    if (i < struct_info.@"struct".fields.len - 1) {
                        value_string = std.fmt.allocPrintSentinel(
                            self.arena.allocator(),
                            "{s}, ",
                            .{value_string},
                            0x0,
                        ) catch "";
                    }
                }
            },
            else => {},
        }

        return value_string;
    }

    fn structFieldToString(
        self: *DebugOutput,
        field_value: anytype,
        field_name: []const u8,
    ) []const u8 {
        const field_info = @typeInfo(@TypeOf(field_value));

        switch (field_info) {
            else => {
                return std.fmt.allocPrint(
                    self.arena.allocator(),
                    "{s}: {s}",
                    .{ field_name, self.valueToString(field_value) },
                ) catch "";
            },
        }
    }

    fn valueToString(
        self: *DebugOutput,
        value: anytype,
    ) []const u8 {
        const field_info = @typeInfo(@TypeOf(value));

        switch (field_info) {
            .@"struct" => {
                return self.structToString(value);
            },
            .int, .float, .comptime_int, .comptime_float => {
                return std.fmt.allocPrint(
                    self.arena.allocator(),
                    "{d}",
                    .{value},
                ) catch "";
            },
            .bool => {
                return std.fmt.allocPrint(
                    self.arena.allocator(),
                    "{s}",
                    .{if (value) "true" else "false"},
                ) catch "";
            },
            .pointer => |pointer_info| {
                switch (pointer_info.size) {
                    .one, .slice => {
                        return std.fmt.allocPrint(
                            self.arena.allocator(),
                            "{s}",
                            .{value},
                        ) catch "";
                    },
                    .many, .c => {
                        return std.fmt.allocPrint(
                            self.arena.allocator(),
                            "{s}",
                            .{std.mem.span(value)},
                        ) catch "";
                    },
                }
            },
            .vector => |vector_info| {
                comptime var format: []const u8 = "{{";
                comptime for (0..vector_info.len) |i| {
                    format = format ++ "{d}";
                    if (i < vector_info.len - 1) {
                        format = format ++ ", ";
                    }
                };
                format = format ++ "}}";

                const ArgsType = makeVectorFormatArgsType(vector_info);
                var args: ArgsType = undefined;
                inline for (0..vector_info.len) |i| {
                    @field(args, std.fmt.comptimePrint("vector_field_{d}", .{i})) = value[i];
                }

                return std.fmt.allocPrint(self.arena.allocator(), format, args) catch "";
            },
            .array => {
                var output = std.fmt.allocPrint(
                    self.arena.allocator(),
                    "[",
                    .{},
                ) catch "";

                for (value, 0..) |item, i| {
                    output = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "{s}{s}",
                        .{ output, self.valueToString(item) },
                    ) catch "";

                    if (i < value.len - 1) {
                        output = std.fmt.allocPrintSentinel(
                            self.arena.allocator(),
                            "{s}, ",
                            .{output},
                            0x0,
                        ) catch "";
                    }
                }

                output = std.fmt.allocPrint(
                    self.arena.allocator(),
                    "{s}]",
                    .{output},
                ) catch "";

                return output;
            },
            .optional => {
                if (value) |unwrapped| {
                    return self.valueToString(unwrapped);
                } else {
                    return "null";
                }
            },
            else => return "unhandled data type",
        }
    }

    fn makeVectorFormatArgsType(vector_info: std.builtin.Type.Vector) type {
        var struct_fields: [vector_info.len]std.builtin.Type.StructField = undefined;

        for (0..vector_info.len) |i| {
            struct_fields[i] = .{
                .name = std.fmt.comptimePrint("vector_field_{d}", .{i}),
                .type = vector_info.child,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(vector_info.child),
            };
        }

        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = &struct_fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    }
};

test "DebugOutput can output a formatted string using the print function" {
    var output: DebugOutput = undefined;
    output.init();

    output.print("This is a {s} that supports formatting: {d}", .{ "test", 0.5 });

    try std.testing.expectEqual(1, output.data.items.len);
    try std.testing.expectEqualSlices(u8, "This is a test that supports formatting: 0.5", output.data.items[0]);

    output.deinit();
    try std.testing.expectEqual(0, output.data.items.len);
}

test "DebugOutput can output a text representation of an arbitrary struct using the printStruct function" {
    var output: DebugOutput = undefined;
    output.init();

    output.printStruct("Title:", .{
        .string = "test",
        .number = 0.5,
        .vector = @as(@Vector(2, f32), .{ 1, 23 }),
        .boolean = true,
        .array = @as([2][]const u8, .{ "foo", "bar" }),
        .nested = .{ .hello = "world", .number = 3 },
    });

    try std.testing.expectEqual(1, output.data.items.len);
    try std.testing.expectEqualSlices(
        u8,
        "Title: string: test, number: 0.5, vector: {1, 23}, boolean: true, array: [foo, bar], nested: hello: world, number: 3",
        output.data.items[0],
    );

    output.deinit();
    try std.testing.expectEqual(0, output.data.items.len);
}

test "DebugOutput.printStruct handles optional types" {
    var output: DebugOutput = undefined;
    output.init();

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

const handleCustomTypesFn = ?*const fn (
    struct_field: std.builtin.Type.StructField,
    field_ptr: anytype,
) bool;

pub fn inspectStructOptional(
    struct_ptr: anytype,
    ignored_fields: []const []const u8,
    expand_sections: bool,
    optHandleCustomTypes: handleCustomTypesFn,
) void {
    switch (@typeInfo(@TypeOf(struct_ptr))) {
        .optional => {
            if (struct_ptr) |ptr| {
                inspectStruct(ptr, ignored_fields, expand_sections, optHandleCustomTypes);
            }
        },
        else => {
            inspectStruct(struct_ptr, ignored_fields, expand_sections, optHandleCustomTypes);
        },
    }
}

pub fn inspectStruct(
    struct_ptr: anytype,
    ignored_fields: []const []const u8,
    expand_sections: bool,
    optHandleCustomTypes: handleCustomTypesFn,
) void {
    const struct_info = @typeInfo(@TypeOf(struct_ptr.*));
    switch (struct_info) {
        .@"struct" => {
            inline for (struct_info.@"struct".fields) |struct_field| {
                var skip_field = false;
                for (ignored_fields) |ignored| {
                    if (std.mem.eql(u8, ignored, struct_field.name)) {
                        skip_field = true;
                        break;
                    }
                }

                if (!skip_field) {
                    const field_ptr = &@field(struct_ptr, struct_field.name);
                    const field_ptr_info = @typeInfo(@TypeOf(field_ptr.*));
                    switch (field_ptr_info) {
                        .pointer => |p| {
                            if (p.is_const) {
                                displayConst(struct_field, field_ptr);
                            } else {
                                inputStruct(
                                    struct_field,
                                    field_ptr,
                                    ignored_fields,
                                    expand_sections,
                                    optHandleCustomTypes,
                                );
                            }
                        },
                        else => {
                            inputStruct(
                                struct_field,
                                field_ptr,
                                ignored_fields,
                                expand_sections,
                                optHandleCustomTypes,
                            );
                        },
                    }
                }
            }
        },
        else => {},
    }
}

pub fn inputStruct(
    struct_field: std.builtin.Type.StructField,
    field_ptr: anytype,
    ignored_fields: []const []const u8,
    expand_sections: bool,
    optHandleCustomTypes: handleCustomTypesFn,
) void {
    var handled: bool = false;
    if (optHandleCustomTypes) |handleCustomTypes| {
        handled = handleCustomTypes(struct_field, field_ptr);
    }
    if (!handled) {
        switch (@TypeOf(field_ptr.*)) {
            bool => {
                inputBool(struct_field.name, field_ptr);
            },
            f32 => {
                inputF32(struct_field.name, field_ptr);
            },
            u32 => {
                inputU32(struct_field.name, field_ptr);
            },
            i32 => {
                inputI32(struct_field.name, field_ptr);
            },
            u64 => {
                inputU64(struct_field.name, field_ptr);
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
                                            struct_field.name,
                                            ignored_fields,
                                            expand_sections,
                                            optHandleCustomTypes,
                                        );
                                    } else {
                                        displayNull(struct_field.name);
                                    }
                                }
                            },
                            else => {
                                if (field_ptr.*) |inner| {
                                    var mutable_inner = inner;
                                    inputStructSection(
                                        &mutable_inner,
                                        struct_field.name,
                                        ignored_fields,
                                        expand_sections,
                                        optHandleCustomTypes,
                                    );
                                } else {
                                    displayNull(struct_field.name);
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
                                        struct_field.name,
                                        ignored_fields,
                                        expand_sections,
                                        optHandleCustomTypes,
                                    );
                                },
                                else => {},
                            }
                        }
                    },
                    .@"enum" => {
                        inputEnum(struct_field.name, field_ptr);
                    },
                    .@"struct" => {
                        inputStructSection(
                            field_ptr,
                            struct_field.name,
                            ignored_fields,
                            expand_sections,
                            optHandleCustomTypes,
                        );
                    },
                    else => {},
                }
            },
        }
    }
}

pub fn inputStructSection(
    target: anytype,
    heading: ?[*:0]const u8,
    ignored_fields: []const []const u8,
    expand_sections: bool,
    optHandleCustomTypes: handleCustomTypesFn,
) void {
    c_imgui.ImGui_PushIDPtr(@ptrCast(heading));
    defer c_imgui.ImGui_PopID();

    const section_flags =
        if (expand_sections) c_imgui.ImGuiTreeNodeFlags_DefaultOpen else c_imgui.ImGuiTreeNodeFlags_None;
    if (c_imgui.ImGui_CollapsingHeaderBoolPtr(heading, null, section_flags)) {
        c_imgui.ImGui_Indent();
        switch (@typeInfo(@TypeOf(target))) {
            .pointer => |ptr_info| {
                if (@typeInfo(ptr_info.child) != .@"opaque" and ptr_info.size == .one) {
                    inspectStruct(target, ignored_fields, expand_sections, optHandleCustomTypes);
                }
            },
            else => {
                inspectStruct(target, ignored_fields, expand_sections, optHandleCustomTypes);
            },
        }
        c_imgui.ImGui_Unindent();
    }
}

pub fn inputBool(heading: ?[*:0]const u8, value: *bool) void {
    c_imgui.ImGui_PushIDPtr(value);
    defer c_imgui.ImGui_PopID();

    _ = c_imgui.ImGui_Checkbox(heading, value);
}

pub fn inputF32(heading: ?[*:0]const u8, value: *f32) void {
    c_imgui.ImGui_PushIDPtr(value);
    defer c_imgui.ImGui_PopID();

    _ = c_imgui.ImGui_InputFloatEx(heading, value, 0.1, 1, "%.2f", 0);
}

pub fn inputU32(heading: ?[*:0]const u8, value: *u32) void {
    c_imgui.ImGui_PushIDPtr(value);
    defer c_imgui.ImGui_PopID();

    _ = c_imgui.ImGui_InputScalarEx(heading, c_imgui.ImGuiDataType_U32, @ptrCast(value), null, null, null, 0);
}

pub fn inputI32(heading: ?[*:0]const u8, value: *u32) void {
    c_imgui.ImGui_PushIDPtr(value);
    defer c_imgui.ImGui_PopID();

    _ = c_imgui.ImGui_InputScalarEx(heading, c_imgui.ImGuiDataType_I32, @ptrCast(value), null, null, null, 0);
}

pub fn inputU64(heading: ?[*:0]const u8, value: *u64) void {
    c_imgui.ImGui_PushIDPtr(value);
    defer c_imgui.ImGui_PopID();

    _ = c_imgui.ImGui_InputScalarEx(heading, c_imgui.ImGuiDataType_U64, @ptrCast(value), null, null, null, 0);
}

pub fn inputEnum(heading: ?[*:0]const u8, value: anytype) void {
    const field_info = @typeInfo(@TypeOf(value.*));
    const count: u32 = field_info.@"enum".fields.len;
    var items: [count][*:0]const u8 = [1][*:0]const u8{undefined} ** count;
    inline for (field_info.@"enum".fields, 0..) |enum_field, i| {
        items[i] = enum_field.name;
    }

    c_imgui.ImGui_PushIDPtr(value);
    defer c_imgui.ImGui_PopID();

    var current_item: i32 = @intCast(@intFromEnum(value.*));
    if (c_imgui.ImGui_ComboCharEx(heading, &current_item, &items, count, 0)) {
        value.* = @enumFromInt(current_item);
    }
}

pub fn inputFlagsU32(heading: ?[*:0]const u8, value: *u32, FlagsEnumType: type) void {
    if (imgui.c.ImGui_CollapsingHeaderBoolPtr(heading, null, imgui.c.ImGuiTreeNodeFlags_None)) {
        inline for (@typeInfo(FlagsEnumType).@"enum".fields) |flag| {
            var bool_value: bool = (value.* & flag.value) != 0;

            c_imgui.ImGui_PushIDPtr(&bool_value);
            defer c_imgui.ImGui_PopID();

            if (c_imgui.ImGui_Checkbox(flag.name, &bool_value)) {
                value.* ^= flag.value;
            }
        }
    }
}

pub fn displayConst(
    struct_field: std.builtin.Type.StructField,
    field_ptr: anytype,
) void {
    switch (@TypeOf(field_ptr.*)) {
        []const u8 => {
            c_imgui.ImGui_LabelText(struct_field.name, field_ptr.ptr);
        },
        else => {
            c_imgui.ImGui_LabelText(struct_field.name, "unknown const");
        },
    }
}

pub fn displayNull(comptime heading: [:0]const u8) void {
    c_imgui.ImGui_PushIDPtr(@ptrCast(heading));
    defer c_imgui.ImGui_PopID();

    c_imgui.ImGui_LabelText(heading, "null");
}
