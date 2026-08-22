package skald

import "core:testing"

// A click is press-then-release. The press opens the popover; the release
// that completes the same click must not close it — otherwise the dropdown
// is only visible while the button is physically held, and the user has to
// drag onto a row rather than click, release, then click a row.
//
// The subtle failure is placement-dependent: when the dropdown can't fit
// below the trigger it flips up and is clamped so it *overlaps* the trigger.
// The mouse-up ending the opening click then lands on whatever row was
// painted over the trigger and instantly commits it. A nil-renderer harness
// can't see this — overlay placement is renderer-gated and always lands
// below (with a gap) headless — so the overlap cases seed a real (GPU-less)
// renderer with a framebuffer short enough to force the flip.

@(private = "file")
CB_Msg :: distinct int

@(private = "file")
CB_Fixture :: struct {
	ws:    Widget_Store,
	th:    Theme,
	lb:    Labels,
	input: Input,
	msgs:  [dynamic]CB_Msg,
	r:     ^Renderer, // nil = below-placement path; set = overlap path
}

@(private = "file")
cb_trigger :: Rect{x = 10, y = 10, w = 220, h = 28}

@(private = "file")
cb_on_trigger :: [2]f32{50, 20}

// A headless renderer (no GPU) with real shaping, sized so a tall dropdown
// under a low trigger flips above and clamps over it.
@(private = "file")
cb_renderer :: proc(fb: [2]u32) -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.fb_size = fb
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	return r
}

@(private = "file")
cb_renderer_free :: proc(r: ^Renderer) {
	if r == nil { return }
	if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
	batch_destroy(&r.batch)
	free(r.cur)
	free(r)
}

@(private = "file")
cb_begin_frame :: proc(f: ^CB_Fixture) -> Ctx(CB_Msg) {
	widget_store_begin_frame(&f.ws, f.input)
	return Ctx(CB_Msg) {
		theme    = &f.th,
		labels   = &f.lb,
		widgets  = &f.ws,
		input    = &f.input,
		msgs     = &f.msgs,
		renderer = f.r,
	}
}

// Stand in for the layout pass, which records a widget's on-screen rect.
@(private = "file")
cb_stamp_rect :: proc(f: ^CB_Fixture, id: Widget_ID, rect: Rect, kind: Widget_Kind = .Combobox) {
	st := f.ws.states[id]
	st.kind       = kind
	st.last_rect  = rect
	st.last_frame = f.ws.frame
	f.ws.states[id] = st
}

@(test)
combobox_stays_open_after_the_click_releases :: proc(t: ^testing.T) {
	f: CB_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	defer delete(f.msgs)

	id      := hash_id("cb-below")
	options := []string{"Alpha", "Beta", "Gamma"}

	// Press on the trigger.
	{
		f.input = Input{mouse_pos = cb_on_trigger}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_trigger)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "press on the trigger should open the popover")

	// Release still over the trigger.
	{
		f.input = Input{mouse_pos = cb_on_trigger}
		f.input.mouse_released[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_trigger)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open,
		"releasing the button that opened it must leave the popover open")

	// Idle frame — still up.
	{
		f.input = Input{mouse_pos = cb_on_trigger}
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_trigger)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "the popover should stay open on an idle frame")
}

@(test)
select_stays_open_after_the_click_releases :: proc(t: ^testing.T) {
	f: CB_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	defer delete(f.msgs)

	id       := hash_id("cb-select")
	options  := []string{"Alpha", "Beta", "Gamma"}
	opt_msgs := []CB_Msg{0, 1, 2}

	{
		f.input = Input{mouse_pos = cb_on_trigger}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_trigger, .Select)
		_ = _select_impl(&ctx, "Alpha", options, opt_msgs, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "press on the trigger should open the popover")

	{
		f.input = Input{mouse_pos = cb_on_trigger}
		f.input.mouse_released[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_trigger, .Select)
		_ = _select_impl(&ctx, "Alpha", options, opt_msgs, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open,
		"releasing the button that opened it must leave the popover open")
}

// A dozen options and a short framebuffer put the trigger low enough that
// the dropdown flips up and clamps over it. The mouse-up completing the
// opening click lands on the trigger — which is now painted with a row on
// top — and must NOT be read as picking that row.
@(private = "file")
CB_MANY :: []string {
	"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta",
	"Eta", "Theta", "Iota", "Kappa", "Lambda", "Mu",
}

// last_rect used for the overlap cases: low in a 180 px-tall window.
@(private = "file")
cb_low_trigger :: Rect{x = 10, y = 120, w = 220, h = 30}

@(test)
combobox_release_over_overlapping_trigger_keeps_popover_open :: proc(t: ^testing.T) {
	f: CB_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	f.r  = cb_renderer({260, 180})
	defer delete(f.msgs)
	defer cb_renderer_free(f.r)

	id  := hash_id("cb-overlap")
	on  := [2]f32{60, 135} // inside the low trigger

	// Press opens the popover; it flips up and clamps over the trigger.
	{
		f.input = Input{mouse_pos = on}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_low_trigger)
		_, _, _ = _combobox_impl(&ctx, "Alpha", CB_MANY, id = id, width = 220, free_form = true)
	}
	testing.expect(t, f.ws.states[id].open, "press on the trigger should open the popover")

	// Release still over the trigger — must not commit the row drawn on it.
	changed: bool
	{
		f.input = Input{mouse_pos = on}
		f.input.mouse_released[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_low_trigger)
		_, _, changed = _combobox_impl(&ctx, "Alpha", CB_MANY, id = id, width = 220, free_form = true)
	}
	testing.expect(t, f.ws.states[id].open,
		"releasing over a trigger the popover overlaps must keep it open")
	testing.expect(t, !changed, "that release must not commit a value")
}

// Control for the test above: in the same overlapping geometry, a release
// on a row that is NOT over the trigger still selects normally. Proves the
// guard exempts only the trigger, not the whole overlapping overlay.
@(test)
combobox_release_on_row_outside_trigger_still_selects :: proc(t: ^testing.T) {
	f: CB_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	f.r  = cb_renderer({260, 180})
	defer delete(f.msgs)
	defer cb_renderer_free(f.r)

	id := hash_id("cb-overlap-ctl")

	{
		f.input = Input{mouse_pos = [2]f32{60, 135}}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_low_trigger)
		_, _, _ = _combobox_impl(&ctx, "Alpha", CB_MANY, id = id, width = 220, free_form = true)
	}
	testing.expect(t, f.ws.states[id].open, "press on the trigger should open the popover")

	// Release high in the overlay (well above the trigger's y-band).
	changed: bool
	{
		f.input = Input{mouse_pos = [2]f32{60, 95}}
		f.input.mouse_released[.Left] = true
		ctx := cb_begin_frame(&f)
		cb_stamp_rect(&f, id, cb_low_trigger)
		_, _, changed = _combobox_impl(&ctx, "Alpha", CB_MANY, id = id, width = 220, free_form = true)
	}
	testing.expect(t, changed, "a release on a row outside the trigger should still select")
	testing.expect(t, !f.ws.states[id].open, "selecting a row closes the popover")
}
