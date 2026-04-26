package skald

import "core:fmt"
import "core:math"
import "core:strings"
import "core:c"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

// sRGB ↔ linear conversion table. Populated once, reused forever.
// The image mip generator decodes each texel to linear before box-
// filtering so downsampling preserves perceived brightness; averaging
// raw sRGB bytes produces noticeably darker mips on gradients.
@(private)
srgb_to_linear_lut: [256]f32
@(private)
srgb_lut_ready:     bool

@(private)
srgb_lut_init :: proc() {
	if srgb_lut_ready { return }
	for i in 0..<256 {
		v := f32(i) / 255.0
		if v <= 0.04045 {
			srgb_to_linear_lut[i] = v / 12.92
		} else {
			srgb_to_linear_lut[i] = math.pow((v + 0.055) / 1.055, 2.4)
		}
	}
	srgb_lut_ready = true
}

@(private)
linear_to_srgb_byte :: proc(l_in: f32) -> u8 {
	l := l_in
	if l < 0 { l = 0 }
	if l > 1 { l = 1 }
	s: f32
	if l <= 0.0031308 {
		s = l * 12.92
	} else {
		s = 1.055 * math.pow(l, 1.0/2.4) - 0.055
	}
	r := s * 255.0 + 0.5
	if r < 0   { r = 0 }
	if r > 255 { r = 255 }
	return u8(r)
}

// downsample_mip halves `src` (sw × sh RGBA8, sRGB-encoded) with a
// 2×2 box filter in linear space. Odd-axis parents clamp to the last
// texel so we don't sample out-of-bounds; this introduces a half-pixel
// bias on odd dimensions — standard for simple mip generators and
// invisible past the first level or two. Alpha is averaged straight
// (not gamma-corrected) and not premultiplied, matching the texture's
// straight-alpha blend.
@(private)
downsample_mip :: proc(src: []u8, sw, sh: u32, dst: []u8, dw, dh: u32) {
	srgb_lut_init()
	for y in u32(0)..<dh {
		sy0 := min(y * 2,     sh - 1)
		sy1 := min(y * 2 + 1, sh - 1)
		for x in u32(0)..<dw {
			sx0 := min(x * 2,     sw - 1)
			sx1 := min(x * 2 + 1, sw - 1)

			p00 := int((sy0 * sw + sx0) * 4)
			p01 := int((sy0 * sw + sx1) * 4)
			p10 := int((sy1 * sw + sx0) * 4)
			p11 := int((sy1 * sw + sx1) * 4)

			r := (srgb_to_linear_lut[src[p00  ]] + srgb_to_linear_lut[src[p01  ]] +
			      srgb_to_linear_lut[src[p10  ]] + srgb_to_linear_lut[src[p11  ]]) * 0.25
			g := (srgb_to_linear_lut[src[p00+1]] + srgb_to_linear_lut[src[p01+1]] +
			      srgb_to_linear_lut[src[p10+1]] + srgb_to_linear_lut[src[p11+1]]) * 0.25
			b := (srgb_to_linear_lut[src[p00+2]] + srgb_to_linear_lut[src[p01+2]] +
			      srgb_to_linear_lut[src[p10+2]] + srgb_to_linear_lut[src[p11+2]]) * 0.25
			a := (f32(src[p00+3]) + f32(src[p01+3]) +
			      f32(src[p10+3]) + f32(src[p11+3])) * 0.25

			di := int((y * dw + x) * 4)
			dst[di  ] = linear_to_srgb_byte(r)
			dst[di+1] = linear_to_srgb_byte(g)
			dst[di+2] = linear_to_srgb_byte(b)
			dst[di+3] = u8(a + 0.5)
		}
	}
}

// Image_Entry is one decoded + uploaded image, ready to draw. The
// descriptor set is pre-built with binding 1 pointing at this image's
// own view, so render-time is just "bind that descriptor set, emit a
// kind=2 quad." Held by the cache; freed on renderer shutdown or LRU
// eviction.
@(private)
Image_Entry :: struct {
	image:     vk.Image,
	mem:       vk.DeviceMemory,
	view:      vk.ImageView,
	dset:      vk.DescriptorSet,
	width:     u32,
	height:    u32,
	mip_count: u32,
	// last_use is the value of Image_Cache.use_counter stamped each time
	// this entry is fetched. Used by the LRU eviction pass to pick the
	// least-recently-drawn image when the cache overflows.
	last_use:  u64,
}

