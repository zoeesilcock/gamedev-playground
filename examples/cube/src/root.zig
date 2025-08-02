const std = @import("std");
const sdl = @import("sdl").c;
const imgui = @import("imgui");
const internal = @import("internal");
const math = @import("math");
const loggingAllocator = if (INTERNAL) @import("logging_allocator").loggingAllocator else undefined;

const INTERNAL: bool = @import("build_options").internal;
const LOG_ALLOCATIONS: bool = @import("build_options").log_allocations;

const Vector2 = math.Vector2;
const Vector3 = math.Vector3;
const Matrix4x4 = math.Matrix4x4;
const X = math.X;
const Y = math.Y;
const Z = math.Z;
const FPSState = internal.FPSState;

// TODO: Remove once Zig has finished migrating to unmanaged-style containers.
const ArrayList = std.ArrayListUnmanaged;

const DebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = INTERNAL,
    .never_unmap = INTERNAL,
});

pub const State = struct {
    game_allocator: *DebugAllocator,
    allocator: std.mem.Allocator,
    debug_allocator: *DebugAllocator = undefined,

    fps_state: ?*FPSState = null,

    window: *sdl.SDL_Window,
    device: *sdl.SDL_GPUDevice,
    fill_pipeline: *sdl.SDL_GPUGraphicsPipeline = undefined,
    line_pipeline: *sdl.SDL_GPUGraphicsPipeline = undefined,
    vertex_buffer: *sdl.SDL_GPUBuffer = undefined,
    index_buffer: *sdl.SDL_GPUBuffer = undefined,
    depth_stencil_texture: *sdl.SDL_GPUTexture = undefined,

    window_width: u32,
    window_height: u32,

    camera: Camera,
    entities: ArrayList(Entity),
};

const Entity = struct {
    position: Vector3 = .{ 0, 0, 0 },
    scale: Vector3 = .{ 1, 1, 1 },
    rotation: Vector3 = .{ 0, 0, 0 },
};

