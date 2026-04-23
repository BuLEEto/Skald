package skald

import "core:fmt"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

// INTER_VARIABLE is the default UI font — Inter Variable by Rasmus Andersson,
// OFL-1.1 licensed. It's baked into the binary via #load so apps have usable
// text rendering out of the box without shipping assets.
@(private)
INTER_VARIABLE :: #load("assets/InterVariable.ttf", []byte)

// ATLAS_SIZE is the initial glyph atlas edge length in pixels. Chosen large
// enough that typical desktop UIs (a handful of sizes across Latin) never
// trigger an in-frame expansion — which would invalidate the UVs of glyphs
// already recorded in the current batch. If callers use a lot of sizes or
// non-Latin scripts the atlas will expand between frames via fontstash's
// resize callback; we rebuild the GPU image on the next frame.
@(private)
ATLAS_SIZE :: 1024

// Font is an opaque handle to a loaded typeface. Obtain one via `font_load`
// or use the default handle returned from `font_default`.
Font :: distinct int

// Text owns the fontstash context and the GPU-side R8_UNORM glyph atlas.
// One instance lives inside the Renderer. The sampler is owned by
// Pipeline (shared across the atlas and every cached image); Text just
// carries the image and view.
@(private)
Text :: struct {
	fs:           fs.FontContext,
	default_font: Font,

	atlas_image:  vk.Image,
	atlas_mem:    vk.DeviceMemory,
	atlas_view:   vk.ImageView,
	atlas_w:      u32,
	atlas_h:      u32,

	// Set by fontstash callbacks when the CPU-side atlas has changed.
	// frame_end checks these before submitting draws and uploads fresh
	// pixels (or rebuilds the GPU image entirely) as needed.
	needs_rebuild: bool, // atlas was resized → recreate GPU image
	dirty_rect:    [4]f32,
	has_dirty:     bool,
}

@(private)
text_init :: proc(t: ^Text, r: ^Renderer) -> (ok: bool) {
	fs.Init(&t.fs, ATLAS_SIZE, ATLAS_SIZE, .TOPLEFT)
	t.fs.userData       = t
	t.fs.callbackResize = text_on_resize
	t.fs.callbackUpdate = text_on_update

	t.atlas_w = ATLAS_SIZE
	t.atlas_h = ATLAS_SIZE
	if !text_create_gpu_image(t, r) { return }

	t.default_font = Font(fs.AddFontMem(&t.fs, "inter", INTER_VARIABLE, false))
	if int(t.default_font) < 0 {
		fmt.eprintln("skald: failed to load embedded Inter font")
		return
	}

	// Upload a fully-blank atlas once so the image layout is
	// SHADER_READ_ONLY before the first frame. Without this, sampling
	// the atlas before any glyph is rasterized would hit an UNDEFINED
	// image.
	text_upload_region(t, r, 0, 0, int(t.atlas_w), int(t.atlas_h))

	ok = true
	return
}

@(private)
text_destroy :: proc(t: ^Text, r: ^Renderer) {
	text_destroy_gpu_image(t, r)
	fs.Destroy(&t.fs)
}

