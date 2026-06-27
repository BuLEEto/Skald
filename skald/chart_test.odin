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
