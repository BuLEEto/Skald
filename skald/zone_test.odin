package skald

// White-box tests for the `zone` interaction-query layer: widget_clicked
// (release-based), widget_pressed (press edge), widget_active (held),
// widget_click_count. Driven headlessly — no renderer needed; we seed the
// zone's last_rect (the render pass's job in a real app) and feed synthetic
// input frames. Frame N's state must survive into N+1, so frames stay
// consecutive and the slot keeps kind = .Click_Zone.

import "core:testing"

@(private = "file")
Z_Msg :: distinct int

// Seed a Click_Zone slot with a known rect so widget_hovered works, and
// stamp last_frame so the first zone() call doesn't reset it.
@(private = "file")
seed_zone :: proc(ws: ^Widget_Store, id: Widget_ID, rect: Rect) {
	ws.states[id] = Widget_State{
		kind       = .Click_Zone,
		last_rect  = rect,
		last_frame = ws.frame,
	}
}

// Advance to the next frame the way the real loop would.
@(private = "file")
next_frame :: proc(ws: ^Widget_Store) { ws.frame += 1 }

@(test)
zone_click_is_release_based :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("z-click")
	area := Rect{10, 10, 100, 40}
	seed_zone(&ws, id, area)

	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input}

	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Frame 1: press inside. Held, but not yet clicked.
	input = Input{mouse_pos = {30, 25}}
	input.mouse_pressed[.Left]    = true
	input.mouse_buttons[.Left]    = true
	input.mouse_click_count[.Left] = 1
	zone(&ctx, dummy, id)
	testing.expect(t, widget_active(&ctx, id, .Left), "held after press")
	testing.expect(t, !widget_clicked(&ctx, id, .Left), "no click until release")
	testing.expect(t, widget_pressed(&ctx, id, .Left), "press edge true on the press frame")

	// Frame 2: release inside → completed click.
	next_frame(&ws)
	input = Input{mouse_pos = {30, 25}}
	input.mouse_released[.Left] = true
	zone(&ctx, dummy, id)
	testing.expect(t, widget_clicked(&ctx, id, .Left), "click fires on release inside")
	testing.expect(t, !widget_active(&ctx, id, .Left), "latch cleared after release")
	testing.expect(t, !widget_pressed(&ctx, id, .Left), "press edge false on release frame")
	testing.expect_value(t, widget_click_count(&ctx, id, .Left), 1)
}

@(test)
zone_press_drag_off_does_not_click :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("z-dragoff")
	area := Rect{10, 10, 100, 40}
	seed_zone(&ws, id, area)

	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Press inside.
	input = Input{mouse_pos = {30, 25}}
	input.mouse_pressed[.Left] = true
	input.mouse_buttons[.Left] = true
	zone(&ctx, dummy, id)
	testing.expect(t, widget_active(&ctx, id, .Left), "held after press inside")

	// Release OUTSIDE the rect → must NOT count as a click.
	next_frame(&ws)
	input = Input{mouse_pos = {500, 500}}
	input.mouse_released[.Left] = true
	zone(&ctx, dummy, id)
	testing.expect(t, !widget_clicked(&ctx, id, .Left),
		"release outside the zone must not fire a click")
	testing.expect(t, !widget_active(&ctx, id, .Left), "latch cleared")
}

@(test)
zone_buttons_are_independent :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("z-buttons")
	seed_zone(&ws, id, Rect{0, 0, 50, 50})

	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Right-press inside: widget_pressed(.Right) true, left untouched.
	input = Input{mouse_pos = {25, 25}}
	input.mouse_pressed[.Right] = true
	input.mouse_buttons[.Right] = true
	zone(&ctx, dummy, id)
	testing.expect(t, widget_pressed(&ctx, id, .Right), "right press edge")
	testing.expect(t, !widget_pressed(&ctx, id, .Left), "left not pressed")
	testing.expect(t, !widget_clicked(&ctx, id, .Left), "left not clicked")

	// Right release inside → right click fires, left still nothing.
	next_frame(&ws)
	input = Input{mouse_pos = {25, 25}}
	input.mouse_released[.Right] = true
	zone(&ctx, dummy, id)
	testing.expect(t, widget_clicked(&ctx, id, .Right), "right click fires")
	testing.expect(t, !widget_clicked(&ctx, id, .Left), "left stays silent")
}

@(test)
zone_double_click_count :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("z-double")
	seed_zone(&ws, id, Rect{0, 0, 50, 50})

	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Press reporting a streak of 2 (SDL double-click), then release.
	input = Input{mouse_pos = {25, 25}}
	input.mouse_pressed[.Left]     = true
	input.mouse_buttons[.Left]     = true
	input.mouse_click_count[.Left] = 2
	zone(&ctx, dummy, id)

	next_frame(&ws)
	input = Input{mouse_pos = {25, 25}}
	input.mouse_released[.Left] = true
	zone(&ctx, dummy, id)

	testing.expect(t, widget_clicked(&ctx, id, .Left), "double-click still a click")
	testing.expect_value(t, widget_click_count(&ctx, id, .Left), 2)
}

