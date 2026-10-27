package skald

import "core:testing"

@(private = "file")
mk_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	return r
}

@(private = "file")
free_renderer :: proc(r: ^Renderer) {
	if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
	free(r.cur)
	free(r)
}

// A dialog's card must be tall enough for content that wraps once clamped to
// the card width. `dialog_card_size` measures height at the clamped inner
// width, so a wrap_row that wraps to several lines gets its real height — not
// the intrinsic one-line size, which left the next sibling (a Close row) below
// the card edge. Reported by ERBossCheckList.
@(test)
dialog_card_grows_for_wrapped_content :: proc(t: ^testing.T) {
	r := mk_renderer()
	defer free_renderer(r)

	kids := make([]View, 8, context.temp_allocator)
	for i in 0 ..< 8 { kids[i] = rect({100, 30}, {0.4, 0.5, 0.8, 1}, 6) }
	content := col(
		wrap_row(..kids, spacing = 10, line_spacing = 8),
		rect({90, 30}, {0.8, 0.3, 0.3, 1}, 6),   // a "Close" row
		spacing = 8,
		cross_align = .Stretch,
	)

	// Dialog caps content to max_width 480 → the 8 chips (intrinsic ~870 wide)
	// wrap to several lines. The card must hold the wrapped rows AND the Close.
	_, card_h := dialog_card_size(r, content, 0, 480, 16, 2000, 2000)
	intrinsic_h := view_size(r, content).y + 2 * 16   // the old, buggy measure (one line)

	testing.expectf(t, card_h > intrinsic_h + 25,
		"card height %.1f must exceed the intrinsic one-line height %.1f by a wrapped row", card_h, intrinsic_h)
}
