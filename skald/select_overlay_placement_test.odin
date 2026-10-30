package skald

import "core:testing"

// The select predicts its dropdown's rect — stamped for the modal input gate
// and outside-click dismiss — while the renderer places the overlay
// independently from `view_size`. If the predicted per-row height drifts from
// the real one, the two flip the menu to opposite sides of the trigger near
// the window edge: the stamped rect then points away from the drawn menu and,
// inside a dialog, the gate hit-tests empty space and swallows every click
// (the menu opens and stays, but nothing is selectable). `opt_h` now measures
// the real row via `measure_text`, so the prediction equals the render.

@(private = "file")
SOP_Msg :: distinct int

@(test)
select_overlay_stamp_matches_render :: proc(t: ^testing.T) {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.fb_size = {900, 620}
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		batch_destroy(&r.batch)
		free(r.cur)
		free(r)
	}

	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	input: Input
	msgs: [dynamic]SOP_Msg
	defer delete(msgs)

	id      := hash_id("sop-select")
	options := []string{"Blank", "Bosses", "Items", "NPCs", "Regions", "Weapons", "Spells"}
	omsgs   := []SOP_Msg{0, 1, 2, 3, 4, 5, 6}

	// Trigger in the former divergence band: near the window bottom, enough
	// rows that an inflated prediction would flip the stamp above the trigger
	// while the real (shorter) menu stays below it.
	trigger := Rect{270, 347, 220, 28}

	widget_store_begin_frame(&ws, input)
	ws.states[id] = Widget_State{kind = .Select, last_rect = trigger, last_frame = ws.frame, open = true}
	ctx := Ctx(SOP_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = r}

	v := _select_impl(&ctx, "Blank", options, omsgs, id = id, width = 220)

	testing.expect(t, len(ws.overlay_rects) > 0, "select stamped an overlay rect")
	pred := ws.overlay_rects[len(ws.overlay_rects) - 1]

	// Measure the overlay child exactly as the renderer does
	// (layout.odin View_Overlay: cs := view_size(r, vv.child^)).
	stack  := v.(View_Stack)
	ov     := stack.children[1].(View_Overlay)
	cs     := view_size(r, ov.child^)
	actual := overlay_placement_rect(&ctx, trigger, {pred.w, cs.y}, .Below, {0, 4})

	// The stamped (predicted) rect must equal what the renderer places, so the
	// modal gate hit-tests the menu the user actually sees.
	testing.expectf(t, abs(pred.h - cs.y) < 0.5,
		"predicted menu height %.1f must match rendered %.1f", pred.h, cs.y)
	testing.expectf(t, abs(pred.y - actual.y) < 0.5,
		"stamped rect y %.1f must match rendered y %.1f (no flip mismatch)", pred.y, actual.y)

	// A click on the centre of the drawn menu lands inside the stamped rect.
	mid := [2]f32{actual.x + actual.w / 2, actual.y + actual.h / 2}
	testing.expect(t, rect_contains_point(pred, mid),
		"a click on the drawn menu must fall inside the stamped rect")
}

// Combobox is immune to the same drift because it builds each dropdown row
// with an explicit `height = opt_h`, so `view_size` returns exactly the
// predicted height. This guards that invariant: if the explicit height were
// ever dropped (rows measuring their own font height like select's buttons),
// the stamp would drift from the render and this would fail.
@(test)
combobox_overlay_stamp_matches_render :: proc(t: ^testing.T) {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.fb_size = {900, 620}
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		batch_destroy(&r.batch)
		free(r.cur)
		free(r)
	}

	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	input: Input
	msgs: [dynamic]SOP_Msg
	defer delete(msgs)

	id      := hash_id("sop-combobox")
	options := []string{"Blank", "Bosses", "Items", "NPCs", "Regions", "Weapons", "Spells"}
	trigger := Rect{270, 347, 220, 34}

	widget_store_begin_frame(&ws, input)
	ws.states[id] = Widget_State{kind = .Combobox, last_rect = trigger, last_frame = ws.frame, open = true}
	ctx := Ctx(SOP_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = r}

	v, _, _ := _combobox_impl(&ctx, "", options, id = id, width = 220, filter = false)

	testing.expect(t, len(ws.overlay_rects) > 0, "combobox stamped an overlay rect")
	pred := ws.overlay_rects[len(ws.overlay_rects) - 1]

	stack  := v.(View_Stack)
	ov     := stack.children[1].(View_Overlay)
	cs     := view_size(r, ov.child^)
	actual := overlay_placement_rect(&ctx, trigger, {pred.w, cs.y}, .Below, {0, 4})

	testing.expectf(t, abs(pred.h - cs.y) < 0.5,
		"combobox predicted menu height %.1f must match rendered %.1f", pred.h, cs.y)
	testing.expectf(t, abs(pred.y - actual.y) < 0.5,
		"combobox stamped rect y %.1f must match rendered y %.1f", pred.y, actual.y)
}
