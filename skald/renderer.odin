package skald

// Skald's renderer runs on a pure-Odin Vulkan 1.3 backend: dynamic
// rendering, no render-pass objects, negative-viewport-Y flip to match
// the WebGPU coordinate system the shader is authored against.
//
// A frame is produced by calling `frame_begin`, then any number of draw
// calls (`draw_rect`, `draw_text`, `image`, ...), then `frame_end`. The
// actual command buffer recording and submission happen inside
// `frame_end` — `frame_begin` only acquires the next swapchain image and
// resets the CPU-side batch. That split keeps text-atlas uploads (which
// run a one-shot submit of their own) from racing with the main frame
// cmd buffer, and lets the app mutate the batch freely while building
// the view tree.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:sdl3"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: 2

// Renderer owns the whole GPU stack for a single window: instance and
// surface down at the Vulkan layer, the swapchain it presents through,
// per-frame command buffers and sync primitives, and the Skald-side
// state (pipeline, batch, glyph atlas, image cache, current-frame info)
// that the public drawing API writes into.
Renderer :: struct {
	window:           ^sdl3.Window,

	instance:         vk.Instance,
	surface:          vk.SurfaceKHR,
	phys_device:      vk.PhysicalDevice,
	device:           vk.Device,
	queue:            vk.Queue,
	queue_family_idx: u32,
	mem_props:        vk.PhysicalDeviceMemoryProperties,

	swapchain:        vk.SwapchainKHR,
	swap_format:      vk.Format,
	swap_extent:      vk.Extent2D,
	swap_images:      []vk.Image,
	swap_views:       []vk.ImageView,

	cmd_pool:         vk.CommandPool,
	cmd_buffers:      [FRAMES_IN_FLIGHT]vk.CommandBuffer,
	image_available:  [FRAMES_IN_FLIGHT]vk.Semaphore,
	// render_finished is one semaphore per swapchain image, not per
	// frame-in-flight. Using a per-slot array previously triggered
	// VUID-vkQueueSubmit-pSignalSemaphores-00067 on macOS/MoltenVK:
	// the Vulkan spec requires the signalled semaphore be unsignalled
	// at submit time, but presenting an image and acquiring a
	// different one later can leave the same-slot semaphore still
	// "in use by QueuePresent." Swapchain images are round-robined
	// with no lag, so one semaphore per image is the correct lifetime.
	render_finished:  []vk.Semaphore,
	in_flight:        [FRAMES_IN_FLIGHT]vk.Fence,
	frame:            u64,
	cur_slot:         u32,
	cur_image:        u32,

	pipeline:   Pipeline,
	batch:      Batch,
	text:       Text,
	images:     Image_Cache,

	// Per-frame state, valid between frame_begin and frame_end.
	//
	// `fb_size` is the *logical* framebuffer size — what the view tree
	// lays out into and the shader's NDC math divides against. `fb_size_px`
	// is the backing swapchain size in physical pixels; it's only
	// consulted at the renderer boundary for scissor conversion.
	// `scale` is `fb_size_px / fb_size` and is baked into the glyph
	// raster size so text stays crisp at non-integer OS scaling.
	frame_clear:   Color,
	fb_size:       [2]u32,
	fb_size_px:    [2]u32,
	scale:         f32,
	frame_valid:   bool,

	// Borrowed by `run` for the lifetime of the main loop. `render_view`
	// records per-widget bounding boxes into `widgets.states` so the next
	// frame's builders can hit-test against them. nil when the renderer
	// is driven directly (02_shapes etc.) without the App loop.
	widgets:       ^Widget_Store,

	// Overlays collected during the main render_view pass. They are
	// drawn in a post-pass (render_overlays) so they sit on top of
	// everything else in the frame — the z-order of a 2-D toolkit is
	// just draw-order, and deferring is cheaper than a depth buffer.
	// Cleared at the top of each frame via the temp allocator.
	overlays:      [dynamic]Overlay_Entry,

	// alpha_multiplier scales the alpha channel of every `draw_*` call.
	// Default 1 (transparent pass-through); render_overlays lowers it
	// to implement popover fade-in / fade-out animations and any other
	// "this whole subtree is translucent" effect. Set at the boundary,
	// render, restore — handlers nest cleanly because we save/restore
	// rather than push/pop a stack.
	alpha_multiplier: f32,
}

