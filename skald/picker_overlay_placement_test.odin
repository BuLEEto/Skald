package skald

import "core:testing"

// The date/time/color pickers build their popovers from fixed layout
// constants (HEADER_H / CELL_H / FOOTER_H, a fixed swatch grid), so the
// height they predict for the overlay — and stamp for the modal input gate —
// already equals the `view_size` the renderer places from. These guard that:
// if a picker's popover ever grew a font-measured row whose real height
// differed from the constant, its stamp would drift from the drawn panel and
// clicks inside a dialog would be swallowed (the bug `select` had, where the
// option rows measured their own button height). See
// select_overlay_placement_test.odin for that case.

@(private = "file")
PK_Msg :: distinct int

@(private = "file")
pk_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.fb_size = {900, 620}
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	return r
}

@(private = "file")
pk_check :: proc(t: ^testing.T, name: string, r: ^Renderer, ws: ^Widget_Store, v: View) {
	testing.expectf(t, len(ws.overlay_rects) > 0, "%s stamped an overlay rect", name)
	if len(ws.overlay_rects) == 0 { return }
	pred := ws.overlay_rects[len(ws.overlay_rects) - 1]

	stack := v.(View_Stack)
	ov    := stack.children[1].(View_Overlay)
	cs    := view_size(r, ov.child^)

	testing.expectf(t, abs(pred.h - cs.y) < 0.5,
		"%s predicted overlay height %.1f must match rendered %.1f", name, pred.h, cs.y)
}

@(test)
picker_overlays_stamp_matches_render :: proc(t: ^testing.T) {
	r := pk_renderer()
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
	msgs: [dynamic]PK_Msg
	defer delete(msgs)

	trigger := Rect{270, 347, 220, 30}

	{
		id := hash_id("pk-date")
		widget_store_begin_frame(&ws, input)
		ws.states[id] = Widget_State{kind = .Date_Picker, last_rect = trigger, last_frame = ws.frame, open = true}
		ctx := Ctx(PK_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = r}
		v, _, _ := _date_picker_impl(&ctx, Date{year = 2026, month = 6, day = 15}, id = id, width = 220)
		pk_check(t, "date", r, &ws, v)
	}
	{
		id := hash_id("pk-time")
		widget_store_begin_frame(&ws, input)
		ws.states[id] = Widget_State{kind = .Time_Picker, last_rect = trigger, last_frame = ws.frame, open = true}
		ctx := Ctx(PK_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = r}
		v, _, _ := _time_picker_impl(&ctx, Time{hour = 10, minute = 30}, id = id, width = 220)
		pk_check(t, "time", r, &ws, v)
	}
	{
		id := hash_id("pk-color")
		widget_store_begin_frame(&ws, input)
		ws.states[id] = Widget_State{kind = .Color_Picker, last_rect = trigger, last_frame = ws.frame, open = true}
		ctx := Ctx(PK_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = r}
		v, _, _ := _color_picker_impl(&ctx, Color{0.5, 0.5, 0.5, 1}, id = id, width = 220)
		pk_check(t, "color", r, &ws, v)
	}
}
