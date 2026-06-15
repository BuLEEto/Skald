package skald

// White-box tests for in-window drag & drop (request 012 Layer 1). Driven
// headlessly like zone_test: seed each widget's last_rect (the render pass's
// job in a real app), keep frames consecutive, and call the builders every
// frame so widget_get doesn't reap the slot. The run-loop hooks (Esc cancel,
// release-over-nothing cancel, ghost render) live in `run` and are exercised
// interactively, not here — these cover the gesture core: threshold start,
// payload carry, release-point drop, and accept-kind filtering.

import "core:testing"

@(private = "file")
DD_Msg :: distinct int

@(private = "file")
seed :: proc(ws: ^Widget_Store, id: Widget_ID, r: Rect) {
	ws.states[id] = Widget_State{kind = .Click_Zone, last_rect = r, last_frame = ws.frame}
}

@(private = "file")
on_drop_id :: proc(p: Drag_Payload) -> DD_Msg { return DD_Msg(int(p.id)) }

@(test)
drag_source_begins_after_threshold :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	src := hash_id("dd-src")
	seed(&ws, src, Rect{0, 0, 100, 40})

	input: Input
	ctx := Ctx(DD_Msg){widgets = &ws, input = &input}
	dummy := rect({1, 1}, Color{})
	payload := Drag_Payload{kind = "file", id = 42}

	// Press inside arms but does not yet start a drag.
	input = Input{mouse_pos = {20, 20}}
	input.mouse_pressed[.Left] = true
	input.mouse_buttons[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	testing.expect(t, !ws.drag.active, "press alone does not start a drag")

	// Move past the 5px threshold while held → drag begins, payload carried,
	// pointer captured on the source.
	ws.frame += 1
	input = Input{mouse_pos = {40, 20}} // dx = 20 > 5
	input.mouse_buttons[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	testing.expect(t, ws.drag.active, "drag begins after threshold movement")
	testing.expect_value(t, ws.drag.payload_kind, "file")
	testing.expect_value(t, ws.drag.payload_id, u64(42))
	testing.expect_value(t, ws.pointer_capture_id, src)
}

@(test)
drop_target_fires_on_release_over_it :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	src := hash_id("dd-src2")
	tgt := hash_id("dd-tgt2")
	seed(&ws, src, Rect{0, 0, 100, 40})
	seed(&ws, tgt, Rect{200, 0, 100, 40})

	msgs: [dynamic]DD_Msg
	defer delete(msgs)
	input: Input
	ctx := Ctx(DD_Msg){widgets = &ws, input = &input, msgs = &msgs}
	dummy := rect({1, 1}, Color{})
	payload := Drag_Payload{kind = "file", id = 7}

	// Frame 1: press in the source.
	input = Input{mouse_pos = {20, 20}}
	input.mouse_pressed[.Left] = true
	input.mouse_buttons[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	drop_target(&ctx, dummy, on_drop_id, id = tgt, accepts = "file")

	// Frame 2: threshold move → drag active.
	ws.frame += 1
	input = Input{mouse_pos = {40, 20}}
	input.mouse_buttons[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	drop_target(&ctx, dummy, on_drop_id, id = tgt, accepts = "file")
	testing.expect(t, ws.drag.active, "drag active after threshold")

	// Frame 3: hover the target, still held — no drop yet.
	ws.frame += 1
	input = Input{mouse_pos = {240, 20}}
	input.mouse_buttons[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	drop_target(&ctx, dummy, on_drop_id, id = tgt, accepts = "file")
	testing.expect_value(t, len(msgs), 0)

	// Frame 4: release over the target → on_drop fires once with the payload
	// id, and the drag ends.
	ws.frame += 1
	input = Input{mouse_pos = {240, 20}}
	input.mouse_released[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	drop_target(&ctx, dummy, on_drop_id, id = tgt, accepts = "file")
	testing.expect_value(t, len(msgs), 1)
	if len(msgs) == 1 { testing.expect_value(t, msgs[0], DD_Msg(7)) }
	testing.expect(t, !ws.drag.active, "drag ends after a successful drop")
}

@(test)
drop_target_rejects_wrong_kind :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1

	src := hash_id("dd-src3")
	tgt := hash_id("dd-tgt3")
	seed(&ws, src, Rect{0, 0, 100, 40})
	seed(&ws, tgt, Rect{200, 0, 100, 40})

	msgs: [dynamic]DD_Msg
	defer delete(msgs)
	input: Input
	ctx := Ctx(DD_Msg){widgets = &ws, input = &input, msgs = &msgs}
	dummy := rect({1, 1}, Color{})
	payload := Drag_Payload{kind = "file", id = 9}

	// Arm + begin a "file" drag.
	input = Input{mouse_pos = {20, 20}}
	input.mouse_pressed[.Left] = true
	input.mouse_buttons[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	drop_target(&ctx, dummy, on_drop_id, id = tgt, accepts = "folder")

	ws.frame += 1
	input = Input{mouse_pos = {40, 20}}
	input.mouse_buttons[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	drop_target(&ctx, dummy, on_drop_id, id = tgt, accepts = "folder")

	// Release over a target that only accepts "folder" → no drop. The drag
	// stays active (the run-loop cancel hook would clear it in a real app).
	ws.frame += 1
	input = Input{mouse_pos = {240, 20}}
	input.mouse_released[.Left] = true
	drag_source(&ctx, dummy, payload, dummy, id = src)
	drop_target(&ctx, dummy, on_drop_id, id = tgt, accepts = "folder")
	testing.expect_value(t, len(msgs), 0)
	testing.expect(t, ws.drag.active, "kind mismatch must not fire or end the drag")

	_drag_end_store(&ws) // clean up the still-live drag for the leak check
}