@(test)
zone_blocked_behind_modal :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	// frame >= 2 so prev_frame != the default last_overlay_frame (0); at
	// frame 1 an unstamped widget would falsely read as overlay-stamped.
	ws.frame = 5

	id := hash_id("z-modal")
	seed_zone(&ws, id, Rect{0, 0, 50, 50})
	ws.modal_rect_prev = Rect{0, 0, 800, 600} // a modal was open last frame

	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Press + release squarely inside the zone's rect — but it's a main-tree
	// widget behind a modal, so widget_hovered z-blocks it and nothing fires.
	input = Input{mouse_pos = {25, 25}}
	input.mouse_pressed[.Left] = true
	input.mouse_buttons[.Left] = true
	zone(&ctx, dummy, id)
	testing.expect(t, !widget_active(&ctx, id, .Left), "press behind modal must not latch")
	testing.expect(t, !widget_pressed(&ctx, id, .Left), "press edge z-blocked by modal")

	next_frame(&ws)
	input = Input{mouse_pos = {25, 25}}
	input.mouse_released[.Left] = true
	zone(&ctx, dummy, id)
	testing.expect(t, !widget_clicked(&ctx, id, .Left), "click behind modal must not fire")
}

@(test)
clickable_sends_on_left_release :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("c-left")
	seed_zone(&ws, id, Rect{0, 0, 50, 50})

	msgs: [dynamic]Z_Msg
	defer delete(msgs)
	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input, msgs = &msgs}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Left press alone fires nothing (release-based)...
	input = Input{mouse_pos = {25, 25}}
	input.mouse_pressed[.Left] = true
	input.mouse_buttons[.Left] = true
	clickable(&ctx, dummy, Z_Msg(1), id = id)
	testing.expect_value(t, len(msgs), 0)

	// ...release inside fires on_click once.
	next_frame(&ws)
	input = Input{mouse_pos = {25, 25}}
	input.mouse_released[.Left] = true
	clickable(&ctx, dummy, Z_Msg(1), id = id)
	testing.expect_value(t, len(msgs), 1)
	if len(msgs) == 1 { testing.expect_value(t, msgs[0], Z_Msg(1)) }

	// Right-click does nothing on a clickable (left-only by design).
	clear(&msgs)
	next_frame(&ws)
	input = Input{mouse_pos = {25, 25}}
	input.mouse_pressed[.Right] = true
	input.mouse_buttons[.Right] = true
	clickable(&ctx, dummy, Z_Msg(1), id = id)
	testing.expect_value(t, len(msgs), 0)
}

@(test)
clickable_lr_right_fires :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("c-lr")
	seed_zone(&ws, id, Rect{0, 0, 50, 50})

	msgs: [dynamic]Z_Msg
	defer delete(msgs)
	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input, msgs = &msgs}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// The 4-arg form (proc-group dispatch to clickable_lr): right-press fires
	// on_right_click, left untouched.
	input = Input{mouse_pos = {25, 25}}
	input.mouse_pressed[.Right] = true
	input.mouse_buttons[.Right] = true
	clickable(&ctx, dummy, Z_Msg(1), Z_Msg(2), id = id)
	testing.expect_value(t, len(msgs), 1)
	if len(msgs) == 1 { testing.expect_value(t, msgs[0], Z_Msg(2)) }
}

@(test)
clickable_keyboard_activates :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("c-kbd")
	seed_zone(&ws, id, Rect{0, 0, 50, 50})

	msgs: [dynamic]Z_Msg
	defer delete(msgs)
	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input, msgs = &msgs}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Focused, no mouse, Space pressed → on_click fires (keyboard a11y).
	ws.focused_id = id
	input = Input{mouse_pos = {999, 999}} // pointer nowhere near it
	input.keys_pressed += {.Space}
	clickable(&ctx, dummy, Z_Msg(7), id = id)
	testing.expect_value(t, len(msgs), 1)
	if len(msgs) == 1 { testing.expect_value(t, msgs[0], Z_Msg(7)) }
}

@(test)
clickable_disabled_is_inert :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	id := hash_id("c-disabled")
	seed_zone(&ws, id, Rect{0, 0, 50, 50})

	msgs: [dynamic]Z_Msg
	defer delete(msgs)
	input: Input
	ctx := Ctx(Z_Msg){widgets = &ws, input = &input, msgs = &msgs}
	dummy := rect({1, 1}, Color{0, 0, 0, 0})

	// Press then release inside, but disabled → nothing sends.
	input = Input{mouse_pos = {25, 25}}
	input.mouse_pressed[.Left] = true
	input.mouse_buttons[.Left] = true
	clickable(&ctx, dummy, Z_Msg(1), id = id, disabled = true)
	next_frame(&ws)
	input = Input{mouse_pos = {25, 25}}
	input.mouse_released[.Left] = true
	clickable(&ctx, dummy, Z_Msg(1), id = id, disabled = true)
	testing.expect_value(t, len(msgs), 0)
}
