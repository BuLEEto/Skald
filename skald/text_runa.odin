package skald

import "core:fmt"
import "core:math"
import vk "vendor:vulkan"
import runa "third_party/runa"

// Text_Runa carries the runa-backed text state. Allocated once per
// Renderer when the `SKALD_RUNA` build define is true *and*
// `text_init_runa` succeeds; otherwise `Text.runa_state` stays nil
// and the renderer transparently falls back to fontstash.
//
// Phase 1a: mono (alpha) glyph path. The runa atlas is sized 1024×1024
// to match Skald's existing GPU image; alpha-page dirty rects flow into
// the same R8_UNORM texture fontstash used, so the rest of the
// renderer is untouched. Colour-emoji (RGBA) glyphs are detected but
// skipped — they render as nothing until Phase 1b lights up the second
// atlas + shader variant.
@(private)
Text_Runa :: struct {
	cache: runa.Cache,
	atlas: runa.Atlas,
	// Heap-allocated runa.Font values, indexed by skald.Font (cast to
	// int). Order is locked at init: 0 = default (Inter), 1 = bold,
	// 2 = italic, 3 = bold-italic. App-loaded fonts append from index 4.
	fonts: [dynamic]^runa.Font,

	// Skald font IDs that have been registered as fallbacks to any
	// base font. v0.1 simplification: a single global chain rather
	// than a per-base map. Every shaping call picks from
	// [primary] ++ fallback_chain.
	fallback_chain: [dynamic]int,

	// (font, glyph_id, size, subpx) → packed slot. raster_glyph
	// re-packs the atlas every call, so without this cache every
	// draw_text would fill the atlas with duplicates and overflow.
	glyph_cache: map[Glyph_Key]runa.Atlas_Slot,

	// Per-page registration flags for the colour atlas. Each colour
	// page maps to a synthetic image-cache entry
	// (`skald://runa-color-atlas/N`); the bool here marks whether the
	// N-th page has been seeded with `image_load_pixels` yet.
	// Registration is deferred to first dirty upload because
	// `text_init` runs before `image_cache_init`.
	color_atlas_registered: [dynamic]bool,

	// Reusable Font_Stack buffer. Built once per `font_add_fallback`
	// and re-pointed each call so `measure_text_runa` / `draw_text_runa`
	// don't allocate a fresh slice every time. Gallery-style UIs hit
	// this path dozens of times per frame; the savings show up as ~3 %
	// in p50 frame time.
	stack_buf: [dynamic]^runa.Font,

	// Per-page GPU resources for runa.atlas.pages_alpha[1..]. Page 0 is
	// mapped onto Skald's existing `Text.atlas_image` (the same R8_UNORM
	// image fontstash uses), so the default text descriptor still works
	// and apps that fit inside one page pay nothing extra. Pages 1, 2…
	// are lazily allocated here when runa's shelf packer spills beyond
	// the first page — each gets its own R8_UNORM image + descriptor
	// set bound to it, picked up by `batch_push_glyph` via a Batch_Range
	// swap (same pattern as `batch_push_image`).
	alpha_pages: [dynamic]Runa_Alpha_Page,
}

// Runa_Alpha_Page holds the GPU side of one runa alpha-atlas page
// beyond page 0. Allocated on demand by `text_runa_ensure_alpha_page`
// the first time a glyph with `slot.page_index = i` (for i ≥ 1)
// appears in `text_runa_emit_glyph`.
@(private)
Runa_Alpha_Page :: struct {
	image:  vk.Image,
	memory: vk.DeviceMemory,
	view:   vk.ImageView,
	dset:   vk.DescriptorSet,
	w, h:   u32,
}

// Glyph_Key keys the raster-slot cache. `size_q` is `size * 4` rounded
// (1/4-pixel quantisation — enough granularity for fractional DPI scale
// without exploding the cache).
@(private)
Glyph_Key :: struct {
	font:   ^runa.Font,
	gid:    u16,
	size_q: u32,
	subpx:  u8,
}

// Synthetic image-cache key prefix for runa's RGBA glyph atlas
// pages. Each colour page becomes one image-cache entry named
// `skald://runa-color-atlas/N`, so multi-page colour atlases (rare
// in practice but possible) Just Work via the existing image-cache
// + batch_push_image machinery.
@(private)
COLOR_ATLAS_KEY_PREFIX :: "skald://runa-color-atlas/"

