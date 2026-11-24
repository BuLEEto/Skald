package skald

import "core:math"
import "core:slice"
import "core:testing"

// draw_text(angle) turns every glyph quad about the baseline origin, so a
// rotated string is exactly the flat one rotated; angle 0 is untouched.

@(test)
draw_text_rotates_about_origin :: proc(t: ^testing.T) {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		batch_destroy(&r.batch)
		free(r.cur)
		free(r)
	}
	O :: [2]f32{100, 50}

	draw_text(r, "Jan", O.x, O.y, {1, 1, 1, 1}, 14)
	flat := slice.clone(r.batch.vertices[:], context.temp_allocator)
	clear(&r.batch.vertices)
	clear(&r.batch.indices)

	draw_text(r, "Jan", O.x, O.y, {1, 1, 1, 1}, 14, angle = -math.PI / 2)
	testing.expect(t, len(flat) > 0, "text emitted glyph quads")
	testing.expect_value(t, len(r.batch.vertices), len(flat))
	for v, i in r.batch.vertices {
		d    := flat[i].pos - O
		want := O + {d.y, -d.x} // -90°: the line now runs upward
		testing.expectf(t, abs(v.pos.x - want.x) < 0.01 && abs(v.pos.y - want.y) < 0.01,
			"vertex %d at %v, want %v", i, v.pos, want)
	}

	// Off a right angle glyphs rasterize at 2×; the scale must come back.
	draw_text(r, "Jan", O.x, O.y, {1, 1, 1, 1}, 14, angle = -math.PI / 4)
	testing.expect_value(t, r.scale, f32(1))
}