@(private)
text_create_gpu_image :: proc(t: ^Text, r: ^Renderer) -> bool {
	text_destroy_gpu_image(t, r)

	ii := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, imageType = .D2, format = .R8_UNORM,
		extent = {t.atlas_w, t.atlas_h, 1}, mipLevels = 1, arrayLayers = 1,
		samples = {._1}, tiling = .OPTIMAL,
		usage = {.TRANSFER_DST, .SAMPLED}, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(r.device, &ii, nil, &t.atlas_image); res != .SUCCESS {
		fmt.eprintfln("skald: CreateImage (atlas): %v", res); return false
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, t.atlas_image, &req)
	ai := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = req.size,
		memoryTypeIndex = vk_find_mem_type(r, req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	if res := vk.AllocateMemory(r.device, &ai, nil, &t.atlas_mem); res != .SUCCESS {
		fmt.eprintfln("skald: AllocateMemory (atlas): %v", res); return false
	}
	vk.BindImageMemory(r.device, t.atlas_image, t.atlas_mem, 0)

	viw := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = t.atlas_image, viewType = .D2, format = .R8_UNORM,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if res := vk.CreateImageView(r.device, &viw, nil, &t.atlas_view); res != .SUCCESS {
		fmt.eprintfln("skald: CreateImageView (atlas): %v", res); return false
	}
	return true
}

@(private)
text_destroy_gpu_image :: proc(t: ^Text, r: ^Renderer) {
	if t.atlas_view  != 0 { vk.DestroyImageView(r.device, t.atlas_view, nil); t.atlas_view  = 0 }
	if t.atlas_image != 0 { vk.DestroyImage(r.device, t.atlas_image, nil);    t.atlas_image = 0 }
	if t.atlas_mem   != 0 { vk.FreeMemory(r.device, t.atlas_mem, nil);        t.atlas_mem   = 0 }
}

// text_upload_dirty is called once per frame from frame_end. If the
// CPU-side atlas grew, the GPU image is recreated and the whole thing
// is uploaded. Otherwise only the dirty sub-region is uploaded. No-op
// on a clean frame. Returns true when the image was recreated — the
// caller must call pipeline_rebuild_descriptor to rebind the new view.
@(private)
text_upload_dirty :: proc(t: ^Text, r: ^Renderer) -> (rebuilt: bool) {
	if t.needs_rebuild {
		t.atlas_w = u32(t.fs.width)
		t.atlas_h = u32(t.fs.height)
		if !text_create_gpu_image(t, r) { return }
		text_upload_region(t, r, 0, 0, int(t.atlas_w), int(t.atlas_h))
		t.needs_rebuild = false
		t.has_dirty     = false
		rebuilt = true
		return
	}

	// fs.ValidateTexture drains the fontstash dirty rect; we also track
	// one ourselves via the update callback in case the user drove
	// validation.
	dr: [4]f32
	if fs.ValidateTexture(&t.fs, &dr) {
		text_mark_dirty(t, dr)
	}
	if t.has_dirty {
		x := int(t.dirty_rect[0])
		y := int(t.dirty_rect[1])
		w := int(t.dirty_rect[2]) - x
		h := int(t.dirty_rect[3]) - y
		if w > 0 && h > 0 {
			text_upload_region(t, r, x, y, w, h)
		}
		t.has_dirty = false
	}
	return
}

// text_upload_region stages `w × h` bytes from the CPU-side atlas at
// (x, y) into the GPU image's matching region. One-shot submit —
// atlas updates are rare enough that we don't need to pipeline them
// into the main frame command buffer.
@(private)
text_upload_region :: proc(t: ^Text, r: ^Renderer, x, y, w, h: int) {
	bytes := vk.DeviceSize(w * h)
	stg_buf, stg_mem := vk_make_buffer(r, bytes, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	defer {
		vk.DestroyBuffer(r.device, stg_buf, nil)
		vk.FreeMemory(r.device, stg_mem, nil)
	}

	ptr: rawptr
	vk.MapMemory(r.device, stg_mem, 0, bytes, {}, &ptr)
	// Pack row-by-row from the fontstash atlas (whose stride is atlas_w)
	// into a tight `w`-wide staging buffer so CmdCopyBufferToImage doesn't
	// need a bufferRowLength hint.
	stride := int(t.atlas_w)
	dst := cast([^]u8)ptr
	for row in 0..<h {
		src_off := (y + row) * stride + x
		dst_off := row * w
		src := t.fs.textureData[src_off : src_off + w]
		for col in 0..<w { dst[dst_off + col] = src[col] }
	}
	vk.UnmapMemory(r.device, stg_mem)

	range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	cb := vk_begin_one_shot(r); defer vk_end_one_shot(r, cb)

	// UNDEFINED as the old layout is safe whether this is the first
	// upload (image just created) or a subsequent one — Vulkan treats
	// UNDEFINED as "contents may be discarded", which is what we want.
	vk_image_barrier(cb, t.atlas_image, range,
		{}, {.TRANSFER_WRITE},
		.UNDEFINED, .TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE}, {.TRANSFER})

	region := vk.BufferImageCopy{
		bufferOffset = 0,
		bufferRowLength = 0, bufferImageHeight = 0,
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageOffset = {i32(x), i32(y), 0},
		imageExtent = {u32(w), u32(h), 1},
	}
	vk.CmdCopyBufferToImage(cb, stg_buf, t.atlas_image, .TRANSFER_DST_OPTIMAL, 1, &region)

	vk_image_barrier(cb, t.atlas_image, range,
		{.TRANSFER_WRITE}, {.SHADER_READ},
		.TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER}, {.FRAGMENT_SHADER})
}

