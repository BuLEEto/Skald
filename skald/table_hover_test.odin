package skald

import "core:testing"

// White-box tests for request 037: table's opt-in row backgrounds
// (`hover_row_bg` under the pointer, `zebra_row_bg` on alternating rows).
// The app supplies the color, so the only honest check is that the exact
// color reaches the draw batch. We render the table on a real (GPU-less)
// renderer — the same headless pattern as text_align / combobox tests —
// and scan for the distinctive quad. Hover needs a prior frame to stamp
// the row zones' rects (it hit-tests them the same way row-click does),
// so the hover case renders twice.

@(private = "file")
TH_Msg :: distinct int

// Distinctive colors no theme uses, matched on RGB (alpha carries the
// renderer's alpha_multiplier, which we set to 1 but ignore to be safe).
@(private = "file") TH_HOVER :: Color{0.123, 0.456, 0.789, 1}
@(private = "file") TH_ZEBRA :: Color{0.246, 0.135, 0.864, 1}

@(private = "file") TH_VP  :: [2]f32{200, 200}
@(private = "file") TH_HDR :: f32(24)
@(private = "file") TH_IH  :: f32(24)
@(private = "file") TH_N   :: 5 // 5*24 = 120 < body 176 → no scrollbar

// One flex column; cells are spacers so the test doesn't depend on text
// shaping — only the full-width row background matters here.
@(private = "file")
th_cols := []Table_Column{{label = "", flex = 1}}

@(private = "file")
th_row :: proc(ctx: ^Ctx(TH_Msg), s: int, row: int) -> []View {
	cells := make([]View, 1, context.temp_allocator)
	cells[0] = spacer(0)
	return cells
}

@(private = "file")
TH_Fixture :: struct {
	ws:    Widget_Store,
	th:    Theme,
	lb:    Labels,
	input: Input,
	msgs:  [dynamic]TH_Msg,
	r:     ^Renderer,
}

@(private = "file")
th_setup :: proc(f: ^TH_Fixture) -> bool {
	widget_store_init(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	f.r = new(Renderer)
	f.r.cur = new(Window_Target)
	f.r.scale = 1
	f.r.fb_size = {200, 200}
	f.r.alpha_multiplier = 1
	f.r.widgets = &f.ws // so View_Zone renders stamp row rects
	f.r.text.atlas_w = ATLAS_SIZE
	f.r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&f.r.text, f.r)
	return f.r.text.runa_state != nil // false = runa-less build, caller skips
}

@(private = "file")
th_teardown :: proc(f: ^TH_Fixture) {
	if f.r.text.runa_state != nil { text_runa_free(f.r.text.runa_state) }
	batch_destroy(&f.r.batch)
	free(f.r.cur)
	free(f.r)
	widget_store_destroy(&f.ws)
	delete(f.msgs)
}

// Build + render one frame at a given mouse position, with the given
// opt-in backgrounds. Returns after the row zones are stamped and the
// row backgrounds are in the batch.
@(private = "file")
th_frame :: proc(f: ^TH_Fixture, mouse: [2]f32, hover, zebra: Maybe(Color)) {
	f.input = Input{mouse_pos = mouse}
	widget_store_begin_frame(&f.ws, f.input)
	ctx := Ctx(TH_Msg) {
		theme    = &f.th,
		labels   = &f.lb,
		widgets  = &f.ws,
		input    = &f.input,
		msgs     = &f.msgs,
		renderer = f.r,
	}
	v := table_full(&ctx, 0, th_cols, TH_N, TH_IH, TH_VP, th_row, nil, nil, nil, nil,
		nil, nil, nil, header_height = TH_HDR, hover_row_bg = hover, zebra_row_bg = zebra)
	batch_reset(&f.r.batch)
	render_view(f.r, v, {0, 0}, TH_VP)
}

@(private = "file")
th_has_color :: proc(f: ^TH_Fixture, c: Color) -> bool {
	tol := f32(0.003)
	for v in f.r.batch.vertices {
		if abs(v.color[0]-c[0]) < tol && abs(v.color[1]-c[1]) < tol &&
		   abs(v.color[2]-c[2]) < tol {
			return true
		}
	}
	return false
}

@(test)
table_hover_tints_the_row_under_the_pointer :: proc(t: ^testing.T) {
	f: TH_Fixture
	if !th_setup(&f) { return }
	defer th_teardown(&f)

	// Frame 1 stamps the row zones (mouse parked off the table); the
	// hover tint can't have painted yet — no prior rect to hit-test.
	th_frame(&f, {-50, -50}, TH_HOVER, nil)
	testing.expect(t, !th_has_color(&f, TH_HOVER),
		"nothing hovered → the hover color must not be drawn")

	// Frame 2: pointer over row 1 ([48,72] in y). widget_hovered reads
	// frame 1's stamped rect, so this row now paints with the hover bg.
	th_frame(&f, {100, 60}, TH_HOVER, nil)
	testing.expect(t, th_has_color(&f, TH_HOVER),
		"the row under the pointer must paint with hover_row_bg")
}

@(test)
table_hover_is_opt_in :: proc(t: ^testing.T) {
	f: TH_Fixture
	if !th_setup(&f) { return }
	defer th_teardown(&f)

	// Same two frames, but hover_row_bg is nil: hovering a row must not
	// introduce the tint — today's flat behavior is preserved.
	th_frame(&f, {-50, -50}, nil, nil)
	th_frame(&f, {100, 60}, nil, nil)
	testing.expect(t, !th_has_color(&f, TH_HOVER),
		"with hover_row_bg nil, a hovered row stays untinted")
}

@(test)
table_zebra_tints_alternating_rows :: proc(t: ^testing.T) {
	f: TH_Fixture
	if !th_setup(&f) { return }
	defer th_teardown(&f)

	// Zebra needs no hover state — odd rows (1, 3) take the stripe on the
	// first frame.
	th_frame(&f, {-50, -50}, nil, TH_ZEBRA)
	testing.expect(t, th_has_color(&f, TH_ZEBRA),
		"zebra_row_bg must paint the alternating rows")

	// Control: nil zebra draws no stripe (opt-in, non-breaking).
	th_frame(&f, {-50, -50}, nil, nil)
	testing.expect(t, !th_has_color(&f, TH_ZEBRA),
		"with zebra_row_bg nil, no row takes the stripe")
}