// Overlay_Entry is one deferred popover/tooltip/menu to be rendered
// after the main tree. `origin` is already in framebuffer pixel space;
// `size` is the child's intrinsic size. The child itself is a plain
// View so overlays can contain any sub-tree.
Overlay_Entry :: struct {
	origin: [2]f32,
	size:   [2]f32,
	child:  View,
	// shadow_radius controls the drop shadow drawn beneath this overlay.
	// 0 suppresses the shadow entirely (used for dialog scrims + other
	// full-screen entries that shouldn't cast one); a non-zero value
	// should match the overlay card's visible corner radius so the
	// shadow hugs its silhouette. Everyone else gets a soft shadow
	// inserted between the main frame and the popover — see
	// `render_overlays` in layout.odin.
	shadow_radius: f32,
	// opacity fades the entire overlay subtree by multiplying the
	// renderer's `alpha_multiplier` while rendering this child. 1
	// is fully visible (default); 0 is invisible. Popover builders
	// set this from an animated `anim_t` so opening / closing fades
	// instead of snapping.
	opacity: f32,
}

// renderer_init brings up Vulkan for the given window. The window must
// have been created with `sdl3.WindowFlag.VULKAN` set — `window_open`
// in platform.odin handles that.
renderer_init :: proc(r: ^Renderer, w: ^Window) -> (ok: bool) {
	r.window = w.handle

	get_proc := sdl3.Vulkan_GetVkGetInstanceProcAddr()
	if get_proc == nil {
		fmt.eprintfln("skald: Vulkan_GetVkGetInstanceProcAddr returned nil (window missing {{.VULKAN}} flag?)")
		return
	}
	vk.load_proc_addresses_global(rawptr(get_proc))

	if !vk_create_instance(r) { return }
	if !sdl3.Vulkan_CreateSurface(r.window, r.instance, nil, &r.surface) {
		fmt.eprintfln("skald: Vulkan_CreateSurface: %s", sdl3.GetError())
		return
	}
	if !vk_pick_physical_device(r) { return }
	vk.GetPhysicalDeviceMemoryProperties(r.phys_device, &r.mem_props)
	if !vk_create_device(r)            { return }
	if !vk_create_swapchain(r, w)             { return }
	if !vk_create_commands_and_sync(r)        { return }
	if !vk_create_render_finished_semaphores(r) { return }

	if !text_init(&r.text, r) {
		fmt.eprintln("skald: text init failed")
		return
	}
	if !pipeline_init(&r.pipeline, r, &r.text) {
		fmt.eprintln("skald: pipeline init failed")
		return
	}
	if !image_cache_init(&r.images, r) {
		fmt.eprintln("skald: image cache init failed")
		return
	}

	ok = true
	return
}

// renderer_resize tears down and rebuilds the swapchain for the
// window's new framebuffer size. Called from `window_pump` when SDL3
// reports a resize, and from frame_begin when AcquireNextImage
// returns OUT_OF_DATE.
renderer_resize :: proc(r: ^Renderer, w: ^Window) {
	if w.size_px.x == 0 || w.size_px.y == 0 { return }
	vk.DeviceWaitIdle(r.device)
	vk_destroy_swapchain(r)
	vk_create_swapchain(r, w)
	// Swapchain image count can change on resize (some drivers flip
	// between 2 and 3 images depending on extent); refresh the
	// per-image render_finished semaphores to match.
	vk_create_render_finished_semaphores(r)
}

