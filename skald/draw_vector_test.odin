package skald

// White-box tests for the vector primitives. They only append to the batch's
// vertex/index buffers (no GPU), so a heap-allocated Renderer with a batch is
// enough — we assert triangle counts and that degenerate inputs emit nothing
// rather than crash. draw_stroke's internal scratch lands on the temp
// allocator, reclaimed by each test's free_all.

import "core:testing"

@(private = "file")
vtest_renderer :: proc() -> ^Renderer {
	// batch / alpha_multiplier live on Window_Target, reached via `using cur`;
	// a bare Renderer has cur == nil, so allocate a target too.
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.alpha_multiplier = 1
	r.batch.vertices = make([dynamic]Vertex)
	r.batch.indices  = make([dynamic]u32)
	return r
}

@(private = "file")
vtest_free :: proc(r: ^Renderer) {
	delete(r.batch.vertices)
	delete(r.batch.indices)
	free(r.cur)
	free(r)
}

@(private = "file")
tri_count :: proc(r: ^Renderer) -> int { return len(r.batch.indices) / 3 }

@(test)
vector_primitives_emit_triangles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	white := Color{1, 1, 1, 1}

	r := vtest_renderer()
	draw_line(r, {0, 0}, {10, 0}, 2, white)
	testing.expect(t, tri_count(r) > 0, "line emits triangles")
	testing.expect(t, len(r.batch.indices) % 3 == 0, "index count multiple of 3")
	vtest_free(r)

	r = vtest_renderer()
	draw_circle(r, {50, 50}, 20, white)
	testing.expect(t, tri_count(r) > 0, "circle emits triangles")
	vtest_free(r)

	r = vtest_renderer()
	draw_ring(r, {50, 50}, 20, 3, white)
	testing.expect(t, tri_count(r) > 0, "ring emits triangles")
	vtest_free(r)

	r = vtest_renderer()
	draw_arc(r, {50, 50}, 20, 0, 3.14, 4, white)
	testing.expect(t, tri_count(r) > 0, "arc emits triangles")
	vtest_free(r)

	r = vtest_renderer()
	draw_bezier(r, {0, 0}, {10, 40}, {40, 40}, {50, 0}, 3, white)
	testing.expect(t, tri_count(r) > 0, "cubic bezier emits triangles")
	vtest_free(r)

	r = vtest_renderer()
	draw_rect_outline(r, {10, 10, 80, 40}, 2, white, radius = 8)
	testing.expect(t, tri_count(r) > 0, "rounded rect outline emits triangles")
	vtest_free(r)
}

@(test)
vector_polygon_triangulates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	white := Color{1, 1, 1, 1}

	// A simple polygon of n vertices ear-clips to exactly n-2 triangles.
	r := vtest_renderer()
	quad := [][2]f32{{0, 0}, {10, 0}, {10, 10}, {0, 10}}
	draw_polygon(r, quad, white)
	testing.expect_value(t, tri_count(r), 2)
	vtest_free(r)

	// A concave (reflex vertex at {10,5}) simple pentagon: still n-2 = 3, which
	// only holds if the ear clip handled the reflex vertex and ran to completion.
	r2 := vtest_renderer()
	concave := [][2]f32{{0, 0}, {10, 5}, {20, 0}, {20, 20}, {0, 20}}
	draw_polygon(r2, concave, white)
	testing.expect_value(t, tri_count(r2), 3)
	vtest_free(r2)
}

@(test)
vector_degenerate_inputs_emit_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	white := Color{1, 1, 1, 1}
	r := vtest_renderer()
	defer vtest_free(r)

	draw_line(r, {0, 0}, {10, 0}, 0, white)             // zero width
	draw_circle(r, {0, 0}, 0, white)                    // zero radius
	draw_ring(r, {0, 0}, 0, 2, white)                   // zero radius
	draw_arc(r, {0, 0}, 0, 0, 1, 2, white)              // zero radius
	draw_polyline(r, [][2]f32{{0, 0}}, 2, white)        // single point
	draw_polygon(r, [][2]f32{{0, 0}, {1, 1}}, white)    // < 3 points
	draw_rect_outline(r, {0, 0, 40, 40}, 0, white)      // zero width

	testing.expect_value(t, len(r.batch.vertices), 0)
	testing.expect_value(t, len(r.batch.indices), 0)
}

@(test)
vector_aa_adds_fringe :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	white := Color{1, 1, 1, 1}

	ra := vtest_renderer()
	draw_circle(ra, {50, 50}, 20, white, aa = false)
	rb := vtest_renderer()
	draw_circle(rb, {50, 50}, 20, white, aa = true)
	testing.expect(t, len(rb.batch.vertices) > len(ra.batch.vertices),
		"aa circle adds a feathered rim")
	vtest_free(ra)
	vtest_free(rb)
}

@(test)
overlay_pin_flag_propagates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v := overlay(Rect{10, 10, 0, 0}, spacer(5), pin = true)
	ov, ok := v.(View_Overlay)
	testing.expect(t, ok, "overlay builds a View_Overlay")
	testing.expect(t, ov.pin, "pin flag propagates onto the node")

	v2 := overlay(Rect{10, 10, 0, 0}, spacer(5))
	ov2, _ := v2.(View_Overlay)
	testing.expect(t, !ov2.pin, "pin defaults off")
}
