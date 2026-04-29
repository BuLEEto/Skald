package example_text

import "gui:skald"

main :: proc() {
	th := skald.theme_dark()

	w, ok := skald.window_open("Skald — Text", {960, 600})
	if !ok { return }
	defer skald.window_close(&w)

	r: skald.Renderer
	if !skald.renderer_init(&r, &w) { return }
	defer skald.renderer_destroy(&r)

	for !w.should_close {
		skald.window_pump(&w)
		if w.resized { skald.renderer_resize(&r, &w) }

		if skald.frame_begin(&r, &w, th.color.bg) {
			// Headline + tagline — exercises the display and lg sizes.
			skald.draw_text(&r, "Skald",                th.spacing.xl + 16, 80,  th.color.fg,       th.font.size_display)
			skald.draw_text(&r, "a quiet GUI for Odin", th.spacing.xl + 16, 120, th.color.fg_muted, th.font.size_lg)

			// Body text on a surface — visual check on contrast + AA.
			skald.draw_rect(&r, {40, 160, 520, 140}, th.color.surface, th.radius.lg)
			skald.draw_text(&r, "The frame pumps SDL events, clears to bg,",
				56, 200, th.color.fg,       th.font.size_md)
			skald.draw_text(&r, "and submits one batched draw per frame.",
				56, 224, th.color.fg,       th.font.size_md)
			skald.draw_text(&r, "Rounded rects and text share one pipeline.",
				56, 252, th.color.fg_muted, th.font.size_sm)
			skald.draw_text(&r, "Fontstash drives a shared R8 glyph atlas.",
				56, 276, th.color.fg_muted, th.font.size_sm)

			// Swatches + labels — verifies the color tokens themselves.
			swatch(&r, &th, 40,  340, "primary", th.color.primary)
			swatch(&r, &th, 160, 340, "success", th.color.success)
			swatch(&r, &th, 280, 340, "warning", th.color.warning)
			swatch(&r, &th, 400, 340, "danger",  th.color.danger)

			// Width-based layout — measure, then right-align a line to the
			// window's right edge. Re-measured each frame so resize reflows.
			line := "right-aligned via measure_text"
			w_px, _ := skald.measure_text(&r, line, th.font.size_md)
			skald.draw_text(&r, line, f32(w.size_logical.x) - 40 - w_px, 440, th.color.fg, th.font.size_md)

			// Smallest sizes — stress the AA band.
			skald.draw_text(&r, "xs — still readable. fwidth AA + sRGB surface.",
				40, 500, th.color.fg_muted, th.font.size_xs)
			skald.draw_text(&r, "xs − 1 — the floor before hinting would matter.",
				40, 520, th.color.fg_muted, th.font.size_xs - 1)

			skald.frame_end(&r)
		}
	}
}

swatch :: proc(r: ^skald.Renderer, th: ^skald.Theme, x, y: f32, label: string, color: skald.Color) {
	skald.draw_rect(r, {x, y, 20, 20}, color, th.radius.sm)
	skald.draw_text(r, label, x + 28, y + 16, color, th.font.size_md)
}