const Camera = struct {
    position: Vector3,
    target: Vector3,
    up: Vector3,
    fov: f32,
    aspect_ratio: f32,
    near_plane: f32,
    far_plane: f32,

    pub fn init(aspect_ratio: f32) Camera {
        return .{
            .position = .{ 5, 5, 5 },
            .target = .{ 0, 0, 0 },
            .up = .{ 0, 1, 0 },
            .fov = 75 * sdl.SDL_PI_F / 180,
            .aspect_ratio = aspect_ratio,
            .near_plane = 0.01,
            .far_plane = 100,
        };
    }

    fn calculateRotationMatrix(rotation: Vector3) Matrix4x4 {
        const a: f32 = @cos(rotation[X]);
        const b: f32 = @sin(rotation[X]);
        const c: f32 = @cos(rotation[Y]);
        const d: f32 = @sin(rotation[Y]);
        const e: f32 = @cos(rotation[Z]);
        const f: f32 = @sin(rotation[Z]);
        const ad: f32 = a * d;
        const bd: f32 = b * d;
        return .new(.{
            c * e,           -c * f,          d,      0,
            bd * e + a * f,  -bd * f + a * e, -b * c, 0,
            -ad * e + b * f, ad * f + b * e,  a * c,  0,
            0,               0,               0,      1,
        });
    }

    pub fn calculateMVPMatrix(self: *Camera, entity: Entity) Matrix4x4 {
        const translation: Matrix4x4 = .new(.{
            1,                  0,                  0,                  0,
            0,                  1,                  0,                  0,
            0,                  0,                  1,                  0,
            entity.position[X], entity.position[Y], entity.position[Z], 1,
        });
        const rotation: Matrix4x4 = calculateRotationMatrix(entity.rotation);
        const scale: Matrix4x4 = .new(.{
            entity.scale[X], 0,               0,               0,
            0,               entity.scale[Y], 0,               0,
            0,               0,               entity.scale[Z], 0,
            0,               0,               0,               1,
        });
        const model: Matrix4x4 = translation.multiply(scale).multiply(rotation);

        const position = self.position;
        const one_over_fov: f32 = 1 / sdl.SDL_tanf(self.fov * 0.5);
        const proj: Matrix4x4 = .new(.{
            one_over_fov / self.aspect_ratio, 0,            0,                                                                       0,
            0,                                one_over_fov, 0,                                                                       0,
            0,                                0,            self.far_plane / (self.near_plane - self.far_plane),                     -1,
            0,                                0,            (self.near_plane * self.far_plane) / (self.near_plane - self.far_plane), 0,
        });

        const target_to_position = position - self.target;
        const vector_a: Vector3 = math.normalizeV3(target_to_position);
        const vector_b: Vector3 = math.normalizeV3(math.crossV3(self.up, vector_a));
        const vector_c: Vector3 = math.crossV3(vector_a, vector_b);
        const view: Matrix4x4 = .new(.{
            vector_b[X],                     vector_c[X],                     vector_a[X],                     0,
            vector_b[Y],                     vector_c[Y],                     vector_a[Y],                     0,
            vector_b[Z],                     vector_c[Z],                     vector_a[Z],                     0,
            -math.dotV3(vector_b, position), -math.dotV3(vector_c, position), -math.dotV3(vector_a, position), 1,
        });

        return model.multiply(view).multiply(proj);
    }
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

const VERTICES: []const PositionColorVertex = &.{
    .{ .x = -1, .y = -1, .z = -1, .r = 255, .g = 0, .b = 0, .a = 255 },
    .{ .x = 1, .y = -1, .z = -1, .r = 255, .g = 0, .b = 0, .a = 255 },
    .{ .x = 1, .y = 1, .z = -1, .r = 255, .g = 0, .b = 0, .a = 255 },
    .{ .x = -1, .y = 1, .z = -1, .r = 255, .g = 0, .b = 0, .a = 255 },

    .{ .x = -1, .y = -1, .z = 1, .r = 0, .g = 255, .b = 0, .a = 255 },
    .{ .x = 1, .y = -1, .z = 1, .r = 0, .g = 255, .b = 0, .a = 255 },
    .{ .x = 1, .y = 1, .z = 1, .r = 0, .g = 255, .b = 0, .a = 255 },
    .{ .x = -1, .y = 1, .z = 1, .r = 0, .g = 255, .b = 0, .a = 255 },

    .{ .x = -1, .y = -1, .z = -1, .r = 0, .g = 0, .b = 255, .a = 255 },
    .{ .x = -1, .y = 1, .z = -1, .r = 0, .g = 0, .b = 255, .a = 255 },
    .{ .x = -1, .y = 1, .z = 1, .r = 0, .g = 0, .b = 255, .a = 255 },
    .{ .x = -1, .y = -1, .z = 1, .r = 0, .g = 0, .b = 255, .a = 255 },

    .{ .x = 1, .y = -1, .z = -1, .r = 200, .g = 0, .b = 200, .a = 255 },
    .{ .x = 1, .y = 1, .z = -1, .r = 200, .g = 0, .b = 200, .a = 255 },
    .{ .x = 1, .y = 1, .z = 1, .r = 200, .g = 0, .b = 200, .a = 255 },
    .{ .x = 1, .y = -1, .z = 1, .r = 200, .g = 0, .b = 200, .a = 255 },

    .{ .x = -1, .y = -1, .z = -1, .r = 200, .g = 200, .b = 0, .a = 255 },
    .{ .x = -1, .y = -1, .z = 1, .r = 200, .g = 200, .b = 0, .a = 255 },
    .{ .x = 1, .y = -1, .z = 1, .r = 200, .g = 200, .b = 0, .a = 255 },
    .{ .x = 1, .y = -1, .z = -1, .r = 200, .g = 200, .b = 0, .a = 255 },

    .{ .x = -1, .y = 1, .z = -1, .r = 0, .g = 200, .b = 200, .a = 255 },
    .{ .x = -1, .y = 1, .z = 1, .r = 0, .g = 200, .b = 200, .a = 255 },
    .{ .x = 1, .y = 1, .z = 1, .r = 0, .g = 200, .b = 200, .a = 255 },
    .{ .x = 1, .y = 1, .z = -1, .r = 0, .g = 200, .b = 200, .a = 255 },
};
const INDICES: []const u16 = &.{
    0,  1,  2,  0,  2,  3,
    6,  5,  4,  7,  6,  4,
    8,  9,  10, 8,  10, 11,
    14, 13, 12, 15, 14, 12,
    16, 17, 18, 16, 18, 19,
    22, 21, 20, 23, 22, 20,
};

pub export fn init(window_width: u32, window_height: u32, window: *sdl.SDL_Window) *anyopaque {
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
        .window_width = window_width,
        .window_height = window_height,
        .device = sdl.SDL_CreateGPUDevice(
            sdl.SDL_GPU_SHADERFORMAT_SPIRV | sdl.SDL_GPU_SHADERFORMAT_DXIL | sdl.SDL_GPU_SHADERFORMAT_MSL,
            true,
            null,
        ).?,
        .camera = Camera.init(@as(f32, @floatFromInt(window_width)) / @as(f32, @floatFromInt(window_height))),
        .entities = .empty,
    };

    if (INTERNAL) {
        state.debug_allocator = backing_allocator.create(DebugAllocator) catch {
            @panic("Failed to initialize debug allocator.");
        };
        state.debug_allocator.* = .init;

        state.fps_state =
            state.debug_allocator.allocator().create(FPSState) catch @panic("Failed to allocate FPS state");
        state.fps_state.?.init(sdl.SDL_GetPerformanceFrequency());
    }

    const new_entity = state.entities.addOne(state.allocator) catch @panic("Failed to add entity");
    new_entity.* = .{};

    const window_claimed = sdl.SDL_ClaimWindowForGPUDevice(state.device, state.window);
    if (!window_claimed) {
        @panic("Failed to claim window for GPU device.");
    }

    const vertex_shader = loadShader(state, "cube.vert", 0, 1, 0, 0);
    if (vertex_shader == null) {
        @panic("Failed to load vertex shader");
    }
    defer sdl.SDL_ReleaseGPUShader(state.device, vertex_shader);

    const fragment_shader = loadShader(state, "solid_color.frag", 0, 0, 0, 0);
    if (fragment_shader == null) {
        @panic("Failed to load fragment shader");
    }
    defer sdl.SDL_ReleaseGPUShader(state.device, fragment_shader);

    var depth_stencil_format: sdl.SDL_GPUTextureFormat = undefined;
    if (sdl.SDL_GPUTextureSupportsFormat(
        state.device,
        sdl.SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT,
        sdl.SDL_GPU_TEXTURETYPE_2D,
        sdl.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    )) {
        depth_stencil_format = sdl.SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT;
    } else if (sdl.SDL_GPUTextureSupportsFormat(
        state.device,
        sdl.SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT,
        sdl.SDL_GPU_TEXTURETYPE_2D,
        sdl.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    )) {
        depth_stencil_format = sdl.SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
    } else {
        @panic("Failed to find a supported stencil format");
    }

    if (sdl.SDL_CreateGPUTexture(
        state.device,
        &.{
            .type = sdl.SDL_GPU_TEXTURETYPE_2D,
            .width = window_width,
            .height = window_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.SDL_GPU_SAMPLECOUNT_1,
            .format = depth_stencil_format,
            .usage = sdl.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        },
    )) |texture| {
        state.depth_stencil_texture = texture;
    } else {
        @panic("Failed to create depth stencil texure");
    }

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
            .has_depth_stencil_target = true,
            .depth_stencil_format = depth_stencil_format,
        },
        .vertex_input_state = .{
            .num_vertex_buffers = 1,
            .vertex_buffer_descriptions = vertex_buffer_descriptions.ptr,
            .num_vertex_attributes = 2,
            .vertex_attributes = vertex_attributes.ptr,
        },
        .depth_stencil_state = .{
            .enable_depth_test = true,
            .enable_depth_write = true,
            .enable_stencil_test = false,
            .compare_op = sdl.SDL_GPU_COMPAREOP_LESS,
            .write_mask = 0xFF,
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
        .size = VERTICES.len * @sizeOf(PositionColorVertex),
    };
    if (sdl.SDL_CreateGPUBuffer(state.device, &buffer_create_info)) |buffer| {
        state.vertex_buffer = buffer;
    } else {
        @panic("Failed to create vertex buffer.");
    }
    buffer_create_info = .{
        .usage = sdl.SDL_GPU_BUFFERUSAGE_INDEX,
        .size = INDICES.len * @sizeOf(u16),
    };
    if (sdl.SDL_CreateGPUBuffer(state.device, &buffer_create_info)) |buffer| {
        state.index_buffer = buffer;
    } else {
        @panic("Failed to create index buffer.");
    }

    submitVertexData(state);

    if (INTERNAL) {
        imgui.initGPU(state.window, state.device, @floatFromInt(window_width), @floatFromInt(window_height));
    }

    return state;
}

