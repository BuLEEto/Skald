package skald

// Skald's one render pipeline: a single graphics pipeline drives every
// primitive the framework can emit (rounded rects, glyph quads,
// RGBA-textured quads, solid-color triangles). The fragment shader
// branches on a per-vertex `kind` attribute. One pipeline, one draw
// call per Batch_Range — switching range just means new scissor, and
// optionally a new descriptor set (per-image texture override).
//
// GLSL SPIR-V is compiled out-of-tree via glslc (see shaders/) and
// embedded via #load.

import "core:fmt"
import vk "vendor:vulkan"

// Uniforms mirrors the `Uniforms` struct in the shader: framebuffer
// size as a 16-byte-aligned UBO. Vulkan requires UBOs to be at least 16
// bytes; the _pad keeps us at the minimum size.
@(private)
Uniforms :: struct #align(16) {
	fb_size: [2]f32,
	_pad:    [2]f32,
}

@(private)
VERT_SPV_BYTES :: #load("shaders/ui.vert.spv")
@(private)
FRAG_SPV_BYTES :: #load("shaders/ui.frag.spv")

// Pipeline owns the objects that stay alive for the lifetime of the
// renderer: shader modules, descriptor layout/pool/set, pipeline layout
// + pipeline, the persistently-mapped uniform buffer, the sampler
// shared across the glyph atlas and every image, and the growable
// vertex/index buffers the batch flushes into each frame.
//
// The descriptor set is allocated once at init and its binding 1 is
// rewritten on atlas resize via `pipeline_rebuild_descriptor`. Image
// draws use their own per-image descriptor sets allocated from
// Image_Cache's own pool (same layout, binding 1 points at the image's
// view).
@(private)
// Pipeline owns the DEVICE-scoped graphics plumbing shared across every
// window Skald renders into: shader modules, descriptor layouts, the
// VkPipeline + pipeline layout, the texture sampler, and the descriptor
// pool that per-target + per-image descriptor sets are allocated from.
//
// Per-window writable state — the vertex buffer, index buffer, uniform
// buffer, and the atlas-bound descriptor set — lives on `Window_Target`
// so two windows submitting in the same frame don't race on shared
// writes. See `target_vk_init` / `target_vk_destroy` / `target_upload_batch`.
Pipeline :: struct {
	vert_module:  vk.ShaderModule,
	frag_module:  vk.ShaderModule,

	dset_layout:  vk.DescriptorSetLayout,
	pipe_layout:  vk.PipelineLayout,
	pipeline:     vk.Pipeline,

	sampler:      vk.Sampler,
	dset_pool:    vk.DescriptorPool,
}

@(private)
pipeline_init :: proc(p: ^Pipeline, r: ^Renderer, t: ^Text) -> (ok: bool) {
	if !pipeline_create_shaders   (p, r) { return }
	if !pipeline_create_descriptor(p, r) { return }
	if !pipeline_create_pipeline  (p, r) { return }
	if !pipeline_create_sampler   (p, r) { return }
	ok = true
	return
}

@(private)
pipeline_destroy :: proc(p: ^Pipeline, r: ^Renderer) {
	d := r.device

	if p.sampler     != 0 { vk.DestroySampler(d, p.sampler, nil); p.sampler = 0 }
	if p.dset_pool   != 0 { vk.DestroyDescriptorPool(d, p.dset_pool, nil); p.dset_pool = 0 }
	if p.dset_layout != 0 { vk.DestroyDescriptorSetLayout(d, p.dset_layout, nil); p.dset_layout = 0 }

	if p.pipeline    != 0 { vk.DestroyPipeline(d, p.pipeline, nil);          p.pipeline    = 0 }
	if p.pipe_layout != 0 { vk.DestroyPipelineLayout(d, p.pipe_layout, nil); p.pipe_layout = 0 }
	if p.vert_module != 0 { vk.DestroyShaderModule(d, p.vert_module, nil);   p.vert_module = 0 }
	if p.frag_module != 0 { vk.DestroyShaderModule(d, p.frag_module, nil);   p.frag_module = 0 }
}

