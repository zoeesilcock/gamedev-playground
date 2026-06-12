//! Exposes the Imgui C API as well as backend support fo SDL3 Renderer and SDL3 GPU.
//!
//! Note that importing this module without the `INTERNAL` build_option set to true will give an empty struct that only
//! contains a fake `ImGuiContext` type since that is needed for function signatures. The point of this is to make it a
//! compile time error to use any internal functions in a release version. This is implemented in `flint.zig`.

/// The Imgui C API, generated using dear_bindings.
pub const c = @import("imgui_c");
const sdl = @import("sdl.zig").c;
const fs = @import("fs.zig");

/// The ImGuiContext type is used in function signatures. When `INTERNAL` is set to false the library exposes a fake
/// version of this in the form of an `anyopaque` since the type is needed for function signatures.
pub const ImGuiContext = c.ImGuiContext;

const Backend = enum {
    Renderer,
    GPU,
};

extern fn ImGui_ImplSDL3_InitForOpenGL(window: ?*sdl.SDL_Window, sdl_gl_context: *anyopaque) bool;
extern fn ImGui_ImplSDL3_InitForVulkan(window: ?*sdl.SDL_Window) bool;
extern fn ImGui_ImplSDL3_InitForD3D(window: ?*sdl.SDL_Window) bool;
extern fn ImGui_ImplSDL3_InitForMetal(window: ?*sdl.SDL_Window) bool;
extern fn ImGui_ImplSDL3_InitForSDLRenderer(window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) bool;
extern fn ImGui_ImplSDL3_InitForSDLGPU(window: ?*sdl.SDL_Window) bool;
extern fn ImGui_ImplSDL3_InitForOther(window: ?*sdl.SDL_Window) bool;
extern fn ImGui_ImplSDL3_Shutdown() void;
extern fn ImGui_ImplSDL3_NewFrame() void;
extern fn ImGui_ImplSDL3_ProcessEvent(event: ?*sdl.SDL_Event) bool;

extern fn ImGui_ImplSDLRenderer3_Init(renderer: ?*sdl.SDL_Renderer) bool;
extern fn ImGui_ImplSDLRenderer3_Shutdown() void;
extern fn ImGui_ImplSDLRenderer3_NewFrame() void;
extern fn ImGui_ImplSDLRenderer3_RenderDrawData(draw_data: *const c.ImDrawData, renderer: ?*sdl.SDL_Renderer) void;

const ImGui_ImplSDLGPU3_InitInfo = struct {
    Device: ?*sdl.SDL_GPUDevice = null,
    ColorTargetFormat: sdl.SDL_GPUTextureFormat = sdl.SDL_GPU_TEXTUREFORMAT_INVALID,
    MSAASamples: sdl.SDL_GPUSampleCount = sdl.SDL_GPU_SAMPLECOUNT_1,
    SwapchainComposition: sdl.SDL_GPUSwapchainComposition = sdl.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
    PresentMode: sdl.SDL_GPUPresentMode = sdl.SDL_GPU_PRESENTMODE_VSYNC,
};
extern fn ImGui_ImplSDLGPU3_Init(info: ?*ImGui_ImplSDLGPU3_InitInfo) bool;
extern fn ImGui_ImplSDLGPU3_Shutdown() void;
extern fn ImGui_ImplSDLGPU3_NewFrame() void;
extern fn ImGui_ImplSDLGPU3_PrepareDrawData(draw_data: ?*c.ImDrawData, command_buffer: ?*sdl.SDL_GPUCommandBuffer) void;
extern fn ImGui_ImplSDLGPU3_RenderDrawData(draw_data: ?*c.ImDrawData, command_buffer: ?*sdl.SDL_GPUCommandBuffer, render_pass: ?*sdl.SDL_GPURenderPass, pipeline: ?*sdl.SDL_GPUGraphicsPipeline) void;

