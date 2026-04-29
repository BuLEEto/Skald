package example_clip

import "gui:skald"

main :: proc() {
	th := skald.theme_dark()

	w, ok := skald.window_open("Skald — Clip", {960, 600})
	if !ok { return }
	defer skald.window_close(&w)

	r: skald.Renderer
	if !skald.renderer_init(&r, &w) { return }
	defer skald.renderer_destroy(&r)

	for !w.should_close {
		skald.window_pump(&w)
		if w.resized { skald.renderer_resize(&r, &w) }

		if skald.frame_begin(&r, &w, th.color.bg) {
			skald.draw_text(&r, "push_clip / pop_clip",
				40, 60, th.color.fg, th.font.size_xl)
			skald.draw_text(&r, "Each panel contains an oversized content block. push_clip keeps it in the box.",
				40, 92, th.color.fg_muted, th.font.size_sm)

			// Each panel is 240x160. The content block drawn inside each is
			// 440x280 — nearly 2x the panel in both dimensions — so the
			// difference between clipped and unclipped is obvious.

			// Left: clipped. Content is bounded to the panel's rounded rect.
			skald.draw_text(&r, "push_clip", 40, 150, th.color.fg, th.font.size_sm)
			left := skald.Rect{40, 160, 240, 160}
			skald.draw_rect(&r, left, th.color.surface, th.radius.lg)
			skald.push_clip(&r, left)
			draw_overflow_content(&r, &th, left.x, left.y)
			skald.pop_clip(&r)

			// Right: same content, no clip. Bleed is intentional — this is
			// what the left panel would look like without push_clip.
			skald.draw_text(&r, "no clip (bleed)", 480, 150, th.color.fg_muted, th.font.size_sm)
			right := skald.Rect{480, 160, 240, 160}
			skald.draw_rect(&r, right, th.color.surface, th.radius.lg)
			draw_overflow_content(&r, &th, right.x, right.y)

			// Nested clip — inner ∩ outer. The inner clip sits *inside* the
			// outer rect and further narrows it to a single horizontal band.
			skald.draw_text(&r, "nested clips intersect",
				40, 470, th.color.fg, th.font.size_sm)
			outer := skald.Rect{40, 480, 820, 100}
			skald.draw_rect(&r, outer, th.color.surface, th.radius.lg)

			skald.push_clip(&r, outer)
			// Inner is 24 px tall, in the middle of the outer strip. Only
			// the three text lines whose baselines land in that band show.
			inner := skald.Rect{outer.x, outer.y + 38, outer.w, 24}
			skald.push_clip(&r, inner)
			for i := 0; i < 7; i += 1 {
				y := outer.y + 22 + f32(i) * 12
				skald.draw_text(&r, "clip intersection band — only lines inside the inner rect render",
					outer.x + 16, y, th.color.fg, th.font.size_xs)
			}
			skald.pop_clip(&r)
			skald.pop_clip(&r)

			skald.frame_end(&r)
		}
	}
}

// draw_overflow_content fills a 440x280 region anchored to (x, y) — far
// larger than the 240x160 panels in this example, so the bleed is obvious
// when called without push_clip.
draw_overflow_content :: proc(r: ^skald.Renderer, th: ^skald.Theme, x, y: f32) {
	// Big colored block that extends past the panel on all sides.
	skald.draw_rect(r, {x - 40, y - 40, 440, 280}, th.color.primary, th.radius.md)

	// A contrasting grid inside it so the bleed is easy to see.
	for row := 0; row < 6; row += 1 {
		for col := 0; col < 10; col += 1 {
			cx := x - 30 + f32(col) * 42
			cy := y - 30 + f32(row) * 42
			skald.draw_rect(r, {cx, cy, 32, 32}, th.color.on_primary, th.radius.sm)
		}
	}

	// A text label well outside the panel's right edge — shows text clipping
	// specifically (not just rectangle clipping).
	skald.draw_text(r, "text far to the right — clipped or not?",
		x + 200, y + 32, th.color.fg, th.font.size_md)
}