// target_upload_batch writes the frame's vertices + indices into the
// target's HOST_VISIBLE buffers, growing them (next pow2) if the
// existing allocations aren't big enough. Called once per target per
// frame from frame_end. No-op on an empty batch. Per-target ownership
// means two windows submitting in the same frame never race on
// overlapping writes — the big reason this state isn't on Pipeline.
@(private)
target_upload_batch :: proc(r: ^Renderer, t: ^Window_Target, b: ^Batch) {
	if len(b.vertices) == 0 { return }
	vbytes := vk.DeviceSize(len(b.vertices) * size_of(Vertex))
	ibytes := vk.DeviceSize(len(b.indices)  * size_of(u32))

	if vbytes > t.vertex_buf_bytes {
		if t.vertex_buf != 0 { vk.DestroyBuffer(r.device, t.vertex_buf, nil) }
		if t.vertex_mem != 0 { vk.FreeMemory   (r.device, t.vertex_mem, nil) }
		t.vertex_buf_bytes = vk.DeviceSize(next_pow2_u64(u64(vbytes)))
		t.vertex_buf, t.vertex_mem = vk_make_buffer(
			r, t.vertex_buf_bytes, {.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
	}
	if ibytes > t.index_buf_bytes {
		if t.index_buf != 0 { vk.DestroyBuffer(r.device, t.index_buf, nil) }
		if t.index_mem != 0 { vk.FreeMemory   (r.device, t.index_mem, nil) }
		t.index_buf_bytes = vk.DeviceSize(next_pow2_u64(u64(ibytes)))
		t.index_buf, t.index_mem = vk_make_buffer(
			r, t.index_buf_bytes, {.INDEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
	}

	ptr: rawptr
	vk.MapMemory(r.device, t.vertex_mem, 0, vbytes, {}, &ptr)
	vk_copy_bytes(ptr, raw_data(b.vertices), int(vbytes))
	vk.UnmapMemory(r.device, t.vertex_mem)

	vk.MapMemory(r.device, t.index_mem, 0, ibytes, {}, &ptr)
	vk_copy_bytes(ptr, raw_data(b.indices), int(ibytes))
	vk.UnmapMemory(r.device, t.index_mem)
}

// target_vk_init allocates the per-window descriptor set that binds
// the shared text atlas. Vertex + index buffers grow lazily on the
// first `target_upload_batch` call, and fb_size travels via push
// constants — so there's nothing else to wire here. Called from
// `renderer_init` for the primary target and from
// `drain_window_ops`.Open for secondaries.
@(private)
target_vk_init :: proc(r: ^Renderer, t: ^Window_Target, p: ^Pipeline, text: ^Text) -> bool {
	ai := vk.DescriptorSetAllocateInfo{
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = p.dset_pool,
		descriptorSetCount = 1,
		pSetLayouts = &p.dset_layout,
	}
	if res := vk.AllocateDescriptorSets(r.device, &ai, &t.dset); res != .SUCCESS {
		fmt.eprintfln("skald: AllocateDescriptorSets (target): %v", res); return false
	}
	target_rebuild_descriptor(r, t, p, text.atlas_view)
	return true
}

// target_vk_destroy releases the per-target descriptor set + the on-
// demand vertex + index buffers. Caller is responsible for a
// `vk.DeviceWaitIdle` or equivalent fence wait first — we don't
// synchronise here.
@(private)
target_vk_destroy :: proc(r: ^Renderer, t: ^Window_Target, p: ^Pipeline) {
	d := r.device

	if t.vertex_buf != 0 { vk.DestroyBuffer(d, t.vertex_buf, nil); t.vertex_buf = 0 }
	if t.vertex_mem != 0 { vk.FreeMemory   (d, t.vertex_mem, nil); t.vertex_mem = 0 }
	t.vertex_buf_bytes = 0
	if t.index_buf  != 0 { vk.DestroyBuffer(d, t.index_buf,  nil); t.index_buf  = 0 }
	if t.index_mem  != 0 { vk.FreeMemory   (d, t.index_mem,  nil); t.index_mem  = 0 }
	t.index_buf_bytes = 0

	if t.dset != 0 {
		vk.FreeDescriptorSets(d, p.dset_pool, 1, &t.dset)
		t.dset = 0
	}
}

// target_rebuild_descriptor rewrites this target's single descriptor
// binding to point at `view` (the shared text atlas). Called from
// `target_vk_init` at setup time and broadcast across all open targets
// whenever the atlas resizes.
@(private)
target_rebuild_descriptor :: proc(r: ^Renderer, t: ^Window_Target, p: ^Pipeline, view: vk.ImageView) {
	ii := vk.DescriptorImageInfo{
		sampler = p.sampler, imageView = view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet{
		sType = .WRITE_DESCRIPTOR_SET, dstSet = t.dset,
		dstBinding = 0, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER,
		pImageInfo = &ii,
	}
	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
}

// targets_rebuild_descriptors broadcasts a descriptor rebuild to every
// open target. Called when the text atlas resizes — every target's
// descriptor set binding 1 needs to be re-pointed at the fresh view.
@(private)
targets_rebuild_descriptors :: proc(r: ^Renderer, p: ^Pipeline, view: vk.ImageView) {
	for t in r.targets {
		if t.dset != 0 {
			target_rebuild_descriptor(r, t, p, view)
		}
	}
}

// ---- internal ----

@(private)
pipeline_create_shaders :: proc(p: ^Pipeline, r: ^Renderer) -> bool {
	vmod, vok := vk_make_shader_module(r, VERT_SPV_BYTES)
	if !vok { return false }
	fmod, fok := vk_make_shader_module(r, FRAG_SPV_BYTES)
	if !fok { vk.DestroyShaderModule(r.device, vmod, nil); return false }
	p.vert_module = vmod
	p.frag_module = fmod
	return true
}

@(private)
pipeline_create_descriptor :: proc(p: ^Pipeline, r: ^Renderer) -> bool {
	// Single binding: the combined image sampler — atlas for the
	// default set, per-image views for image draws. fb_size used to
	// live at binding 0 as a uniform buffer; it's a push constant now.
	bindings := [?]vk.DescriptorSetLayoutBinding{
		{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}
	li := vk.DescriptorSetLayoutCreateInfo{
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)), pBindings = raw_data(bindings[:]),
	}
	if res := vk.CreateDescriptorSetLayout(r.device, &li, nil, &p.dset_layout); res != .SUCCESS {
		fmt.eprintfln("skald: CreateDescriptorSetLayout: %v", res); return false
	}
	// Pool size accommodates a healthy number of descriptor sets: one
	// per open window (atlas) plus headroom for per-image sets as the
	// image cache grows. FREE_DESCRIPTOR_SET lets us free individual
	// sets when a window closes so long-running apps that churn
	// popovers don't exhaust the pool.
	POOL_SETS :: 256
	pool_sizes := [?]vk.DescriptorPoolSize{
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = POOL_SETS},
	}
	pi := vk.DescriptorPoolCreateInfo{
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		// FREE_DESCRIPTOR_SET lets individual sets be freed when a
		// window closes — without it, closing + reopening popovers
		// in a long-running DE would gradually exhaust the pool.
		flags = {.FREE_DESCRIPTOR_SET},
		maxSets = POOL_SETS,
		poolSizeCount = u32(len(pool_sizes)), pPoolSizes = raw_data(pool_sizes[:]),
	}
	if res := vk.CreateDescriptorPool(r.device, &pi, nil, &p.dset_pool); res != .SUCCESS {
		fmt.eprintfln("skald: CreateDescriptorPool: %v", res); return false
	}
	return true
}

@(private)
pipeline_create_pipeline :: proc(p: ^Pipeline, r: ^Renderer) -> bool {
	stages := [?]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = p.vert_module, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = p.frag_module, pName = "main"},
	}
	vbind := vk.VertexInputBindingDescription{binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
	vattr := [?]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, color))},
		{location = 2, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Vertex, center))},
		{location = 3, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Vertex, half_size))},
		{location = 4, binding = 0, format = .R32_SFLOAT,          offset = u32(offset_of(Vertex, radius))},
		{location = 5, binding = 0, format = .R32_SFLOAT,          offset = u32(offset_of(Vertex, kind))},
		{location = 6, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Vertex, uv))},
	}
	vinput := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = &vbind,
		vertexAttributeDescriptionCount = u32(len(vattr)), pVertexAttributeDescriptions = raw_data(vattr[:]),
	}
	ia := vk.PipelineInputAssemblyStateCreateInfo{
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_LIST,
	}
	vp := vk.PipelineViewportStateCreateInfo{
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1,
	}
	rs := vk.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL, cullMode = {}, frontFace = .COUNTER_CLOCKWISE, lineWidth = 1,
	}
	ms := vk.PipelineMultisampleStateCreateInfo{
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1},
	}
	// Standard source-over alpha blend.
	blend_attach := vk.PipelineColorBlendAttachmentState{
		blendEnable = true,
		srcColorBlendFactor = .SRC_ALPHA, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,       dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA, alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	cb := vk.PipelineColorBlendStateCreateInfo{
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1, pAttachments = &blend_attach,
	}
	dyn_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn := vk.PipelineDynamicStateCreateInfo{
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dyn_states)), pDynamicStates = raw_data(dyn_states[:]),
	}
	// Push-constant range carries fb_size across all draws in a frame.
	// 8 bytes (vec2) is within the 128-byte guaranteed minimum; no
	// alignment surprises. vkCmdPushConstants per frame_end sets this
	// before any draws bind the pipeline.
	pc_range := vk.PushConstantRange{
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(Uniforms),
	}
	pl_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1, pSetLayouts = &p.dset_layout,
		pushConstantRangeCount = 1, pPushConstantRanges = &pc_range,
	}
	if res := vk.CreatePipelineLayout(r.device, &pl_info, nil, &p.pipe_layout); res != .SUCCESS {
		fmt.eprintfln("skald: CreatePipelineLayout: %v", res); return false
	}
	color_fmt := r.swap_format
	dyn_rendering := vk.PipelineRenderingCreateInfo{
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = 1, pColorAttachmentFormats = &color_fmt,
	}
	info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO, pNext = &dyn_rendering,
		stageCount = u32(len(stages)), pStages = raw_data(stages[:]),
		pVertexInputState = &vinput, pInputAssemblyState = &ia,
		pViewportState = &vp, pRasterizationState = &rs,
		pMultisampleState = &ms, pColorBlendState = &cb,
		pDynamicState = &dyn, layout = p.pipe_layout,
	}
	if res := vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &p.pipeline); res != .SUCCESS {
		fmt.eprintfln("skald: CreateGraphicsPipelines: %v", res); return false
	}
	return true
}