// renderer_destroy releases every Vulkan resource owned by the
// renderer. Order mirrors the init sequence in reverse: Skald-side
// resources first, then device-scoped handles, then instance.
renderer_destroy :: proc(r: ^Renderer) {
	if r.device != nil {
		vk.DeviceWaitIdle(r.device)
		image_cache_destroy(&r.images, r)
		pipeline_destroy(&r.pipeline, r)
		text_destroy(&r.text, r)
		batch_destroy(&r.batch)
		vk_destroy_commands_and_sync(r)
		vk_destroy_swapchain(r)
		vk.DestroyDevice(r.device, nil); r.device = nil
	}
	if r.surface != 0 && r.instance != nil {
		sdl3.Vulkan_DestroySurface(r.instance, r.surface, nil); r.surface = 0
	}
	if r.instance != nil {
		vk.DestroyInstance(r.instance, nil); r.instance = nil
	}
}

// frame_begin waits for the next in-flight slot, acquires the next
// swapchain image, and resets the CPU-side batch. Draws are recorded
// into `r.batch` by the public API; frame_end flushes them to a command
// buffer and submits.
//
// Returns ok=false when the frame should be skipped (swapchain out of
// date — caller should skip frame_end and loop back through
// renderer_resize next frame).
frame_begin :: proc(r: ^Renderer, w: ^Window, clear: Color) -> (ok: bool) {
	slot := u32(r.frame % FRAMES_IN_FLIGHT)
	vk.WaitForFences(r.device, 1, &r.in_flight[slot], true, max(u64))

	img_idx: u32
	acq := vk.AcquireNextImageKHR(
		r.device, r.swapchain, max(u64),
		r.image_available[slot], 0, &img_idx,
	)
	if acq == .ERROR_OUT_OF_DATE_KHR {
		renderer_resize(r, w)
		return
	}
	if acq != .SUCCESS && acq != .SUBOPTIMAL_KHR {
		fmt.eprintfln("skald: AcquireNextImageKHR: %v", acq)
		return
	}
	vk.ResetFences(r.device, 1, &r.in_flight[slot])

	r.cur_slot    = slot
	r.cur_image   = img_idx
	r.frame_clear = clear
	r.fb_size     = w.size_logical
	r.fb_size_px  = w.size_px
	r.scale       = w.scale
	r.frame_valid      = true
	r.overlays         = make([dynamic]Overlay_Entry, context.temp_allocator)
	r.alpha_multiplier = 1

	batch_reset(&r.batch)

	// Seed a single Batch_Range covering the whole framebuffer. push_clip
	// either opens a new range or, if nothing has been drawn yet, rewrites
	// this seed range's scissor in place.
	append(&r.batch.ranges, Batch_Range{
		clip        = rect_to_scissor({0, 0, f32(r.fb_size.x), f32(r.fb_size.y)}, r.fb_size_px, r.scale),
		index_start = 0,
	})

	pipeline_update_uniforms(&r.pipeline, r.fb_size)

	ok = true
	return
}

