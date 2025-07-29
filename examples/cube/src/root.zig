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
    fill_pipeline: *sdl.SDL_GPUGraphicsPipeline = undefined,
    line_pipeline: *sdl.SDL_GPUGraphicsPipeline = undefined,
    vertex_buffer: *sdl.SDL_GPUBuffer = undefined,
};

const PositionColorVertex = struct {
    x: f32,
    y: f32,
    z: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
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
        state.debug_allocator = backing_allocator.create(DebugAllocator) catch {
            @panic("Failed to initialize debug allocator.");
        };
        state.debug_allocator.* = .init;
    }

    const vertex_shader = loadShader(state, "cube.vert", 0, 0, 0, 0);
    if (vertex_shader == null) {
        @panic("Failed to load vertex shader");
    }
    defer sdl.SDL_ReleaseGPUShader(state.device, vertex_shader);

    const fragment_shader = loadShader(state, "solid_color.frag", 0, 0, 0, 0);
    if (fragment_shader == null) {
        @panic("Failed to load fragment shader");
    }
    defer sdl.SDL_ReleaseGPUShader(state.device, fragment_shader);

    const color_target_descriptions: []const sdl.SDL_GPUColorTargetDescription = &.{.{
        .format = sdl.SDL_GetGPUSwapchainTextureFormat(state.device, state.window),
    }};
    const vertex_buffer_descriptions: []const sdl.SDL_GPUVertexBufferDescription = &.{
        .{
            .slot = 0,
            .input_rate = sdl.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
            .pitch = @sizeOf(PositionColorVertex),
        },
    };
    const vertex_attributes: []const sdl.SDL_GPUVertexAttribute = &.{
        .{
            .buffer_slot = 0,
            .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .location = 0,
            .offset = 0,
        },
        .{
            .buffer_slot = 0,
            .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM,
            .location = 1,
            .offset = @sizeOf(f32) * 3,
        },
    };
    var pipeline_create_info: sdl.SDL_GPUGraphicsPipelineCreateInfo = .{
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = color_target_descriptions.ptr,
        },
        .vertex_input_state = .{
            .num_vertex_buffers = 1,
            .vertex_buffer_descriptions = vertex_buffer_descriptions.ptr,
            .num_vertex_attributes = 2,
            .vertex_attributes = vertex_attributes.ptr,
        },
        .primitive_type = sdl.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
    };

    pipeline_create_info.rasterizer_state.fill_mode = sdl.SDL_GPU_FILLMODE_FILL;
    if (sdl.SDL_CreateGPUGraphicsPipeline(state.device, &pipeline_create_info)) |fill_pipeline| {
        state.fill_pipeline = fill_pipeline;
    } else {
        @panic("Failed to create fill pipeline.");
    }

    pipeline_create_info.rasterizer_state.fill_mode = sdl.SDL_GPU_FILLMODE_LINE;
    if (sdl.SDL_CreateGPUGraphicsPipeline(state.device, &pipeline_create_info)) |line_pipeline| {
        state.line_pipeline = line_pipeline;
    } else {
        @panic("Failed to create line pipeline.");
    }

    var buffer_create_info: sdl.SDL_GPUBufferCreateInfo = .{
        .usage = sdl.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = @sizeOf(PositionColorVertex) * 3,
    };
    if (sdl.SDL_CreateGPUBuffer(state.device, &buffer_create_info)) |buffer| {
        state.vertex_buffer = buffer;
    } else {
        @panic("Failed to create vertex buffer.");
    }

    var transfer_buffer_create_info: sdl.SDL_GPUTransferBufferCreateInfo = .{
        .usage = sdl.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @sizeOf(PositionColorVertex) * 3,
    };
    const opt_transfer_buffer: ?*sdl.SDL_GPUTransferBuffer = sdl.SDL_CreateGPUTransferBuffer(
        state.device,
        &transfer_buffer_create_info,
    );
    if (opt_transfer_buffer) |transfer_buffer| {
        if (sdl.SDL_MapGPUTransferBuffer(state.device, transfer_buffer, false)) |data| {
            var transfer_data: [*]PositionColorVertex = @ptrCast(@alignCast(data));
            transfer_data[0] = .{ .x = -1, .y = -1, .z = 0, .r = 255, .g = 0, .b = 0, .a = 255 };
            transfer_data[1] = .{ .x = 1, .y = -1, .z = 0, .r = 0, .g = 255, .b = 0, .a = 255 };
            transfer_data[2] = .{ .x = 0, .y = 1, .z = 0, .r = 0, .g = 0, .b = 255, .a = 255 };

            sdl.SDL_UnmapGPUTransferBuffer(state.device, transfer_buffer);

            const upload_command_buffer: ?*sdl.SDL_GPUCommandBuffer = sdl.SDL_AcquireGPUCommandBuffer(state.device);
            const copy_pass: ?*sdl.SDL_GPUCopyPass = sdl.SDL_BeginGPUCopyPass(upload_command_buffer);
            sdl.SDL_UploadToGPUBuffer(
                copy_pass,
                &.{
                    .transfer_buffer = transfer_buffer,
                    .offset = 0,
                },
                &.{
                    .buffer = state.vertex_buffer,
                    .offset = 0,
                    .size = @sizeOf(PositionColorVertex) * 3,
                },
                false,
            );

            sdl.SDL_EndGPUCopyPass(copy_pass);
            _ = sdl.SDL_SubmitGPUCommandBuffer(upload_command_buffer);
            sdl.SDL_ReleaseGPUTransferBuffer(state.device, transfer_buffer);
        } else {
            @panic("Failed to map transfer buffer to GPU.");
        }
    } else {
        @panic("Failed to create transfer buffer.");
    }

    return state;
}

