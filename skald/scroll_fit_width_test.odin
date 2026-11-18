package skald

import "core:testing"

// A vertical scroll lays its content out at the viewport width, so a
// wrap_row wraps there; a width the content declares is honoured instead.
// virtual_list_variable measures rows at that same width so its cached
// heights match what renders.

@(private = "file")
FW_Msg :: distinct int

@(private = "file")
fw_chips :: proc() -> View {
	kids := make([]View, 10, context.temp_allocator)
	for i in 0 ..< 10 { kids[i] = rect({60, 24}, {0.4, 0.5, 0.8, 1}) }
	// Natural single line: 10*60 + 9*6 = 654 px; at 300 px it wraps to 3 lines.
	return col(wrap_row(..kids, spacing = 6, line_spacing = 6), cross_align = .Stretch)
}

@(private = "file")
fw_renderer :: proc(ws: ^Widget_Store) -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.fb_size = {800, 600}
	r.widgets = ws
	return r
}

@(private = "file")
fw_free :: proc(r: ^Renderer) {
	batch_destroy(&r.batch)
	free(r.cur)
	free(r)
}

@(test)
scroll_content_fits_viewport_width :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	r := fw_renderer(&ws)
	defer fw_free(r)

	id := hash_id("fit")
	content := fw_chips()
	render_view(r, View_Scroll{id = id, size = {300, 200}, content = &content}, {0, 0}, {300, 200})
	// 3 wrapped lines: 3*24 + 2*6 = 84 (it was 24, one clipped line).
	testing.expect_value(t, ws.states[id].content_h, f32(84))

	// A declared width is honoured: wrap_row(width = 1000) stays on one line.
	kids := make([]View, 10, context.temp_allocator)
	for i in 0 ..< 10 { kids[i] = rect({60, 24}, {0.4, 0.5, 0.8, 1}) }
	wide := wrap_row(..kids, spacing = 6, width = 1000)
	id2 := hash_id("declared")
	render_view(r, View_Scroll{id = id2, size = {300, 200}, content = &wide}, {0, 0}, {300, 200})
	testing.expect_value(t, ws.states[id2].content_h, f32(24))
}

@(test)
virtual_list_variable_measures_at_viewport_width :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	r := fw_renderer(&ws)
	defer fw_free(r)
	th := theme_dark()
	input: Input
	widget_store_begin_frame(&ws, input)
	ctx := Ctx(FW_Msg){theme = &th, widgets = &ws, input = &input, renderer = r}

	row :: proc(ctx: ^Ctx(FW_Msg), s: int, i: int) -> View { return fw_chips() }
	id := hash_id("vlv")
	_ = virtual_list_variable(&ctx, 0, 3, {300, 200}, row, nil, id, 0, 40, {}, {}, 30, 30, false, -1)

	heights := ws.states[id].virtual_heights
	testing.expect(t, heights != nil && len(heights^) >= 1, "heights cached")
	// Measured at the 300 px row width (wrapped), not the 654 px natural width.
	testing.expect_value(t, heights^[0], f32(84))
}
