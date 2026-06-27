package skald

// White-box tests for multiline text_input wrapping, exercising the REAL
// shaping path on BOTH backends. Both runa (text_init_runa) and fontstash
// (fs.Init + AddFontMem) bring up their text state without a GPU — runa's
// atlas is a CPU rect-packer, and fontstash's measurement path is metric-
// only with nil-guarded upload callbacks. The renderer is heap-allocated
// (it embeds fontstash's FontContext) and given a Window_Target because
// `scale` is reached through `using cur`.
//
// The headline property (check_wrap_fits) is the safety net for the O(L)
// cumulative-advance wrap: every visual line, measured by the SAME
// measure_text the renderer draws and positions the caret with, must fit
// inside inner_w. If text_line_advances ever disagreed with measure_text
// enough to pack an extra rune, this fails.

import "core:math"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import fs "vendor:fontstash"

// Crash-safety: throw adversarial input at every wrap entry point and
// confirm none panic (bounds-checks are on, so an OOB index aborts here).
// Complements runa_fuzz, which fuzzes the shaper itself — this fuzzes the
// Skald wrap code that sits on top of it.
@(test)
wrap_no_crash_on_adversarial :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }

	inputs: [dynamic]string
	inputs.allocator = context.temp_allocator

	tok := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 200 { strings.write_byte(&tok, 'a') }                   // long spaceless token (hard-break path)
	append(&inputs, strings.to_string(tok))

	append(&inputs, "several normal words here that wrap onto a few lines for good measure")
	append(&inputs, "")
	append(&inputs, "\n\n\n\n")
	append(&inputs, "                                   ")
	append(&inputs, "\t\ttabs\there\tand\tthere\t")

	// Malformed UTF-8: lone lead byte, lone continuation, truncated seq, 0xFF.
	bad: [dynamic]u8
	bad.allocator = context.temp_allocator
	append(&bad, 'h', 'i', ' ', 0xFF, 0xFE, 0xC0, 0x80, 0x80, 'x', 0xE0, 0xA0, ' ', 'y', 0xED)
	append(&inputs, string(bad[:]))
	append(&inputs, "mix 😀\xff\xfe end\n\ttab \xc0 word")

	for s in inputs {
		for w in ([]f32{0, 1, 5, 80, 400}) {
			build_visual_lines(r, s, 16, w, true, 0)
			wrap_text(r, s, w, 16, 0)
			wrap_rich_text(r, []Text_Span{{str = s}}, 16, 0, w)
			text_line_advances(r, s, 16, 0)
		}
	}
	testing.expect(t, true, "reached end without panic")
}

@(private = "file")
runa_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target) // `scale` lives here via `using cur`
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	font_use_default_emoji(r) // register Twemoji so emoji shape with real advances
	return r
}

@(private = "file")
free_runa_renderer :: proc(r: ^Renderer) {
	if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
	free(r.cur)
	free(r)
}

@(private = "file")
fontstash_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	fs.Init(&r.text.fs, ATLAS_SIZE, ATLAS_SIZE, .TOPLEFT)
	r.text.default_font = Font(fs.AddFontMem(&r.text.fs, "inter", INTER_VARIABLE, false))
	// runa_state stays nil, so measure_text / text_line_advances dispatch
	// to the fontstash path even in a runa-default build.
	return r
}

@(private = "file")
free_fontstash_renderer :: proc(r: ^Renderer) {
	fs.Destroy(&r.text.fs)
	free(r.cur)
	free(r)
}

@(private = "file")
WRAP_CASES := []string{
	"hello world this is a test of word wrapping behaviour across lines",
	"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", // no spaces -> hard break
	"see https://example.com/p/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?x=1 now",
	"café résumé naïve coördinate fiancée jalapeño",                       // accents / combining
	"日本語のテキスト折り返しのテスト用文字列です",                            // CJK, no spaces
	"line one\nline two is a fair bit longer than line one\nthree",        // hard newlines
	"   leading and    multiple     spaces    between    words   ",
	"tap 😀 to react 🎉 then ship 🚀 looks good 👍 all done ✅ great",      // colour emoji (padded advance)
	"hello عربي world שלום mixed direction text wrapping here ok",          // mixed LTR / RTL runs
	"emoji-glued😀😀😀😀😀😀😀😀😀😀nospaces and then words after the run",  // emoji with no break points
	"a",
	"",
}

