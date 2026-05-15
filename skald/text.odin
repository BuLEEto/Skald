package skald

import "core:fmt"
import "core:strings"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

// INTER_VARIABLE is the default UI font — Inter Variable by Rasmus Andersson,
// OFL-1.1 licensed. It's baked into the binary via #load so apps have usable
// text rendering out of the box without shipping assets.
@(private)
INTER_VARIABLE :: #load("assets/InterVariable.ttf", []byte)

// INTER_BOLD / INTER_ITALIC / INTER_BOLD_ITALIC are static-weight Inter
// faces baked into the binary alongside the variable file. Same OFL-1.1
// licence (see assets/InterVariable-OFL.txt). fontstash can't drive
// OpenType variation axes, so the only way to render proper bold and
// italic is separate font handles — these power `rich_text`'s emphasis
// spans (per-span `weight = .Bold` and `italic = true`) without
// requiring apps to ship their own copies.
@(private)
INTER_BOLD :: #load("assets/Inter-Bold.ttf", []byte)
@(private)
INTER_ITALIC :: #load("assets/Inter-Italic.ttf", []byte)
@(private)
INTER_BOLD_ITALIC :: #load("assets/Inter-BoldItalic.ttf", []byte)

// TWEMOJI_MOZILLA is the bundled colour-emoji font — Twitter / Twemoji
// artwork built into a COLRv0 layered TTF by Mozilla, CC-BY-4.0
// (artwork) + Apache-2.0 (tooling). See assets/Twemoji-Mozilla-CCBY.txt
// for the full attribution. Loaded on demand by `font_use_default_emoji`;
// the bytes are embedded in every Skald binary either way thanks to
// `#load`-at-compile-time semantics, but apps that don't call the
// helper never register the font and pay zero runtime cost.
@(private)
TWEMOJI_MOZILLA :: #load("assets/Twemoji-Mozilla.ttf", []byte)

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
//
// `runa_state` is the dispatch flag for the experimental pure-Odin
// runa text engine: nil → fontstash drives everything (the path that
// has shipped since 1.0); non-nil → runa drives. Currently always nil
// (Phase 1a stubs); set non-nil once the runa wiring lands so the
// public APIs route to the new code path.
@(private)
Text :: struct {
	fs:           fs.FontContext,
	default_font: Font,
	// Inter static-weight handles for rich_text's emphasis spans.
	// Registered alongside `default_font` in `text_init`; loading them
	// is one-shot metadata work — the glyphs themselves are only
	// rasterised into the atlas the first time a span requests them.
	bold_font:        Font,
	italic_font:      Font,
	bold_italic_font: Font,

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

	// Optional runa-backed state. nil → fontstash backend; non-nil →
	// public APIs route to the runa equivalents in text_runa.odin.
	runa_state: ^Text_Runa,

	// Cached handle for `font_use_default_emoji`. Zero (i.e. invalid)
	// until the first call; subsequent calls return the same Font so
	// apps can sprinkle the helper liberally without re-loading the
	// 1.4 MB Twemoji bytes or appending duplicate font entries.
	default_emoji_font:        Font,
	default_emoji_font_loaded: bool,
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

	// Register the static emphasis weights. AddFontMem only parses the
	// font tables — no atlas pages allocated yet — so this is cheap.
	// Glyphs only enter the atlas the first time a renderer call asks
	// for them, so apps that never use rich_text's emphasis pay
	// ~nothing for these beyond the binary size.
	t.bold_font = Font(fs.AddFontMem(&t.fs, "inter-bold", INTER_BOLD, false))
	if int(t.bold_font) < 0 {
		fmt.eprintln("skald: failed to load embedded Inter Bold")
		return
	}
	t.italic_font = Font(fs.AddFontMem(&t.fs, "inter-italic", INTER_ITALIC, false))
	if int(t.italic_font) < 0 {
		fmt.eprintln("skald: failed to load embedded Inter Italic")
		return
	}
	t.bold_italic_font = Font(fs.AddFontMem(&t.fs, "inter-bold-italic", INTER_BOLD_ITALIC, false))
	if int(t.bold_italic_font) < 0 {
		fmt.eprintln("skald: failed to load embedded Inter Bold Italic")
		return
	}

	// Upload a fully-blank atlas once so the image layout is
	// SHADER_READ_ONLY before the first frame. Without this, sampling
	// the atlas before any glyph is rasterized would hit an UNDEFINED
	// image.
	text_upload_region(t, r, 0, 0, int(t.atlas_w), int(t.atlas_h))

	// Bring up the runa backend (the default since 1.0). `text_init_runa`
	// attempts to initialise the pure-Odin text engine; on success it
	// allocates the Text_Runa state and assigns it to t.runa_state,
	// flipping every public API to the runa path. On failure we keep
	// fontstash so the app stays running. Build with
	// `-define:SKALD_RUNA=false` to skip this and stay on fontstash.
	when RUNA_BACKEND_DEFAULT {
		if !text_init_runa(t, r) {
			fmt.eprintln("skald: runa init failed; falling back to fontstash")
		}
	}

	ok = true
	return
}

