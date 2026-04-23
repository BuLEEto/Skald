package example_shapes

import "gui:skald"

main :: proc() {
	th := skald.theme_dark()

	w, ok := skald.window_open("Skald — Shapes", {960, 600})
	if !ok { return }
	defer skald.window_close(&w)

	r: skald.Renderer
	if !skald.renderer_init(&r, &w) { return }
	defer skald.renderer_destroy(&r)

	for !w.should_close {
		skald.window_pump(&w)
		if w.resized { skald.renderer_resize(&r, &w) }

		if skald.frame_begin(&r, &w, th.color.bg) {
			// A row showing radii sm/md/lg/xl — eyeball the AA quality.
			skald.draw_rect(&r, {40,  40, 180, 120}, th.color.surface, 0)
			skald.draw_rect(&r, {240, 40, 180, 120}, th.color.primary, th.radius.sm)
			skald.draw_rect(&r, {440, 40, 180, 120}, th.color.success, th.radius.lg)
			skald.draw_rect(&r, {640, 40, 180, 120}, th.color.danger,  th.radius.xl)

			// A pill shape — theme radius clamps to a perfect capsule.
			skald.draw_rect(&r, {40, 200, 280, 56}, th.color.primary, th.radius.pill)

			// Overlapping translucent rectangles to show blend correctness.
			overlay_a := skald.rgba(0x30a46cbb)
			overlay_b := skald.rgba(0x2b5fffbb)
			skald.draw_rect(&r, {360, 200, 200, 120}, overlay_a, th.radius.xl)
			skald.draw_rect(&r, {460, 240, 200, 120}, overlay_b, th.radius.xl)

			// A staircase of muted bars with varied radii.
			for i := 0; i < 8; i += 1 {
				y := f32(360 + i*28)
				skald.draw_rect(&r, {40, y, f32(60 + i*90), 20}, th.color.fg_muted, f32(i)*2)
			}

			skald.frame_end(&r)
		}
	}
}
