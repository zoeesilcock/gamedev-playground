const c = @import("game.zig").c;

pub extern fn ImGui_ImplSDL3_InitForOpenGL(window: ?*c.SDL_Window, sdl_gl_context: *anyopaque) bool;
pub extern fn ImGui_ImplSDL3_InitForVulkan(window: ?*c.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForD3D(window: ?*c.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForMetal(window: ?*c.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForSDLRenderer(window: ?*c.SDL_Window, renderer: ?*c.SDL_Renderer) bool;
pub extern fn ImGui_ImplSDL3_InitForOther(window: ?*c.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_Shutdown() void;
pub extern fn ImGui_ImplSDL3_NewFrame() void;
pub extern fn ImGui_ImplSDL3_ProcessEvent(event: c.SDL_Event) bool;

pub extern fn ImGui_ImplSDLRenderer3_Init(renderer: ?*c.SDL_Renderer) bool;
pub extern fn ImGui_ImplSDLRenderer3_Shutdown() void;
pub extern fn ImGui_ImplSDLRenderer3_NewFrame() void;
pub extern fn ImGui_ImplSDLRenderer3_RenderDrawData(draw_data: *const c.ImDrawData, renderer: ?*c.SDL_Renderer) void;

var im_context: ?*c.ImGuiContext = null;
pub fn init(window: *c.SDL_Window, renderer: *c.SDL_Renderer, width: f32, height: f32) void {
    im_context = c.igCreateContext(null);
    c.igSetCurrentContext(im_context);
    {
        var im_io = c.igGetIO()[0];
        im_io.IniFilename = null;
        im_io.ConfigFlags = c.ImGuiConfigFlags_NavEnableKeyboard | c.ImGuiConfigFlags_NavEnableGamepad;
        im_io.DisplaySize.x = width;
        im_io.DisplaySize.y = height;
    }

    c.igStyleColorsDark(null);
    _ = ImGui_ImplSDL3_InitForSDLRenderer(window, renderer);
    _ = ImGui_ImplSDLRenderer3_Init(renderer);
}

pub fn deinit() void {
    ImGui_ImplSDL3_Shutdown();
    ImGui_ImplSDLRenderer3_Shutdown();
    c.igDestroyContext(im_context);
}

pub fn processEvent(event: c.SDL_Event) bool {
    _ = ImGui_ImplSDL3_ProcessEvent(event);
    const im_io = c.igGetIO()[0];
    return im_io.WantCaptureMouse or im_io.WantCaptureKeyboard;
}

pub fn newFrame() void {
    ImGui_ImplSDL3_NewFrame();
    ImGui_ImplSDLRenderer3_NewFrame();
    c.igNewFrame();
}

pub fn render(renderer: *c.SDL_Renderer) void {
    c.igRender();
    ImGui_ImplSDLRenderer3_RenderDrawData(c.igGetDrawData(), renderer);
}