@(private = "file")
check_wrap_fits :: proc(t: ^testing.T, r: ^Renderer) {
	fsz: f32 = 16
	for inner_w in ([]f32{80, 160, 240}) {
		for s in WRAP_CASES {
			vls := build_visual_lines(r, s, fsz, inner_w, true, 0)

			// Coverage: starts at 0, ends at len(s), contiguous lines
			// (gap 0 = soft hard-break, gap 1 = a consumed space or '\n').
			testing.expect_value(t, vls[0].start, 0)
			testing.expect_value(t, vls[len(vls) - 1].end, len(s))
			for k in 1 ..< len(vls) {
				gap := vls[k].start - vls[k - 1].end
				testing.expectf(t, gap == 0 || gap == 1,
					"non-contiguous lines in %q: gap=%d", s, gap)
			}

			// No overflow: each drawn segment fits, except a lone rune that
			// is itself wider than inner_w (can't be shrunk further).
			for vl in vls {
				seg := s[vl.start:vl.end]
				if utf8.rune_count_in_string(seg) <= 1 { continue }
				w, _ := measure_text(r, seg, fsz, 0)
				testing.expectf(t, w <= inner_w + 0.5,
					"line %q width %.2f exceeds inner_w %.2f", seg, w, inner_w)
			}
		}
	}
}

@(private = "file")
check_advances :: proc(t: ^testing.T, r: ^Renderer) {
	fsz: f32 = 16
	for s in ([]string{"hello world", "café résumé", "日本語テキスト", "the quick brown fox"}) {
		adv := text_line_advances(r, s, fsz, 0)
		testing.expect_value(t, len(adv), len(s) + 1)
		testing.expect_value(t, adv[0], 0)

		// Total cumulative advance equals the measured width of the whole
		// string (same per-glyph advance, summed the same way).
		full, _ := measure_text(r, s, fsz, 0)
		testing.expectf(t, math.abs(adv[len(s)] - full) < 0.5,
			"total advance %.3f != measured width %.3f for %q", adv[len(s)], full, s)

		// Monotonic non-decreasing (cumulative widths never go backwards).
		for k in 1 ..= len(s) {
			testing.expectf(t, adv[k] >= adv[k - 1] - 0.001,
				"advances not monotonic at byte %d of %q", k, s)
		}
	}
}

// check_wrap_text: every wrapped line of static text() fits max_width when
// measured the way it'll be drawn (lone over-wide runes excepted).
@(private = "file")
check_wrap_text :: proc(t: ^testing.T, r: ^Renderer) {
	fsz: f32 = 16
	for mw in ([]f32{80, 160, 240}) {
		for s in WRAP_CASES {
			lines := wrap_text(r, s, mw, fsz, 0)
			testing.expect(t, len(lines) >= 1, "wrap_text returned no lines")
			for ln in lines {
				if utf8.rune_count_in_string(ln) <= 1 { continue }
				w, _ := measure_text(r, ln, fsz, 0)
				testing.expectf(t, w <= mw + 0.5,
					"wrap_text line %q width %.2f > max %.2f", ln, w, mw)
			}
		}
	}
}

// check_wrap_rich: every wrapped rich_text line's width (summed from the
// per-span advances the wrap decided on) fits max_width.
@(private = "file")
check_wrap_rich :: proc(t: ^testing.T, r: ^Renderer) {
	spans := []Text_Span{
		span_bold("Heading "),
		Text_Span{str = "then a normal run of several words that should wrap across lines "},
		span_link("https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "url"),
		Text_Span{str = " and 😀 emoji 🎉 plus some tail words here too"},
	}
	for mw in ([]f32{80, 160, 240}) {
		lines := wrap_rich_text(r, spans, 16, 0, mw)
		testing.expect(t, len(lines) >= 1, "wrap_rich_text returned no lines")
		for ln in lines {
			nr := 0
			for seg in ln.segments {
				nr += utf8.rune_count_in_string(spans[seg.span_idx].str[seg.byte_start:seg.byte_end])
			}
			if nr <= 1 { continue }
			testing.expectf(t, ln.width <= mw + 0.5,
				"rich line width %.2f > max %.2f", ln.width, mw)
		}
	}
}

@(test)
text_wrap_runa :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return } // runa init unavailable
	check_wrap_fits(t, r)
	check_advances(t, r)
	check_wrap_text(t, r)
	check_wrap_rich(t, r)
}