// IMAGE_CACHE_MAX_ENTRIES caps the number of live GPU textures the
// renderer holds. Past that, every new `image_cache_get` miss evicts the
// least-recently-used entry (descriptor set / image view / image / mem
// released, key freed). Tune if you ship an app that scrolls through
// thousands of unique images (file browser thumbnails) — but note that
// async decoding is a separate concern and not covered by this cap alone.
IMAGE_CACHE_MAX_ENTRIES :: 256

// Image_Cache maps a file path to its on-GPU representation. Lookups are
// lazy: the first `skald.image(ctx, "foo.png", ...)` that reaches the
// renderer triggers a sync stb_image decode + staged upload; subsequent
// frames hit the cache. The map owns the cloned path key and the
// heap-allocated Image_Entry, both released in image_cache_destroy.
//
// v1 is single-threaded and eager-on-first-use. Async loading (nbio or a
// worker thread for larger images) is a follow-up — the hot path is
// already just a hashmap lookup.
@(private)
Image_Cache :: struct {
	entries:     map[string]^Image_Entry,
	// use_counter is a monotonically increasing tick bumped on every
	// cache hit + insert. Entries stamp the current value in their
	// `last_use` field so `image_cache_evict_lru` can find the oldest.
	use_counter: u64,
	dset_pool:   vk.DescriptorPool,
}

@(private)
image_cache_init :: proc(c: ^Image_Cache, r: ^Renderer) -> bool {
	pool_sizes := [?]vk.DescriptorPoolSize{
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = IMAGE_CACHE_MAX_ENTRIES},
	}
	pi := vk.DescriptorPoolCreateInfo{
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		flags = {.FREE_DESCRIPTOR_SET},
		maxSets = IMAGE_CACHE_MAX_ENTRIES,
		poolSizeCount = u32(len(pool_sizes)), pPoolSizes = raw_data(pool_sizes[:]),
	}
	if res := vk.CreateDescriptorPool(r.device, &pi, nil, &c.dset_pool); res != .SUCCESS {
		fmt.eprintfln("skald: CreateDescriptorPool (images): %v", res)
		return false
	}
	return true
}

