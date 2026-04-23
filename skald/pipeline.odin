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
Pipeline :: struct {
	vert_module:  vk.ShaderModule,
	frag_module:  vk.ShaderModule,

	dset_layout:  vk.DescriptorSetLayout,
	pipe_layout:  vk.PipelineLayout,
	pipeline:     vk.Pipeline,

	uniform_buf:  vk.Buffer,
	uniform_mem:  vk.DeviceMemory,
	uniform_ptr:  rawptr,

	vertex_buf:       vk.Buffer,
	vertex_mem:       vk.DeviceMemory,
	vertex_buf_bytes: vk.DeviceSize,
	index_buf:        vk.Buffer,
	index_mem:        vk.DeviceMemory,
	index_buf_bytes:  vk.DeviceSize,

	sampler:    vk.Sampler,
	dset_pool:  vk.DescriptorPool,
	dset:       vk.DescriptorSet,
}

@(private)
pipeline_init :: proc(p: ^Pipeline, r: ^Renderer, t: ^Text) -> (ok: bool) {
	if !pipeline_create_shaders   (p, r) { return }
	if !pipeline_create_descriptor(p, r) { return }
	if !pipeline_create_pipeline  (p, r) { return }
	if !pipeline_create_uniform   (p, r) { return }
	if !pipeline_create_sampler   (p, r) { return }
	pipeline_rebuild_descriptor(p, r, t.atlas_view)
	ok = true
	return
}

@(private)
pipeline_destroy :: proc(p: ^Pipeline, r: ^Renderer) {
	d := r.device

	if p.vertex_buf != 0 { vk.DestroyBuffer(d, p.vertex_buf, nil); p.vertex_buf = 0 }
	if p.vertex_mem != 0 { vk.FreeMemory   (d, p.vertex_mem, nil); p.vertex_mem = 0 }
	if p.index_buf  != 0 { vk.DestroyBuffer(d, p.index_buf,  nil); p.index_buf  = 0 }
	if p.index_mem  != 0 { vk.FreeMemory   (d, p.index_mem,  nil); p.index_mem  = 0 }

	if p.sampler     != 0 { vk.DestroySampler(d, p.sampler, nil); p.sampler = 0 }
	if p.dset_pool   != 0 { vk.DestroyDescriptorPool(d, p.dset_pool, nil); p.dset_pool = 0 }
	if p.dset_layout != 0 { vk.DestroyDescriptorSetLayout(d, p.dset_layout, nil); p.dset_layout = 0 }

	if p.uniform_ptr != nil { vk.UnmapMemory(d, p.uniform_mem); p.uniform_ptr = nil }
	if p.uniform_buf != 0   { vk.DestroyBuffer(d, p.uniform_buf, nil); p.uniform_buf = 0 }
	if p.uniform_mem != 0   { vk.FreeMemory(d, p.uniform_mem, nil);    p.uniform_mem = 0 }

	if p.pipeline    != 0 { vk.DestroyPipeline(d, p.pipeline, nil);          p.pipeline    = 0 }
	if p.pipe_layout != 0 { vk.DestroyPipelineLayout(d, p.pipe_layout, nil); p.pipe_layout = 0 }
	if p.vert_module != 0 { vk.DestroyShaderModule(d, p.vert_module, nil);   p.vert_module = 0 }
	if p.frag_module != 0 { vk.DestroyShaderModule(d, p.frag_module, nil);   p.frag_module = 0 }
}

// pipeline_update_uniforms writes the current framebuffer size into
// the persistently-mapped uniform buffer. Cheap — 16 bytes,
// HOST_COHERENT so no fence sync needed.
@(private)
pipeline_update_uniforms :: proc(p: ^Pipeline, fb: [2]u32) {
	u := Uniforms{fb_size = {f32(fb.x), f32(fb.y)}}
	vk_copy_bytes(p.uniform_ptr, &u, size_of(Uniforms))
}