@(test)
text_wrap_fontstash :: proc(t: ^testing.T) {
	r := fontstash_renderer()
	defer free_fontstash_renderer(r)
	check_wrap_fits(t, r)
	check_advances(t, r)
	check_wrap_text(t, r)
	check_wrap_rich(t, r)
}

@(test)
visual_line_cache_behaviour :: proc(t: ^testing.T) {
	st: Widget_State
	defer vline_cache_free(st.vline_cache)

	// r == nil forces wrap off, so build_visual_lines just splits on '\n'
	// — deterministic without a renderer, which lets us probe the memo.
	// "x\ny\nz" is 5 bytes, 3 logical lines.
	a := build_visual_lines_cached(&st, nil, "x\ny\nz", 14, 100, true, 0)
	testing.expect_value(t, len(a), 3)
	testing.expect(t, st.vline_cache != nil, "cache allocated on first build")
	testing.expect_value(t, st.vline_cache.text_len, 5)

	// Prove the next identical call HITS the cache rather than rebuilding:
	// sabotage the stored table, and a hit must echo the (now-empty) copy.
	clear(&st.vline_cache.lines)
	b := build_visual_lines_cached(&st, nil, "x\ny\nz", 14, 100, true, 0)
	testing.expectf(t, len(b) == 0, "expected cache hit (len 0 after sabotage), got %d", len(b))

	// A width change is a key miss -> rebuild from scratch (3 lines again).
	c := build_visual_lines_cached(&st, nil, "x\ny\nz", 14, 200, true, 0)
	testing.expect_value(t, len(c), 3)
	testing.expect_value(t, st.vline_cache.inner_w, f32(200))

	// A content change is a key miss -> new length + table ("p\nq" = 3 bytes).
	d := build_visual_lines_cached(&st, nil, "p\nq", 14, 200, true, 0)
	testing.expect_value(t, len(d), 2)
	testing.expect_value(t, st.vline_cache.text_len, 3)
}

// --- text_input_offset_at / _offset_rect accessors ---

@(test)
offset_accessor_single_line_roundtrip :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }

	Msg :: distinct int
	store: Widget_Store
	widget_store_init(&store)
	defer widget_store_destroy(&store)
	store.frame = 5

	id   := Widget_ID(7)
	text := "hello world example text"
	fs:  f32 = 16
	_, line_h := measure_text(r, "Ag", fs, 0)
	store.states[id] = Widget_State{
		kind         = .Text_Input,
		last_frame   = store.frame,
		last_rect    = {10, 20, 300, 40},
		tg_text      = text,
		tg_fs        = fs,
		tg_pad       = {8, 8},
		tg_line_h    = line_h,
		tg_multiline = false,
	}
	input: Input
	ctx := Ctx(Msg){widgets = &store, input = &input, renderer = r}

	// A point at byte o's left edge maps back to o (no wrap, no scroll).
	for off in ([]int{0, 3, 6, 11, 18, len(text)}) {
		rect, ok := text_input_offset_rect(&ctx, id, off)
		testing.expectf(t, ok, "offset_rect ok for off=%d", off)
		off2, ok2 := text_input_offset_at(&ctx, id, {rect.x + 0.5, rect.y + line_h * 0.5})
		testing.expect(t, ok2, "offset_at ok")
		testing.expectf(t, off2 == off, "single-line roundtrip off=%d -> %d", off, off2)
	}

	// Monotonic: later offsets sit further right.
	r1, _ := text_input_offset_rect(&ctx, id, 3)
	r2, _ := text_input_offset_rect(&ctx, id, 9)
	testing.expect(t, r2.x > r1.x, "offset_rect x should increase with offset")

	// Stale geometry (widget didn't render recently) -> ok=false.
	store.frame = 9
	_, ok_stale := text_input_offset_rect(&ctx, id, 3)
	testing.expect(t, !ok_stale, "stale geometry must return ok=false")
}