// image_cache_get returns the cached entry for `path`, loading it on
// demand. Returns nil when the file can't be decoded — callers render a
// magenta placeholder (easy-to-spot) in that case rather than crashing.
@(private)
image_cache_get :: proc(r: ^Renderer, path: string) -> ^Image_Entry {
	if r == nil || r.device == nil { return nil }

	if r.images.entries == nil {
		r.images.entries = make(map[string]^Image_Entry)
	}
	r.images.use_counter += 1
	if entry, ok := r.images.entries[path]; ok {
		entry.last_use = r.images.use_counter
		return entry
	}

	// Cap cache size: evict least-recently-used before inserting.
	if len(r.images.entries) >= IMAGE_CACHE_MAX_ENTRIES {
		image_cache_evict_lru(&r.images, r)
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	w_c, h_c, ch_c: c.int
	pixels := stbi.load(cpath, &w_c, &h_c, &ch_c, 4) // force RGBA8
	if pixels == nil {
		fmt.eprintfln("skald: image decode failed: %s (%s)", path, stbi.failure_reason())
		return nil
	}
	defer stbi.image_free(pixels)

	w := u32(w_c)
	h := u32(h_c)
	rgba := ([^]u8)(pixels)[:int(w * h * 4)]
	return image_cache_insert(r, path, w, h, rgba)
}

// image_upload_level stages `bytes` into a HOST_VISIBLE buffer and
// records a CmdCopyBufferToImage into `cb` targeting (image, level).
// The staging buffer + memory are appended to `sbufs` / `smems` so the
// caller can free them after the command-buffer's QueueWaitIdle. Used
// by both the create path (image_cache_insert) and the streaming
// refresh path (image_update_pixels) so the upload geometry stays
// in one place.
@(private)
image_upload_level :: proc(
	r: ^Renderer, cb: vk.CommandBuffer, image: vk.Image,
	level: u32, lw, lh: u32, bytes: []u8,
	sbufs: ^[dynamic]vk.Buffer, smems: ^[dynamic]vk.DeviceMemory,
) {
	size := vk.DeviceSize(len(bytes))
	stg_buf, stg_mem := vk_make_buffer(r, size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	append(sbufs, stg_buf); append(smems, stg_mem)
	ptr: rawptr
	vk.MapMemory(r.device, stg_mem, 0, size, {}, &ptr)
	vk_copy_bytes(ptr, raw_data(bytes), int(size))
	vk.UnmapMemory(r.device, stg_mem)

	region := vk.BufferImageCopy{
		imageSubresource = {aspectMask = {.COLOR}, mipLevel = level, layerCount = 1},
		imageExtent = {lw, lh, 1},
	}
	vk.CmdCopyBufferToImage(cb, stg_buf, image, .TRANSFER_DST_OPTIMAL, 1, &region)
}

// image_cache_insert allocates a VkImage of (w, h), uploads `rgba` (plus
// downsampled mips), wraps it in a view + descriptor set, and stores
// the resulting Image_Entry in the cache under `key`. Used by the
// file-path loader (after stb decode) and by the public
// `image_load_pixels` entry point.
//
// The `rgba` slice must be exactly w*h*4 bytes (RGBA8). It is consumed
// synchronously into a staging buffer; the caller's memory does not
// need to outlive this call.
@(private)
image_cache_insert :: proc(r: ^Renderer, key: string, w, h: u32, rgba: []u8) -> ^Image_Entry {
	if int(w) * int(h) * 4 != len(rgba) {
		fmt.eprintfln("skald: image_cache_insert size mismatch (w=%d h=%d, %d bytes given)",
			w, h, len(rgba))
		return nil
	}

	// Mip count: ceil(log2(max(w, h))) + 1, so a 1000-px texture gets
	// 10 levels down to 1×1. Mips are built CPU-side below; the sampler
	// uses trilinear filtering (mipmapMode = Linear) so downscales stay
	// sharp without shimmer.
	mip_count: u32 = 1
	{
		s := max(w, h)
		for s > 1 { s >>= 1; mip_count += 1 }
	}

	// R8G8B8A8_SRGB so sampling produces linear values — the swapchain
	// format (BGRA8_SRGB) re-encodes to sRGB on write. PNGs are stored in
	// sRGB, so this is the correct format for photographic and UI art.
	// If an app needs linear textures (normal maps, data textures) they'd
	// need a separate code path; v1 doesn't.
	image: vk.Image
	mem:   vk.DeviceMemory
	{
		ii := vk.ImageCreateInfo{
			sType = .IMAGE_CREATE_INFO, imageType = .D2, format = .R8G8B8A8_SRGB,
			extent = {w, h, 1}, mipLevels = mip_count, arrayLayers = 1,
			samples = {._1}, tiling = .OPTIMAL,
			usage = {.TRANSFER_DST, .SAMPLED}, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
		}
		if res := vk.CreateImage(r.device, &ii, nil, &image); res != .SUCCESS {
			fmt.eprintfln("skald: CreateImage (image): %v", res); return nil
		}
		req: vk.MemoryRequirements
		vk.GetImageMemoryRequirements(r.device, image, &req)
		ai := vk.MemoryAllocateInfo{
			sType = .MEMORY_ALLOCATE_INFO,
			allocationSize = req.size,
			memoryTypeIndex = vk_find_mem_type(r, req.memoryTypeBits, {.DEVICE_LOCAL}),
		}
		if res := vk.AllocateMemory(r.device, &ai, nil, &mem); res != .SUCCESS {
			fmt.eprintfln("skald: AllocateMemory (image): %v", res)
			vk.DestroyImage(r.device, image, nil); return nil
		}
		vk.BindImageMemory(r.device, image, mem, 0)
	}

	full_range := vk.ImageSubresourceRange{
		aspectMask = {.COLOR}, baseMipLevel = 0, levelCount = mip_count,
		baseArrayLayer = 0, layerCount = 1,
	}

	cb := vk_begin_one_shot(r)

	vk_image_barrier(cb, image, full_range,
		{}, {.TRANSFER_WRITE},
		.UNDEFINED, .TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE}, {.TRANSFER})

	// Staging buffers live until QueueWaitIdle completes (inside
	// vk_end_one_shot), so we stash them and free them after.
	staging_bufs: [dynamic]vk.Buffer;        staging_bufs.allocator = context.temp_allocator
	staging_mems: [dynamic]vk.DeviceMemory;  staging_mems.allocator = context.temp_allocator

	// Level 0: upload the caller's pixels directly.
	image_upload_level(r, cb, image, 0, w, h, rgba, &staging_bufs, &staging_mems)

	// Levels 1..N: box-filter the previous level in linear space and
	// upload. Each level's RAM comes from temp_allocator — we've already
	// copied it into the GPU by the time the function returns, and
	// free_all(temp) at frame-end reclaims the scratch.
	if mip_count > 1 {
		cur := rgba
		cur_w := w; cur_h := h
		for level in u32(1)..<mip_count {
			dw := max(u32(1), cur_w / 2)
			dh := max(u32(1), cur_h / 2)
			next := make([]u8, int(dw * dh * 4), context.temp_allocator)
			downsample_mip(cur, cur_w, cur_h, next, dw, dh)
			image_upload_level(r, cb, image, level, dw, dh, next, &staging_bufs, &staging_mems)
			cur = next; cur_w = dw; cur_h = dh
		}
	}

	vk_image_barrier(cb, image, full_range,
		{.TRANSFER_WRITE}, {.SHADER_READ},
		.TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER}, {.FRAGMENT_SHADER})

	vk_end_one_shot(r, cb)

	// Now safe to free staging resources (QueueWaitIdle completed).
	for buf in staging_bufs { vk.DestroyBuffer(r.device, buf, nil) }
	for m   in staging_mems { vk.FreeMemory(r.device, m, nil) }

	// Image view over all mips.
	view: vk.ImageView
	{
		viw := vk.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image, viewType = .D2, format = .R8G8B8A8_SRGB,
			subresourceRange = full_range,
		}
		if res := vk.CreateImageView(r.device, &viw, nil, &view); res != .SUCCESS {
			fmt.eprintfln("skald: CreateImageView (image): %v", res)
			vk.DestroyImage(r.device, image, nil); vk.FreeMemory(r.device, mem, nil)
			return nil
		}
	}

	// Per-image descriptor set. Same layout as Pipeline's single-
	// binding set — binding 0 points at this image's view + sampler.
	// fb_size is pushed via push constants, no uniform binding needed.
	dset: vk.DescriptorSet
	{
		layout := r.pipeline.dset_layout
		ai := vk.DescriptorSetAllocateInfo{
			sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = r.images.dset_pool,
			descriptorSetCount = 1, pSetLayouts = &layout,
		}
		if res := vk.AllocateDescriptorSets(r.device, &ai, &dset); res != .SUCCESS {
			fmt.eprintfln("skald: AllocateDescriptorSets (image): %v", res)
			vk.DestroyImageView(r.device, view, nil)
			vk.DestroyImage(r.device, image, nil); vk.FreeMemory(r.device, mem, nil)
			return nil
		}
		ii := vk.DescriptorImageInfo{
			sampler = r.pipeline.sampler, imageView = view, imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		write := vk.WriteDescriptorSet{
			sType = .WRITE_DESCRIPTOR_SET, dstSet = dset,
			dstBinding = 0, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &ii,
		}
		vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
	}

	entry := new(Image_Entry)
	entry^ = Image_Entry{
		image = image, mem = mem, view = view, dset = dset,
		width = w, height = h, mip_count = mip_count,
		last_use = r.images.use_counter,
	}
	// Clone the key so it outlives the caller's string — view-tree
	// strings and synthetic names alike may live in the frame arena.
	r.images.entries[strings.clone(key)] = entry
	return entry
}