pub export fn deinit(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    sdl.SDL_ReleaseGPUGraphicsPipeline(state.device, state.fill_pipeline);
    sdl.SDL_ReleaseGPUGraphicsPipeline(state.device, state.line_pipeline);

    sdl.SDL_ReleaseGPUBuffer(state.device, state.vertex_buffer);

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
    const state: *State = @ptrCast(@alignCast(state_ptr));

    const command_buffer: ?*sdl.SDL_GPUCommandBuffer = sdl.SDL_AcquireGPUCommandBuffer(state.device);
    if (command_buffer == null) {
        std.log.err("Failed to acquire GPU commmand buffer: {s}", .{sdl.SDL_GetError()});
    }

    var opt_swapchain_texture: ?*sdl.SDL_GPUTexture = null;
    if (!sdl.SDL_WaitAndAcquireGPUSwapchainTexture(command_buffer, state.window, &opt_swapchain_texture, null, null)) {
        std.log.err("Failed to acquire GPU swapchain texture: {s}", .{sdl.SDL_GetError()});
    }

    if (opt_swapchain_texture) |swapchain_texture| {
        var color_target_info: sdl.SDL_GPUColorTargetInfo = .{
            .texture = swapchain_texture,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            .load_op = sdl.SDL_GPU_LOADOP_CLEAR,
            .store_op = sdl.SDL_GPU_STOREOP_STORE,
        };
        const render_pass: ?*sdl.SDL_GPURenderPass = sdl.SDL_BeginGPURenderPass(command_buffer, &color_target_info, 1, null);
        sdl.SDL_BindGPUGraphicsPipeline(render_pass, state.fill_pipeline);
        sdl.SDL_BindGPUVertexBuffers(render_pass, 0, &.{ .buffer = state.vertex_buffer, .offset = 0 }, 1);
        sdl.SDL_DrawGPUPrimitives(render_pass, 3, 1, 0, 0);
        sdl.SDL_EndGPURenderPass(render_pass);
    }
    if (!sdl.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        std.log.err("Failed to submit GPU command buffer: {s}", .{sdl.SDL_GetError()});
    }
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
        std.log.info("Loading {s} shader in SPIRV format.", .{name});
        format = sdl.SDL_GPU_SHADERFORMAT_SPIRV;
        extension = ".spv";
    } else if ((backend_formats & sdl.SDL_GPU_SHADERFORMAT_MSL) != 0) {
        std.log.info("Loading {s} shader in MSL format.", .{name});
        format = sdl.SDL_GPU_SHADERFORMAT_MSL;
        entrypoint = "main0";
        extension = ".msl";
    } else if ((backend_formats & sdl.SDL_GPU_SHADERFORMAT_DXIL) != 0) {
        std.log.info("Loading {s} shader in DXIL format.", .{name});
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
        std.log.info("Failed to load shader file: {s}", .{file_name});
    }

    return shader;
}