// frame_end uploads the accumulated batch, records a full frame command
// buffer (clear → draw every range → transition to PRESENT_SRC), submits
// it, and presents. Safe to call after a skipped frame_begin — it
// no-ops.
//
// Atlas dirty-rect uploads happen first, before the main cmd buffer
// starts recording, because the one-shot cmd buffer they use needs to
// complete synchronously before we bind the updated atlas view.
frame_end :: proc(r: ^Renderer) {
	if !r.frame_valid { return }

	if text_upload_dirty(&r.text, r) {
		pipeline_rebuild_descriptor(&r.pipeline, r, r.text.atlas_view)
	}
	pipeline_upload_batch(&r.pipeline, r, &r.batch)

	slot := r.cur_slot
	img  := r.cur_image
	cb   := r.cmd_buffers[slot]

	vk.ResetCommandBuffer(cb, {})
	bi := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cb, &bi)

	range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	vk_image_barrier(cb, r.swap_images[img], range,
		{}, {.COLOR_ATTACHMENT_WRITE},
		.UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL,
		{.TOP_OF_PIPE}, {.COLOR_ATTACHMENT_OUTPUT})

	attach := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = r.swap_views[img],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR, storeOp = .STORE,
		clearValue = vk.ClearValue{color = {float32 = {
			r.frame_clear.r, r.frame_clear.g, r.frame_clear.b, r.frame_clear.a,
		}}},
	}
	ri := vk.RenderingInfo{
		sType = .RENDERING_INFO,
		renderArea = {extent = r.swap_extent},
		layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach,
	}
	vk.CmdBeginRendering(cb, &ri)

	// Vulkan NDC is Y-down; the WGSL-authored shader is Y-up. A negative
	// viewport height flips the rasterizer so the shader stays 1:1 with
	// the WebGPU coordinate system. Vulkan 1.1+ core, no extension dance.
	vp := vk.Viewport{
		x = 0, y = f32(r.swap_extent.height),
		width = f32(r.swap_extent.width), height = -f32(r.swap_extent.height),
		minDepth = 0, maxDepth = 1,
	}
	vk.CmdSetViewport(cb, 0, 1, &vp)

	if len(r.batch.indices) > 0 {
		vk.CmdBindPipeline(cb, .GRAPHICS, r.pipeline.pipeline)
		offset: vk.DeviceSize = 0
		vbuf := r.pipeline.vertex_buf
		vk.CmdBindVertexBuffers(cb, 0, 1, &vbuf, &offset)
		vk.CmdBindIndexBuffer(cb, r.pipeline.index_buf, 0, .UINT32)

		// Default descriptor set for ranges that don't carry an override
		// (which is everything except per-image ranges). Ranges that
		// share a descriptor set coalesce so we only issue
		// CmdBindDescriptorSets when it actually changes.
		total := u32(len(r.batch.indices))
		last_ds: vk.DescriptorSet = 0
		for rng, i in r.batch.ranges {
			end := total if i == len(r.batch.ranges) - 1 else r.batch.ranges[i + 1].index_start
			count := end - rng.index_start
			if count == 0                               { continue }
			if rng.clip[2] == 0 || rng.clip[3] == 0    { continue }
			ds := rng.bind_group
			if ds == 0 { ds = r.pipeline.dset }
			if ds != last_ds {
				ds_mut := ds
				vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.pipeline.pipe_layout, 0, 1, &ds_mut, 0, nil)
				last_ds = ds
			}
			sc := vk.Rect2D{
				offset = {i32(rng.clip[0]), i32(rng.clip[1])},
				extent = {rng.clip[2], rng.clip[3]},
			}
			vk.CmdSetScissor(cb, 0, 1, &sc)
			vk.CmdDrawIndexed(cb, count, 1, rng.index_start, 0, 0)
		}
	}

	vk.CmdEndRendering(cb)

	vk_image_barrier(cb, r.swap_images[img], range,
		{.COLOR_ATTACHMENT_WRITE}, {},
		.COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_OUTPUT}, {.BOTTOM_OF_PIPE})

	vk.EndCommandBuffer(cb)

	wait_stage: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
	cb_ptr := cb
	// render_finished is indexed by swapchain-image, not frame slot.
	// See the comment on the field in `Renderer` for why.
	submit := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		waitSemaphoreCount = 1, pWaitSemaphores = &r.image_available[slot], pWaitDstStageMask = &wait_stage,
		commandBufferCount = 1, pCommandBuffers = &cb_ptr,
		signalSemaphoreCount = 1, pSignalSemaphores = &r.render_finished[img],
	}
	if res := vk.QueueSubmit(r.queue, 1, &submit, r.in_flight[slot]); res != .SUCCESS {
		fmt.eprintfln("skald: QueueSubmit: %v", res)
	}

	img_mut := img
	present := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1, pWaitSemaphores = &r.render_finished[img],
		swapchainCount = 1, pSwapchains = &r.swapchain, pImageIndices = &img_mut,
	}
	p := vk.QueuePresentKHR(r.queue, &present)
	if p != .SUCCESS && p != .SUBOPTIMAL_KHR && p != .ERROR_OUT_OF_DATE_KHR {
		fmt.eprintfln("skald: QueuePresentKHR: %v", p)
	}

	r.frame += 1
	r.frame_valid = false
}