// image_load_pixels registers an in-memory RGBA8 buffer with the image
// cache under a synthetic name, so any later `image(ctx, name, …)` call
// draws it the same way as a file-loaded image. Use this when the
// pixels come from anywhere other than disk — a rasterized DXF / SVG /
// PDF page, a video frame, an in-memory PNG fetched over the network,
// a procedurally generated thumbnail, a golden-image test fixture.
//
// `rgba` must be exactly `w * h * 4` bytes. Format is RGBA8 sRGB,
// matching the file-loaded path; pre-multiplied alpha is not assumed.
// The bytes are copied into a staging buffer synchronously — the
// caller's slice does not need to outlive this call.
//
// Pick a name unlikely to collide with any file path you might also
// load (e.g. `"app://thumb/42"`, `"dxfwg.viewport"`). If `name` is
// already registered the existing entry is replaced (after a
// `DeviceWaitIdle` so any in-flight frame referencing it has finished).
//
// Returns true on success, false on size mismatch or allocation
// failure. The image draws via `image(ctx, name, ...)` and participates
// in LRU eviction the same as file-loaded images.
//
// **Not** intended for per-frame updates (paint apps, video playback,
// CAD viewport panning). Replacement allocates a fresh `VkImage` +
// `DeviceMemory` + descriptor set every call and waits the device idle
// to release the old one — at 60 fps that's strictly worse than
// redrawing many quads. For per-frame refreshes at the same size, use
// `image_update_pixels` after the initial `image_load_pixels` — it
// reuses the existing GPU allocation and skips the device-wait.
image_load_pixels :: proc(r: ^Renderer, name: string, w, h: u32, rgba: []u8) -> bool {
	if r == nil || r.device == nil { return false }
	if w == 0 || h == 0            { return false }
	if int(w) * int(h) * 4 != len(rgba) {
		fmt.eprintfln("skald: image_load_pixels(%s): size mismatch (w=%d h=%d, %d bytes given)",
			name, w, h, len(rgba))
		return false
	}

	if r.images.entries == nil {
		r.images.entries = make(map[string]^Image_Entry)
	}

	// Replacing an existing entry: wait for in-flight frames to drain
	// so we don't free a VkImage the GPU is still sampling, then drop
	// the old entry. Cheap when no replacement is happening.
	if existing, ok := r.images.entries[name]; ok && existing != nil {
		vk.DeviceWaitIdle(r.device)
		if existing.dset  != 0 { vk.FreeDescriptorSets(r.device, r.images.dset_pool, 1, &existing.dset) }
		if existing.view  != 0 { vk.DestroyImageView(r.device, existing.view, nil) }
		if existing.image != 0 { vk.DestroyImage(r.device, existing.image, nil) }
		if existing.mem   != 0 { vk.FreeMemory(r.device, existing.mem, nil) }
		// Recover the cloned key so the next insert can re-clone without
		// leaking the prior allocation.
		for k in r.images.entries {
			if k == name {
				delete_key(&r.images.entries, k)
				delete(k)
				break
			}
		}
		free(existing)
	} else if len(r.images.entries) >= IMAGE_CACHE_MAX_ENTRIES {
		image_cache_evict_lru(&r.images, r)
	}

	r.images.use_counter += 1
	return image_cache_insert(r, name, w, h, rgba) != nil
}