@(private)
text_runa_color_key :: proc(idx: int) -> string {
	return fmt.tprintf("%s%d", COLOR_ATLAS_KEY_PREFIX, idx)
}

// RUNA_BACKEND_DEFAULT is true when the build was passed
// `-define:SKALD_RUNA=true`. text_init reads this to decide whether
// to even attempt the runa init path.
@(private)
RUNA_BACKEND_DEFAULT :: #config(SKALD_RUNA, false)

// text_init_runa allocates the Text_Runa state, opens the four bundled
// Inter faces against runa's parser, sizes the atlas to match Skald's
// 1024² GPU image, and parks the state on t.runa_state so every
// public API dispatches to the runa path from this frame onwards.
// Returns true on success; caller falls back to fontstash on false.
@(private)
text_init_runa :: proc(t: ^Text, r: ^Renderer) -> bool {
	rs := new(Text_Runa)
	rs.atlas = runa.atlas_make(u16(t.atlas_w), u16(t.atlas_h))
	rs.cache = runa.cache_make()
	rs.fonts          = make([dynamic]^runa.Font, 0, 4)
	rs.fallback_chain = make([dynamic]int, 0, 4)
	rs.glyph_cache    = make(map[Glyph_Key]runa.Atlas_Slot, 256)
	rs.stack_buf      = make([dynamic]^runa.Font, 1, 5)

	// Lock the embedded-Inter font indices to the same values fontstash
	// would have assigned (0..3), so app code that called font_default /
	// font_bold under fontstash keeps working.
	ok := text_runa_add_font(rs, INTER_VARIABLE) &&
	      text_runa_add_font(rs, INTER_BOLD) &&
	      text_runa_add_font(rs, INTER_ITALIC) &&
	      text_runa_add_font(rs, INTER_BOLD_ITALIC)
	if !ok {
		fmt.eprintln("skald: runa font load failed; falling back to fontstash")
		text_runa_free(rs)
		return false
	}

	t.default_font     = Font(0)
	t.bold_font        = Font(1)
	t.italic_font      = Font(2)
	t.bold_italic_font = Font(3)

	t.runa_state = rs
	return true
}

@(private)
text_destroy_runa :: proc(t: ^Text, r: ^Renderer) {
	if t.runa_state == nil { return }
	for &page in t.runa_state.alpha_pages {
		text_runa_destroy_alpha_page(&page, r)
	}
	text_runa_free(t.runa_state)
	t.runa_state = nil
}

@(private)
text_runa_free :: proc(rs: ^Text_Runa) {
	delete(rs.glyph_cache)
	delete(rs.fallback_chain)
	delete(rs.stack_buf)
	delete(rs.alpha_pages)
	delete(rs.color_atlas_registered)
	for f in rs.fonts {
		runa.font_destroy(f)
		free(f)
	}
	delete(rs.fonts)
	runa.cache_destroy(&rs.cache)
	runa.atlas_destroy(&rs.atlas)
	free(rs)
}

@(private)
text_runa_add_font :: proc(rs: ^Text_Runa, data: []u8) -> bool {
	f := new(runa.Font)
	loaded, err := runa.font_load(data)
	if err != .None {
		free(f)
		return false
	}
	f^ = loaded
	append(&rs.fonts, f)
	return true
}

// text_runa_stack returns the per-call Font_Stack: [primary] ++ every
// fallback that has been registered via font_add_fallback. Reuses a
// persistent buffer on Text_Runa rather than allocating a fresh slice
// per call — gallery-style UIs hit this dozens of times per frame.
@(private)
text_runa_stack :: proc(rs: ^Text_Runa, primary: Font) -> runa.Font_Stack {
	idx := int(primary)
	if idx < 0 || idx >= len(rs.fonts) { idx = 0 }
	n := 1 + len(rs.fallback_chain)
	resize(&rs.stack_buf, n)
	rs.stack_buf[0] = rs.fonts[idx]
	for fi, i in rs.fallback_chain {
		rs.stack_buf[i+1] = rs.fonts[fi]
	}
	return runa.Font_Stack(rs.stack_buf[:n])
}

