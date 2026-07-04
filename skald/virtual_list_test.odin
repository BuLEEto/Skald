package skald

// White-box tests for virtual_list's reveal_row (req 029): passing a row
// index scrolls the minimal amount to bring it into view, gated on *change*
// so a steady value never fights the user's manual scroll — the same knob
// (and discipline) `table` has. Driven headlessly: the fixed-height path is
// pure View construction + scroll-store math (no renderer), so we call the
// public proc and read the offset back off the .Scroll slot.

import "core:testing"

@(private = "file")
VL_Msg :: distinct int

@(private = "file")
vl_row :: proc(ctx: ^Ctx(VL_Msg), s: int, i: int) -> View {
	return spacer(20)
}

@(private = "file")
vl_row30 :: proc(ctx: ^Ctx(VL_Msg), s: int, i: int) -> View {
	return spacer(30)
}

// A 200px-tall viewport over 100 rows of 20px = 2000px content, max_off 1800.
@(private = "file") VL_VP :: [2]f32{100, 200}
@(private = "file") VL_N  :: 100
@(private = "file") VL_IH :: f32(20)

// theme is a ^Theme on Ctx and virtual_list dereferences it for the
// track/thumb colour fallback, so a headless ctx must point at a real one.
@(private = "file")
vl_ctx :: proc(ws: ^Widget_Store, input: ^Input, theme: ^Theme) -> Ctx(VL_Msg) {
	return Ctx(VL_Msg){widgets = ws, input = input, theme = theme}
}

@(test)
virtual_list_reveal_scrolls_below_into_view :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	input: Input
	th := theme_dark()
	ctx := vl_ctx(&ws, &input, &th)

	id := hash_id("vl-below")
	// Row 50 sits at [1000,1020], well below the [0,200] fold → scroll down
	// the minimum: bottom(1020) - vp(200) = 820.
	virtual_list(&ctx, 0, VL_N, VL_IH, VL_VP, vl_row, nil, id = id, reveal_row = 50)

	st := widget_get(&ctx, id, .Scroll)
	testing.expect_value(t, st.scroll_y, f32(820))
	testing.expect_value(t, st.reveal_marker, 51)
}

@(test)
virtual_list_reveal_scrolls_above_into_view :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	input: Input
	th := theme_dark()
	ctx := vl_ctx(&ws, &input, &th)

	id := hash_id("vl-above")
	// Already scrolled to 1000; reveal row 5 (top 100) is above the fold →
	// scroll up so its top is flush: 100.
	ws.states[id] = Widget_State{kind = .Scroll, scroll_y = 1000, last_frame = ws.frame}
	virtual_list(&ctx, 0, VL_N, VL_IH, VL_VP, vl_row, nil, id = id, reveal_row = 5)

	st := widget_get(&ctx, id, .Scroll)
	testing.expect_value(t, st.scroll_y, f32(100))
	testing.expect_value(t, st.reveal_marker, 6)
}

@(test)
virtual_list_reveal_last_row_clamps :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	input: Input
	th := theme_dark()
	ctx := vl_ctx(&ws, &input, &th)

	id := hash_id("vl-last")
	// Row 99 at [1980,2000]; bottom-vp = 1800, exactly max_off → clean clamp.
	virtual_list(&ctx, 0, VL_N, VL_IH, VL_VP, vl_row, nil, id = id, reveal_row = 99)

	st := widget_get(&ctx, id, .Scroll)
	testing.expect_value(t, st.scroll_y, f32(1800))
}

@(test)
virtual_list_reveal_change_gated :: proc(t: ^testing.T) {
	// The core discipline: a *steady* reveal_row must not re-snap the
	// viewport, so manual scroll between reveals sticks.
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	input: Input
	th := theme_dark()
	ctx := vl_ctx(&ws, &input, &th)

	id := hash_id("vl-gated")

	// Frame 1: reveal row 50 → snaps to 820, marks 51.
	virtual_list(&ctx, 0, VL_N, VL_IH, VL_VP, vl_row, nil, id = id, reveal_row = 50)
	testing.expect_value(t, widget_get(&ctx, id, .Scroll).scroll_y, f32(820))

	// User wheels back up to 300 (poke the slot as the render pass would).
	st := ws.states[id]
	st.scroll_y = 300
	ws.states[id] = st

	// Frame 2: same reveal_row 50 (unchanged) → marker already 51, no re-snap.
	ws.frame = 2
	virtual_list(&ctx, 0, VL_N, VL_IH, VL_VP, vl_row, nil, id = id, reveal_row = 50)
	testing.expect_value(t, widget_get(&ctx, id, .Scroll).scroll_y, f32(300))
}

@(test)
virtual_list_variable_reveal_uses_prefix_sum :: proc(t: ^testing.T) {
	// The variable-height path reveals via the prefix sum of cached
	// heights. All rows are spacer(30) so view_size measures them without
	// a renderer, and every height resolves to 30 (== estimate).
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	input: Input
	th := theme_dark()
	ctx := vl_ctx(&ws, &input, &th)

	id := hash_id("vl-var")
	// Row 50 top = 50*30 = 1500, bottom 1530 → scroll_y = 1530 - vp(200) = 1330.
	virtual_list(&ctx, 0, VL_N, 0, VL_VP, vl_row30, nil,
		id = id, variable_height = true, estimated_height = 30, reveal_row = 50)

	st := widget_get(&ctx, id, .Scroll)
	testing.expect_value(t, st.scroll_y, f32(1330))
	testing.expect_value(t, st.reveal_marker, 51)
}

@(test)
virtual_list_reveal_negative_is_noop :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	input: Input
	th := theme_dark()
	ctx := vl_ctx(&ws, &input, &th)

	id := hash_id("vl-noop")
	// Default -1 must leave the offset untouched — byte-identical to today.
	virtual_list(&ctx, 0, VL_N, VL_IH, VL_VP, vl_row, nil, id = id, reveal_row = -1)

	st := widget_get(&ctx, id, .Scroll)
	testing.expect_value(t, st.scroll_y, f32(0))
	testing.expect_value(t, st.reveal_marker, 0)
}