// image_update_pixels refreshes an already-registered image in place,
// reusing its `VkImage` / `DeviceMemory` / `VkImageView` / descriptor
// set. Intended for per-frame streaming sources — software rasterizers
// (CAD pan/zoom), video frame queues, paint canvases, anything that
// produces fresh RGBA on a clock. Cost is one staged copy + a
// `QueueWaitIdle` to drain the upload before staging-buffer free; no
// `DeviceWaitIdle`, no fresh allocations, no descriptor-set rebuild —
// orders of magnitude cheaper than `image_load_pixels` at 60 fps.
//
// Preconditions: `name` must already be registered (call
// `image_load_pixels` once to seed the entry), and `w` × `h` must
// match the existing entry's extent. Returns false on either miss —
// callers handle the size-changed case by re-seeding via
// `image_load_pixels`.
//
// `rgba` is RGBA8 sRGB, w*h*4 bytes, copied synchronously into a
// staging buffer.
//
// Mip caveat: when the registered image was created with mips
// (anything not 1×1), this proc regenerates **all** mip levels each
// call by box-filtering on the CPU and uploading every level. That's
// the correct behaviour for content viewed at varying scales (the
// sampler picks a mip per pixel) but adds cost roughly proportional
// to 4/3 × the level-0 upload. If you know the image is always
// sampled at native size or larger (the common CAD-viewport case),
// the cost is dominated by level 0 and the mip overhead is just the
// CPU box-filter — still vastly cheaper than the alloc/free path.
image_update_pixels :: proc(r: ^Renderer, name: string, w, h: u32, rgba: []u8) -> bool {
	if r == nil || r.device == nil || r.images.entries == nil { return false }
	if w == 0 || h == 0 { return false }
	if int(w) * int(h) * 4 != len(rgba) {
		fmt.eprintfln("skald: image_update_pixels(%s): size mismatch (w=%d h=%d, %d bytes given)",
			name, w, h, len(rgba))
		return false
	}
	entry, ok := r.images.entries[name]
	if !ok || entry == nil { return false }
	if entry.width != w || entry.height != h { return false }

	full_range := vk.ImageSubresourceRange{
		aspectMask = {.COLOR}, baseMipLevel = 0, levelCount = entry.mip_count,
		baseArrayLayer = 0, layerCount = 1,
	}

	cb := vk_begin_one_shot(r)

	// Image was left in SHADER_READ_ONLY_OPTIMAL by its previous
	// upload (or by image_cache_insert at create time). Flip it to
	// TRANSFER_DST_OPTIMAL so we can copy into it.
	vk_image_barrier(cb, entry.image, full_range,
		{.SHADER_READ}, {.TRANSFER_WRITE},
		.SHADER_READ_ONLY_OPTIMAL, .TRANSFER_DST_OPTIMAL,
		{.FRAGMENT_SHADER}, {.TRANSFER})

	staging_bufs: [dynamic]vk.Buffer;        staging_bufs.allocator = context.temp_allocator
	staging_mems: [dynamic]vk.DeviceMemory;  staging_mems.allocator = context.temp_allocator

	image_upload_level(r, cb, entry.image, 0, w, h, rgba, &staging_bufs, &staging_mems)

	// Regenerate mips so shrunken samples don't read stale levels
	// from the previous frame's content. Same algorithm as the create
	// path; box-filter in linear space, upload each level.
	if entry.mip_count > 1 {
		cur := rgba
		cur_w := w; cur_h := h
		for level in u32(1)..<entry.mip_count {
			dw := max(u32(1), cur_w / 2)
			dh := max(u32(1), cur_h / 2)
			next := make([]u8, int(dw * dh * 4), context.temp_allocator)
			downsample_mip(cur, cur_w, cur_h, next, dw, dh)
			image_upload_level(r, cb, entry.image, level, dw, dh, next, &staging_bufs, &staging_mems)
			cur = next; cur_w = dw; cur_h = dh
		}
	}

	// Back to sampling layout for the rest of the frame.
	vk_image_barrier(cb, entry.image, full_range,
		{.TRANSFER_WRITE}, {.SHADER_READ},
		.TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER}, {.FRAGMENT_SHADER})

	vk_end_one_shot(r, cb)

	for buf in staging_bufs { vk.DestroyBuffer(r.device, buf, nil) }
	for m   in staging_mems { vk.FreeMemory(r.device, m, nil) }

	r.images.use_counter += 1
	entry.last_use = r.images.use_counter
	return true
}

