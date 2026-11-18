package skald

import "core:testing"

// `scroll(..., horizontal = true)`: x-wheel and Shift+wheel pan sideways,
// clamped to the content width; and horizontal stamps must not block the
// vertical wheel from reaching an outer scroller.

@(private = "file")
HS_Msg :: distinct int

@(private = "file")
hs_seed :: proc(ws: ^Widget_Store, id: Widget_ID, vp: Rect, cw, ch: f32) {
	ws.states[id] = Widget_State{
		kind = .Scroll, last_rect = vp, last_frame = ws.frame, content_w = cw, content_h = ch,
	}
}

@(test)
horizontal_scroll_wheel_and_clamp :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("hs")
	vp := Rect{0, 0, 300, 200}
	hs_seed(&ws, id, vp, 900, 200)
	input := Input{mouse_pos = {150, 100}, scroll = {1, 0}}
	ctx := Ctx(HS_Msg){widgets = &ws, input = &input}

	// x-wheel right → pans right one step, and the delta is consumed.
	st, _ := scroll_advance_x(&ctx, id, 900, 40, 0, 0)
	testing.expect_value(t, st.scroll_x, f32(40))
	testing.expect_value(t, input.scroll.x, f32(0))

	// Shift+wheel-down (diverted by the builder as shift_y) also pans right.
	input = Input{mouse_pos = {150, 100}}
	st, _ = scroll_advance_x(&ctx, id, 900, 40, -1, 0)
	testing.expect_value(t, st.scroll_x, f32(80))

	// Overscroll clamps to content_w - viewport width.
	input = Input{mouse_pos = {150, 100}, scroll = {100, 0}}
	st, _ = scroll_advance_x(&ctx, id, 900, 40, 0, 0)
	testing.expect_value(t, st.scroll_x, f32(600))
}

@(test)
horizontal_stamp_does_not_block_outer_vertical_wheel :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	outer := hash_id("page")
	inner := hash_id("wide-table")
	outer_vp := Rect{0, 0, 600, 800}
	inner_vp := Rect{100, 200, 300, 200} // wide but not tall: horizontal only

	hs_seed(&ws, outer, outer_vp, 600, 5000)
	hs_seed(&ws, inner, inner_vp, 900, 200)
	input := Input{mouse_pos = {200, 300}}
	ctx := Ctx(HS_Msg){widgets = &ws, input = &input}

	// Frame 1: publish stamps (outer vertical, inner horizontal).
	_, _ = scroll_advance(&ctx, outer, 5000, 40)
	_, _ = scroll_advance_x(&ctx, inner, 900, 40, 0, 0)
	ws.scroll_rects, ws.scroll_rects_prev = ws.scroll_rects_prev, ws.scroll_rects
	clear(&ws.scroll_rects)
	ws.frame += 1
	hs_seed(&ws, outer, outer_vp, 600, 5000)
	hs_seed(&ws, inner, inner_vp, 900, 200)

	// Frame 2: plain vertical wheel over the wide table → the page scrolls.
	input = Input{mouse_pos = {200, 300}, scroll = {0, -1}}
	st, _ := scroll_advance(&ctx, outer, 5000, 40)
	testing.expect(t, st.scroll_y != 0, "vertical wheel over a horizontal-only scroller reaches the outer page")
}

@(test)
shift_wheel_passes_inner_vertical_to_horizontal :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	outer := hash_id("h-scroll")   // wide: horizontal
	inner := hash_id("table-body") // tall: vertical, inside it
	outer_vp := Rect{0, 0, 520, 300}
	inner_vp := Rect{0, 32, 520, 248}
	hs_seed(&ws, inner, inner_vp, 520, 1000)
	append(&ws.scroll_rects_prev, Scroll_Rect{id = outer, rect = outer_vp, h = true})

	input := Input{mouse_pos = {200, 150}, scroll = {0, -1}, modifiers = {.Shift}}
	ctx := Ctx(HS_Msg){widgets = &ws, input = &input}

	// Shift held over a horizontal scroller: the inner row-scroller leaves the
	// wheel for it instead of scrolling rows.
	st, _ := scroll_advance(&ctx, inner, 1000, 40)
	testing.expect_value(t, st.scroll_y, f32(0))
	testing.expect_value(t, input.scroll.y, f32(-1))

	// Without Shift it scrolls rows as before.
	input = Input{mouse_pos = {200, 150}, scroll = {0, -1}}
	st, _ = scroll_advance(&ctx, inner, 1000, 40)
	testing.expect(t, st.scroll_y > 0, "plain wheel still scrolls the rows")
}
