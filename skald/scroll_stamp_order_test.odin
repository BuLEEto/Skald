package skald

// Reproduction for the dropdown-wheel bug: nested-scroll wheel routing
// assumes the stamp order in `scroll_rects` runs outer → inner, and picks
// the last-stamped rect under the cursor as the innermost scroller.
//
// That holds only when every scroller in the chain resolves at the same
// stage. A fill-mode scroll — scroll(ctx, {0,0}, ...) — defers through
// `sized`, so its scroll_advance runs during layout, AFTER an inner
// fixed-size scroll built as one of its own arguments has already
// stamped. The list then reads inner → outer, the backwards scan finds
// the OUTER rect first, and the inner scroller never claims the wheel.

import "core:testing"

@(private = "file")
SO_Msg :: distinct int

@(private = "file")
seed :: proc(ws: ^Widget_Store, id: Widget_ID, vp: Rect, content_h: f32) {
	ws.states[id] = Widget_State{
		kind = .Scroll, last_rect = vp, last_frame = ws.frame, content_h = content_h,
	}
}

// Runs one frame: stamps the two viewports in the given order, then swaps
// so the next frame's routing consults them. Returns whether the inner
// scroller claimed the wheel on the following frame.
@(private = "file")
inner_claims :: proc(outer_first: bool) -> bool {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	outer := hash_id("panel-scroll")
	inner := hash_id("dropdown-scroll")

	// The dropdown sits inside the panel, so both contain the cursor.
	outer_vp := Rect{0, 0, 600, 800}
	inner_vp := Rect{100, 200, 300, 240}
	content: f32 = 5000

	seed(&ws, outer, outer_vp, content)
	seed(&ws, inner, inner_vp, content)

	input: Input
	ctx := Ctx(SO_Msg){widgets = &ws, input = &input}

	// Frame 1: no wheel, just publish the viewports in the order under test.
	input = Input{mouse_pos = {200, 300}, scroll = {0, 0}}
	if outer_first {
		_, _ = scroll_advance(&ctx, outer, content, 40)
		_, _ = scroll_advance(&ctx, inner, content, 40)
	} else {
		_, _ = scroll_advance(&ctx, inner, content, 40)
		_, _ = scroll_advance(&ctx, outer, content, 40)
	}

	ws.scroll_rects, ws.scroll_rects_prev = ws.scroll_rects_prev, ws.scroll_rects
	clear(&ws.scroll_rects)
	ws.frame += 1
	seed(&ws, outer, outer_vp, content)
	seed(&ws, inner, inner_vp, content)

	// Frame 2: wheel with the cursor over the dropdown.
	input = Input{mouse_pos = {200, 300}, scroll = {0, -1}}
	st, _ := scroll_advance(&ctx, inner, content, 40)
	return st.scroll_y != 0
}

@(test)
nested_wheel_goes_to_inner_when_outer_stamps_first :: proc(t: ^testing.T) {
	// The order the routing was written for.
	testing.expect(t, inner_claims(outer_first = true),
		"inner scroller should claim the wheel when stamps run outer -> inner")
}

@(test)
nested_wheel_lost_when_inner_stamps_first :: proc(t: ^testing.T) {
	// The order a fill-mode outer scroll actually produces.
	testing.expect(t, inner_claims(outer_first = false),
		"inner scroller should claim the wheel regardless of stamp order")
}