// ---- internal: instance / physical device / logical device ----

@(private)
vk_create_instance :: proc(r: ^Renderer) -> bool {
	app := vk.ApplicationInfo{
		sType = .APPLICATION_INFO,
		pApplicationName = "skald",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName = "skald",
		engineVersion = vk.MAKE_VERSION(0, 1, 0),
		apiVersion = vk.API_VERSION_1_3,
	}
	n: u32
	exts_raw := sdl3.Vulkan_GetInstanceExtensions(&n)
	exts_slice := slice.from_ptr(exts_raw, int(n))

	// macOS has no fully-conformant Vulkan driver; MoltenVK is a
	// "portability subset" implementation. To opt into that on the
	// Vulkan loader we have to request VK_KHR_portability_enumeration
	// at instance level AND set the ENUMERATE_PORTABILITY flag, or
	// CreateInstance returns ERROR_INCOMPATIBLE_DRIVER. Without this
	// block a Linux/Windows build just works; macOS needs the opt-in.
	// Every other platform ignores the extra extension + flag.
	exts := make([dynamic]cstring, 0, len(exts_slice) + 1, context.temp_allocator)
	for e in exts_slice { append(&exts, e) }
	flags: vk.InstanceCreateFlags
	when ODIN_OS == .Darwin {
		append(&exts, "VK_KHR_portability_enumeration")
		flags = {.ENUMERATE_PORTABILITY_KHR}
	}

	info := vk.InstanceCreateInfo{
		sType = .INSTANCE_CREATE_INFO,
		flags = flags,
		pApplicationInfo = &app,
		enabledExtensionCount = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}
	if res := vk.CreateInstance(&info, nil, &r.instance); res != .SUCCESS {
		fmt.eprintfln("skald: CreateInstance: %v", res)
		return false
	}
	vk.load_proc_addresses_instance(r.instance)
	return true
}

@(private)
vk_pick_physical_device :: proc(r: ^Renderer) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(r.instance, &count, nil)
	if count == 0 {
		fmt.eprintln("skald: no Vulkan-capable GPUs")
		return false
	}
	devices := make([]vk.PhysicalDevice, count); defer delete(devices)
	vk.EnumeratePhysicalDevices(r.instance, &count, raw_data(devices))

	best_score := -1
	for d in devices {
		qf, ok := vk_find_graphics_present_family(d, r.surface)
		if !ok { continue }
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(d, &props)
		score := 1
		if props.deviceType == .DISCRETE_GPU { score += 1000 }
		if score > best_score {
			best_score = score
			r.phys_device = d
			r.queue_family_idx = qf
			name := strings.string_from_null_terminated_ptr(
				raw_data(props.deviceName[:]), len(props.deviceName),
			)
			fmt.printfln("skald: gpu %s", name)
		}
	}
	if best_score < 0 {
		fmt.eprintln("skald: no Vulkan GPU with graphics + present support")
		return false
	}
	return true
}

@(private)
vk_find_graphics_present_family :: proc(d: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (u32, bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &count, nil)
	props := make([]vk.QueueFamilyProperties, count); defer delete(props)
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &count, raw_data(props))
	for p, i in props {
		if .GRAPHICS not_in p.queueFlags { continue }
		present_ok: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(d, u32(i), surface, &present_ok)
		if present_ok { return u32(i), true }
	}
	return 0, false
}