pub export fn deinit(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        imgui.deinit();
    }

    sdl.SDL_ReleaseGPUGraphicsPipeline(state.device, state.fill_pipeline);
    sdl.SDL_ReleaseGPUGraphicsPipeline(state.device, state.line_pipeline);

    sdl.SDL_ReleaseGPUTexture(state.device, state.depth_stencil_texture);

    sdl.SDL_ReleaseGPUBuffer(state.device, state.vertex_buffer);
    sdl.SDL_ReleaseGPUBuffer(state.device, state.index_buffer);

    sdl.SDL_ReleaseWindowFromGPUDevice(state.device, state.window);
    sdl.SDL_DestroyGPUDevice(state.device);
}

pub export fn willReload(state_ptr: *anyopaque) void {
    _ = state_ptr;

    if (INTERNAL) {
        imgui.deinit();
    }
}

pub export fn reloaded(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));
    submitVertexData(state);

    if (INTERNAL) {
        imgui.initGPU(state.window, state.device, @floatFromInt(state.window_width), @floatFromInt(state.window_height));
    }
}

pub export fn processInput(state_ptr: *anyopaque) bool {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    var continue_running: bool = true;
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event)) {
        if (event.type == sdl.SDL_EVENT_QUIT or (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE)) {
            continue_running = false;
            break;
        }

        if (event.type == sdl.SDL_EVENT_KEY_DOWN) {
            switch (event.key.key) {
                sdl.SDLK_F1 => {
                    state.fps_state.?.toggleMode();
                },
                else => {},
            }
        }
    }

    return continue_running;
}

