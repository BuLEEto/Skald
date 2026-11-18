package skald

import "core:testing"

// An invalid `text_input` with an `error` wraps the field + message in a
// column. It must stretch, or a width=0 (flex) field collapses to 0 when the
// error appears; and the message must wrap at the field's effective width.

@(private = "file")
TI_Msg :: distinct int

@(private = "file")
ti_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	return r
}

@(test)
text_input_error_wrap_stretches :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	input: Input
	msgs: [dynamic]TI_Msg
	defer delete(msgs)
	r := ti_renderer()
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		batch_destroy(&r.batch)
		free(r.cur)
		free(r)
	}

	widget_store_begin_frame(&ws, input)
	ctx := Ctx(TI_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = r}

	v, _, _ := _text_input_impl(&ctx, "", placeholder = "p", invalid = true, error = "required")

	stack, ok := v.(View_Stack)
	testing.expect(t, ok, "invalid+error text_input wraps field + message in a stack")
	testing.expect_value(t, stack.cross_align, Cross_Align.Stretch)
}

@(test)
text_input_error_message_wraps_at_field_width :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	input: Input
	msgs: [dynamic]TI_Msg
	defer delete(msgs)
	r := ti_renderer()
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		batch_destroy(&r.batch)
		free(r.cur)
		free(r)
	}
	widget_store_begin_frame(&ws, input)
	ctx := Ctx(TI_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = r}
	err_max_w :: proc(v: View) -> f32 { return v.(View_Stack).children[1].(View_Text).max_width }

	// Flex field (width = 0) laid out at 240 px last frame: wrap at 236, not -4.
	id := hash_id("ti-flex")
	ws.states[id] = Widget_State{kind = .Text_Input, last_rect = {0, 0, 240, 32}, last_frame = ws.frame}
	v, _, _ := _text_input_impl(&ctx, "", id = id, invalid = true, error = "a long validation message")
	testing.expect_value(t, err_max_w(v), f32(236))

	// Fixed width still wraps at width - 4.
	v, _, _ = _text_input_impl(&ctx, "", id = hash_id("ti-fixed"), width = 300, invalid = true, error = "x")
	testing.expect_value(t, err_max_w(v), f32(296))
}

// A field that wrapped at a borrowed width asks for one more frame when
// layout gives it a different width (a resize), and stays idle otherwise.
@(test)
wrap_width_change_requests_frame :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	r := new(Renderer)
	r.cur = new(Window_Target)
	defer { free(r.cur); free(r) }
	r.widgets = &ws
	id := hash_id("ti-resize")

	ws.states[id] = Widget_State{kind = .Text_Input, wrap_w = 400}
	widget_record_rect(r, id, {0, 0, 400, 32})
	testing.expect_value(t, ws.next_frame_deadline_ns, i64(0))

	widget_record_rect(r, id, {0, 0, 860, 32})
	testing.expect_value(t, ws.next_frame_deadline_ns, i64(1))
}