@(private)
pipeline_create_sampler :: proc(p: ^Pipeline, r: ^Renderer) -> bool {
	// Linear + trilinear so image mip chains (PNG thumbnails, responsive
	// photos) stay crisp at arbitrary scales. Harmless for the glyph
	// atlas — single-level, so the sampler only ever reads mip 0 there.
	info := vk.SamplerCreateInfo{
		sType = .SAMPLER_CREATE_INFO,
		magFilter = .LINEAR, minFilter = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE, addressModeV = .CLAMP_TO_EDGE, addressModeW = .CLAMP_TO_EDGE,
		mipmapMode = .LINEAR, maxLod = 32,
	}
	if res := vk.CreateSampler(r.device, &info, nil, &p.sampler); res != .SUCCESS {
		fmt.eprintfln("skald: CreateSampler: %v", res); return false
	}
	return true
}

// ---- shared Vulkan helpers (used by pipeline, text, image) ----

@(private)
vk_make_shader_module :: proc(r: ^Renderer, bytes: []u8) -> (vk.ShaderModule, bool) {
	info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(bytes), pCode = cast(^u32)raw_data(bytes),
	}
	m: vk.ShaderModule
	if res := vk.CreateShaderModule(r.device, &info, nil, &m); res != .SUCCESS {
		fmt.eprintfln("skald: CreateShaderModule: %v", res)
		return 0, false
	}
	return m, true
}