@(private)
text_mark_dirty :: proc(t: ^Text, rect: [4]f32) {
	if !t.has_dirty {
		t.dirty_rect = rect
		t.has_dirty  = true
		return
	}
	t.dirty_rect[0] = min(t.dirty_rect[0], rect[0])
	t.dirty_rect[1] = min(t.dirty_rect[1], rect[1])
	t.dirty_rect[2] = max(t.dirty_rect[2], rect[2])
	t.dirty_rect[3] = max(t.dirty_rect[3], rect[3])
}

@(private)
text_on_resize :: proc(data: rawptr, w, h: int) {
	t := cast(^Text)data
	t.needs_rebuild = true
}

@(private)
text_on_update :: proc(data: rawptr, dirty: [4]f32, _: rawptr) {
	t := cast(^Text)data
	text_mark_dirty(t, dirty)
}

// ---- public text API ----

// font_default returns the handle of the embedded Inter Variable font. It is
// always loaded and is the default for `draw_text`.
font_default :: proc(r: ^Renderer) -> Font {
	return r.text.default_font
}

// font_load registers a TTF/OTF font from memory. The bytes are borrowed —
// callers must keep the slice alive for the lifetime of the renderer.
font_load :: proc(r: ^Renderer, name: string, data: []byte) -> Font {
	return Font(fs.AddFontMem(&r.text.fs, name, data, false))
}

// font_add_fallback chains `fallback` to `base` so codepoints missing
// from `base` (e.g. CJK / Arabic / Devanagari glyphs absent from the
// bundled Inter) are looked up in `fallback` next. Use the default
// font as `base` to extend the framework-wide glyph coverage, or
// chain multiple fallbacks in priority order:
//
//     cjk := skald.font_load(r, "noto-cjk", noto_cjk_ttf)
//     ara := skald.font_load(r, "noto-ar",  noto_ar_ttf)
//     skald.font_add_fallback(r, skald.font_default(r), cjk)
//     skald.font_add_fallback(r, skald.font_default(r), ara)
//
// The first fallback that contains a codepoint wins. Up to
// `MAX_FALLBACKS` (20 per fontstash) can be chained per base font.
// Skald ships only with Inter (Latin + Cyrillic); apps targeting
// other scripts bundle the TTFs they need and register them here.
font_add_fallback :: proc(r: ^Renderer, base, fallback: Font) -> bool {
	return fs.AddFallbackFont(&r.text.fs, int(base), int(fallback))
}

