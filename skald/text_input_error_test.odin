package skald

import "core:testing"

// An invalid `text_input` with an `error` wraps the field + message in a
// column. That column must stretch its cross axis, or a width=0 field (one
// filling a `flex` slot) collapses to its intrinsic 0 the moment the error
// appears. Reported as issue #14. This guards the `cross_align = .Stretch`.

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