// pipeline_upload_batch writes the current batch vertices + indices
// into HOST_VISIBLE buffers, growing them (next pow2) if the existing
// allocations aren't big enough. Called once per frame from frame_end.
// No-op on an empty batch.
@(private)
pipeline_upload_batch :: proc(p: ^Pipeline, r: ^Renderer, b: ^Batch) {
	if len(b.vertices) == 0 { return }
	vbytes := vk.DeviceSize(len(b.vertices) * size_of(Vertex))
	ibytes := vk.DeviceSize(len(b.indices)  * size_of(u32))

	if vbytes > p.vertex_buf_bytes {
		if p.vertex_buf != 0 { vk.DestroyBuffer(r.device, p.vertex_buf, nil) }
		if p.vertex_mem != 0 { vk.FreeMemory   (r.device, p.vertex_mem, nil) }
		p.vertex_buf_bytes = vk.DeviceSize(next_pow2_u64(u64(vbytes)))
		p.vertex_buf, p.vertex_mem = vk_make_buffer(
			r, p.vertex_buf_bytes, {.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
	}
	if ibytes > p.index_buf_bytes {
		if p.index_buf != 0 { vk.DestroyBuffer(r.device, p.index_buf, nil) }
		if p.index_mem != 0 { vk.FreeMemory   (r.device, p.index_mem, nil) }
		p.index_buf_bytes = vk.DeviceSize(next_pow2_u64(u64(ibytes)))
		p.index_buf, p.index_mem = vk_make_buffer(
			r, p.index_buf_bytes, {.INDEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
	}

	ptr: rawptr
	vk.MapMemory(r.device, p.vertex_mem, 0, vbytes, {}, &ptr)
	vk_copy_bytes(ptr, raw_data(b.vertices), int(vbytes))
	vk.UnmapMemory(r.device, p.vertex_mem)

	vk.MapMemory(r.device, p.index_mem, 0, ibytes, {}, &ptr)
	vk_copy_bytes(ptr, raw_data(b.indices), int(ibytes))
	vk.UnmapMemory(r.device, p.index_mem)
}

// pipeline_rebuild_descriptor rewrites binding 1 of the pipeline's
// descriptor set to point at the given image view. Binding 0 (uniform
// buffer) is always re-written as well since Vulkan allows partial
// writes but writing both keeps the code simple. Called from
// pipeline_init and whenever Text reports the atlas was resized.
@(private)
pipeline_rebuild_descriptor :: proc(p: ^Pipeline, r: ^Renderer, view: vk.ImageView) {
	bi := vk.DescriptorBufferInfo{
		buffer = p.uniform_buf, offset = 0, range = size_of(Uniforms),
	}
	ii := vk.DescriptorImageInfo{
		sampler = p.sampler, imageView = view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	writes := [?]vk.WriteDescriptorSet{
		{
			sType = .WRITE_DESCRIPTOR_SET, dstSet = p.dset,
			dstBinding = 0, descriptorCount = 1, descriptorType = .UNIFORM_BUFFER,
			pBufferInfo = &bi,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET, dstSet = p.dset,
			dstBinding = 1, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &ii,
		},
	}
	vk.UpdateDescriptorSets(r.device, u32(len(writes)), raw_data(writes[:]), 0, nil)
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
	bindings := [?]vk.DescriptorSetLayoutBinding{
		{binding = 0, descriptorType = .UNIFORM_BUFFER,         descriptorCount = 1, stageFlags = {.VERTEX}},
		{binding = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}
	li := vk.DescriptorSetLayoutCreateInfo{
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)), pBindings = raw_data(bindings[:]),
	}
	if res := vk.CreateDescriptorSetLayout(r.device, &li, nil, &p.dset_layout); res != .SUCCESS {
		fmt.eprintfln("skald: CreateDescriptorSetLayout: %v", res); return false
	}
	pool_sizes := [?]vk.DescriptorPoolSize{
		{type = .UNIFORM_BUFFER,         descriptorCount = 1},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1},
	}
	pi := vk.DescriptorPoolCreateInfo{
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets = 1,
		poolSizeCount = u32(len(pool_sizes)), pPoolSizes = raw_data(pool_sizes[:]),
	}
	if res := vk.CreateDescriptorPool(r.device, &pi, nil, &p.dset_pool); res != .SUCCESS {
		fmt.eprintfln("skald: CreateDescriptorPool: %v", res); return false
	}
	ai := vk.DescriptorSetAllocateInfo{
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = p.dset_pool,
		descriptorSetCount = 1, pSetLayouts = &p.dset_layout,
	}
	if res := vk.AllocateDescriptorSets(r.device, &ai, &p.dset); res != .SUCCESS {
		fmt.eprintfln("skald: AllocateDescriptorSets: %v", res); return false
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
	pl_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1, pSetLayouts = &p.dset_layout,
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
pipeline_create_uniform :: proc(p: ^Pipeline, r: ^Renderer) -> bool {
	p.uniform_buf, p.uniform_mem = vk_make_buffer(
		r, size_of(Uniforms), {.UNIFORM_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	if p.uniform_buf == 0 { return false }
	if res := vk.MapMemory(r.device, p.uniform_mem, 0, size_of(Uniforms), {}, &p.uniform_ptr); res != .SUCCESS {
		fmt.eprintfln("skald: MapMemory (uniform): %v", res); return false
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

@(private)
vk_begin_one_shot :: proc(r: ^Renderer) -> vk.CommandBuffer {
	ai := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = r.cmd_pool, level = .PRIMARY, commandBufferCount = 1,
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
	vk.FreeCommandBuffers(r.device, r.cmd_pool, 1, &cb_mut)
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