// We have to manually define the internal parts because dcimgui_internal.h contains bitfields that aren't supported
// by traslate-c. Issue: https://codeberg.org/ziglang/translate-c/issues/179
pub const internal = struct {
    pub const ImGuiDockNodeFlagsPrivate = struct {
        pub const DockSpace: c.ImGuiDockNodeFlags = 1 << 10;
        pub const CentralNode: c.ImGuiDockNodeFlags = 1 << 11;
        pub const NoTabBar: c.ImGuiDockNodeFlags = 1 << 12;
        pub const HiddenTabBar: c.ImGuiDockNodeFlags = 1 << 13;
        pub const NoWindowMenuButton: c.ImGuiDockNodeFlags = 1 << 14;
        pub const NoCloseButton: c.ImGuiDockNodeFlags = 1 << 15;
        pub const NoResizeX: c.ImGuiDockNodeFlags = 1 << 16;
        pub const NoResizeY: c.ImGuiDockNodeFlags = 1 << 17;
        pub const DockedWindowsInFocusRoute: c.ImGuiDockNodeFlags = 1 << 18;
        pub const NoDockingSplitOther: c.ImGuiDockNodeFlags = 1 << 19;
        pub const NoDockingOverMe: c.ImGuiDockNodeFlags = 1 << 20;
        pub const NoDockingOverOther: c.ImGuiDockNodeFlags = 1 << 21;
        pub const NoDockingOverEmpty: c.ImGuiDockNodeFlags = 1 << 22;
    };
    pub extern fn ImGui_DockBuilderDockWindow(window_name: [*:0]const u8, node_id: c.ImGuiID) callconv(.c) void;
    pub extern fn ImGui_DockBuilderGetNode(node_id: c.ImGuiID) callconv(.c) ?*anyopaque;
    pub extern fn ImGui_DockBuilderGetCentralNode(node_id: c.ImGuiID) callconv(.c) ?*anyopaque;
    pub extern fn ImGui_DockBuilderAddNode() callconv(.c) c.ImGuiID;
    pub extern fn ImGui_DockBuilderAddNodeEx(node_id: c.ImGuiID, flags: c.ImGuiDockNodeFlags) callconv(.c) c.ImGuiID;
    pub extern fn ImGui_DockBuilderRemoveNode(node_id: c.ImGuiID) callconv(.c) void;
    pub extern fn ImGui_DockBuilderRemoveNodeDockedWindows(node_id: c.ImGuiID) callconv(.c) void;
    pub extern fn ImGui_DockBuilderRemoveNodeDockedWindowsEx(node_id: c.ImGuiID, clear_settings_refs: bool) callconv(.c) void;
    pub extern fn ImGui_DockBuilderRemoveNodeChildNodes(node_id: c.ImGuiID) callconv(.c) void;
    pub extern fn ImGui_DockBuilderSetNodePos(node_id: c.ImGuiID, pos: c.ImVec2) callconv(.c) void;
    pub extern fn ImGui_DockBuilderSetNodeSize(node_id: c.ImGuiID, size: c.ImVec2) callconv(.c) void;
    pub extern fn ImGui_DockBuilderSplitNode(node_id: c.ImGuiID, split_dir: c.ImGuiDir, size_ratio_for_node_at_dir: f32, out_id_at_dir: *c.ImGuiID, out_id_at_opposite_dir: *c.ImGuiID) callconv(.c) c.ImGuiID;
    pub extern fn ImGui_DockBuilderCopyDockSpace(src_dockspace_id: c.ImGuiID, dst_dockspace_id: c.ImGuiID, in_window_remap_pairs: *c.ImVector_const_charPtr) callconv(.c) void;
    pub extern fn ImGui_DockBuilderCopyNode(src_node_id: c.ImGuiID, dst_node_id: c.ImGuiID, out_node_remap_pairs: *c.ImVector_ImGuiID) callconv(.c) void;
    pub extern fn ImGui_DockBuilderCopyWindowSettings(src_name: [*:0]const u8, dst_name: [*:0]const u8) callconv(.c) void;
    pub extern fn ImGui_DockBuilderFinish(node_id: c.ImGuiID) callconv(.c) void;
};

pub var context: ?*ImGuiContext = null;
var backend: Backend = .Renderer;

/// Set the imgui context and backend, this is needed when using the dependency sets that manage the imgui
/// lifecycle for you (all but `GameLib.Dependencies.Minimal`).
pub fn setup(imgui_context: ?*ImGuiContext, imgui_backend: Backend) void {
    backend = imgui_backend;
    context = imgui_context;
    c.ImGui_SetCurrentContext(context);
}

/// Initialize the SDL3 Renderer backend.
/// Call this function when you game launches if you are managing the imgui lifecycle yourself.
pub fn init(window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, width: f32, height: f32) void {
    setup(c.ImGui_CreateContext(null), .Renderer);
    {
        var im_io: *c.ImGuiIO = @ptrCast(c.ImGui_GetIO());
        im_io.ConfigFlags =
            c.ImGuiConfigFlags_NavEnableKeyboard |
            c.ImGuiConfigFlags_NavEnableGamepad |
            c.ImGuiConfigFlags_DockingEnable;
        im_io.DisplaySize.x = width;
        im_io.DisplaySize.y = height;
    }

    c.ImGui_StyleColorsDark(null);
    _ = ImGui_ImplSDL3_InitForSDLRenderer(window, renderer);
    _ = ImGui_ImplSDLRenderer3_Init(renderer);
}