// text_upload_dirty_runa drains every dirty alpha + colour page in
// runa's atlas into its corresponding Skald-side GPU resource.
//
// Alpha page 0 → the shared `Text.atlas_image` (the same R8_UNORM
// image fontstash uses, so the default text descriptor still works).
// Alpha pages 1+ → per-page images on `Text_Runa.alpha_pages`,
// lazily allocated. Drawing routes glyphs to the right descriptor
// via `slot.page_index`.
//
// Colour page 0 → the `skald://runa-color-atlas` image-cache entry.
// Colour pages 1+ → per-index entries (same key pattern). Drawing
// routes via `batch_push_image` with the matching entry's descriptor.
//
// Returns false for `rebuilt` — pages never resize, only grow in
// count.
@(private)
text_upload_dirty_runa :: proc(t: ^Text, r: ^Renderer) -> (rebuilt: bool) {
	rs := t.runa_state
	if rs == nil { return }

	// Alpha (mono) glyphs.
	for i in 0..<len(rs.atlas.pages_alpha) {
		page := &rs.atlas.pages_alpha[i]
		if !page.is_dirty { continue }

		x0 := int(page.dirty_min.x)
		y0 := int(page.dirty_min.y)
		x1 := int(page.dirty_max.x)
		y1 := int(page.dirty_max.y)
		w := x1 - x0
		h := y1 - y0
		if w > 0 && h > 0 {
			if i == 0 {
				// Page 0 is mapped to the shared atlas image.
				text_upload_region_from(t, r, x0, y0, w, h, page.pixels, int(page.width))
			} else {
				gp := text_runa_ensure_alpha_page(rs, r, i)
				if gp != nil {
					text_upload_region_to(r, gp, x0, y0, w, h, page.pixels, int(page.width))
				}
			}
		}
		page.is_dirty  = false
		page.dirty_min = {}
		page.dirty_max = {}
	}

	// Colour glyphs → per-page image-cache entries. Registration is
	// lazy (image_cache_init runs after text_init, so we can't seed
	// at init time); the first dirty rect for each page triggers
	// `image_load_pixels`, subsequent ones use `image_update_pixels`.
	// The whole page uploads each time — no sub-region API yet —
	// which is cheap enough at 4 MB-per-update because frames
	// introducing new emoji are rare.
	for i in 0..<len(rs.atlas.pages_color) {
		page := &rs.atlas.pages_color[i]
		if !page.is_dirty { continue }

		w, h := u32(page.width), u32(page.height)
		registered := i < len(rs.color_atlas_registered) && rs.color_atlas_registered[i]
		key := text_runa_color_key(i)
		if !registered {
			if image_load_pixels(r, key, w, h, page.pixels) {
				for len(rs.color_atlas_registered) <= i {
					append(&rs.color_atlas_registered, false)
				}
				rs.color_atlas_registered[i] = true
			}
		} else {
			image_update_pixels(r, key, w, h, page.pixels)
		}
		page.is_dirty  = false
		page.dirty_min = {}
		page.dirty_max = {}
	}
	return
}

@(private)
font_load_runa :: proc(r: ^Renderer, name: string, data: []byte) -> Font {
	rs := r.text.runa_state
	if !text_runa_add_font(rs, data) { return Font(-1) }
	return Font(len(rs.fonts) - 1)
}

@(private)
font_add_fallback_runa :: proc(r: ^Renderer, base, fallback: Font) -> bool {
	rs := r.text.runa_state
	fb := int(fallback)
	if fb < 0 || fb >= len(rs.fonts) { return false }
	// v0.1 simplification: one global chain, ignore `base`. Apps that
	// chain CJK or Arabic to the default Inter end up with the same
	// effective behaviour because the primary is the only font that
	// ever gets shaping pressure to look elsewhere.
	append(&rs.fallback_chain, fb)
	return true
}

// text_runa_px_size converts a Skald "logical pixel" size into the
// equivalent runa size. The two backends disagree on what "size = N"
// means: fontstash (via stb_truetype.ScaleForPixelHeight) scales so
// `ascent - descent` equals N pixels; runa scales so the *em-square*
// equals N pixels. For Inter (upem 2048, ascent 2169, descent -552)
// that's a 1.33× discrepancy — runa would render ~33% larger at the
// same numerical size. We rescale here so Skald apps see consistent
// glyph dimensions regardless of which backend drives.
//
// Conversion: runa_px = skald_px × upem / (ascent − descent).
// For multi-font runs the primary font's ratio is used; fallback
// glyphs (emoji) render at the primary's effective em-size, which is
// the typical behaviour across renderers.
@(private)
text_runa_px_size :: proc(fnt: ^runa.Font, skald_px: f32) -> f32 {
	if fnt == nil { return skald_px }
	extent := fnt.ascent - fnt.descent
	if extent <= 0 || fnt.units_per_em == 0 { return skald_px }
	return skald_px * f32(fnt.units_per_em) / extent
}

