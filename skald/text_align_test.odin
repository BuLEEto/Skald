package skald

// White-box test for View_Text.align (horizontal placement within an
// assigned width). Renders the same label into a box wider than its
// content at .Start / .Center / .End and reads the leftmost glyph vertex
// x out of the batch. Start pins to the left edge, Center sits at half the
// slack, End pushes the trailing edge to the right border. Uses the real
// shaping + layout path on a heap renderer (no GPU) like wrap_test.

import "core:testing"

@(private = "file")
align_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	return r
}

@(private = "file")
align_free :: proc(r: ^Renderer) {
	if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
	batch_destroy(&r.batch)
	free(r.cur)
	free(r)
}

// Leftmost glyph vertex x after rendering v into [origin, size].
@(private = "file")
render_min_x :: proc(r: ^Renderer, v: View, size: [2]f32) -> (min_x: f32, drew: bool) {
	batch_reset(&r.batch)
	render_view(r, v, {0, 0}, size)
	min_x = 1e9
	for vert in r.batch.vertices {
		if vert.pos.x < min_x { min_x = vert.pos.x }
		drew = true
	}
	return
}

@(test)
text_align_places_within_width :: proc(t: ^testing.T) {
	r := align_renderer()
	defer align_free(r)
	if r.text.runa_state == nil { return } // runa-less build: skip

	str  := "hi"
	size := f32(14)
	w, _ := measure_text(r, str, size, 0)
	box  := [2]f32{w + 200, size * 2} // 200px of horizontal slack

	start_x, ok1 := render_min_x(r, text(str, {255, 255, 255, 255}, size, align = .Start),  box)
	cen_x,   ok2 := render_min_x(r, text(str, {255, 255, 255, 255}, size, align = .Center), box)
	end_x,   ok3 := render_min_x(r, text(str, {255, 255, 255, 255}, size, align = .End),    box)
	testing.expect(t, ok1 && ok2 && ok3, "all three variants must draw glyphs")

	// Start hugs the left edge (~0); Center is offset by half the slack;
	// End by all of it. Allow a glyph's left-side-bearing tolerance.
	tol := f32(4)
	testing.expect(t, abs(start_x - 0) < tol, "Start should pin to the left edge")
	testing.expectf(t, abs(cen_x - (box.x - w) / 2) < tol,
		"Center off by too much: got %v want ~%v", cen_x, (box.x - w) / 2)
	testing.expectf(t, abs(end_x - (box.x - w)) < tol,
		"End off by too much: got %v want ~%v", end_x, box.x - w)
	testing.expect(t, cen_x > start_x && end_x > cen_x, "Start < Center < End")
}

@(test)
text_align_noop_when_content_sized :: proc(t: ^testing.T) {
	r := align_renderer()
	defer align_free(r)
	if r.text.runa_state == nil { return }

	str  := "hello"
	size := f32(14)
	w, _ := measure_text(r, str, size, 0)
	box  := [2]f32{w, size * 2} // slot == content: no slack, align is inert

	s_x, _ := render_min_x(r, text(str, {255, 255, 255, 255}, size, align = .Start),  box)
	c_x, _ := render_min_x(r, text(str, {255, 255, 255, 255}, size, align = .Center), box)
	e_x, _ := render_min_x(r, text(str, {255, 255, 255, 255}, size, align = .End),    box)
	tol := f32(0.01)
	testing.expect(t, abs(s_x - c_x) < tol && abs(s_x - e_x) < tol,
		"with no slack all alignments draw at the same x")
}