// Regression (req 022): the editable text_input shapes its raw buffer, so a
// literal TAB must measure + position as TAB_WIDTH spaces (parity with text())
// instead of missing-glyph tofu — and the offset accessors must stay aligned.
@(test)
text_input_tab_renders_as_spaces :: proc(t: ^testing.T) {
	#assert(TAB_WIDTH == 4) // bump the reference string below if this changes
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }

	fs: f32 = 16
	// A tab measures exactly TAB_WIDTH spaces wide — the RHS is literal
	// spaces (no tab), so this isn't circular: it pins the expansion width.
	tab_w,   _ := measure_text(r, "\t",   fs, 0)
	four_sp, _ := measure_text(r, "    ", fs, 0)
	testing.expectf(t, abs(tab_w - four_sp) < 0.01,
		"tab should measure as %d spaces: tab=%v spaces=%v", TAB_WIDTH, tab_w, four_sp)
	testing.expect(t, tab_w > 0, "tab must have positive width (not zero/tofu)")

	Msg :: distinct int
	store: Widget_Store
	widget_store_init(&store)
	defer widget_store_destroy(&store)
	store.frame = 5

	id   := Widget_ID(11)
	text := "\tindented"
	_, line_h := measure_text(r, "Ag", fs, 0)
	store.states[id] = Widget_State{
		kind         = .Text_Input,
		last_frame   = store.frame,
		last_rect    = {10, 20, 300, 40},
		tg_text      = text,
		tg_fs        = fs,
		tg_pad       = {8, 8},
		tg_line_h    = line_h,
		tg_multiline = false,
	}
	input: Input
	ctx := Ctx(Msg){widgets = &store, input = &input, renderer = r}

	// The caret just past the tab (offset 1) sits one tab-width right of the
	// line start — i.e. the tab occupies its expanded width, not 1 glyph.
	rect0, _ := text_input_offset_rect(&ctx, id, 0)
	rect1, _ := text_input_offset_rect(&ctx, id, 1)
	testing.expectf(t, abs((rect1.x - rect0.x) - tab_w) < 0.5,
		"offset 1 should sit one tab-width right of offset 0: got %v want %v",
		rect1.x - rect0.x, tab_w)

	// A click landing past the tab gap maps to a byte at/after the tab (it's
	// one atomic rune — nav never lands "inside" it).
	col, ok := text_input_offset_at(&ctx, id, {rect1.x + 0.5, rect1.y + line_h * 0.5})
	testing.expect(t, ok, "offset_at ok")
	testing.expectf(t, col >= 1, "click past the tab should land at/after the tab byte, got %d", col)
}