@(private)
text_destroy :: proc(t: ^Text, r: ^Renderer) {
	if t.runa_state != nil {
		text_destroy_runa(t, r)
	}
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
	if t.runa_state != nil {
		return text_upload_dirty_runa(t, r)
	}
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
	text_upload_region_from(t, r, x, y, w, h, t.fs.textureData, int(t.atlas_w))
}

// text_upload_region_from is the backend-agnostic uploader for the
// *shared* R8 atlas image (`Text.atlas_image`). `src` is the
// CPU-side R8 atlas; `src_stride` is its row pitch in bytes. Used by
// both fontstash (via text_upload_region) and runa page 0 (via
// text_upload_dirty_runa). Pages 1+ go via `text_upload_region_to`.
@(private)
text_upload_region_from :: proc(t: ^Text, r: ^Renderer, x, y, w, h: int, src: []u8, src_stride: int) {
	vk_upload_r8_region(r, t.atlas_image, x, y, w, h, src, src_stride)
}

// vk_upload_r8_region copies a `w × h` R8 byte region from `src`
// (at the given source stride) into `image` at offset `(x, y)`.
// One-shot submit — atlas updates are rare enough that we don't need
// to pipeline them into the main frame command buffer.
@(private)
vk_upload_r8_region :: proc(r: ^Renderer, image: vk.Image, x, y, w, h: int, src: []u8, src_stride: int) {
	bytes := vk.DeviceSize(w * h)
	stg_buf, stg_mem := vk_make_buffer(r, bytes, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	defer {
		vk.DestroyBuffer(r.device, stg_buf, nil)
		vk.FreeMemory(r.device, stg_mem, nil)
	}

	ptr: rawptr
	vk.MapMemory(r.device, stg_mem, 0, bytes, {}, &ptr)
	// Pack row-by-row from the source atlas (whose stride is src_stride)
	// into a tight `w`-wide staging buffer so CmdCopyBufferToImage doesn't
	// need a bufferRowLength hint.
	dst := cast([^]u8)ptr
	for row in 0..<h {
		src_off := (y + row) * src_stride + x
		dst_off := row * w
		row_src := src[src_off : src_off + w]
		for col in 0..<w { dst[dst_off + col] = row_src[col] }
	}
	vk.UnmapMemory(r.device, stg_mem)

	range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	cb := vk_begin_one_shot(r); defer vk_end_one_shot(r, cb)

	// UNDEFINED as the old layout is safe whether this is the first
	// upload (image just created) or a subsequent one — Vulkan treats
	// UNDEFINED as "contents may be discarded", which is what we want.
	vk_image_barrier(cb, image, range,
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
	vk.CmdCopyBufferToImage(cb, stg_buf, image, .TRANSFER_DST_OPTIMAL, 1, &region)

	vk_image_barrier(cb, image, range,
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

// font_bold / font_italic / font_bold_italic return the handles of the
// embedded Inter static weights — what `rich_text` selects internally
// when a span has `weight = .Bold` and/or `italic = true`. Apps that
// want to use these weights outside rich_text (e.g. a header in a
// bespoke layout) can pass the handle directly to `text(...)` /
// `draw_text(...)` like any other font.
font_bold :: proc(r: ^Renderer) -> Font {
	return r.text.bold_font
}
font_italic :: proc(r: ^Renderer) -> Font {
	return r.text.italic_font
}
font_bold_italic :: proc(r: ^Renderer) -> Font {
	return r.text.bold_italic_font
}

// font_load registers a TTF/OTF font from memory. The bytes are borrowed —
// callers must keep the slice alive for the lifetime of the renderer.
font_load :: proc(r: ^Renderer, name: string, data: []byte) -> Font {
	if r.text.runa_state != nil {
		return font_load_runa(r, name, data)
	}
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
	if r.text.runa_state != nil {
		return font_add_fallback_runa(r, base, fallback)
	}
	return fs.AddFallbackFont(&r.text.fs, int(base), int(fallback))
}

// font_use_default_emoji registers Skald's bundled Twemoji-Mozilla
// (COLRv0 colour-emoji TTF) as a fallback to the default Inter font
// and returns its handle. Idempotent — calling more than once
// returns the existing handle without re-registering.
//
// Why this is opt-in rather than automatic: every text widget paying
// the fallback-lookup cost for codepoints it never renders has a
// real cost (one extra cmap lookup per missing-from-Inter character
// per shape). Apps that don't show emoji avoid it by not calling.
//
// Backend support: under runa (the default backend) the glyphs render
// as full COLRv0 colour via the RGBA atlas — what you'd expect from
// "colour emoji". The legacy fontstash backend (opted into with
// `-define:SKALD_RUNA=false`) doesn't decode COLR / CBDT / sbix at
// all, so emoji fall through to fontstash's missing-glyph tofu; this helper is
// effectively a no-op there. Becomes useful by default in 1.1 when
// runa is the default backend.
//
//     fnt := skald.font_use_default_emoji(ctx.renderer)
//     // Now any text() / button() / text_input() etc. picks up
//     // emoji glyphs (under runa) — no other code changes.
//
// Bundled artwork is Twemoji, CC-BY-4.0. Apps shipping a Skald
// binary are redistributing the artwork; an attribution line in
// the app's About / docs satisfies the licence requirement. See
// `skald/assets/Twemoji-Mozilla-CCBY.txt` for the full notice.
font_use_default_emoji :: proc(r: ^Renderer) -> Font {
	if r.text.default_emoji_font_loaded {
		return r.text.default_emoji_font
	}
	fnt := font_load(r, "twemoji", TWEMOJI_MOZILLA)
	r.text.default_emoji_font_loaded = true
	r.text.default_emoji_font        = fnt
	if int(fnt) >= 0 {
		font_add_fallback(r, font_default(r), fnt)
	}
	return fnt
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
	if r.text.runa_state != nil {
		draw_text_runa(r, text, x, y, color, size, font)
		return
	}
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
	if r.text.runa_state != nil {
		return text_ascent_runa(r, size, font)
	}
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
	if r.text.runa_state != nil {
		return measure_text_runa(r, text, size, font)
	}
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

// split_lines splits `s` on cross-platform line breaks. Handles `\r\n`
// (Windows), bare `\r` (classic Mac), and `\n` (Unix). Returned slice
// and its backing string-views all live in context.temp_allocator —
// valid for the rest of the frame, not across frames. An empty input
// returns a single empty line. Convention matches `wrap_text`: a
// trailing newline does NOT produce a trailing empty line (rendering
// "a\n" as one row of "a" matches what most UI text engines do).
split_lines :: proc(s: string) -> []string {
	lines: [dynamic]string
	lines.allocator = context.temp_allocator

	if len(s) == 0 {
		append(&lines, "")
		return lines[:]
	}

	line_start := 0
	i := 0
	for i < len(s) {
		ch := s[i]
		if ch == '\n' {
			append(&lines, s[line_start:i])
			i += 1
			line_start = i
		} else if ch == '\r' {
			append(&lines, s[line_start:i])
			i += 1
			// Swallow the \n of a \r\n pair so the empty line between
			// them isn't double-counted.
			if i < len(s) && s[i] == '\n' { i += 1 }
			line_start = i
		} else {
			i += 1
		}
	}
	if line_start < len(s) {
		append(&lines, s[line_start:])
	}
	if len(lines) == 0 {
		append(&lines, "")
	}
	return lines[:]
}

// Visible width of a `\t` character, in space-widths of the current
// font. Hardcoded for v1; matches common editor defaults. Can become a
// per-call argument later if anyone needs 2 or 8.
TAB_WIDTH :: 4

// expand_tabs replaces each `\t` in `s` with `TAB_WIDTH` spaces and
// returns the result. Returns the input unchanged (no allocation) if
// `s` contains no tabs — the overwhelming common case for label /
// paragraph text. Allocates into context.temp_allocator when expansion
// is needed, so the returned string is valid for the rest of the
// frame.
//
// Used by `text()` (via wrap_text and the no-wrap render path) so a
// tab in user-supplied content renders as a visible run of whitespace
// instead of fontstash's missing-glyph tofu. For monospace code the
// visual lands at the standard 4-column indent; for proportional text
// the tab is roughly 4 space-widths wide. This is the simple model —
// no column-aligned tab stops, no per-paragraph reset. App code that
// needs editor-grade tab handling can pre-process its strings.
expand_tabs :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\t') { return s }
	sb := strings.builder_make(context.temp_allocator)
	strings.builder_grow(&sb, len(s) + TAB_WIDTH)
	for i in 0..<len(s) {
		if s[i] == '\t' {
			for _ in 0..<TAB_WIDTH { strings.write_byte(&sb, ' ') }
		} else {
			strings.write_byte(&sb, s[i])
		}
	}
	return strings.to_string(sb)
}

// wrap_text breaks `text` into lines so no line's measured width exceeds
// `max_width`. The break algorithm is word-boundary (single spaces),
// matching what a typical desktop paragraph engine does for UI copy.
// Words longer than `max_width` get placed on their own line and overflow
// — this isn't a typesetter, it's a UI label, and hyphenation is not worth
// the complexity for the common case.
//
// Existing newlines in `text` (any of `\n`, `\r\n`, `\r`) force a break.
// Returned slice and its backing strings all live in context.temp_allocator
// — valid for the rest of the frame, not across frames.
wrap_text :: proc(
	r:         ^Renderer,
	text:      string,
	max_width: f32,
	size:      f32  = 14,
	font:      Font = 0,
) -> []string {
	if max_width <= 0 {
		// No-wrap mode: just split on line breaks and return.
		return split_lines(text)
	}
	if len(text) == 0 {
		out := make([]string, 1, context.temp_allocator)
		out[0] = ""
		return out
	}

	f := font == 0 ? r.text.default_font : font

	// Per-frame memoisation. View_Text widgets get measured (view_size)
	// and rendered (render_view) on the same instance every frame —
	// without this cache the wrap work runs twice per text widget per
	// frame, which dominates frame time for chat-style UIs with long
	// pasted content. The cache map lives in the temp arena and is
	// reset every frame_begin, so the values' []string backing slices
	// (also in temp) remain valid for the rest of the frame and are
	// collected together.
	use_cache := r != nil && r.frame_valid
	key: Wrap_Key
	if use_cache {
		key = Wrap_Key{
			text_ptr  = rawptr(raw_data(text)),
			text_len  = len(text),
			max_width = max_width,
			size      = size,
			font      = f,
		}
		if cached, ok := r.wrap_cache[key]; ok { return cached }
	}
	scale := r.scale
	if scale <= 0 { scale = 1 }
	// wrap_text measures candidate lines against `max_width` (logical).
	// We scale the threshold up once and compare physical widths inside
	// the loop instead of dividing every measurement down.
	//
	// Measurement dispatches through `measure_text` so the active text
	// backend (fontstash or runa) and `draw_text` agree on widths — when
	// we measured here with fontstash directly and rendered with runa,
	// the ~1% per-glyph metric differences accumulated into visible
	// overflow at line ends in chat-style UIs.
	max_width_px := max_width * scale

	lines: [dynamic]string
	lines.allocator = context.temp_allocator

	// Honour hard breaks first (cross-platform: \n, \r\n, \r), then
	// word-wrap each paragraph to fit max_width.
	paragraphs := split_lines(text)
	for para_raw in paragraphs {
		// Tabs in `para_raw` get expanded to TAB_WIDTH spaces so the
		// word-wrap measure below sees actual visible width — and so
		// the lines returned to the renderer don't contain literal
		// `\t` (which fontstash would draw as a missing-glyph tofu).
		// `expand_tabs` no-ops on tab-free input.
		para := expand_tabs(para_raw)
		if len(para) == 0 {
			// Preserve empty paragraphs so vertical spacing in the
			// source survives.
			append(&lines, "")
			continue
		}
		cursor := 0
		emitted_any := false
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
				cw, _ := measure_text(r, candidate, size, f)
				w := cw * scale
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
			emitted_any = true
		}
		// A paragraph that was nothing but spaces still represents one
		// visible row in the source — keep its vertical slot.
		if !emitted_any { append(&lines, "") }
	}

	if len(lines) == 0 {
		append(&lines, "")
	}
	out := lines[:]
	if use_cache { r.wrap_cache[key] = out }
	return out
}

// Rich_Segment is one styled run inside a single visual line of a
// `rich_text` widget — a contiguous byte range from one Text_Span
// plus its measured width and x position within the line. Generated
// by `wrap_rich_text`; consumed by layout's View_Rich_Text render
// path which iterates segments per line and draws each in the span's
// font / size / colour.
Rich_Segment :: struct {
	span_idx:   int,
	byte_start: int,
	byte_end:   int,
	x_offset:   f32,
	width:      f32,
}

// Rich_Line is one visual line in a wrapped rich-text paragraph.
// `ascent` is the max ascent across the line's segments — used as the
// baseline offset so spans with different font sizes share a common
// glyph-baseline. `height` is the max line-height across the line's
// segments; consecutive lines stack by this amount.
Rich_Line :: struct {
	segments: []Rich_Segment,
	width:    f32,
	ascent:   f32,
	height:   f32,
}

// Atom is one indivisible unit in the wrap pass: a word run, a space,
// or a hard newline. Word atoms get broken between (not within) by the
// greedy fit-and-fall-back-to-last-space algorithm; spaces double as
// the break opportunities; breaks force a new line.
@(private)
Rich_Atom :: struct {
	span_idx:   int,
	byte_start: int,
	byte_end:   int,
	width:      f32,
	ascent:     f32,
	line_h:     f32,
	kind:       Rich_Atom_Kind,
}

@(private)
Rich_Atom_Kind :: enum {
	Word,
	Space,
	Break,
}

// wrap_rich_text breaks `spans` into visual lines no wider than
// `max_width` (set to 0 for no-wrap → one line per hard newline).
// The algorithm:
//
//   1. Atomise. Walk each span byte-by-byte producing word / space /
//      break atoms. Atoms carry their measured width in their span's
//      font + size, plus the ascent / line-height they contribute.
//   2. Layout. Greedy fit: try to place each atom on the current
//      line. When a word would overflow, rewind to the last space on
//      the line, finalise (trimming the trailing space), and resume
//      with the post-space tail.
//   3. Emit. Group consecutive same-span atoms in each line into
//      Rich_Segments and stash them in a Rich_Line with the line's
//      width + max ascent + max line-height.
//
// Returned slice + nested slices all live in context.temp_allocator
// — valid for the rest of the frame.
wrap_rich_text :: proc(
	r:         ^Renderer,
	spans:     []Text_Span,
	base_size: f32,
	base_font: Font,
	max_width: f32,
) -> []Rich_Line {
	lines: [dynamic]Rich_Line
	lines.allocator = context.temp_allocator

	default_ascent: f32 = 0
	default_line_h: f32 = base_size + 4
	if r != nil {
		default_ascent = text_ascent(r, base_size, base_font)
		_, default_line_h = measure_text(r, "", base_size, base_font)
	}

	if r == nil || len(spans) == 0 {
		append(&lines, Rich_Line{ascent = default_ascent, height = default_line_h})
		return lines[:]
	}

	// 1) Atomise.
	atoms: [dynamic]Rich_Atom
	atoms.allocator = context.temp_allocator
	for sp, sp_idx in spans {
		if len(sp.str) == 0 { continue }
		fnt := rich_span_font(r, base_font, sp)
		sz  := rich_span_size(base_size, sp)
		asc := text_ascent(r, sz, fnt)
		_, lh := measure_text(r, "", sz, fnt)
		space_w, _ := measure_text(r, " ", sz, fnt)
		s := sp.str
		i := 0
		for i < len(s) {
			ch := s[i]
			if ch == '\n' {
				append(&atoms, Rich_Atom{
					span_idx = sp_idx,
					byte_start = i, byte_end = i + 1,
					width = 0, ascent = asc, line_h = lh,
					kind = .Break,
				})
				i += 1
				continue
			}
			if ch == ' ' {
				append(&atoms, Rich_Atom{
					span_idx = sp_idx,
					byte_start = i, byte_end = i + 1,
					width = space_w, ascent = asc, line_h = lh,
					kind = .Space,
				})
				i += 1
				continue
			}
			word_start := i
			for i < len(s) && s[i] != ' ' && s[i] != '\n' { i += 1 }
			ww, _ := measure_text(r, s[word_start:i], sz, fnt)
			append(&atoms, Rich_Atom{
				span_idx = sp_idx,
				byte_start = word_start, byte_end = i,
				width = ww, ascent = asc, line_h = lh,
				kind = .Word,
			})
		}
	}

	// 2) Layout. We rebuild the current line as a sub-slice of atoms,
	// then flush + reset when a break or overflow happens.
	cur: [dynamic]Rich_Atom
	cur.allocator = context.temp_allocator
	cur_w: f32 = 0

	flush :: proc(lines: ^[dynamic]Rich_Line, cur: ^[dynamic]Rich_Atom, default_a, default_h: f32) {
		// Trim trailing spaces — they shouldn't take horizontal slot
		// on a wrapped line, matching how editors / browsers render.
		for len(cur) > 0 && cur[len(cur)-1].kind == .Space {
			pop(cur)
		}
		if len(cur) == 0 {
			append(lines, Rich_Line{ascent = default_a, height = default_h})
			return
		}
		// Build segments: group consecutive atoms with the same
		// span_idx and adjacent byte ranges into one Rich_Segment.
		segs: [dynamic]Rich_Segment
		segs.allocator = context.temp_allocator
		x: f32 = 0
		max_a, max_h: f32
		for atom in cur {
			if atom.ascent > max_a { max_a = atom.ascent }
			if atom.line_h > max_h { max_h = atom.line_h }
			if len(segs) > 0 {
				last := &segs[len(segs) - 1]
				if last.span_idx == atom.span_idx && last.byte_end == atom.byte_start {
					last.byte_end = atom.byte_end
					last.width   += atom.width
					x            += atom.width
					continue
				}
			}
			append(&segs, Rich_Segment{
				span_idx   = atom.span_idx,
				byte_start = atom.byte_start,
				byte_end   = atom.byte_end,
				x_offset   = x,
				width      = atom.width,
			})
			x += atom.width
		}
		if max_a == 0 { max_a = default_a }
		if max_h == 0 { max_h = default_h }
		append(lines, Rich_Line{
			segments = segs[:],
			width    = x,
			ascent   = max_a,
			height   = max_h,
		})
	}

	for atom in atoms {
		if atom.kind == .Break {
			flush(&lines, &cur, default_ascent, default_line_h)
			clear(&cur)
			cur_w = 0
			continue
		}
		// Overflow check: if this word would push past max_width and
		// the current line isn't empty, try to break before it. We
		// only break on Word atoms (spaces extending past max_width
		// stay on the current line and get trimmed in flush).
		if max_width > 0 && atom.kind == .Word && len(cur) > 0 && cur_w + atom.width > max_width {
			// Find last space in cur to break at.
			last_space := -1
			for j := len(cur) - 1; j >= 0; j -= 1 {
				if cur[j].kind == .Space { last_space = j; break }
			}
			if last_space >= 0 {
				// Tail = everything after the space (the partial word
				// that started before this atom).
				tail_start := last_space + 1
				tail: [dynamic]Rich_Atom
				tail.allocator = context.temp_allocator
				for j := tail_start; j < len(cur); j += 1 {
					append(&tail, cur[j])
				}
				// Drop tail (and the space itself stays — flush trims it).
				resize(&cur, last_space + 1)
				flush(&lines, &cur, default_ascent, default_line_h)
				clear(&cur)
				cur_w = 0
				for t in tail {
					append(&cur, t)
					cur_w += t.width
				}
			} else {
				// No space on the line — break before this word anyway.
				flush(&lines, &cur, default_ascent, default_line_h)
				clear(&cur)
				cur_w = 0
			}
		}
		append(&cur, atom)
		cur_w += atom.width
	}

	// Final line (may be empty if the only content was a trailing
	// break, in which case we still want the empty visual line so the
	// blank row survives).
	flush(&lines, &cur, default_ascent, default_line_h)

	return lines[:]
}