@(private)
measure_text_runa :: proc(
	r:    ^Renderer,
	text: string,
	size: f32,
	font: Font,
) -> (width, line_height: f32) {
	rs := r.text.runa_state
	if rs == nil { return }
	f := font == 0 ? r.text.default_font : font
	if int(f) < 0 || int(f) >= len(rs.fonts) { return }

	scale := r.scale
	if scale <= 0 { scale = 1 }

	stack := text_runa_stack(rs, f)
	px_size := text_runa_px_size(rs.fonts[int(f)], size * scale)
	opts  := runa.Paragraph_Opts{fonts = stack, size = px_size}
	w, h  := runa.measure_text_cached(text, opts, &rs.cache)
	return w / scale, h / scale
}

@(private)
text_ascent_runa :: proc(r: ^Renderer, size: f32, font: Font) -> f32 {
	rs := r.text.runa_state
	if rs == nil { return 0 }
	f := font == 0 ? r.text.default_font : font
	if int(f) < 0 || int(f) >= len(rs.fonts) { return 0 }

	scale := r.scale
	if scale <= 0 { scale = 1 }
	fnt := rs.fonts[int(f)]
	if fnt.units_per_em == 0 { return 0 }
	// Match fontstash convention: ascent_px = ascent × skald_size / (ascent − descent).
	extent := fnt.ascent - fnt.descent
	if extent <= 0 { return 0 }
	return fnt.ascent * (size * scale) / extent / scale
}

@(private)
draw_text_runa :: proc(
	r:     ^Renderer,
	text:  string,
	x, y:  f32,
	color: Color,
	size:  f32,
	font:  Font,
) {
	rs := r.text.runa_state
	if rs == nil { return }
	f := font == 0 ? r.text.default_font : font
	if int(f) < 0 || int(f) >= len(rs.fonts) { return }

	scale := r.scale
	if scale <= 0 { scale = 1 }
	inv := 1 / scale
	px_size := text_runa_px_size(rs.fonts[int(f)], size * scale)

	stack := text_runa_stack(rs, f)
	opts := runa.Paragraph_Opts{fonts = stack, size = px_size}

	// `runa.layout_paragraph` threads the cache through to
	// `shape_text_cached` when a non-nil ^Cache is passed (runa 0.2+),
	// so per-frame redraws of static text hit the shape cache and
	// avoid re-running GSUB / GPOS every call. The earlier custom
	// run-walker is no longer needed — the fix landed in runa proper.
	lines, err := runa.layout_paragraph(text, opts, &rs.cache, context.temp_allocator)
	if err != .None { return }

	pen_x := x * scale
	pen_y := y * scale

	for line in lines {
		for g in line.glyphs {
			text_runa_emit_glyph(rs, r, g.font, u16(g.glyph_id),
				g.x_advance, g.x_offset, g.y_advance, g.y_offset,
				px_size, inv, &pen_x, &pen_y, color)
		}
	}
}