// Regression (req 022): the three text leaves (measure_text, draw_text,
// text_line_advances) must agree on a tab's width — else a layout that reserves
// space from advances (rich_text offsets, wrap breaks) then draws with draw_text
// overlaps. Advances stay RAW-byte-indexed, so each prefix == measure_text.
@(test)
text_line_advances_tab_matches_measure :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }

	fs: f32 = 16
	s  := "a\tb\tc" // tabs interleaved with glyphs, len 5, tabs at bytes 1 and 3
	adv := text_line_advances(r, s, fs, 0)
	testing.expectf(t, len(adv) == len(s) + 1,
		"advances stay indexed by raw byte: len(adv)=%d want %d", len(adv), len(s)+1)

	// Full width equals measure_text (which expands tabs).
	full, _ := measure_text(r, s, fs, 0)
	testing.expectf(t, abs(adv[len(s)] - full) < 0.01,
		"full advance %v should equal measure_text %v", adv[len(s)], full)

	// Every raw-byte prefix width matches measure_text of that prefix — the
	// property rich-text layout relies on (advance reserved == width drawn).
	for b in 0 ..= len(s) {
		w, _ := measure_text(r, s[:b], fs, 0)
		testing.expectf(t, abs(adv[b] - w) < 0.01,
			"prefix[:%d]: advance %v vs measure %v", b, adv[b], w)
	}

	// Monotonic (a tab can't make the pen go backwards).
	for b in 1 ..= len(s) {
		testing.expectf(t, adv[b] >= adv[b-1],
			"advances must be non-decreasing at byte %d", b)
	}

	// Tab interleaved with multi-byte UTF-8 — the remap steps its expanded
	// cursor per raw byte, so verify advances stay aligned at every RUNE
	// boundary (what wrap / rich-text / hit-test actually index).
	u := "é\t€\tabc" // é=2 bytes, €=3 bytes, tabs between
	uadv := text_line_advances(r, u, fs, 0)
	testing.expectf(t, len(uadv) == len(u) + 1,
		"utf8+tab advances raw-indexed: len=%d want %d", len(uadv), len(u)+1)
	bi := 0
	for bi <= len(u) {
		w, _ := measure_text(r, u[:bi], fs, 0)
		testing.expectf(t, abs(uadv[bi] - w) < 0.01,
			"utf8+tab prefix[:%d]: advance %v vs measure %v", bi, uadv[bi], w)
		if bi == len(u) { break }
		_, n := utf8.decode_rune_in_string(u[bi:])
		bi += max(n, 1)
	}
}

@(test)
offset_accessor_multiline :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }

	Msg :: distinct int
	store: Widget_Store
	widget_store_init(&store)
	defer widget_store_destroy(&store) // frees vline_cache too

	id      := Widget_ID(3)
	text    := "first line here\nsecond line below"
	fs:     f32 = 16
	inner_w: f32 = 400
	_, line_h := measure_text(r, "Ag", fs, 0)

	vls := build_visual_lines(r, text, fs, inner_w, true, 0)
	cache := new(Visual_Line_Cache)
	cache.lines = make([dynamic]Visual_Line)
	append(&cache.lines, ..vls)

	store.states[id] = Widget_State{
		kind         = .Text_Input,
		last_frame   = store.frame,
		last_rect    = {0, 0, inner_w + 16, 200},
		tg_text      = text,
		tg_fs        = fs,
		tg_pad       = {8, 8},
		tg_line_h    = line_h,
		tg_stride    = line_h, // line_spacing == 0 here
		tg_multiline = true,
		vline_cache  = cache,
	}
	input: Input
	ctx := Ctx(Msg){widgets = &store, input = &input, renderer = r}

	nl := 0 // byte index of the '\n'
	for ch, i in text { if ch == '\n' { nl = i; break } }

	r_first, ok1  := text_input_offset_rect(&ctx, id, 2)       // line 0
	r_second, ok2 := text_input_offset_rect(&ctx, id, nl + 3)  // line 1
	testing.expect(t, ok1 && ok2, "both offsets resolve")
	testing.expect(t, r_second.y > r_first.y, "later line sits lower on screen")

	// A point inside line 1 maps to a byte on line 1 (>= nl+1).
	off, ok3 := text_input_offset_at(&ctx, id, {r_second.x + 0.5, r_second.y + line_h * 0.5})
	testing.expect(t, ok3, "offset_at ok")
	testing.expectf(t, off >= nl + 1, "click on line 1 should map past the newline, got %d", off)
}

