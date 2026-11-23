package skald

import "core:testing"

// Fixed columns wider than a table scroll it sideways: the body becomes a
// two-axis scroll and the header pans with it (a clip offset by scroll_x).
// Columns that fit leave the table exactly as before.

@(private = "file")
HS_Msg :: distinct int

@(private = "file")
hs_cell :: proc(ctx: ^Ctx(HS_Msg), s: int, row: int) -> []View {
	cells := make([]View, 4, context.temp_allocator)
	for &c in cells { c = text("cell", {1, 1, 1, 1}, 14) }
	return cells
}

@(private = "file")
hs_parts :: proc(v: View) -> (header: View, body: View_Scroll) {
	stack := v.(View_Stack)
	return stack.children[0], stack.children[1].(View_Scroll)
}

@(test)
table_scrolls_wide_columns_sideways :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	input: Input
	msgs: [dynamic]HS_Msg
	defer delete(msgs)
	widget_store_begin_frame(&ws, input)
	ctx := Ctx(HS_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs}

	wide := []Table_Column{{width = 300}, {width = 300}, {width = 300}, {width = 300}}
	vp := [2]f32{680, 300}

	// Last frame left the body (below a 32 px header) panned 100 px right.
	id := hash_id("hs-table")
	ws.states[widget_resolve_id(&ctx, id)] = Widget_State{
		kind = .Scroll, last_rect = {0, 32, vp.x, vp.y - 32}, scroll_x = 100, last_frame = ws.frame,
	}
	header, body := hs_parts(table(&ctx, 0, wide, 100, 28, vp, hs_cell, nil, nil, nil, nil, nil, nil, id = id))
	testing.expect(t, body.horizontal, "wide columns make the body scroll sideways")
	testing.expect_value(t, body.offset_x, f32(100))
	clip, is_clip := header.(View_Clip)
	testing.expect(t, is_clip, "the header pans inside a clip")
	testing.expect_value(t, clip.offset.x, f32(100))
	testing.expect_value(t, clip.size.x, vp.x - SCROLL_BAR_GUTTER) // ends where the body's clip does

	// Columns that fit: no horizontal scroll, header is the plain row.
	fit := []Table_Column{{width = 150}, {width = 150}, {width = 150}, {width = 150}}
	header, body = hs_parts(table(&ctx, 0, fit, 100, 28, vp, hs_cell, nil, nil, nil, nil, nil, nil, id = hash_id("hs-fit")))
	testing.expect(t, !body.horizontal, "columns that fit keep a vertical-only body")
	_, is_row := header.(View_Stack)
	testing.expect(t, is_row, "a fitting header is not clipped")
}