@(private)
text_runa_emit_glyph :: proc(
	rs:        ^Text_Runa,
	r:         ^Renderer,
	fnt:       ^runa.Font,
	gid:       u16,
	x_advance, x_offset, y_advance, y_offset: f32,
	px_size, inv: f32,
	pen_x, pen_y: ^f32,
	color:     Color,
) {
	// Inlined version of the per-glyph push that used to live in the
	// draw_text_runa loop. Same subpixel-x bucket + pixel-snap fix.
	gx_phys := pen_x^ + x_offset
	frac_x  := gx_phys - math.floor(gx_phys)
	subpx   := u8(frac_x * 4)
	if subpx > 3 { subpx = 0 }

	slot, ok := text_runa_get_slot(rs, fnt, gid, px_size, subpx)
	if ok && slot.px_size.x > 0 && slot.px_size.y > 0 {
		bx := math.floor(pen_x^ + x_offset + slot.bearing.x)
		by := math.floor(pen_y^ + y_offset + slot.bearing.y)
		x0 := bx * inv
		y0 := by * inv
		x1 := (bx + f32(slot.px_size.x)) * inv
		y1 := (by + f32(slot.px_size.y)) * inv
		if slot.is_color {
			entry := text_runa_ensure_color_atlas(rs, r, int(slot.page_index))
			if entry != nil {
				batch_push_image(r, entry.dset,
					Rect{x0, y0, x1 - x0, y1 - y0},
					[4]f32{slot.uv_rect[0], slot.uv_rect[1], slot.uv_rect[2], slot.uv_rect[3]},
					Color{1, 1, 1, 1})
			}
		} else if slot.page_index == 0 {
			// Page 0 lands in the shared atlas image; the default text
			// descriptor already binds it, so the normal kind=1 push works.
			batch_push_glyph(r,
				x0, y0, x1, y1,
				slot.uv_rect[0], slot.uv_rect[1],
				slot.uv_rect[2], slot.uv_rect[3],
				color)
		} else {
			// Pages 1+ live on per-page images with their own descriptor
			// set; swap the binding for this quad via the paged variant.
			page := text_runa_ensure_alpha_page(rs, r, int(slot.page_index))
			if page != nil {
				batch_push_glyph_paged(r, page.dset,
					x0, y0, x1, y1,
					slot.uv_rect[0], slot.uv_rect[1],
					slot.uv_rect[2], slot.uv_rect[3],
					color)
			}
		}
	}
	pen_x^ += x_advance
	pen_y^ += y_advance
}

// text_runa_ensure_alpha_page lazily allocates the GPU image +
// descriptor set for runa's `pages_alpha[idx]` (for idx ≥ 1; page 0
// is mapped onto the shared `Text.atlas_image` and never reaches
// here). Called from both the upload-dirty path (to seed the GPU
// resources when a new page is first written to) and from
// `text_runa_emit_glyph` (to look up the descriptor set when a glyph
// references a non-zero page index). Returns nil on failure.
@(private)
text_runa_ensure_alpha_page :: proc(rs: ^Text_Runa, r: ^Renderer, idx: int) -> ^Runa_Alpha_Page {
	if idx <= 0 { return nil }
	// Skald-side pages are 1-indexed onto pages_alpha[1..]; we store
	// them densely in `alpha_pages[idx-1]` so a slot.page_index of 1
	// maps to alpha_pages[0]. Grow the dynamic array as needed.
	for len(rs.alpha_pages) < idx {
		append(&rs.alpha_pages, Runa_Alpha_Page{})
	}
	page := &rs.alpha_pages[idx - 1]
	if page.image != 0 { return page }

	if idx >= len(rs.atlas.pages_alpha) { return nil }
	src := &rs.atlas.pages_alpha[idx]
	if !text_runa_create_alpha_page(page, r, u32(src.width), u32(src.height)) {
		return nil
	}
	return page
}