// draw_image paints an image cache entry into a canvas-style draw
// callback at `rect` (logical pixels, same coordinate space as
// `draw_rect` / `draw_text`). The image must already be registered
// — by file path via the normal `image()` widget render, or by name
// via `image_load_pixels`. Use this when you want to composite an
// image inside a `canvas` callback so app-drawn overlay primitives
// (lines, markers, text) can sit on top in the same view node.
//
// Fit modes follow the same semantics as `image()`:
//   .Fill    stretch to fill, aspect ignored
//   .Contain scale to fit inside, letterbox the shorter axis
//   .Cover   scale to fill, crop the overflow via UV trim (default)
//   .None    native size, centered (clipped to `rect`)
//
// Returns false if `name` isn't registered (caller can paint a
// placeholder); true on success.
draw_image :: proc(
	r:    ^Renderer,
	name: string,
	rect: Rect,
	fit:  Image_Fit = .Cover,
	tint: Color     = {1, 1, 1, 1},
) -> bool {
	if r == nil { return false }
	entry := image_cache_get(r, name)
	if entry == nil { return false }
	pos, uv := image_fit_rects(rect, f32(entry.width), f32(entry.height), fit)
	push_clip(r, rect)
	batch_push_image(r, entry.dset, pos, uv, tint)
	pop_clip(r)
	return true
}

// image_unload drops a registered image, releasing its GPU resources.
// Safe to call with a name that was never registered (no-op). Used to
// reclaim memory when the producer of a registered image (a closed CAD
// document, a finished video) no longer needs it on screen — file-
// loaded images self-evict via LRU and rarely need this.
image_unload :: proc(r: ^Renderer, name: string) {
	if r == nil || r.device == nil || r.images.entries == nil { return }
	entry, ok := r.images.entries[name]
	if !ok || entry == nil { return }
	vk.DeviceWaitIdle(r.device)
	if entry.dset  != 0 { vk.FreeDescriptorSets(r.device, r.images.dset_pool, 1, &entry.dset) }
	if entry.view  != 0 { vk.DestroyImageView(r.device, entry.view, nil) }
	if entry.image != 0 { vk.DestroyImage(r.device, entry.image, nil) }
	if entry.mem   != 0 { vk.FreeMemory(r.device, entry.mem, nil) }
	for k in r.images.entries {
		if k == name {
			delete_key(&r.images.entries, k)
			delete(k)
			break
		}
	}
	free(entry)
}

