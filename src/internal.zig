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

    pub fn init(self: *FPSState, frequency: u64) void {
        self.current_frame_index = 0;
        self.performance_frequency = frequency;
        self.frame_times = [1]u64{0} ** MAX_FRAME_TIME_COUNT;
        self.average = 0;
        self.display_mode = .Number;
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
            c_imgui.ImGui_SetNextWindowPosEx(c_imgui.ImVec2{ .x = 5, .y = 5 }, 0, c_imgui.ImVec2{ .x = 0, .y = 0 });
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

const handleCustomTypesFn = ?*const fn (
    struct_field: std.builtin.Type.StructField,
    field_ptr: anytype,
) bool;

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
