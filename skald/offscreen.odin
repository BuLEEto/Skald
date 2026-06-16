package skald

// Offscreen render: rasterize a View tree to a CPU pixel buffer, transparent
// background. Used to render the cross-app drag-OUT ghost into a wl_shm icon
// (request 019, stage 2) — the compositor renders the drag icon from a client
// buffer, and Skald otherwise only renders to its swapchain.
//
// Output is the swapchain format (B8G8R8A8_SRGB) with PREMULTIPLIED alpha:
// drawing over a 0-alpha clear with Skald's SRC_ALPHA / ONE_MINUS_SRC_ALPHA
// blend leaves rgb already multiplied by a — exactly what wl_shm's ARGB8888
// (also B,G,R,A little-endian) wants, so the bytes need no conversion.

import "core:mem"
import vk "vendor:vulkan"

// render_view_to_pixels rasterizes `v` (sized by `view_size`, clamped to
// max_w/max_h) to heap pixels the caller frees. Synchronous (one GPU submit +
// wait) — fine for a once-per-drag icon snapshot. Returns ok=false if there's
// no live render target to borrow the pipeline/atlas from.
@(private)
render_view_to_pixels :: proc(r: ^Renderer, v: View, max_w, max_h: int) -> (px: []u8, w, h: int, ok: bool) {
	if r.cur == nil { return }

	fs := view_size(r, v)
	w = clamp(int(fs.x + 0.5), 1, max_w)
	h = clamp(int(fs.y + 0.5), 1, max_h)

	// Build the batch for an offscreen target of this size. Mirror the bits of
	// frame_begin that render_view depends on (wrap cache, overlay sink, alpha,
	// fb_size). Temp-allocated — freed with the frame arena.
	r.fb_size          = {u32(w), u32(h)}
	r.fb_size_px       = {u32(w), u32(h)}
	r.scale            = 1
	r.alpha_multiplier = 1
	r.overlays         = make([dynamic]Overlay_Entry, context.temp_allocator)
	r.wrap_cache       = make(map[Wrap_Key][]string, allocator = context.temp_allocator)
	batch_reset(&r.batch)
	append(&r.batch.ranges, Batch_Range{
		clip        = rect_to_scissor({0, 0, f32(w), f32(h)}, r.fb_size_px, r.scale),
		index_start = 0,
	})
	render_view(r, v, {0, 0}, {f32(w), f32(h)})

	if len(r.batch.indices) == 0 { return }

	// Make sure any glyphs the ghost introduced are uploaded to the atlas.
	if text_upload_dirty(&r.text, r) {
		targets_rebuild_descriptors(r, &r.pipeline, r.text.atlas_view)
	}

	// Transient vertex/index buffers (host-visible) so we never disturb a
	// window target's buffers that an in-flight frame may still be reading.
	vbytes := vk.DeviceSize(len(r.batch.vertices) * size_of(Vertex))
	ibytes := vk.DeviceSize(len(r.batch.indices) * size_of(u32))
	vbuf, vmem := vk_make_buffer(r, vbytes, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	ibuf, imem := vk_make_buffer(r, ibytes, {.INDEX_BUFFER},  {.HOST_VISIBLE, .HOST_COHERENT})
	defer {
		vk.DestroyBuffer(r.device, vbuf, nil); vk.FreeMemory(r.device, vmem, nil)
		vk.DestroyBuffer(r.device, ibuf, nil); vk.FreeMemory(r.device, imem, nil)
	}
	{
		p: rawptr
		vk.MapMemory(r.device, vmem, 0, vbytes, {}, &p); mem.copy(p, raw_data(r.batch.vertices), int(vbytes)); vk.UnmapMemory(r.device, vmem)
		vk.MapMemory(r.device, imem, 0, ibytes, {}, &p); mem.copy(p, raw_data(r.batch.indices),  int(ibytes)); vk.UnmapMemory(r.device, imem)
	}

	// Offscreen color image (swapchain format) + host-visible readback buffer.
	img: vk.Image; imgmem: vk.DeviceMemory; iview: vk.ImageView
	if !offscreen_image(r, w, h, &img, &imgmem, &iview) { return }
	defer {
		vk.DestroyImageView(r.device, iview, nil)
		vk.DestroyImage(r.device, img, nil)
		vk.FreeMemory(r.device, imgmem, nil)
	}
	rbytes := vk.DeviceSize(w * h * 4)
	rbuf, rmem := vk_make_buffer(r, rbytes, {.TRANSFER_DST}, {.HOST_VISIBLE, .HOST_COHERENT})
	defer { vk.DestroyBuffer(r.device, rbuf, nil); vk.FreeMemory(r.device, rmem, nil) }

	cb := vk_begin_one_shot(r)
	range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	vk_image_barrier(cb, img, range, {}, {.COLOR_ATTACHMENT_WRITE},
		.UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL, {.TOP_OF_PIPE}, {.COLOR_ATTACHMENT_OUTPUT})

	attach := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO, imageView = iview,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL, loadOp = .CLEAR, storeOp = .STORE,
		clearValue = vk.ClearValue{color = {float32 = {0, 0, 0, 0}}}, // transparent
	}
	ri := vk.RenderingInfo{
		sType = .RENDERING_INFO, renderArea = {extent = {u32(w), u32(h)}},
		layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach,
	}
	vk.CmdBeginRendering(cb, &ri)

	// Negative-height viewport: same Y-flip the swapchain uses (shader is Y-up).
	vp := vk.Viewport{x = 0, y = f32(h), width = f32(w), height = -f32(h), minDepth = 0, maxDepth = 1}
	vk.CmdSetViewport(cb, 0, 1, &vp)

	vk.CmdBindPipeline(cb, .GRAPHICS, r.pipeline.pipeline)
	uni := Uniforms{fb_size = {f32(w), f32(h)}}
	vk.CmdPushConstants(cb, r.pipeline.pipe_layout, {.VERTEX}, 0, size_of(Uniforms), &uni)
	off: vk.DeviceSize = 0
	vbuf_mut := vbuf
	vk.CmdBindVertexBuffers(cb, 0, 1, &vbuf_mut, &off)
	vk.CmdBindIndexBuffer(cb, ibuf, 0, .UINT32)

	total := u32(len(r.batch.indices))
	last_ds: vk.DescriptorSet = 0
	for rng, i in r.batch.ranges {
		end := total if i == len(r.batch.ranges) - 1 else r.batch.ranges[i + 1].index_start
		count := end - rng.index_start
		if count == 0                            { continue }
		if rng.clip[2] == 0 || rng.clip[3] == 0  { continue }
		ds := rng.bind_group
		if ds == 0 { ds = r.dset }
		if ds != last_ds {
			ds_mut := ds
			vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.pipeline.pipe_layout, 0, 1, &ds_mut, 0, nil)
			last_ds = ds
		}
		sc := vk.Rect2D{offset = {i32(rng.clip[0]), i32(rng.clip[1])}, extent = {rng.clip[2], rng.clip[3]}}
		vk.CmdSetScissor(cb, 0, 1, &sc)
		vk.CmdDrawIndexed(cb, count, 1, rng.index_start, 0, 0)
	}

	vk.CmdEndRendering(cb)
	vk_image_barrier(cb, img, range, {.COLOR_ATTACHMENT_WRITE}, {.TRANSFER_READ},
		.COLOR_ATTACHMENT_OPTIMAL, .TRANSFER_SRC_OPTIMAL, {.COLOR_ATTACHMENT_OUTPUT}, {.TRANSFER})
	region := vk.BufferImageCopy{
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent      = {u32(w), u32(h), 1},
	}
	vk.CmdCopyImageToBuffer(cb, img, .TRANSFER_SRC_OPTIMAL, rbuf, 1, &region)
	vk_end_one_shot(r, cb) // submits + waits idle

	px = make([]u8, int(rbytes))
	p: rawptr
	vk.MapMemory(r.device, rmem, 0, rbytes, {}, &p)
	mem.copy(raw_data(px), p, int(rbytes))
	vk.UnmapMemory(r.device, rmem)
	ok = true
	return
}

@(private)
offscreen_image :: proc(r: ^Renderer, w, h: int, img: ^vk.Image, mem_out: ^vk.DeviceMemory, view: ^vk.ImageView) -> bool {
	ii := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, imageType = .D2, format = r.swap_format,
		extent = {u32(w), u32(h), 1}, mipLevels = 1, arrayLayers = 1,
		samples = {._1}, tiling = .OPTIMAL,
		usage = {.COLOR_ATTACHMENT, .TRANSFER_SRC}, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	if vk.CreateImage(r.device, &ii, nil, img) != .SUCCESS { return false }
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, img^, &req)
	ai := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size,
		memoryTypeIndex = vk_find_mem_type(r, req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	if vk.AllocateMemory(r.device, &ai, nil, mem_out) != .SUCCESS {
		vk.DestroyImage(r.device, img^, nil); return false
	}
	vk.BindImageMemory(r.device, img^, mem_out^, 0)
	viw := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO, image = img^, viewType = .D2, format = r.swap_format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if vk.CreateImageView(r.device, &viw, nil, view) != .SUCCESS {
		vk.FreeMemory(r.device, mem_out^, nil); vk.DestroyImage(r.device, img^, nil); return false
	}
	return true
}
