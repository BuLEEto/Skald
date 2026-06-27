#+build !linux
package skald

// dmabuf import is a Linux/Wayland feature (VK_EXT_external_memory_dma_buf).
// On other platforms the struct still exists so cross-platform app code
// compiles, and the import is a no-op that always falls back.

Dmabuf_Image :: struct {
	fd:       int,
	width:    u32,
	height:   u32,
	fourcc:   u32,
	modifier: u64,
	stride:   u32,
	offset:   u32,
}

// image_import_dmabuf — see the Linux implementation. Always returns false
// off Linux; callers fall back to image_load_pixels / image_update_pixels.
image_import_dmabuf :: proc(r: ^Renderer, key: string, img: Dmabuf_Image) -> bool {
	return false
}
