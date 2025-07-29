const std = @import("std");
const sdl = @import("sdl").c;
const loggingAllocator = if (INTERNAL) @import("logging_allocator").loggingAllocator else undefined;

const INTERNAL: bool = @import("build_options").internal;
const LOG_ALLOCATIONS: bool = @import("build_options").log_allocations;

const DebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = INTERNAL,
    .never_unmap = INTERNAL,
});

pub const State = struct {
    game_allocator: *DebugAllocator,
    allocator: std.mem.Allocator,
    debug_allocator: *DebugAllocator = undefined,

    window: *sdl.SDL_Window,
    device: *sdl.SDL_GPUDevice,
};

pub export fn init(window_width: u32, window_height: u32, window: *sdl.SDL_Window) *anyopaque {
    _ = window_width;
    _ = window_height;

    var backing_allocator = std.heap.page_allocator;
    var game_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize game allocator."));
    game_allocator.* = .init;

    var allocator = game_allocator.allocator();
    if (INTERNAL and LOG_ALLOCATIONS) {
        const logging_allocator = loggingAllocator(game_allocator.allocator());
        var logging_allocator_ptr = (backing_allocator.create(@TypeOf(logging_allocator)) catch @panic("Failed to initialize logging allocator."));
        logging_allocator_ptr.* = logging_allocator;
        allocator = logging_allocator_ptr.allocator();
    }

    var state: *State = allocator.create(State) catch @panic("Out of memory");
    state.* = .{
        .allocator = allocator,
        .game_allocator = game_allocator,
        .window = window,
        .device = sdl.SDL_CreateGPUDevice(
            sdl.SDL_GPU_SHADERFORMAT_SPIRV | sdl.SDL_GPU_SHADERFORMAT_DXIL | sdl.SDL_GPU_SHADERFORMAT_MSL,
            true,
            null,
        ).?,
    };

    const window_claimed = sdl.SDL_ClaimWindowForGPUDevice(state.device, state.window);
    if (!window_claimed) {
        @panic("Failed to claim window for GPU device.");
    }

    if (INTERNAL) {
        state.debug_allocator = (backing_allocator.create(DebugAllocator) catch @panic("Failed to initialize debug allocator."));
        state.debug_allocator.* = .init;
    }

    const vertex_shader = loadShader(state, "cube.vert", 0, 0, 0, 0);
    if (vertex_shader == null) {
        @panic("Failed to load vertex shader");
    }
    const fragment_shader = loadShader(state, "solid_color.frag", 0, 0, 0, 0);
    if (fragment_shader == null) {
        @panic("Failed to load fragment shader");
    }

    return state;
}

pub export fn deinit(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    sdl.SDL_ReleaseWindowFromGPUDevice(state.device, state.window);
    sdl.SDL_DestroyGPUDevice(state.device);
}

pub export fn willReload(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn reloaded(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn processInput(state_ptr: *anyopaque) bool {
    _ = state_ptr;

    var continue_running: bool = true;
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event)) {
        if (event.type == sdl.SDL_EVENT_QUIT or (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE)) {
            continue_running = false;
            break;
        }
    }

    return continue_running;
}

pub export fn tick(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

pub export fn draw(state_ptr: *anyopaque) void {
    _ = state_ptr;
}

fn loadShader(
    state: *State,
    name: []const u8,
    sampler_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    storage_texture_count: u32,
) ?*sdl.SDL_GPUShader {
    var shader: ?*sdl.SDL_GPUShader = null;
    var entrypoint: []const u8 = "main";
    var extension: []const u8 = "";
    var format: sdl.SDL_GPUShaderFormat = sdl.SDL_GPU_SHADERFORMAT_INVALID;
    var stage: sdl.SDL_GPUShaderStage = sdl.SDL_GPU_SHADERSTAGE_VERTEX;
    if (std.mem.indexOf(u8, name, ".frag") != null) {
        stage = sdl.SDL_GPU_SHADERSTAGE_FRAGMENT;
    }

    const backend_formats: sdl.SDL_GPUShaderFormat = sdl.SDL_GetGPUShaderFormats(state.device);
    if ((backend_formats & sdl.SDL_GPU_SHADERFORMAT_SPIRV) != 0) {
        std.log.info("Loading {s} shader in SPIRV format.", .{ name });
        format = sdl.SDL_GPU_SHADERFORMAT_SPIRV;
        extension = ".spv";
    } else if ((backend_formats & sdl.SDL_GPU_SHADERFORMAT_MSL) != 0) {
        std.log.info("Loading {s} shader in MSL format.", .{ name });
        format = sdl.SDL_GPU_SHADERFORMAT_MSL;
        entrypoint = "main0";
        extension = ".msl";
    } else if ((backend_formats & sdl.SDL_GPU_SHADERFORMAT_DXIL) != 0) {
        std.log.info("Loading {s} shader in DXIL format.", .{ name });
        format = sdl.SDL_GPU_SHADERFORMAT_DXIL;
        extension = ".dxil";
    } else {
        std.log.info("Unrecognized shader format: {d}", .{format});
        @panic("Unrecognized shader format");
    }

    var buf: [128]u8 = undefined;
    const file_name: []u8 = std.fmt.bufPrintZ(&buf, "assets/shaders/{s}{s}", .{ name, extension }) catch "";
    var code_size: usize = 0;
    if (sdl.SDL_LoadFile(file_name.ptr, &code_size)) |code| {
        const shader_info: sdl.SDL_GPUShaderCreateInfo = .{
            .code = @ptrCast(code),
            .code_size = code_size,
            .entrypoint = entrypoint.ptr,
            .format = format,
            .stage = stage,
            .num_samplers = sampler_count,
            .num_uniform_buffers = uniform_buffer_count,
            .num_storage_buffers = storage_buffer_count,
            .num_storage_textures = storage_texture_count,
        };
        shader = sdl.SDL_CreateGPUShader(state.device, &shader_info);
    } else {
        std.log.info("Failed to load shader file: {s}", .{ file_name });
    }

    return shader;
}
