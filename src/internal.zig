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