// draw_text queues a string for rendering this frame. `x, y` is the baseline
// origin in *logical* pixels; `size` is the cap height in logical pixels
// (roughly the number on CSS font-size sliders). Color must be linear —
// use `rgb` / `rgba` to convert from sRGB hex.
//
// DPI handling: glyphs are rasterized at `size × r.scale` so a physical
// pixel in the atlas lines up 1:1 with a physical pixel on screen, keeping
// text crisp at any OS scaling factor. The emitted quads stay in logical
// coordinates so the rest of the renderer can stay DPI-oblivious.
draw_text :: proc(
	r:     ^Renderer,
	text:  string,
	x, y:  f32,
	color: Color,
	size:  f32 = 14,
	font:  Font = 0,
) {
	f := font == 0 ? r.text.default_font : font
	scale := r.scale
	if scale <= 0 { scale = 1 }
	inv := 1 / scale

	fs.BeginState(&r.text.fs)
	defer fs.EndState(&r.text.fs)
	fs.SetFont(&r.text.fs, int(f))
	fs.SetSize(&r.text.fs, size * scale)
	fs.SetAlignHorizontal(&r.text.fs, .LEFT)
	fs.SetAlignVertical(&r.text.fs, .BASELINE)

	iter := fs.TextIterInit(&r.text.fs, x * scale, y * scale, text)
	q: fs.Quad
	for fs.TextIterNext(&r.text.fs, &iter, &q) {
		batch_push_glyph(r,
			q.x0 * inv, q.y0 * inv, q.x1 * inv, q.y1 * inv,
			q.s0, q.t0, q.s1, q.t1, color)
	}
}

// text_ascent returns the font's ascent (distance from baseline up to the
// top of the cap) at the given size. The layout code uses it to convert a
// top-left anchored View_Text origin into the baseline y that `draw_text`
// expects.
text_ascent :: proc(r: ^Renderer, size: f32, font: Font = 0) -> f32 {
	f := font == 0 ? r.text.default_font : font
	scale := r.scale
	if scale <= 0 { scale = 1 }
	fs.BeginState(&r.text.fs)
	defer fs.EndState(&r.text.fs)
	fs.SetFont(&r.text.fs, int(f))
	fs.SetSize(&r.text.fs, size * scale)
	ascent, _, _ := fs.VerticalMetrics(&r.text.fs)
	return ascent / scale
}

// measure_text returns the advance width and line height of the string at
// the given size. Useful for layout code that needs to size a label before
// rendering.
measure_text :: proc(
	r:    ^Renderer,
	text: string,
	size: f32 = 14,
	font: Font = 0,
) -> (width, line_height: f32) {
	f := font == 0 ? r.text.default_font : font
	scale := r.scale
	if scale <= 0 { scale = 1 }
	inv := 1 / scale

	fs.BeginState(&r.text.fs)
	defer fs.EndState(&r.text.fs)
	fs.SetFont(&r.text.fs, int(f))
	fs.SetSize(&r.text.fs, size * scale)
	fs.SetAlignHorizontal(&r.text.fs, .LEFT)
	fs.SetAlignVertical(&r.text.fs, .BASELINE)

	width = fs.TextBounds(&r.text.fs, text, 0, 0, nil) * inv
	_, _, lh := fs.VerticalMetrics(&r.text.fs)
	line_height = lh * inv
	return
}

// byte_index_at_x returns the byte index in `text` whose horizontal
// position is closest to `x` measured in pixels from the left edge of the
// string. Used by text_input to translate a mouse click in the content
// region into a caret position.
//
// The search walks rune-by-rune, measuring the prefix up to each boundary.
// That's O(n²) in string length — fine for single-line UI fields where n
// is small. If we ever host a prose editor this will want per-glyph advances
// pulled from the fontstash state instead.
byte_index_at_x :: proc(
	r:    ^Renderer,
	text: string,
	size: f32  = 14,
	font: Font = 0,
	x:    f32,
) -> int {
	if x <= 0 || len(text) == 0 { return 0 }
	// Measurements are cheap against fontstash's cache but still atlas-
	// bound, so bail once we pass the target x.
	prev_w: f32 = 0
	prev_i: int = 0
	i := 0
	for i < len(text) {
		step := utf8_step(text, i)
		next_i := i + step
		w, _ := measure_text(r, text[:next_i], size, font)
		if w >= x {
			// Pick the boundary closer to x (mid-glyph decides by nearest edge).
			if x - prev_w < w - x { return prev_i }
			return next_i
		}
		prev_w = w
		prev_i = next_i
		i      = next_i
	}
	return len(text)
}