@(private)
text_runa_create_alpha_page :: proc(page: ^Runa_Alpha_Page, r: ^Renderer, w, h: u32) -> bool {
	ii := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, imageType = .D2, format = .R8_UNORM,
		extent = {w, h, 1}, mipLevels = 1, arrayLayers = 1,
		samples = {._1}, tiling = .OPTIMAL,
		usage = {.TRANSFER_DST, .SAMPLED}, sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(r.device, &ii, nil, &page.image); res != .SUCCESS {
		fmt.eprintfln("skald: CreateImage (runa alpha page): %v", res); return false
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, page.image, &req)
	ai := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = req.size,
		memoryTypeIndex = vk_find_mem_type(r, req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	if res := vk.AllocateMemory(r.device, &ai, nil, &page.memory); res != .SUCCESS {
		fmt.eprintfln("skald: AllocateMemory (runa alpha page): %v", res); return false
	}
	vk.BindImageMemory(r.device, page.image, page.memory, 0)

	viw := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = page.image, viewType = .D2, format = .R8_UNORM,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if res := vk.CreateImageView(r.device, &viw, nil, &page.view); res != .SUCCESS {
		fmt.eprintfln("skald: CreateImageView (runa alpha page): %v", res); return false
	}

	// Descriptor set lives in the pipeline's pool, same layout as the
	// per-target text descriptor. One per page, shared across windows
	// — the pipeline binds it at the same slot as the default atlas
	// when this page's glyphs are drawn (via a Batch_Range swap).
	da := vk.DescriptorSetAllocateInfo{
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = r.pipeline.dset_pool,
		descriptorSetCount = 1,
		pSetLayouts = &r.pipeline.dset_layout,
	}
	if res := vk.AllocateDescriptorSets(r.device, &da, &page.dset); res != .SUCCESS {
		fmt.eprintfln("skald: AllocateDescriptorSets (runa alpha page): %v", res); return false
	}
	di := vk.DescriptorImageInfo{
		sampler = r.pipeline.sampler, imageView = page.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	w_desc := vk.WriteDescriptorSet{
		sType = .WRITE_DESCRIPTOR_SET, dstSet = page.dset,
		dstBinding = 0, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER,
		pImageInfo = &di,
	}
	vk.UpdateDescriptorSets(r.device, 1, &w_desc, 0, nil)

	page.w = w
	page.h = h
	return true
}

// text_upload_region_to uploads a dirty `w × h` region of the runa
// CPU-side alpha page into the matching Skald GPU image. Mirror of
// `text_upload_region_from`'s underlying `vk_upload_r8_region` but
// targeted at one of the per-page images.
@(private)
text_upload_region_to :: proc(r: ^Renderer, page: ^Runa_Alpha_Page, x, y, w, h: int, src: []u8, src_stride: int) {
	if page.image == 0 { return }
	vk_upload_r8_region(r, page.image, x, y, w, h, src, src_stride)
}

@(private)
text_runa_destroy_alpha_page :: proc(page: ^Runa_Alpha_Page, r: ^Renderer) {
	if page.dset   != 0 { vk.FreeDescriptorSets(r.device, r.pipeline.dset_pool, 1, &page.dset); page.dset = 0 }
	if page.view   != 0 { vk.DestroyImageView(r.device, page.view, nil); page.view = 0 }
	if page.image  != 0 { vk.DestroyImage(r.device, page.image, nil); page.image = 0 }
	if page.memory != 0 { vk.FreeMemory(r.device, page.memory, nil); page.memory = 0 }
}

// text_runa_ensure_color_atlas lazily registers colour atlas page
// `idx` with the image cache and returns its entry. Called from
// `text_runa_emit_glyph` for each colour glyph — this has to happen
// during view (not at frame_end) so the entry's descriptor set is
// available for the same frame's render pass. Returns nil on
// registration failure (that page's colour glyphs render as nothing).
@(private)
text_runa_ensure_color_atlas :: proc(rs: ^Text_Runa, r: ^Renderer, idx: int) -> ^Image_Entry {
	key := text_runa_color_key(idx)
	if idx < len(rs.color_atlas_registered) && rs.color_atlas_registered[idx] {
		return image_cache_get(r, key)
	}
	if idx >= len(rs.atlas.pages_color) { return nil }
	page := &rs.atlas.pages_color[idx]
	if !image_load_pixels(r, key, u32(page.width), u32(page.height), page.pixels) {
		return nil
	}
	// Grow the registration-flag array as needed and mark this page seeded.
	for len(rs.color_atlas_registered) <= idx {
		append(&rs.color_atlas_registered, false)
	}
	rs.color_atlas_registered[idx] = true
	// Initial upload covered the current state; clear the dirty flag
	// so `text_upload_dirty_runa` doesn't re-upload the same bytes at
	// frame_end. Subsequent dirty rects (later frames) flow through
	// `image_update_pixels` normally.
	page.is_dirty  = false
	page.dirty_min = {}
	page.dirty_max = {}
	return image_cache_get(r, key)
}

// text_runa_get_slot is the raster-cache lookup. On miss it rasterises
// + atlas-packs the glyph (mono path) and stores the result. Colour
// glyphs are rastered too but flagged `is_color`; draw_text_runa
// currently skips them — Phase 1b wires the RGBA atlas + shader.
@(private)
text_runa_get_slot :: proc(
	rs:       ^Text_Runa,
	font:     ^runa.Font,
	gid:      u16,
	px_size:  f32,
	subpx:   u8,
) -> (slot: runa.Atlas_Slot, ok: bool) {
	key := Glyph_Key{font = font, gid = gid, size_q = u32(px_size * 4), subpx = subpx}
	if existing, hit := rs.glyph_cache[key]; hit { return existing, true }

	s, err := runa.raster_glyph(font, gid, px_size, subpx, &rs.atlas)
	if err != .None { return }
	rs.glyph_cache[key] = s
	return s, true
}