@(private)
vk_find_mem_type :: proc(r: ^Renderer, type_bits: u32, props: vk.MemoryPropertyFlags) -> u32 {
	for i in 0..<r.mem_props.memoryTypeCount {
		if (type_bits & (1 << i)) != 0 &&
		   (r.mem_props.memoryTypes[i].propertyFlags & props) == props {
			return i
		}
	}
	fmt.eprintfln("skald: no compatible memory type for bits=%b props=%v", type_bits, props)
	return 0
}

@(private)
vk_make_buffer :: proc(
	r: ^Renderer,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	props: vk.MemoryPropertyFlags,
) -> (vk.Buffer, vk.DeviceMemory) {
	bi := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO, size = size, usage = usage, sharingMode = .EXCLUSIVE,
	}
	buf: vk.Buffer
	if res := vk.CreateBuffer(r.device, &bi, nil, &buf); res != .SUCCESS {
		fmt.eprintfln("skald: CreateBuffer: %v", res); return 0, 0
	}
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(r.device, buf, &req)
	ai := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = req.size,
		memoryTypeIndex = vk_find_mem_type(r, req.memoryTypeBits, props),
	}
	mem: vk.DeviceMemory
	if res := vk.AllocateMemory(r.device, &ai, nil, &mem); res != .SUCCESS {
		fmt.eprintfln("skald: AllocateMemory: %v", res)
		vk.DestroyBuffer(r.device, buf, nil); return 0, 0
	}
	vk.BindBufferMemory(r.device, buf, mem, 0)
	return buf, mem
}