@(private)
utf8_step :: proc(s: string, i: int) -> int {
	if i >= len(s) { return 0 }
	b := s[i]
	switch {
	case b < 0x80:    return 1
	case b < 0xC0:    return 1 // invalid continuation; advance one anyway
	case b < 0xE0:    return 2
	case b < 0xF0:    return 3
	}
	return 4
}

// wrap_text breaks `text` into lines so no line's measured width exceeds
// `max_width`. The break algorithm is word-boundary (single spaces),
// matching what a typical desktop paragraph engine does for UI copy.
// Words longer than `max_width` get placed on their own line and overflow
// — this isn't a typesetter, it's a UI label, and hyphenation is not worth
// the complexity for the common case.
//
// Existing newlines in `text` force a break. Returned slice and its
// backing strings all live in context.temp_allocator — valid for the rest
// of the frame, not across frames.
wrap_text :: proc(
	r:         ^Renderer,
	text:      string,
	max_width: f32,
	size:      f32  = 14,
	font:      Font = 0,
) -> []string {
	if max_width <= 0 || len(text) == 0 {
		out := make([]string, 1, context.temp_allocator)
		out[0] = text
		return out
	}

	f := font == 0 ? r.text.default_font : font
	scale := r.scale
	if scale <= 0 { scale = 1 }
	// wrap_text measures candidate lines against `max_width` (logical). To
	// avoid a per-measure divide we scale the threshold up once instead of
	// dividing every TextBounds result down.
	max_width_px := max_width * scale

	fs.BeginState(&r.text.fs)
	defer fs.EndState(&r.text.fs)
	fs.SetFont(&r.text.fs, int(f))
	fs.SetSize(&r.text.fs, size * scale)
	fs.SetAlignHorizontal(&r.text.fs, .LEFT)
	fs.SetAlignVertical(&r.text.fs, .BASELINE)

	lines: [dynamic]string
	lines.allocator = context.temp_allocator

	// Walk the source one hard-break paragraph at a time so embedded \n
	// in the input still force a line break in the output.
	line_start := 0
	i := 0
	for i <= len(text) {
		hard_break := i == len(text) || text[i] == '\n'
		if !hard_break { i += 1; continue }

		para := text[line_start:i]
		// Word-wrap this paragraph.
		cursor := 0
		for cursor < len(para) {
			// Skip any leading spaces at the line start — callers
			// rarely want a line that begins with whitespace.
			for cursor < len(para) && para[cursor] == ' ' { cursor += 1 }
			if cursor >= len(para) { break }

			// Greedy word packing: extend the line as long as
			// including the next word keeps width ≤ max_width.
			line_begin := cursor
			last_fit_end := cursor
			for cursor < len(para) {
				word_end := cursor
				for word_end < len(para) && para[word_end] != ' ' {
					word_end += 1
				}
				candidate := para[line_begin:word_end]
				w := fs.TextBounds(&r.text.fs, candidate, 0, 0, nil)
				if w <= max_width_px || line_begin == cursor {
					// Either it fits, or it's the first word on the
					// line (overflow is unavoidable for that single
					// word — emit it anyway so we make forward
					// progress instead of looping).
					last_fit_end = word_end
					cursor = word_end
					// Consume a single trailing space for the next
					// word's leading gap.
					if cursor < len(para) && para[cursor] == ' ' { cursor += 1 }
				} else {
					break
				}
			}
			append(&lines, para[line_begin:last_fit_end])
		}
		// Preserve empty paragraphs from consecutive newlines so vertical
		// spacing in the source survives.
		if len(para) == 0 && hard_break && i < len(text) {
			append(&lines, "")
		}

		if i < len(text) {
			i += 1 // skip the \n
			line_start = i
		} else {
			break
		}
	}

	if len(lines) == 0 {
		append(&lines, "")
	}
	return lines[:]
}
