package skald

import "core:testing"

// A dialog with a `footer` pins its action bar to the card's bottom and
// scrolls `content` above it, so a short window never clips the footer's
// controls off the bottom. Reported by ERBossCheckList: a select in a
// dialog vanished on a short window because its action row spilled past
// the card edge and the popover force-closed.
//
// The footer path wraps the body in a fill-mode scroll whose node reports
// a zero intrinsic height, so the card sizes from a separate `measure`
// tree (the unwrapped body + footer) to still reserve the footer's room.
// These guard the `measure` indirection (losing it collapses the card to
// just the footer) and the short-window cap.

@(private = "file")
DF_Msg :: distinct int

@(private = "file")
DF_Fixture :: struct {
	ws:    Widget_Store,
	th:    Theme,
	lb:    Labels,
	input: Input,
	msgs:  [dynamic]DF_Msg,
	r:     ^Renderer,
}

@(private = "file")
df_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	return r
}

@(private = "file")
df_free :: proc(r: ^Renderer) {
	if r == nil { return }
	if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
	batch_destroy(&r.batch)
	free(r.cur)
	free(r)
}

@(private = "file")
df_dismiss :: proc() -> DF_Msg { return 0 }

@(private = "file")
df_ctx :: proc(f: ^DF_Fixture) -> Ctx(DF_Msg) {
	widget_store_begin_frame(&f.ws, f.input)
	return Ctx(DF_Msg){
		theme = &f.th, labels = &f.lb, widgets = &f.ws,
		input = &f.input, msgs = &f.msgs, renderer = f.r,
	}
}

@(test)
dialog_footer_pins_and_reserves_height :: proc(t: ^testing.T) {
	f: DF_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	f.r  = df_renderer()
	defer df_free(f.r)
	defer delete(f.msgs)
	ctx := df_ctx(&f)

	// Tall body (overflows a short window) + a short action bar.
	kids := make([]View, 10, context.temp_allocator)
	for i in 0 ..< 10 { kids[i] = rect({200, 40}, {0.4, 0.5, 0.8, 1}, 6) }
	body   := col(..kids, spacing = 8, cross_align = .Stretch)
	footer := row(rect({120, 36}, {0.3, 0.6, 0.3, 1}, 6), cross_align = .Center)

	v := dialog(&ctx,
		open       = true,
		content    = body,
		on_dismiss = df_dismiss,
		footer     = footer,
		width      = 400,
	)
	vd, ok := v.(View_Dialog)
	testing.expect(t, ok, "dialog must return a View_Dialog")
	testing.expect(t, vd.measure != nil, "a footer dialog carries a measure tree")

	body_h   := view_size(f.r, body).y
	footer_h := view_size(f.r, footer).y

	// Tall framebuffer: the card sizes from `measure` and reserves room for
	// BOTH the scrolling body and the pinned footer.
	_, card_h := dialog_card_size(f.r, vd.measure^, vd.width, vd.max_width, vd.padding, 2000, 2000)
	testing.expectf(t, card_h >= body_h + footer_h,
		"card %.0f must reserve body %.0f + footer %.0f", card_h, body_h, footer_h)

	// Sizing from the RENDERED child (the fill-mode scroll) collapses to ~the
	// footer — this is why the separate `measure` tree exists. Without it the
	// footer would be all that fit and the body would spill, back to the bug.
	_, child_h := dialog_card_size(f.r, vd.child^, vd.width, vd.max_width, vd.padding, 2000, 2000)
	testing.expectf(t, child_h < body_h,
		"rendered-child measure %.0f collapses below body %.0f (needs `measure`)", child_h, body_h)

	// Short framebuffer: the card caps to fit on screen (fb_h - 16), with the
	// footer laid out inside the capped card rather than below it.
	short_fb: f32 = 300
	_, short_h := dialog_card_size(f.r, vd.measure^, vd.width, vd.max_width, vd.padding, 2000, short_fb)
	testing.expectf(t, short_h <= short_fb - 16 + 0.5,
		"short-window card %.0f must cap to fb-16 (%.0f)", short_h, short_fb - 16)
	testing.expect(t, short_h > footer_h, "capped card still taller than the footer alone")
}

@(test)
dialog_without_footer_is_unchanged :: proc(t: ^testing.T) {
	f: DF_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	f.r  = df_renderer()
	defer df_free(f.r)
	defer delete(f.msgs)
	ctx := df_ctx(&f)

	body := col(rect({200, 40}, {0.4, 0.5, 0.8, 1}, 6), cross_align = .Stretch)
	v := dialog(&ctx, open = true, content = body, on_dismiss = df_dismiss)
	vd, ok := v.(View_Dialog)
	testing.expect(t, ok, "dialog must return a View_Dialog")
	testing.expect(t, vd.measure == nil, "no footer -> no measure indirection (unchanged path)")
}
