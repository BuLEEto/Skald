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

// White-box tests for scroll_reveal_focus (req 027): the scroll brings its
// keyboard-focused descendant into view on focus change. A descendant is
// recognised by its recorded clip_rect being contained in the viewport (it
// rendered under the scroll's pushed clip) — no widget hierarchy needed.
// Driven headlessly: seed the focused widget's geometry + the scroll's state,
// set focused_id, call the private proc.

@(private = "file") RF_SCROLL :: Rect{0, 0, 100, 200} // 200px-tall viewport at origin
@(private = "file") RF_CONTENT :: f32(1000)           // content taller than vp → max_off 800

@(private = "file")
seed_focusable :: proc(ws: ^Widget_Store, id: Widget_ID, last_rect, clip_rect: Rect) {
	// kind is irrelevant — scroll_reveal_focus reads the slot directly, never
	// via widget_get (which would reset on a kind mismatch).
	ws.states[id] = Widget_State{
		kind       = .Button,
		last_rect  = last_rect,
		clip_rect  = clip_rect,
		last_frame = ws.frame,
	}
}

@(test)
scroll_reveal_focus_reveals_below :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	sid := hash_id("rf-scroll-below")
	fid := hash_id("rf-child-below")
	// Child rendered last frame fully below the 200px fold (absolute y 500),
	// clip_rect == viewport marks it a descendant.
	seed_focusable(&ws, fid, Rect{0, 500, 100, 30}, RF_SCROLL)
	ws.focused_id = fid

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}
	in_st := Widget_State{kind = .Scroll, last_rect = RF_SCROLL, last_frame = ws.frame, content_h = RF_CONTENT}
	ws.states[sid] = in_st

	out := scroll_reveal_focus(&ctx, sid, in_st, 0, RF_CONTENT)
	// bottom(530) + margin(8) - vp.h(200) = 338
	testing.expect_value(t, out.scroll_y, f32(338))
	testing.expect_value(t, out.reveal_focus_id, fid)
	testing.expect_value(t, widget_get(&ctx, sid, .Scroll).scroll_y, f32(338))
}

@(test)
scroll_reveal_focus_reveals_above :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	sid := hash_id("rf-scroll-above")
	fid := hash_id("rf-child-above")
	// Scrolled to 400; child sits at content y 100, above the visible
	// [400,600] window — rendered last frame at absolute y = -300.
	seed_focusable(&ws, fid, Rect{0, -300, 100, 30}, RF_SCROLL)
	ws.focused_id = fid

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}
	in_st := Widget_State{kind = .Scroll, last_rect = RF_SCROLL, last_frame = ws.frame, scroll_y = 400, content_h = RF_CONTENT}
	ws.states[sid] = in_st

	out := scroll_reveal_focus(&ctx, sid, in_st, 400, RF_CONTENT)
	// top = -300 + 400 = 100; top - margin(8) = 92
	testing.expect_value(t, out.scroll_y, f32(92))
	testing.expect_value(t, out.reveal_focus_id, fid)
}

@(test)
scroll_reveal_focus_steady_focus_holds :: proc(t: ^testing.T) {
	// Focus already acknowledged → don't re-snap, even though the child is
	// off-screen. This is what lets the user wheel a focused control out of
	// view without the scroll fighting back.
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	sid := hash_id("rf-scroll-steady")
	fid := hash_id("rf-child-steady")
	seed_focusable(&ws, fid, Rect{0, 500, 100, 30}, RF_SCROLL)
	ws.focused_id = fid

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}
	in_st := Widget_State{kind = .Scroll, last_rect = RF_SCROLL, last_frame = ws.frame, content_h = RF_CONTENT, reveal_focus_id = fid}
	ws.states[sid] = in_st

	out := scroll_reveal_focus(&ctx, sid, in_st, 0, RF_CONTENT)
	testing.expect_value(t, out.scroll_y, f32(0))
}

@(test)
scroll_reveal_focus_ignores_non_descendant :: proc(t: ^testing.T) {
	// Focused widget lives in another container (clip_rect not within the
	// viewport) → not ours → scroll unchanged, but acknowledged so we don't
	// keep re-checking it.
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	sid := hash_id("rf-scroll-other")
	fid := hash_id("rf-child-other")
	seed_focusable(&ws, fid, Rect{500, 500, 100, 30}, Rect{400, 0, 200, 200})
	ws.focused_id = fid

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}
	in_st := Widget_State{kind = .Scroll, last_rect = RF_SCROLL, last_frame = ws.frame, content_h = RF_CONTENT}
	ws.states[sid] = in_st

	out := scroll_reveal_focus(&ctx, sid, in_st, 0, RF_CONTENT)
	testing.expect_value(t, out.scroll_y, f32(0))
	testing.expect_value(t, out.reveal_focus_id, fid)
}

@(test)
scroll_reveal_focus_visible_child_no_scroll :: proc(t: ^testing.T) {
	// Descendant already fully inside the viewport → no movement, but the
	// focus target is acknowledged so re-focusing it later doesn't re-snap.
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	sid := hash_id("rf-scroll-visible")
	fid := hash_id("rf-child-visible")
	seed_focusable(&ws, fid, Rect{0, 50, 100, 30}, RF_SCROLL) // at content y 50, inside [0,200]
	ws.focused_id = fid

	input: Input
	ctx := Ctx(SC_Msg){widgets = &ws, input = &input}
	in_st := Widget_State{kind = .Scroll, last_rect = RF_SCROLL, last_frame = ws.frame, content_h = RF_CONTENT}
	ws.states[sid] = in_st

	out := scroll_reveal_focus(&ctx, sid, in_st, 0, RF_CONTENT)
	testing.expect_value(t, out.scroll_y, f32(0))
	testing.expect_value(t, out.reveal_focus_id, fid)
}