@(private)
vk_create_device :: proc(r: ^Renderer) -> bool {
	prio: f32 = 1.0
	qinfo := vk.DeviceQueueCreateInfo{
		sType = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = r.queue_family_idx,
		queueCount = 1, pQueuePriorities = &prio,
	}
	dyn := vk.PhysicalDeviceDynamicRenderingFeatures{
		sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		dynamicRendering = true,
	}

	// macOS: MoltenVK advertises VK_KHR_portability_subset and the
	// Vulkan spec requires that apps using a portability-subset device
	// explicitly enable that extension. Not doing so makes CreateDevice
	// fail with ERROR_EXTENSION_NOT_PRESENT (or trigger a validation
	// error in debug builds). Other platforms don't have or need it.
	exts := make([dynamic]cstring, 0, 2, context.temp_allocator)
	append(&exts, "VK_KHR_swapchain")
	when ODIN_OS == .Darwin {
		append(&exts, "VK_KHR_portability_subset")
	}

	info := vk.DeviceCreateInfo{
		sType = .DEVICE_CREATE_INFO,
		pNext = &dyn,
		queueCreateInfoCount = 1, pQueueCreateInfos = &qinfo,
		enabledExtensionCount = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts[:]),
	}
	if res := vk.CreateDevice(r.phys_device, &info, nil, &r.device); res != .SUCCESS {
		fmt.eprintfln("skald: CreateDevice: %v", res)
		return false
	}
	vk.load_proc_addresses_device(r.device)
	vk.GetDeviceQueue(r.device, r.queue_family_idx, 0, &r.queue)
	return true
}

// ---- internal: swapchain ----

@(private)
vk_create_swapchain :: proc(r: ^Renderer, w: ^Window) -> bool {
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.phys_device, r.surface, &caps)

	fn: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.phys_device, r.surface, &fn, nil)
	formats := make([]vk.SurfaceFormatKHR, fn); defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.phys_device, r.surface, &fn, raw_data(formats))
	chosen := formats[0]
	for f in formats {
		if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR { chosen = f; break }
	}

	extent := caps.currentExtent
	if extent.width == max(u32) {
		extent.width  = clamp(w.size_px.x, caps.minImageExtent.width,  caps.maxImageExtent.width)
		extent.height = clamp(w.size_px.y, caps.minImageExtent.height, caps.maxImageExtent.height)
	}

	count := caps.minImageCount + 1
	if caps.maxImageCount > 0 && count > caps.maxImageCount { count = caps.maxImageCount }

	// Default to vsync'd FIFO (battery-friendly, tear-free). Benchmarks
	// can set `SKALD_BENCH_UNCAP=1` to opt into IMMEDIATE so measured
	// frame times reflect real CPU+GPU cost instead of the display's
	// refresh period. IMMEDIATE may not be available everywhere — if
	// the driver rejects the mode, this branch still succeeds via the
	// guaranteed FIFO fallback below.
	present_mode: vk.PresentModeKHR = .FIFO
	if len(os.get_env("SKALD_BENCH_UNCAP", context.temp_allocator)) > 0 {
		present_mode = .IMMEDIATE
	}
	info := vk.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR, surface = r.surface,
		minImageCount = count,
		imageFormat = chosen.format, imageColorSpace = chosen.colorSpace,
		imageExtent = extent, imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		imageSharingMode = .EXCLUSIVE,
		preTransform = caps.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = present_mode, clipped = true,
	}
	if res := vk.CreateSwapchainKHR(r.device, &info, nil, &r.swapchain); res != .SUCCESS {
		fmt.eprintfln("skald: CreateSwapchainKHR: %v", res)
		return false
	}
	r.swap_format = chosen.format
	r.swap_extent = extent

	ic: u32
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &ic, nil)
	r.swap_images = make([]vk.Image, ic)
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &ic, raw_data(r.swap_images))

	r.swap_views = make([]vk.ImageView, ic)
	for img, i in r.swap_images {
		viw := vk.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = img, viewType = .D2, format = chosen.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if res := vk.CreateImageView(r.device, &viw, nil, &r.swap_views[i]); res != .SUCCESS {
			fmt.eprintfln("skald: CreateImageView (swap): %v", res)
			return false
		}
	}
	return true
}

