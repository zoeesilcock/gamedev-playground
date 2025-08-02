pub const c = @cImport({
    @cInclude("dcimgui.h");
});
const sdl = @import("sdl").c;
const std = @import("std");

const Backend = enum {
    Renderer,
    GPU,
};

pub extern fn ImGui_ImplSDL3_InitForOpenGL(window: ?*sdl.SDL_Window, sdl_gl_context: *anyopaque) bool;
pub extern fn ImGui_ImplSDL3_InitForVulkan(window: ?*sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForD3D(window: ?*sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForMetal(window: ?*sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForSDLRenderer(window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) bool;
pub extern fn ImGui_ImplSDL3_InitForSDLGPU(window: ?*sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForOther(window: ?*sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_Shutdown() void;
pub extern fn ImGui_ImplSDL3_NewFrame() void;
pub extern fn ImGui_ImplSDL3_ProcessEvent(event: ?*sdl.SDL_Event) bool;

pub extern fn ImGui_ImplSDLRenderer3_Init(renderer: ?*sdl.SDL_Renderer) bool;
pub extern fn ImGui_ImplSDLRenderer3_Shutdown() void;
pub extern fn ImGui_ImplSDLRenderer3_NewFrame() void;
pub extern fn ImGui_ImplSDLRenderer3_RenderDrawData(draw_data: *const c.ImDrawData, renderer: ?*sdl.SDL_Renderer) void;

const ImGui_ImplSDLGPU3_InitInfo = struct {
    Device: ?*sdl.SDL_GPUDevice = null,
    ColorTargetFormat: sdl.SDL_GPUTextureFormat = sdl.SDL_GPU_TEXTUREFORMAT_INVALID,
    MSAASamples: sdl.SDL_GPUSampleCount = sdl.SDL_GPU_SAMPLECOUNT_1,
};
pub extern fn ImGui_ImplSDLGPU3_Init(info: ?*ImGui_ImplSDLGPU3_InitInfo) bool;
pub extern fn ImGui_ImplSDLGPU3_Shutdown() void;
pub extern fn ImGui_ImplSDLGPU3_NewFrame() void;
pub extern fn ImGui_ImplSDLGPU3_PrepareDrawData(draw_data: ?*c.ImDrawData, command_buffer: ?*sdl.SDL_GPUCommandBuffer) void;
pub extern fn ImGui_ImplSDLGPU3_RenderDrawData(draw_data: ?*c.ImDrawData, command_buffer: ?*sdl.SDL_GPUCommandBuffer, render_pass: ?*sdl.SDL_GPURenderPass, pipeline: ?*sdl.SDL_GPUGraphicsPipeline) void;

var im_context: ?*c.ImGuiContext = null;
var backend: Backend = .Renderer;
pub fn init(window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, width: f32, height: f32) void {
    backend = .Renderer;
    im_context = c.ImGui_CreateContext(null);
    c.ImGui_SetCurrentContext(im_context);
    {
        var im_io = c.ImGui_GetIO()[0];
        im_io.IniFilename = null;
        im_io.ConfigFlags = c.ImGuiConfigFlags_NavEnableKeyboard | c.ImGuiConfigFlags_NavEnableGamepad;
        im_io.DisplaySize.x = width;
        im_io.DisplaySize.y = height;
    }

    c.ImGui_StyleColorsDark(null);
    _ = ImGui_ImplSDL3_InitForSDLRenderer(window, renderer);
    _ = ImGui_ImplSDLRenderer3_Init(renderer);
}

pub fn initGPU(window: *sdl.SDL_Window, device: *sdl.SDL_GPUDevice, width: f32, height: f32) void {
    backend = .GPU;
    im_context = c.ImGui_CreateContext(null);
    c.ImGui_SetCurrentContext(im_context);
    {
        var im_io = c.ImGui_GetIO()[0];
        im_io.IniFilename = null;
        im_io.ConfigFlags = c.ImGuiConfigFlags_NavEnableKeyboard | c.ImGuiConfigFlags_NavEnableGamepad;
        im_io.DisplaySize.x = width;
        im_io.DisplaySize.y = height;
    }

    c.ImGui_StyleColorsDark(null);

    var init_info: ImGui_ImplSDLGPU3_InitInfo = .{
        .Device = device,
        .ColorTargetFormat = sdl.SDL_GetGPUSwapchainTextureFormat(device, window),
        .MSAASamples = sdl.SDL_GPU_SAMPLECOUNT_1,
    };
    _ = ImGui_ImplSDL3_InitForSDLGPU(window);
    _ = ImGui_ImplSDLGPU3_Init(&init_info);
}

pub fn deinit() void {
    ImGui_ImplSDL3_Shutdown();

    switch (backend) {
        .Renderer => ImGui_ImplSDLRenderer3_Shutdown(),
        .GPU => ImGui_ImplSDLGPU3_Shutdown(),
    }

    c.ImGui_DestroyContext(im_context);
}

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

pub fn newFrame() void {
    switch (backend) {
        .Renderer => ImGui_ImplSDLRenderer3_NewFrame(),
        .GPU => ImGui_ImplSDLGPU3_NewFrame(),
    }
    ImGui_ImplSDL3_NewFrame();
    c.ImGui_NewFrame();
}

pub fn render(renderer: *sdl.SDL_Renderer) void {
    c.ImGui_Render();
    ImGui_ImplSDLRenderer3_RenderDrawData(c.ImGui_GetDrawData(), renderer);
}

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
