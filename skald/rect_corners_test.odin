package skald

import "core:testing"

// Per-corner radius wiring: `rect(corners = …)` must thread independent radii
// (top-left, top-right, bottom-right, bottom-left) all the way into the vertex
// buffer, while the plain `radius` form broadcasts one value to all four. The
// SDF itself is GPU-side (verified visually); this guards the view→draw path
// and the broadcast, so a refactor can't silently drop per-corner radii or
// stop widening the uniform case.

@(private = "file")
rc_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.fb_size = {200, 200}
	return r
}

@(private = "file")
rc_free :: proc(r: ^Renderer) {
	batch_destroy(&r.batch)
	free(r.cur)
	free(r)
}

@(test)
rect_per_corner_radius_reaches_vertices :: proc(t: ^testing.T) {
	r := rc_renderer()
	defer rc_free(r)

	// Per-corner: top two rounded (a tab), bottom two square.
	render_view(r, rect({100, 40}, {1, 0, 0, 1}, corners = {14, 14, 0, 0}), {0, 0}, {100, 40})
	testing.expect(t, len(r.batch.vertices) >= 4, "rect emitted a quad")
	testing.expect_value(t, r.batch.vertices[0].radius, [4]f32{14, 14, 0, 0})

	// Uniform radius broadcasts to all four corners.
	clear(&r.batch.vertices)
	clear(&r.batch.indices)
	render_view(r, rect({100, 40}, {1, 0, 0, 1}, radius = 10), {0, 0}, {100, 40})
	testing.expect_value(t, r.batch.vertices[0].radius, [4]f32{10, 10, 10, 10})

	// A corner larger than the half-extent is clamped (half-height = 20 here).
	clear(&r.batch.vertices)
	clear(&r.batch.indices)
	render_view(r, rect({100, 40}, {1, 0, 0, 1}, corners = {99, 0, 0, 0}), {0, 0}, {100, 40})
	testing.expect_value(t, r.batch.vertices[0].radius, [4]f32{20, 0, 0, 0})
}

@(test)
col_row_per_corner_bg_reaches_vertices :: proc(t: ^testing.T) {
	r := rc_renderer()
	defer rc_free(r)

	// A col's background (first quad emitted by stack_render) carries the
	// per-corner radii — e.g. a card rounded only on top.
	render_view(r, col(bg = {0, 0, 1, 1}, corners = {12, 12, 0, 0}), {0, 0}, {120, 60})
	testing.expect(t, len(r.batch.vertices) >= 4, "col bg emitted a quad")
	testing.expect_value(t, r.batch.vertices[0].radius, [4]f32{12, 12, 0, 0})

	// A row broadcasts its uniform `radius` when `corners` is unset.
	clear(&r.batch.vertices)
	clear(&r.batch.indices)
	render_view(r, row(bg = {0, 0, 1, 1}, radius = 8), {0, 0}, {120, 60})
	testing.expect_value(t, r.batch.vertices[0].radius, [4]f32{8, 8, 8, 8})
}