// Regression: with line_spacing > 0 the public offset accessors must stack
// and hit-test lines by stride (line_h + line_spacing), not bare line_h.
// Before the fix, offset_rect placed later lines too high (×line_h) and
// offset_at divided clicks by line_h and overshot to a lower line — the
// same spacing-blind bug as the text_input drag path.
@(test)
offset_accessor_multiline_spaced :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }

	Msg :: distinct int
	store: Widget_Store
	widget_store_init(&store)
	defer widget_store_destroy(&store)

	id      := Widget_ID(7)
	// Four explicit lines so an overshoot is unambiguous.
	text    := "line zero\nline one\nline two\nline three"
	fs:     f32 = 16
	inner_w: f32 = 400
	_, line_h := measure_text(r, "Ag", fs, 0)
	spacing: f32 = 14 // loose leading — what triggers the bug
	stride  := line_h + spacing

	vls := build_visual_lines(r, text, fs, inner_w, true, 0)
	cache := new(Visual_Line_Cache)
	cache.lines = make([dynamic]Visual_Line)
	append(&cache.lines, ..vls)

	store.states[id] = Widget_State{
		kind         = .Text_Input,
		last_frame   = store.frame,
		last_rect    = {0, 0, inner_w + 16, 400},
		tg_text      = text,
		tg_fs        = fs,
		tg_pad       = {8, 8},
		tg_line_h    = line_h,
		tg_stride    = stride,
		tg_multiline = true,
		vline_cache  = cache,
	}
	input: Input
	ctx := Ctx(Msg){widgets = &store, input = &input, renderer = r}

	// offset_rect: consecutive lines are exactly `stride` apart, not line_h,
	// and the caret box height stays line_h.
	r0, ok0 := text_input_offset_rect(&ctx, id, 0)            // line 0
	starts  := line_starts(text)                              // byte of each line start
	r1, ok1 := text_input_offset_rect(&ctx, id, starts[1])   // line 1
	r3, ok3 := text_input_offset_rect(&ctx, id, starts[3])   // line 3
	testing.expect(t, ok0 && ok1 && ok3, "all offsets resolve")
	testing.expectf(t, abs((r1.y - r0.y) - stride) < 0.01,
		"adjacent lines should be stride=%v apart, got %v", stride, r1.y - r0.y)
	testing.expectf(t, abs((r3.y - r0.y) - 3 * stride) < 0.01,
		"line 3 should be 3*stride below line 0, got %v", r3.y - r0.y)
	testing.expectf(t, abs(r0.h - line_h) < 0.01,
		"caret box height stays line_h=%v, got %v", line_h, r0.h)

	// offset_at: a click at the vertical centre of each line resolves to a
	// byte on THAT line — no overshoot. With the old /line_h math, clicking
	// line 3's centre (y ≈ 3*stride) would divide to line index
	// 3*stride/line_h, landing well past the last line.
	for li in 0 ..< len(starts) {
		cy := stride * f32(li) + line_h * 0.5 // centre of line li, content space
		// content space -> screen: + iy (pad.y), scroll_y is 0 here.
		off, ok := text_input_offset_at(&ctx, id, {10, cy + 8})
		testing.expectf(t, ok, "offset_at ok for line %d", li)
		got_line := visual_line_of_byte(cache.lines[:], off)
		testing.expectf(t, got_line == li,
			"click on line %d should resolve to line %d, got line %d (off %d)",
			li, li, got_line, off)
	}
}

// line_starts returns the byte offset of each line's first character
// (split on '\n'). Test helper.
@(private = "file")
line_starts :: proc(s: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	append(&out, 0)
	for ch, i in s { if ch == '\n' { append(&out, i + 1) } }
	return out[:]
}

// Regression (req 021): a command_palette whose list overflows the window
// scrolls the rows inside a capped viewport — and that viewport (whose right
// edge carries the scrollbar) must stay WITHIN the card, not spill into the
// scrim. The bug it guards: `dialog`'s default max_width (480) clamped the card
// narrower than the palette's own `width`, so the full-width scroll viewport
// overflowed and the bar landed past the card's right edge.
@(test)
command_palette_scroll_fits_card :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }
	r.fb_size = {720, 600}
	r.scale   = 1

	Msg :: distinct int
	store: Widget_Store
	widget_store_init(&store)
	defer widget_store_destroy(&store)
	store.frame = 5
	r.widgets = &store

	theme  := theme_dark()
	labels := labels_en()
	input:  Input
	msgs:   [dynamic]Msg
	ctx := Ctx(Msg){ theme = &theme, labels = &labels, input = &input, msgs = &msgs, widgets = &store, renderer = r }

	items: [dynamic]Menu_Item(Msg)
	items.allocator = context.temp_allocator
	for i in 0 ..< 30 { append(&items, Menu_Item(Msg){ label = "Command number 00", msg = Msg(i) }) }
	entries := []Menu_Entry(Msg){ { label = "Cmds", items = items[:] } }

	pid := widget_make_sub_id(Widget_ID(0), 777)
	on_dismiss := proc() -> Msg { return Msg(0) }

	view := command_palette(&ctx, true, entries, on_dismiss, id = pid, max_rows = 30)
	clear(&r.overlays)
	render_view(r, view, {0, 0}, {720, 600})
	render_overlays(r)

	card := store.modal_rect
	sc   := store.states[widget_make_sub_id(pid, 0)].last_rect // the list's scroll viewport
	testing.expect(t, sc.w > 0, "overflowing palette must wrap its list in a scroll")
	testing.expect(t, sc.x >= card.x - 0.5, "scroll starts within the card")
	testing.expectf(t, sc.x + sc.w <= card.x + card.w + 0.5,
		"scroll right %.1f spills past card right %.1f (scrollbar outside the card)",
		sc.x + sc.w, card.x + card.w)
}

