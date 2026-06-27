package skald

// White-box tests for scroll_advance's offset persistence (req 024): the
// wheel / page paths accumulate scroll_y unclamped, so the value written back
// through widget_set must be clamped to [0, content_h - viewport_h] — otherwise
// overscroll sticks ("dead wheel") and an app that pokes scroll_y to jump to the
// end reads back out of range forever. Driven headlessly: seed a .Scroll slot
// with a viewport rect (the render pass's job in a real app) and call the
// private scroll_advance directly.

import "core:testing"

@(private = "file")
SC_Msg :: distinct int

@(private = "file")
seed_scroll :: proc(ws: ^Widget_Store, id: Widget_ID, vp: Rect, scroll_y, content_h: f32) {
	ws.states[id] = Widget_State{
		kind       = .Scroll,
		last_rect  = vp,
		last_frame = ws.frame,
		scroll_y   = scroll_y,
		content_h  = content_h,
	}
}

@(test)
scroll_advance_clamps_overscroll :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("scroll-overscroll")
	vp := Rect{0, 0, 100, 200}        // 200px-tall viewport
	content_h: f32 = 1000             // max_off = 1000 - 200 = 800
	wheel_step: f32 = 40
	seed_scroll(&ws, id, vp, 0, content_h)

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}

	// Wheel DOWN hard from the top (scroll.y < 0 reveals content below =
	// increases offset): 100 notches * 40 = +4000, must clamp to 800, not stick.
	input = Input{mouse_pos = {50, 100}, scroll = {0, -100}}
	st, _ := scroll_advance(&ctx, id, content_h, wheel_step)
	testing.expect_value(t, st.scroll_y, f32(800))
	testing.expect_value(t, widget_get(&ctx, id, .Scroll).scroll_y, f32(800))

	// Wheel UP hard from the bottom: 800 - 4000 = -3200, must clamp to 0.
	ws.frame += 1
	input = Input{mouse_pos = {50, 100}, scroll = {0, 100}}
	st2, _ := scroll_advance(&ctx, id, content_h, wheel_step)
	testing.expect_value(t, st2.scroll_y, f32(0))
	testing.expect_value(t, widget_get(&ctx, id, .Scroll).scroll_y, f32(0))
}

@(test)
scroll_advance_clamps_app_set_sentinel :: proc(t: ^testing.T) {
	// The chat-auto-scroll case from req 024: an app pokes scroll_y to a huge
	// sentinel to "snap to the bottom", relying on a render-time clamp. Before
	// the fix the stored value stayed huge — it read back as permanently
	// at-bottom and the wheel could never bring it back. scroll_advance must
	// clamp the stored offset to the real bottom even with no wheel/page input.
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("scroll-sentinel")
	vp := Rect{0, 0, 100, 200}
	content_h: f32 = 1000             // max_off = 800
	seed_scroll(&ws, id, vp, 1e9, content_h)

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}

	input = Input{mouse_pos = {999, 999}} // pointer nowhere near it; no input
	st, _ := scroll_advance(&ctx, id, content_h, 40)
	testing.expect_value(t, st.scroll_y, f32(800))
	testing.expect_value(t, widget_get(&ctx, id, .Scroll).scroll_y, f32(800))
}

@(test)
scroll_advance_zero_when_content_fits :: proc(t: ^testing.T) {
	// Content shorter than the viewport → no scroll room → stored offset 0,
	// even if a stale value was left over (e.g. content shrank this frame).
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("scroll-fits")
	vp := Rect{0, 0, 100, 200}
	seed_scroll(&ws, id, vp, 150, 120)   // content_h 120 < viewport 200

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}

	input = Input{mouse_pos = {50, 100}}
	st, _ := scroll_advance(&ctx, id, 120, 40)
	testing.expect_value(t, st.scroll_y, f32(0))
}
