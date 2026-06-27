#+build linux
package skald

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import vk "vendor:vulkan"

// Dmabuf_Image describes a single-plane, packed-RGBA external buffer to import
// as a sampleable texture. `fourcc` is a DRM_FORMAT_* code (we support the four
// 8888 packed orders); `modifier` is the DRM format modifier (0 = LINEAR);
// `stride` / `offset` locate the single plane. See image_import_dmabuf.
Dmabuf_Image :: struct {
	fd:       int,
	width:    u32,
	height:   u32,
	fourcc:   u32,
	modifier: u64,
	stride:   u32,
	offset:   u32,
}

@(private = "file") DRM_FORMAT_ARGB8888 :: u32('A') | u32('R') << 8 | u32('2') << 16 | u32('4') << 24
@(private = "file") DRM_FORMAT_XRGB8888 :: u32('X') | u32('R') << 8 | u32('2') << 16 | u32('4') << 24
@(private = "file") DRM_FORMAT_ABGR8888 :: u32('A') | u32('B') << 8 | u32('2') << 16 | u32('4') << 24
@(private = "file") DRM_FORMAT_XBGR8888 :: u32('X') | u32('B') << 8 | u32('2') << 16 | u32('4') << 24

// dmabuf_format maps a DRM fourcc to a sampleable VkFormat. `opaque` = the
// source has no alpha channel (X-format), so the view forces alpha to 1. We use
// the _SRGB variants so sampling matches the rest of the image path. ok = false
// for anything but the four single-plane 8888 orders.
@(private = "file")
dmabuf_format :: proc(fourcc: u32) -> (format: vk.Format, opaque: bool, ok: bool) {
	switch fourcc {
	case DRM_FORMAT_ARGB8888: return .B8G8R8A8_SRGB, false, true
	case DRM_FORMAT_XRGB8888: return .B8G8R8A8_SRGB, true,  true
	case DRM_FORMAT_ABGR8888: return .R8G8B8A8_SRGB, false, true
	case DRM_FORMAT_XBGR8888: return .R8G8B8A8_SRGB, true,  true
	}
	return {}, false, false
}

// dmabuf_modifier_planes returns how many memory planes `modifier` uses for
// `format` (per the device's advertised modifier list), and whether the device
// lists it at all. Used to reject multi-plane (e.g. DCC) modifiers with a clear
// message instead of a downstream CreateImage failure.
@(private = "file")
dmabuf_modifier_planes :: proc(r: ^Renderer, format: vk.Format, modifier: u64) -> (planes: u32, found: bool) {
	list := vk.DrmFormatModifierPropertiesListEXT{sType = .DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT}
	props := vk.FormatProperties2{sType = .FORMAT_PROPERTIES_2, pNext = &list}
	vk.GetPhysicalDeviceFormatProperties2(r.phys_device, format, &props)
	if list.drmFormatModifierCount == 0 { return 0, false }
	mods := make([]vk.DrmFormatModifierPropertiesEXT, list.drmFormatModifierCount, context.temp_allocator)
	list.pDrmFormatModifierProperties = raw_data(mods)
	vk.GetPhysicalDeviceFormatProperties2(r.phys_device, format, &props)
	for m in mods {
		if m.drmFormatModifier == modifier { return m.drmFormatModifierPlaneCount, true }
	}
	return 0, false
}