// Regression (req 023): text_input(multiline) auto-grows between min_lines and
// max_lines, and chat_input delegates to it. Guards the height formula (rest at
// min, grow by newline count, cap at max) AND that a multiline field with NO
// max_lines keeps the old fixed default — so existing callers are unaffected.
@(test)
text_input_min_max_lines_autogrow :: proc(t: ^testing.T) {
	r := runa_renderer()
	defer free_runa_renderer(r)
	if r.text.runa_state == nil { return }
	r.fb_size = {800, 600}
	r.scale   = 1

	Msg :: distinct int
	store: Widget_Store
	widget_store_init(&store)
	defer widget_store_destroy(&store)
	store.frame = 5
	r.widgets = &store

	theme := theme_dark()
	input: Input
	msgs:  [dynamic]Msg
	ctx := Ctx(Msg){ theme = &theme, input = &input, msgs = &msgs, widgets = &store, renderer = r }

	fs    := theme.font.size_md
	pad_y := theme.spacing.sm
	line  := fs + 4   // per-line stride, line_spacing 0

	on_ch :: proc(s: string) -> Msg { return Msg(0) }

	height_of :: proc(v: View) -> (f32, bool) {
		vti, ok := v.(View_Text_Input)
		return vti.height, ok
	}

	// Empty + min_lines=3 → rests three lines tall.
	v := text_input(&ctx, "", on_ch, id = hash_id("ti-a"),
		multiline = true, wrap = true, min_lines = 3, max_lines = 8)
	h, ok := height_of(v)
	testing.expect(t, ok, "expected a View_Text_Input")
	testing.expect_value(t, h, 3 * line + 2 * pad_y)

	// Five newlines (six lines) → grows to six.
	v = text_input(&ctx, "a\nb\nc\nd\ne\nf", on_ch, id = hash_id("ti-b"),
		multiline = true, wrap = true, min_lines = 3, max_lines = 8)
	h, _ = height_of(v)
	testing.expect_value(t, h, 6 * line + 2 * pad_y)

	// Twenty newlines → capped at max_lines (8).
	big := strings.repeat("x\n", 20, context.temp_allocator)
	v = text_input(&ctx, big, on_ch, id = hash_id("ti-c"),
		multiline = true, wrap = true, min_lines = 3, max_lines = 8)
	h, _ = height_of(v)
	testing.expect_value(t, h, 8 * line + 2 * pad_y)

	// No max_lines → auto-grow OFF → the old fixed multiline default
	// (fs*6 + 2*pad + 6). This is the "existing callers unchanged" guard.
	v = text_input(&ctx, "a\nb\nc", on_ch, id = hash_id("ti-d"),
		multiline = true, wrap = true)
	h, _ = height_of(v)
	testing.expect_value(t, h, fs * 6 + 2 * pad_y + 6)

	// chat_input delegates: "a\nb\nc" is three lines, same formula.
	on_sub :: proc(s: string) -> Msg { return Msg(0) }
	cv := chat_input(&ctx, "a\nb\nc", on_ch, on_sub, id = hash_id("ci-a"))
	ch, cok := height_of(cv)
	testing.expect(t, cok, "chat_input should build a View_Text_Input")
	testing.expect_value(t, ch, 3 * line + 2 * pad_y)
}