/// Initialize the SDL3 GPU backend.
/// Call this function when you game launches if you are managing the imgui lifecycle yourself.
pub fn initGPU(window: *sdl.SDL_Window, device: *sdl.SDL_GPUDevice, width: f32, height: f32) void {
    setup(c.ImGui_CreateContext(null), .GPU);
    {
        var im_io: *c.ImGuiIO = @ptrCast(c.ImGui_GetIO());
        im_io.ConfigFlags =
            c.ImGuiConfigFlags_NavEnableKeyboard |
            c.ImGuiConfigFlags_NavEnableGamepad |
            c.ImGuiConfigFlags_DockingEnable;
        im_io.DisplaySize.x = width;
        im_io.DisplaySize.y = height;
    }

    c.ImGui_StyleColorsDark(null);

    var init_info: ImGui_ImplSDLGPU3_InitInfo = .{
        .Device = device,
        .ColorTargetFormat = sdl.SDL_GetGPUSwapchainTextureFormat(device, window),
    };
    _ = ImGui_ImplSDL3_InitForSDLGPU(window);
    _ = ImGui_ImplSDLGPU3_Init(&init_info);
}

/// Changes the path and name of the imgui.ini file which saves the imgui layout for internal builds. This needs to
/// be called after `imgui.setup` as it requires the imgui context to be in place.
pub fn setIniFilename(name: [*c]const u8) void {
    var im_io: *c.ImGuiIO = @ptrCast(c.ImGui_GetIO());
    im_io.IniFilename = name;
}

/// Shutdown the imgui backend.
pub fn deinit() void {
    ImGui_ImplSDL3_Shutdown();

    switch (backend) {
        .Renderer => ImGui_ImplSDLRenderer3_Shutdown(),
        .GPU => ImGui_ImplSDLGPU3_Shutdown(),
    }

    c.ImGui_DestroyContext(context);
}

/// Process SDL events, call this with the event received via `SDL_PollEvent`. Returns a boolean which tells you if
/// Imgui used the event.
pub fn processEvent(event: *sdl.SDL_Event) bool {
    _ = ImGui_ImplSDL3_ProcessEvent(event);
    const im_io = c.ImGui_GetIO()[0];
    const is_key_event =
        event.type == sdl.SDL_EVENT_KEY_DOWN or
        event.type == sdl.SDL_EVENT_KEY_UP;
    const is_mouse_event =
        event.type == sdl.SDL_EVENT_MOUSE_MOTION or
        event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN or
        event.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP;

    return (is_mouse_event and im_io.WantCaptureMouse) or
        (is_key_event and im_io.WantCaptureKeyboard);
}

/// Starts a new frame. Call this on every frame, before making any Imgui windows.
pub fn newFrame() void {
    switch (backend) {
        .Renderer => ImGui_ImplSDLRenderer3_NewFrame(),
        .GPU => ImGui_ImplSDLGPU3_NewFrame(),
    }
    ImGui_ImplSDL3_NewFrame();
    c.ImGui_NewFrame();
}

/// Draws Imgui windows to the screen, call this after all your Imgui windows.
pub fn render(renderer: *sdl.SDL_Renderer) void {
    c.ImGui_Render();
    ImGui_ImplSDLRenderer3_RenderDrawData(c.ImGui_GetDrawData(), renderer);
}

/// Draws Imgui windows to the screen, call this after all your Imgui windows.
pub fn renderGPU(command_buffer: ?*sdl.SDL_GPUCommandBuffer, swapchain_texture: *sdl.SDL_GPUTexture) void {
    c.ImGui_Render();

    const draw_data: *c.ImDrawData = c.ImGui_GetDrawData();
    ImGui_ImplSDLGPU3_PrepareDrawData(draw_data, command_buffer);

    const target_info: sdl.SDL_GPUColorTargetInfo = .{
        .texture = swapchain_texture,
        .load_op = sdl.SDL_GPU_LOADOP_LOAD,
        .store_op = sdl.SDL_GPU_STOREOP_STORE,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .cycle = false,
    };
    const render_pass: ?*sdl.SDL_GPURenderPass = sdl.SDL_BeginGPURenderPass(command_buffer, &target_info, 1, null);

    ImGui_ImplSDLGPU3_RenderDrawData(draw_data, command_buffer, render_pass, null);

    sdl.SDL_EndGPURenderPass(render_pass);
}
