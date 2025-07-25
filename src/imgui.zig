pub const c_sdl = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

pub const c_imgui = @cImport({
    @cInclude("dcimgui.h");
});

pub extern fn ImGui_ImplSDL3_InitForOpenGL(window: ?*c_sdl.SDL_Window, sdl_gl_context: *anyopaque) bool;
pub extern fn ImGui_ImplSDL3_InitForVulkan(window: ?*c_sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForD3D(window: ?*c_sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForMetal(window: ?*c_sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_InitForSDLRenderer(window: ?*c_sdl.SDL_Window, renderer: ?*c_sdl.SDL_Renderer) bool;
pub extern fn ImGui_ImplSDL3_InitForOther(window: ?*c_sdl.SDL_Window) bool;
pub extern fn ImGui_ImplSDL3_Shutdown() void;
pub extern fn ImGui_ImplSDL3_NewFrame() void;
pub extern fn ImGui_ImplSDL3_ProcessEvent(event: ?*c_sdl.SDL_Event) bool;

pub extern fn ImGui_ImplSDLRenderer3_Init(renderer: ?*c_sdl.SDL_Renderer) bool;
pub extern fn ImGui_ImplSDLRenderer3_Shutdown() void;
pub extern fn ImGui_ImplSDLRenderer3_NewFrame() void;
pub extern fn ImGui_ImplSDLRenderer3_RenderDrawData(draw_data: *const c_imgui.ImDrawData, renderer: ?*c_sdl.SDL_Renderer) void;

var im_context: ?*c_imgui.ImGuiContext = null;
pub fn init(window: *c_sdl.SDL_Window, renderer: *c_sdl.SDL_Renderer, width: f32, height: f32) void {
    im_context = c_imgui.ImGui_CreateContext(null);
    c_imgui.ImGui_SetCurrentContext(im_context);
    {
        var im_io = c_imgui.ImGui_GetIO()[0];
        im_io.IniFilename = null;
        im_io.ConfigFlags = c_imgui.ImGuiConfigFlags_NavEnableKeyboard | c_imgui.ImGuiConfigFlags_NavEnableGamepad;
        im_io.DisplaySize.x = width;
        im_io.DisplaySize.y = height;
    }

    c_imgui.ImGui_StyleColorsDark(null);
    _ = ImGui_ImplSDL3_InitForSDLRenderer(window, renderer);
    _ = ImGui_ImplSDLRenderer3_Init(renderer);
}

pub fn deinit() void {
    ImGui_ImplSDL3_Shutdown();
    ImGui_ImplSDLRenderer3_Shutdown();
    c_imgui.ImGui_DestroyContext(im_context);
}

pub fn processEvent(event: *c_sdl.SDL_Event) bool {
    _ = ImGui_ImplSDL3_ProcessEvent(event);
    const im_io = c_imgui.ImGui_GetIO()[0];
    const is_key_event =
        event.type == c_sdl.SDL_EVENT_KEY_DOWN or
        event.type == c_sdl.SDL_EVENT_KEY_UP;
    const is_mouse_event =
        event.type == c_sdl.SDL_EVENT_MOUSE_MOTION or
        event.type == c_sdl.SDL_EVENT_MOUSE_BUTTON_DOWN or
        event.type == c_sdl.SDL_EVENT_MOUSE_BUTTON_UP;

    return
        (is_mouse_event and im_io.WantCaptureMouse) or
        (is_key_event and im_io.WantCaptureKeyboard);
}

pub fn newFrame() void {
    ImGui_ImplSDL3_NewFrame();
    ImGui_ImplSDLRenderer3_NewFrame();
    c_imgui.ImGui_NewFrame();
}

pub fn render(renderer: *c_sdl.SDL_Renderer) void {
    c_imgui.ImGui_Render();
    ImGui_ImplSDLRenderer3_RenderDrawData(c_imgui.ImGui_GetDrawData(), renderer);
}
