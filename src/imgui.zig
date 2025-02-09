const zimgui = @import("zig_imgui");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

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
pub extern fn ImGui_ImplSDLRenderer3_RenderDrawData(draw_data: *const zimgui.DrawData, renderer: ?*c.SDL_Renderer) void;


pub fn init(window: *c.SDL_Window, renderer: *c.SDL_Renderer, width: f32, height: f32) void {
    const im_context = zimgui.CreateContext();
    zimgui.SetCurrentContext(im_context);
    {
        const im_io = zimgui.GetIO();
        im_io.IniFilename = null;
        im_io.ConfigFlags = zimgui.ConfigFlags.with(
            im_io.ConfigFlags,
            .{ .NavEnableKeyboard = true, .NavEnableGamepad = true },
        );
        im_io.DisplaySize.x = width;
        im_io.DisplaySize.y = height;
    }

    _ = ImGui_ImplSDL3_InitForSDLRenderer(window, renderer);
    _ = ImGui_ImplSDLRenderer3_Init(renderer);
    zimgui.StyleColorsDark();
}

pub fn deinit() void {
    ImGui_ImplSDL3_Shutdown();
    ImGui_ImplSDLRenderer3_Shutdown();
    zimgui.DestroyContext();
}

pub fn processEvent(event: c.SDL_Event) bool {
    _ = ImGui_ImplSDL3_ProcessEvent(event);
    const im_io = zimgui.GetIO();
    return im_io.WantCaptureMouse or im_io.WantCaptureKeyboard;
}

pub fn newFrame() void {
    ImGui_ImplSDL3_NewFrame();
    ImGui_ImplSDLRenderer3_NewFrame();
    zimgui.NewFrame();
}

pub fn render(renderer: *c.SDL_Renderer) void {
    zimgui.Render();
    ImGui_ImplSDLRenderer3_RenderDrawData(zimgui.GetDrawData(), renderer);
}