// One-shot command buffers run outside the per-window render loop
// (atlas growth, image uploads). They allocate from `device_cmd_pool`
// — the pool that lives on the Renderer itself and isn't torn down
// when a window closes — so a glyph upload triggered the frame after
// a popover dismissed doesn't find a freshly-destroyed pool.
@(private)
vk_begin_one_shot :: proc(r: ^Renderer) -> vk.CommandBuffer {
	ai := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = r.device_cmd_pool, level = .PRIMARY, commandBufferCount = 1,
	}
	cb: vk.CommandBuffer
	vk.AllocateCommandBuffers(r.device, &ai, &cb)
	bi := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cb, &bi)
	return cb
}

@(private)
vk_end_one_shot :: proc(r: ^Renderer, cb: vk.CommandBuffer) {
	vk.EndCommandBuffer(cb)
	cb_mut := cb
	si := vk.SubmitInfo{sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &cb_mut}
	vk.QueueSubmit(r.queue, 1, &si, 0)
	vk.QueueWaitIdle(r.queue)
	vk.FreeCommandBuffers(r.device, r.device_cmd_pool, 1, &cb_mut)
}

@(private)
vk_copy_bytes :: proc(dst, src: rawptr, n: int) {
	d := cast([^]u8)dst; s := cast([^]u8)src
	for i in 0..<n { d[i] = s[i] }
}

@(private)
next_pow2_u64 :: proc(x: u64) -> u64 {
	if x <= 1 { return 1 }
	r: u64 = 1
	for r < x { r <<= 1 }
	return r
}
