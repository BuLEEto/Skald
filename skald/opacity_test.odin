package skald

// White-box test for View_Opacity. Renders a known-alpha rect through
// `opacity()` and reads the emitted vertex alpha back out of the batch:
// the factor must multiply the painted alpha, nest multiplicatively, and
// leave the global alpha_multiplier restored afterwards. No GPU/text
// needed — draw_rect only appends to r.batch.

import "core:testing"

@(private = "file")
op_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.alpha_multiplier = 1
	return r
}

@(private = "file")
op_free :: proc(r: ^Renderer) {
	batch_destroy(&r.batch)
	free(r.cur)
	free(r)
}

// Render v and return the max vertex alpha emitted (the painted rect's).
@(private = "file")
render_max_alpha :: proc(r: ^Renderer, v: View) -> f32 {
	batch_reset(&r.batch)
	render_view(r, v, {0, 0}, {100, 100})
	a: f32 = 0
	for vert in r.batch.vertices {
		if vert.color.a > a { a = vert.color.a }
	}
	return a
}

@(test)
opacity_multiplies_painted_alpha :: proc(t: ^testing.T) {
	r := op_renderer()
	defer op_free(r)

	red := Color{1, 0, 0, 1} // fully opaque

	full := render_max_alpha(r, rect({40, 40}, red))
	testing.expectf(t, abs(full - 1) < 0.001, "opaque rect should emit alpha 1, got %v", full)

	half := render_max_alpha(r, opacity(0.5, rect({40, 40}, red)))
	testing.expectf(t, abs(half - 0.5) < 0.001, "opacity(0.5) should halve alpha, got %v", half)

	// Nested opacities multiply: 0.5 * 0.4 = 0.2.
	nested := render_max_alpha(r, opacity(0.5, opacity(0.4, rect({40, 40}, red))))
	testing.expectf(t, abs(nested - 0.2) < 0.001, "nested opacity should multiply to 0.2, got %v", nested)

	// factor clamps to [0,1].
	over := render_max_alpha(r, opacity(2.0, rect({40, 40}, red)))
	testing.expectf(t, abs(over - 1) < 0.001, "factor > 1 clamps to opaque, got %v", over)
}

@(test)
opacity_restores_global_alpha :: proc(t: ^testing.T) {
	r := op_renderer()
	defer op_free(r)
	r.alpha_multiplier = 1
	batch_reset(&r.batch)
	render_view(r, opacity(0.3, rect({40, 40}, {1, 1, 1, 1})), {0, 0}, {100, 100})
	testing.expectf(t, abs(r.alpha_multiplier - 1) < 0.001,
		"alpha_multiplier must be restored after the subtree, got %v", r.alpha_multiplier)
}

@(test)
opacity_is_layout_passthrough :: proc(t: ^testing.T) {
	r := op_renderer()
	defer op_free(r)
	child := rect({73, 41}, {1, 1, 1, 1})
	bare := view_size(r, child)
	wrapped := view_size(r, opacity(0.5, child))
	testing.expectf(t, bare == wrapped,
		"opacity must measure identically to its child: %v vs %v", bare, wrapped)
}