// image_import_dmabuf imports an external dmabuf as a sampleable texture under
// `key`, drawn by the normal `image(ctx, key, …)` path. The producer keeps
// writing into the buffer — import once, `image_release` when done. Skald dup()s
// the fd (you keep + close yours); the dup is freed on `image_release`. Returns
// false (no crash) when the device lacks dmabuf support or the format/modifier
// isn't importable — fall back to `image_load_pixels`. Sync is implicit (dmabuf
// fences); an explicit acquire-fence is a later addition.
image_import_dmabuf :: proc(r: ^Renderer, key: string, img: Dmabuf_Image) -> bool {
	if r == nil || r.device == nil || !r.dmabuf_ok { return false }
	if img.width == 0 || img.height == 0 { return false }

	vkfmt, opaque, fmt_ok := dmabuf_format(img.fourcc)
	if !fmt_ok {
		fmt.eprintfln("skald: image_import_dmabuf(%s): unsupported fourcc 0x%X", key, img.fourcc)
		return false
	}

	// We describe a single plane, so a modifier that needs 2+ memory planes
	// (e.g. an AMD DCC-compressed tiling) can't be imported through this struct.
	// Say so clearly — the producer should allocate without compression (a
	// single-plane tiled modifier) or LINEAR — rather than fail at CreateImage.
	if planes, found := dmabuf_modifier_planes(r, vkfmt, img.modifier); found && planes != 1 {
		fmt.eprintfln("skald: image_import_dmabuf(%s): modifier 0x%X needs %d planes (e.g. DCC) — allocate a single-plane or LINEAR buffer",
			key, img.modifier, planes)
		return false
	}

	// Own a private copy of the fd. Vulkan takes ownership of this dup on a
	// successful AllocateMemory (and closes it on FreeMemory); the `owned`
	// guard closes it ourselves only if we bail before that hand-off.
	dupres, derr := linux.dup(linux.Fd(i32(img.fd)))
	if derr != .NONE { return false }
	dupfd := c.int(i32(dupres))
	owned := true
	defer if owned { linux.close(linux.Fd(i32(dupfd))) }

	// Image backed by external (dmabuf) memory, with the explicit DRM modifier +
	// plane layout the producer allocated it with.
	plane := vk.SubresourceLayout{offset = vk.DeviceSize(img.offset), rowPitch = vk.DeviceSize(img.stride)}
	mod := vk.ImageDrmFormatModifierExplicitCreateInfoEXT{
		sType = .IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
		drmFormatModifier = img.modifier,
		drmFormatModifierPlaneCount = 1,
		pPlaneLayouts = &plane,
	}
	ext := vk.ExternalMemoryImageCreateInfo{
		sType = .EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		pNext = &mod,
		handleTypes = {.DMA_BUF_EXT},
	}
	ici := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, pNext = &ext,
		imageType = .D2, format = vkfmt,
		extent = {img.width, img.height, 1}, mipLevels = 1, arrayLayers = 1,
		samples = {._1}, tiling = .DRM_FORMAT_MODIFIER_EXT,
		usage = {.SAMPLED}, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	image: vk.Image
	if res := vk.CreateImage(r.device, &ici, nil, &image); res != .SUCCESS {
		fmt.eprintfln("skald: image_import_dmabuf(%s): CreateImage %v", key, res)
		return false
	}

	// Import the fd as dedicated device memory and bind it.
	fdprops := vk.MemoryFdPropertiesKHR{sType = .MEMORY_FD_PROPERTIES_KHR}
	if res := vk.GetMemoryFdPropertiesKHR(r.device, {.DMA_BUF_EXT}, dupfd, &fdprops); res != .SUCCESS {
		fmt.eprintfln("skald: image_import_dmabuf(%s): GetMemoryFdProperties %v", key, res)
		vk.DestroyImage(r.device, image, nil); return false
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, image, &req)
	type_bits := req.memoryTypeBits & fdprops.memoryTypeBits
	if type_bits == 0 {
		fmt.eprintfln("skald: image_import_dmabuf(%s): no importable memory type", key)
		vk.DestroyImage(r.device, image, nil); return false
	}
	dedicated := vk.MemoryDedicatedAllocateInfo{sType = .MEMORY_DEDICATED_ALLOCATE_INFO, image = image}
	imp := vk.ImportMemoryFdInfoKHR{
		sType = .IMPORT_MEMORY_FD_INFO_KHR, pNext = &dedicated,
		handleType = {.DMA_BUF_EXT}, fd = dupfd,
	}
	ai := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO, pNext = &imp,
		allocationSize = req.size,
		memoryTypeIndex = vk_find_mem_type(r, type_bits, {}),
	}
	mem: vk.DeviceMemory
	if res := vk.AllocateMemory(r.device, &ai, nil, &mem); res != .SUCCESS {
		fmt.eprintfln("skald: image_import_dmabuf(%s): AllocateMemory %v", key, res)
		vk.DestroyImage(r.device, image, nil); return false
	}
	owned = false // Vulkan owns dupfd now; image_release -> FreeMemory closes it
	vk.BindImageMemory(r.device, image, mem, 0)

	// Acquire the imported image (from the foreign queue family when available)
	// and transition it to a sampleable layout. UNDEFINED → SHADER_READ_ONLY is
	// the standard import-then-sample path for modifier images (the modifier,
	// not the Vulkan layout, defines the memory layout).
	src_qf := vk.QUEUE_FAMILY_IGNORED
	dst_qf := vk.QUEUE_FAMILY_IGNORED
	if r.dmabuf_foreign {
		src_qf = vk.QUEUE_FAMILY_FOREIGN_EXT
		dst_qf = r.queue_family_idx
	}
	cb := vk_begin_one_shot(r)
	bar := vk.ImageMemoryBarrier{
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {}, dstAccessMask = {.SHADER_READ},
		oldLayout = .UNDEFINED, newLayout = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = src_qf, dstQueueFamilyIndex = dst_qf,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(cb, {.TOP_OF_PIPE}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &bar)
	vk_end_one_shot(r, cb)

	// View (force alpha = 1 for X-formats) + descriptor set.
	comps: vk.ComponentMapping
	if opaque { comps.a = .ONE }
	view, dset, vdok := image_make_view_dset(r, image, vkfmt, 1, comps)
	if !vdok {
		vk.DestroyImage(r.device, image, nil); vk.FreeMemory(r.device, mem, nil)
		return false
	}

	// Register, replacing any prior entry under this key.
	if r.images.entries == nil { r.images.entries = make(map[string]^Image_Entry) }
	if _, ok := r.images.entries[key]; ok {
		vk.DeviceWaitIdle(r.device)
		image_cache_drop(r, key)
	}
	r.images.use_counter += 1
	entry := new(Image_Entry)
	entry^ = Image_Entry{
		image = image, mem = mem, view = view, dset = dset,
		width = img.width, height = img.height, mip_count = 1,
		external = true, last_use = r.images.use_counter,
	}
	r.images.entries[strings.clone(key)] = entry
	return true
}