pub export fn tick(state_ptr: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr));

    if (INTERNAL) {
        state.fps_state.?.addFrameTime(sdl.SDL_GetPerformanceCounter());
    }

    const test_entity = &state.entities.items[0];
    test_entity.rotation[Y] += 0.01;
    if (test_entity.rotation[Y] > 360) {
        test_entity.rotation[Y] -= 360;
    }
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

        var depth_stencil_target_info: sdl.SDL_GPUDepthStencilTargetInfo = .{
            .texture = state.depth_stencil_texture,
            .cycle = true,
            .clear_depth = 1,
            .clear_stencil = 0,
            .load_op = sdl.SDL_GPU_LOADOP_CLEAR,
            .store_op = sdl.SDL_GPU_STOREOP_STORE,
            .stencil_load_op = sdl.SDL_GPU_LOADOP_CLEAR,
            .stencil_store_op = sdl.SDL_GPU_STOREOP_STORE,
        };

        const render_pass: ?*sdl.SDL_GPURenderPass = sdl.SDL_BeginGPURenderPass(
            command_buffer,
            &color_target_info,
            1,
            &depth_stencil_target_info,
        );
        sdl.SDL_BindGPUGraphicsPipeline(render_pass, state.fill_pipeline);
        sdl.SDL_BindGPUVertexBuffers(render_pass, 0, &.{ .buffer = state.vertex_buffer, .offset = 0 }, 1);
        sdl.SDL_BindGPUIndexBuffer(render_pass, &.{ .buffer = state.index_buffer, .offset = 0 }, sdl.SDL_GPU_INDEXELEMENTSIZE_16BIT);

        for (state.entities.items) |entity| {
            var mvp = state.camera.calculateMVPMatrix(entity);
            sdl.SDL_PushGPUVertexUniformData(command_buffer, 0, &mvp, @sizeOf(Matrix4x4));
            sdl.SDL_DrawGPUIndexedPrimitives(render_pass, INDICES.len, 1, 0, 0, 0);
        }

        sdl.SDL_EndGPURenderPass(render_pass);

        if (INTERNAL) {
            imgui.newFrame();
            state.fps_state.?.draw();
            imgui.renderGPU(command_buffer, swapchain_texture);
        }
    }

    if (!sdl.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        std.log.err("Failed to submit GPU command buffer: {s}", .{sdl.SDL_GetError()});
    }
}

fn submitVertexData(state: *State) void {
    var transfer_buffer_create_info: sdl.SDL_GPUTransferBufferCreateInfo = .{
        .usage = sdl.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @sizeOf(PositionColorVertex) * VERTICES.len + @sizeOf(u16) * INDICES.len,
    };
    const opt_transfer_buffer: ?*sdl.SDL_GPUTransferBuffer = sdl.SDL_CreateGPUTransferBuffer(
        state.device,
        &transfer_buffer_create_info,
    );

    if (opt_transfer_buffer) |transfer_buffer| {
        if (sdl.SDL_MapGPUTransferBuffer(state.device, transfer_buffer, false)) |data| {
            var transfer_data: [*]PositionColorVertex = @ptrCast(@alignCast(data));
            @memcpy(transfer_data[0..VERTICES.len], VERTICES);

            var transfer_data2: [*]u16 = @ptrCast(@alignCast(transfer_data + VERTICES.len));
            @memcpy(transfer_data2[0..INDICES.len], INDICES);

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
                    .size = VERTICES.len * @sizeOf(PositionColorVertex),
                },
                false,
            );
            sdl.SDL_UploadToGPUBuffer(
                copy_pass,
                &.{
                    .transfer_buffer = transfer_buffer,
                    .offset = VERTICES.len * @sizeOf(PositionColorVertex),
                },
                &.{
                    .buffer = state.index_buffer,
                    .offset = 0,
                    .size = INDICES.len * @sizeOf(u16),
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
