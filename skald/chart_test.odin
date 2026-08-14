package skald

// White-box tests for the chart widgets (sparkline / sparkline_multi / gauge).
// The builders are canvas-backed and pure data packing — no renderer needed, so
// we just build them against a minimal Ctx and assert the resulting View_Canvas
// geometry. chart_fmt_num is tested directly (the axis-label number formatter).

import "core:testing"

@(private = "file")
C_Msg :: distinct int

@(test)
chart_fmt_num_formats :: proc(t: ^testing.T) {
	testing.expect_value(t, chart_fmt_num(0),       "0")
	testing.expect_value(t, chart_fmt_num(50),      "50")
	testing.expect_value(t, chart_fmt_num(100),     "100")
	testing.expect_value(t, chart_fmt_num(999),     "999")
	testing.expect_value(t, chart_fmt_num(1000),    "1k")
	testing.expect_value(t, chart_fmt_num(2000),    "2k")
	testing.expect_value(t, chart_fmt_num(1.5e6),   "1.5M")
	testing.expect_value(t, chart_fmt_num(2.5e9),   "2.5G")
}

@(test)
chart_fmt_log_formats_decades :: proc(t: ^testing.T) {
	testing.expect_value(t, chart_fmt_log(1),     "1")
	testing.expect_value(t, chart_fmt_log(10),    "10")
	testing.expect_value(t, chart_fmt_log(100),   "100")
	testing.expect_value(t, chart_fmt_log(1000),  "1k")
	testing.expect_value(t, chart_fmt_log(1e-3),  "1e-3")
	testing.expect_value(t, chart_fmt_log(1e-6),  "1e-6")
	testing.expect_value(t, chart_fmt_log(0),     "0")
}

@(test)
chart_fmt_secs_humane :: proc(t: ^testing.T) {
	testing.expect_value(t, chart_fmt_secs(30),      "30s")
	testing.expect_value(t, chart_fmt_secs(600),     "10m")   // 10 min
	testing.expect_value(t, chart_fmt_secs(21600),   "6h")    // 6 h
	testing.expect_value(t, chart_fmt_secs(259200),  "3d")    // 3 d
}

@(test)
chart_norm_maps_true_position :: proc(t: ^testing.T) {
	// A 0..9 axis: 5 sits at 5/9, the real height — not a rounded quarter tick.
	// This is what explicit y_ticks rely on to label meaningful levels correctly.
	lin := Chart_Axis{min = 0, max = 9, scale = .Linear}
	testing.expect_value(t, chart_norm(&lin, 0), f32(0))
	testing.expect_value(t, chart_norm(&lin, 9), f32(1))
	testing.expectf(t, abs(chart_norm(&lin, 5) - 5.0 / 9.0) < 1e-6, "5 maps to 5/9")

	// Log axis: 1e-4 is two decades up a 1e-6..1e-3 span → 2/3.
	log := Chart_Axis{min = 1e-6, max = 1e-3, scale = .Log10}
	testing.expect_value(t, chart_norm(&log, 1e-6), f32(0))
	testing.expect_value(t, chart_norm(&log, 1e-3), f32(1))
	testing.expectf(t, abs(chart_norm(&log, 1e-4) - 2.0 / 3.0) < 1e-5, "1e-4 maps to 2/3")
}

@(private = "file")
chart_ctx :: proc(ws: ^Widget_Store, th: ^Theme, input: ^Input) -> Ctx(C_Msg) {
	return Ctx(C_Msg){widgets = ws, theme = th, input = input}
}

@(test)
sparkline_builds_canvas :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1
	th := theme_dark()
	input: Input
	ctx := chart_ctx(&ws, &th, &input)

	v := sparkline(&ctx, []f32{1, 2, 3, 4}, 200, 60, max = 100, grid = true, y_unit = "%")
	cv, ok := v.(View_Canvas)
	testing.expect(t, ok, "sparkline should build a View_Canvas")
	testing.expect_value(t, cv.size, [2]f32{200, 60})

	// width 0 fills its slot; the intrinsic fallback is the 120px min.
	v0 := sparkline(&ctx, []f32{1, 2}, 0, 50)
	c0, _ := v0.(View_Canvas)
	testing.expect_value(t, c0.size.x, f32(0))
	testing.expect_value(t, c0.min.x, f32(120))
}

@(test)
sparkline_multi_builds_canvas :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1
	th := theme_dark()
	input: Input
	ctx := chart_ctx(&ws, &th, &input)

	traces := []Trace{
		{values = []f32{0, 10, 20}},
		{values = []f32{5, 15, 25}, color = Color{1, 0, 0, 1}, fill = 0.2},
	}
	v := sparkline_multi(&ctx, traces, 300, 80, grid = true)
	cv, ok := v.(View_Canvas)
	testing.expect(t, ok, "sparkline_multi should build a View_Canvas")
	testing.expect_value(t, cv.size, [2]f32{300, 80})
}

@(test)
sparkline_log_with_bands_builds :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1
	th := theme_dark()
	input: Input
	ctx := chart_ctx(&ws, &th, &input)

	bands := []Ref_Band{
		{lo = 1e-6, hi = 1e-5, color = Color{0, 1, 0, 0.2}, label = "C"},
		{lo = 1e-5, hi = 1e-4, color = Color{1, 1, 0, 0.2}, label = "M"},
	}
	v := sparkline(&ctx, []f32{1e-8, 1e-6, 1e-5, 1e-4}, 240, 100,
		min = 1e-9, max = 1e-3, scale = .Log10, bands = bands, y_unit = "W/m²")
	cv, ok := v.(View_Canvas)
	testing.expect(t, ok, "log sparkline with bands should build a View_Canvas")
	testing.expect_value(t, cv.size, [2]f32{240, 100})
}

@(test)
bar_chart_builds_canvas :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1
	th := theme_dark()
	input: Input
	ctx := chart_ctx(&ws, &th, &input)

	kp_color :: proc(v: f32) -> Color {
		return v >= 5 ? Color{1, 0, 0, 1} : Color{0, 1, 0, 1}
	}
	v := bar_chart(&ctx, []f32{2, 4, 6, 3}, 200, 80, max = 9, color_of = kp_color,
		grid = true, y_ticks = []f32{0, 3, 5, 7, 9},
		bands = []Ref_Band{{lo = 5, hi = 6, color = Color{1, 0.7, 0, 0.2}, label = "G1"}})
	cv, ok := v.(View_Canvas)
	testing.expect(t, ok, "bar_chart should build a View_Canvas")
	testing.expect_value(t, cv.size, [2]f32{200, 80})

	// width 0 fills its slot; the intrinsic fallback is the 120px min.
	v0 := bar_chart(&ctx, []f32{1, 2, 3}, 0, 50)
	c0, _ := v0.(View_Canvas)
	testing.expect_value(t, c0.size.x, f32(0))
	testing.expect_value(t, c0.min.x, f32(120))
}

@(test)
gauge_builds_canvas :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1
	th := theme_dark()
	input: Input
	ctx := chart_ctx(&ws, &th, &input)

	v := gauge(&ctx, 0.5)
	cv, ok := v.(View_Canvas)
	testing.expect(t, ok, "gauge should build a View_Canvas")
	testing.expect_value(t, cv.size, [2]f32{64, 64})

	v2 := gauge(&ctx, 1.5, 100) // value clamps internally; size honoured
	c2, _ := v2.(View_Canvas)
	testing.expect_value(t, c2.size, [2]f32{100, 100})
}