@(private)
vk_destroy_swapchain :: proc(r: ^Renderer) {
	for v in r.swap_views {
		if v != 0 { vk.DestroyImageView(r.device, v, nil) }
	}
	if r.swap_views  != nil { delete(r.swap_views);  r.swap_views  = nil }
	if r.swap_images != nil { delete(r.swap_images); r.swap_images = nil }
	if r.swapchain != 0 {
		vk.DestroySwapchainKHR(r.device, r.swapchain, nil)
		r.swapchain = 0
	}
}

// ---- internal: commands + sync ----

@(private)
vk_create_commands_and_sync :: proc(r: ^Renderer) -> bool {
	pi := vk.CommandPoolCreateInfo{
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.queue_family_idx,
	}
	if res := vk.CreateCommandPool(r.device, &pi, nil, &r.cmd_pool); res != .SUCCESS {
		fmt.eprintfln("skald: CreateCommandPool: %v", res)
		return false
	}
	ai := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = r.cmd_pool, level = .PRIMARY,
		commandBufferCount = FRAMES_IN_FLIGHT,
	}
	if res := vk.AllocateCommandBuffers(r.device, &ai, &r.cmd_buffers[0]); res != .SUCCESS {
		fmt.eprintfln("skald: AllocateCommandBuffers: %v", res)
		return false
	}
	si := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	fi := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
	for i in 0..<FRAMES_IN_FLIGHT {
		vk.CreateSemaphore(r.device, &si, nil, &r.image_available[i])
		vk.CreateFence    (r.device, &fi, nil, &r.in_flight[i])
	}
	// render_finished semaphores are sized to the swapchain at
	// `vk_create_render_finished_semaphores` (called after the
	// swapchain is created and on every resize).
	return true
}

// vk_create_render_finished_semaphores (re)allocates one semaphore
// per swapchain image. Called after the swapchain is created and
// after every resize, because the image count can change when the
// compositor switches present modes or when the swap was recreated.
@(private)
vk_create_render_finished_semaphores :: proc(r: ^Renderer) -> bool {
	vk_destroy_render_finished_semaphores(r)
	r.render_finished = make([]vk.Semaphore, len(r.swap_images))
	si := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	for i in 0..<len(r.render_finished) {
		if res := vk.CreateSemaphore(r.device, &si, nil, &r.render_finished[i]); res != .SUCCESS {
			fmt.eprintfln("skald: CreateSemaphore (render_finished %d): %v", i, res)
			return false
		}
	}
	return true
}

@(private)
vk_destroy_render_finished_semaphores :: proc(r: ^Renderer) {
	for s in r.render_finished {
		if s != 0 { vk.DestroySemaphore(r.device, s, nil) }
	}
	if r.render_finished != nil {
		delete(r.render_finished)
		r.render_finished = nil
	}
}

@(private)
vk_destroy_commands_and_sync :: proc(r: ^Renderer) {
	for i in 0..<FRAMES_IN_FLIGHT {
		if r.image_available[i] != 0 { vk.DestroySemaphore(r.device, r.image_available[i], nil); r.image_available[i] = 0 }
		if r.in_flight[i]       != 0 { vk.DestroyFence    (r.device, r.in_flight[i],       nil); r.in_flight[i]       = 0 }
	}
	vk_destroy_render_finished_semaphores(r)
	if r.cmd_pool != 0 {
		vk.DestroyCommandPool(r.device, r.cmd_pool, nil)
		r.cmd_pool = 0
	}
}

@(private)
vk_image_barrier :: proc(
	cb: vk.CommandBuffer, image: vk.Image, range: vk.ImageSubresourceRange,
	src_access, dst_access: vk.AccessFlags,
	old_layout, new_layout: vk.ImageLayout,
	src_stage, dst_stage:   vk.PipelineStageFlags,
) {
	b := vk.ImageMemoryBarrier{
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = src_access, dstAccessMask = dst_access,
		oldLayout = old_layout, newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image, subresourceRange = range,
	}
	vk.CmdPipelineBarrier(cb, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &b)
}