// image_cache_evict_lru drops the entry with the smallest `last_use`,
// releasing its GPU resources. Linear scan — fine at a cap of a few
// hundred; if the cap ever grows into the thousands, swap in a min-heap
// keyed on last_use.
@(private)
image_cache_evict_lru :: proc(c: ^Image_Cache, r: ^Renderer) {
	oldest_key: string
	oldest_use: u64 = max(u64)
	found := false
	for key, entry in c.entries {
		if entry == nil { continue }
		if entry.last_use < oldest_use {
			oldest_use = entry.last_use
			oldest_key = key
			found = true
		}
	}
	if !found { return }
	entry := c.entries[oldest_key]
	if entry != nil {
		if entry.dset  != 0 { vk.FreeDescriptorSets(r.device, c.dset_pool, 1, &entry.dset) }
		if entry.view  != 0 { vk.DestroyImageView(r.device, entry.view, nil) }
		if entry.image != 0 { vk.DestroyImage(r.device, entry.image, nil) }
		if entry.mem   != 0 { vk.FreeMemory(r.device, entry.mem, nil) }
		free(entry)
	}
	delete_key(&c.entries, oldest_key)
	delete(oldest_key)
}

@(private)
image_cache_destroy :: proc(c: ^Image_Cache, r: ^Renderer) {
	if c.entries != nil {
		for key, entry in c.entries {
			if entry == nil { continue }
			if entry.view  != 0 { vk.DestroyImageView(r.device, entry.view, nil) }
			if entry.image != 0 { vk.DestroyImage(r.device, entry.image, nil) }
			if entry.mem   != 0 { vk.FreeMemory(r.device, entry.mem, nil) }
			// Descriptor sets are freed wholesale when the pool is destroyed.
			free(entry)
			delete(key)
		}
		delete(c.entries)
		c.entries = nil
	}
	if c.dset_pool != 0 {
		vk.DestroyDescriptorPool(r.device, c.dset_pool, nil)
		c.dset_pool = 0
	}
}

// image_fit_rects computes the destination quad + UV sub-rect for a
// given fit mode. Inputs: `box` is the layout slot (in framebuffer
// pixels after translation); `iw`/`ih` are the image's pixel size.
// Returns (pos_rect, uv) where uv is `{u0, v0, u1, v1}`.
@(private)
image_fit_rects :: proc(
	box:   Rect,
	iw, ih: f32,
	fit:   Image_Fit,
) -> (pos: Rect, uv: [4]f32) {
	uv = {0, 0, 1, 1}
	if iw <= 0 || ih <= 0 || box.w <= 0 || box.h <= 0 {
		return box, uv
	}
	switch fit {
	case .Fill:
		pos = box
	case .None:
		// Native size centered; callers push_clip if they care about
		// overflow. Common for icons that ship at 1:1.
		dx := (box.w - iw) * 0.5
		dy := (box.h - ih) * 0.5
		pos = Rect{box.x + dx, box.y + dy, iw, ih}
	case .Contain:
		// Scale to fit *inside* box, preserving aspect. Letterbox with
		// transparent pixels (the quad shrinks — nothing draws in the
		// gap, so the parent's bg shows through).
		s := min(box.w / iw, box.h / ih)
		nw := iw * s
		nh := ih * s
		pos = Rect{box.x + (box.w - nw) * 0.5, box.y + (box.h - nh) * 0.5, nw, nh}
	case .Cover:
		// Scale to *fill* box, preserving aspect. The quad still covers
		// `box` exactly — we crop the UVs to exclude the overflow edge,
		// so the image appears centered with sides/tops trimmed.
		box_aspect := box.w / box.h
		img_aspect := iw / ih
		pos = box
		if img_aspect > box_aspect {
			// Image is wider — crop left/right.
			visible_u := box_aspect / img_aspect
			pad := (1.0 - visible_u) * 0.5
			uv = {pad, 0, 1.0 - pad, 1}
		} else {
			// Image is taller — crop top/bottom.
			visible_v := img_aspect / box_aspect
			pad := (1.0 - visible_v) * 0.5
			uv = {0, pad, 1, 1.0 - pad}
		}
	}
	return
}
