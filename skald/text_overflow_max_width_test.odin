package skald

import "core:testing"

// With `max_width` set, `.Clip` / `.Ellipsis` keep the text on one line and
// truncate at `max_width`; only `.Visible` wraps. The key guard is `view_size`:
// a truncating text must reserve a single line's height, not the wrapped
// height, or its row grows tall while drawing one line. Raised in discussion
// #15 (jc-design) for table cells.

@(private = "file")
tov_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	return r
}

@(test)
text_max_width_overflow_stays_single_line :: proc(t: ^testing.T) {
	r := tov_renderer()
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		batch_destroy(&r.batch)
		free(r.cur)
		free(r)
	}

	long := "This is a very long cell value that will not fit in 240px"
	_, lh := measure_text(r, "", 14, 0)

	// .Visible wraps → taller than a single line.
	wrapped := view_size(r, text(long, {1, 1, 1, 1}, 14, 0, 240, .Visible))
	testing.expect(t, wrapped.y > lh + 1, ".Visible wraps to multiple lines")

	// .Ellipsis / .Clip stay on one line (single-line height), width = max_width.
	elided := view_size(r, text(long, {1, 1, 1, 1}, 14, 0, 240, .Ellipsis))
	testing.expectf(t, abs(elided.y - lh) < 1, ".Ellipsis single-line height, got %.1f vs %.1f", elided.y, lh)
	testing.expect_value(t, elided.x, f32(240))

	clipped := view_size(r, text(long, {1, 1, 1, 1}, 14, 0, 240, .Clip))
	testing.expectf(t, abs(clipped.y - lh) < 1, ".Clip single-line height, got %.1f vs %.1f", clipped.y, lh)
}
