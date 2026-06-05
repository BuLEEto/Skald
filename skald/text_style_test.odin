package skald

// White-box tests for normalize_text_styles — the byte-range hygiene behind
// text_input `styles` (rich-text stage 1a): clamping, rune-boundary snapping,
// {}-colour inheritance, and dropping degenerate ranges.

import "core:testing"

@(test)
text_styles_passthrough_and_inherit :: proc(t: ^testing.T) {
	fg  := Color{1, 1, 1, 1}
	red := Color{1, 0, 0, 1}
	styles := []Text_Style{
		{start = 0, end = 3, color = red},
		{start = 6, end = 11, color = {}}, // {} inherits fg
	}
	out := normalize_text_styles(styles, "hello world", fg, context.allocator)
	defer delete(out, context.allocator)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0], Text_Style{start = 0, end = 3,  color = red})
	testing.expect_value(t, out[1], Text_Style{start = 6, end = 11, color = fg}) // colour resolved
}

@(test)
text_styles_clamp_and_drop :: proc(t: ^testing.T) {
	fg := Color{1, 1, 1, 1}
	styles := []Text_Style{
		{start = -3, end = 100, color = fg}, // clamps to {0,5}
		{start = 4,  end = 2,   color = fg}, // inverted → dropped
		{start = 3,  end = 3,   color = fg}, // zero-width → dropped
	}
	out := normalize_text_styles(styles, "hello", fg, context.allocator) // len 5
	defer delete(out, context.allocator)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Text_Style{start = 0, end = 5, color = fg})
}

@(test)
text_styles_rune_snap :: proc(t: ^testing.T) {
	fg := Color{1, 1, 1, 1}
	// "aébc": a(0) é=C3,A9(1,2) b(3) c(4). start=2 is the é continuation
	// byte → snaps back to the rune start at 1; end=4 is a clean boundary.
	styles := []Text_Style{{start = 2, end = 4, color = fg}}
	out := normalize_text_styles(styles, "aébc", fg, context.allocator)
	defer delete(out, context.allocator)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].start, 1)
	testing.expect_value(t, out[0].end, 4)
}

@(test)
text_style_font_resolution :: proc(t: ^testing.T) {
	r: Renderer
	r.text.default_font     = 1
	r.text.bold_font        = 2
	r.text.italic_font      = 3
	r.text.bold_italic_font = 4
	base := Font(9)

	// Explicit font wins over everything.
	testing.expect_value(t, text_style_font(&r, base, Text_Style{font = 5}), Font(5))
	// Weight / italic derive the bundled face.
	testing.expect_value(t, text_style_font(&r, base, Text_Style{weight = .Bold}), Font(2))
	testing.expect_value(t, text_style_font(&r, base, Text_Style{italic = true}), Font(3))
	testing.expect_value(t, text_style_font(&r, base, Text_Style{weight = .Bold, italic = true}), Font(4))
	// Colour-only style keeps the base face, so advances are unchanged.
	testing.expect_value(t, text_style_font(&r, base, Text_Style{color = Color{1, 0, 0, 1}}), base)
	// No base font → the renderer default.
	testing.expect_value(t, text_style_font(&r, 0, Text_Style{}), Font(1))
}

@(test)
text_styles_empty_and_all_dropped_are_nil :: proc(t: ^testing.T) {
	fg := Color{1, 1, 1, 1}
	none := normalize_text_styles(nil, "abc", fg, context.allocator)
	testing.expect_value(t, len(none), 0)

	dropped := normalize_text_styles(
		[]Text_Style{{start = 2, end = 1, color = {}}}, "abc", fg, context.allocator)
	testing.expect_value(t, len(dropped), 0) // nothing survives → nil, no alloc
}
