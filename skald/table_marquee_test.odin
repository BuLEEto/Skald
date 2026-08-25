package skald

import "core:testing"

// White-box tests for request 038: table rubber-band (marquee) multi-select.
// The leading (first visible) column is the file-grab zone — a press there is
// unchanged (mouse-down select). A press to its right (a row's whitespace, or
// the empty body) arms a marquee: drag past the threshold draws a box and
// streams the rows it covers; a release under the threshold is a plain click.
//
// Layout for these: a fixed 80-px leading column + a flex column, in a 200×200
// surface with a 24-px header and 24-px rows. So x<80 is the grab zone and
// x>=80 is the marquee zone; row i occupies screen y [24+24i, 48+24i].
//
// The band is drawn in the overlay post-pass, so these render on the headless
// renderer AND drain the overlay queue before scanning the batch. The marquee
// hit-tests the body's viewport rect (stamped at render), so every gesture
// frame is preceded by a frame that stamps it. Each fire is captured by
// encoding it into the returned Msg and reading the per-fixture msg queue —
// never file globals, which the parallel test runner would race on.

@(private = "file")
TM_Msg :: struct {
	is_click: bool,
	begin:    bool,       // marquee: first fire of the gesture
	row:      int,        // click row, or covered-row count is in `n`
	n:        int,
	rows:     [64]int,
	mods:     Modifiers,
}

@(private = "file") TM_BG     :: Color{0.910, 0.320, 0.140, 1}
@(private = "file") TM_BORDER :: Color{0.140, 0.820, 0.560, 1}

@(private = "file") TM_VP  :: [2]f32{200, 200}
@(private = "file") TM_HDR :: f32(24)
@(private = "file") TM_IH  :: f32(24)

@(private = "file")
tm_cols := []Table_Column{{label = "A", width = 80}, {label = "B", flex = 1}}

// Leading cell is a fixed 50-px block — a deterministic stand-in for an
// icon+name of known extent, so the grab-zone math (icon+name, not the whole
// 80-px column) is testable without depending on font metrics. With the 8-px
// cell padding the grab zone ends at x=58, leaving the Name column's
// whitespace (58..80) as marquee-startable.
@(private = "file") TM_LEAD_W :: f32(50)

@(private = "file")
tm_row :: proc(ctx: ^Ctx(TM_Msg), s: int, row: int) -> []View {
	cells := make([]View, 2, context.temp_allocator)
	cells[0] = rect({TM_LEAD_W, TM_IH}, Color{0.5, 0.5, 0.5, 1})
	cells[1] = spacer(0)
	return cells
}

@(private = "file")
tm_on_click :: proc(row: int, mods: Modifiers) -> TM_Msg {
	return TM_Msg{is_click = true, row = row, mods = mods}
}

@(private = "file")
tm_on_marquee :: proc(rows: []int, mods: Modifiers, begin: bool) -> TM_Msg {
	m: TM_Msg
	m.begin = begin
	m.n = len(rows)
	for r, i in rows { if i < len(m.rows) { m.rows[i] = r } }
	m.mods = mods
	return m
}

@(private = "file")
TM_Fixture :: struct {
	ws:    Widget_Store,
	th:    Theme,
	lb:    Labels,
	input: Input,
	msgs:  [dynamic]TM_Msg,
	r:     ^Renderer,
}

@(private = "file")
tm_setup :: proc(f: ^TM_Fixture) -> bool {
	widget_store_init(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	f.r = new(Renderer)
	f.r.cur = new(Window_Target)
	f.r.scale = 1
	f.r.fb_size = {200, 200}
	f.r.alpha_multiplier = 1
	f.r.widgets = &f.ws
	f.r.overlays = make([dynamic]Overlay_Entry)
	f.r.text.atlas_w = ATLAS_SIZE
	f.r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&f.r.text, f.r)
	return f.r.text.runa_state != nil // false = runa-less build, caller skips
}

@(private = "file")
tm_teardown :: proc(f: ^TM_Fixture) {
	if f.r.text.runa_state != nil { text_runa_free(f.r.text.runa_state) }
	batch_destroy(&f.r.batch)
	delete(f.r.overlays)
	free(f.r.cur)
	free(f.r)
	widget_store_destroy(&f.ws)
	delete(f.msgs)
}

// One frame: drive the mouse (press = button edge this frame, held = button
// down), build the table with the given callbacks + band colors, render, and
// drain the overlay queue so the band lands in the batch. row_count varies
// per test to control empty space.
@(private = "file")
tm_frame :: proc(
	f: ^TM_Fixture, n: int, mouse: [2]f32, press, held: bool,
	click: proc(row: int, mods: Modifiers) -> TM_Msg,
	mq: proc(rows: []int, mods: Modifiers, begin: bool) -> TM_Msg,
	bg, border: Maybe(Color), mods: Modifiers = {},
	is_sel: proc(s: int, row: int) -> bool = nil,
) {
	f.input = Input{mouse_pos = mouse, modifiers = mods}
	f.input.mouse_pressed[.Left] = press
	f.input.mouse_buttons[.Left] = held
	widget_store_begin_frame(&f.ws, f.input)
	ctx := Ctx(TM_Msg) {
		theme    = &f.th,
		labels   = &f.lb,
		widgets  = &f.ws,
		input    = &f.input,
		msgs     = &f.msgs,
		renderer = f.r,
	}
	v := table_full(&ctx, 0, tm_cols, n, TM_IH, TM_VP, tm_row, nil, click, is_sel, nil,
		nil, nil, nil, header_height = TM_HDR,
		on_marquee = mq, marquee_bg = bg, marquee_border = border)
	batch_reset(&f.r.batch)
	clear(&f.r.overlays)
	render_view(f.r, v, {0, 0}, TM_VP)
	render_overlays(f.r)
}

@(private = "file")
tm_marquee_fires :: proc(f: ^TM_Fixture) -> int {
	n := 0
	for m in f.msgs { if !m.is_click { n += 1 } }
	return n
}

@(private = "file")
tm_click_fires :: proc(f: ^TM_Fixture) -> int {
	n := 0
	for m in f.msgs { if m.is_click { n += 1 } }
	return n
}

@(private = "file")
tm_last_marquee :: proc(f: ^TM_Fixture) -> (TM_Msg, bool) {
	#reverse for m in f.msgs { if !m.is_click { return m, true } }
	return {}, false
}

@(private = "file")
tm_last_click :: proc(f: ^TM_Fixture) -> (TM_Msg, bool) {
	#reverse for m in f.msgs { if m.is_click { return m, true } }
	return {}, false
}

@(private = "file")
tm_has_color :: proc(f: ^TM_Fixture, c: Color) -> bool {
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
table_marquee_whitespace_drag_selects_a_mid_list_range :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// 6 rows → content 144 px fits the 176-px body: no empty space, no
	// scrollbar. This is the case phase A couldn't help with.
	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)

	// Press in row 1's whitespace (x 140 > the 80-px leading column, y 60).
	// It arms — nothing fires yet, and crucially the row's mouse-down select
	// is suppressed.
	tm_frame(&f, 6, {140, 60}, true, true, tm_on_click, tm_on_marquee, nil, nil)
	testing.expect(t, tm_marquee_fires(&f) == 0 && tm_click_fires(&f) == 0,
		"a whitespace press arms silently — no click, no marquee yet")

	// Drag down into row 3 (y 116, moved 56 px > threshold): the box spans
	// screen y 60..116 and covers rows 1,2,3.
	tm_frame(&f, 6, {140, 116}, false, true, tm_on_click, tm_on_marquee, nil, nil)
	m, ok := tm_last_marquee(&f)
	testing.expect(t, ok && m.n == 3, "the box over rows 1-3 covers three rows")
	testing.expect(t, m.rows[0] == 1 && m.rows[1] == 2 && m.rows[2] == 3,
		"the covered rows are the mid-list range 1,2,3")
	testing.expect(t, tm_click_fires(&f) == 0,
		"a whitespace drag never fires a row click")
}

@(test)
table_marquee_press_on_the_name_is_unchanged :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// A press on the name content itself (x 40, inside the 8..58 grab zone)
	// still selects on mouse-down, exactly as before — it never arms a marquee.
	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 6, {40, 60}, true, true, tm_on_click, tm_on_marquee, nil, nil)
	c, ok := tm_last_click(&f)
	testing.expect(t, ok && c.row == 1, "a press on the name selects its row on mouse-down")
	testing.expect(t, tm_marquee_fires(&f) == 0, "a press on the name starts no marquee")
}

@(test)
table_marquee_starts_in_the_leading_column_whitespace :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// The heart of the field fix: a short name (50 px) in an 80-px leading
	// column leaves whitespace at x 58..80. A press there (x 70 — past the
	// name, still inside the Name column) must arm a marquee, not grab the
	// row. Whole-column grab (B′) got this wrong and the gesture "barely
	// worked" because that whitespace is exactly where people drag from.
	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 6, {70, 60}, true, true, tm_on_click, tm_on_marquee, nil, nil)
	testing.expect(t, tm_click_fires(&f) == 0,
		"a press in the name's trailing whitespace does not grab-select the row")

	tm_frame(&f, 6, {70, 116}, false, true, tm_on_click, tm_on_marquee, nil, nil)
	m, ok := tm_last_marquee(&f)
	testing.expect(t, ok && m.n == 3 && m.rows[0] == 1,
		"dragging from the name's whitespace draws a box (covers rows 1-3)")
	testing.expect(t, tm_click_fires(&f) == 0, "still no row click — it's a marquee")
}

@(test)
table_marquee_whitespace_click_selects_the_row :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// Whitespace press then release without crossing the threshold: a plain
	// click. The select is deferred to release (so a drag could have won),
	// and lands on the pressed row.
	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 6, {140, 60}, true, true, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 6, {141, 61}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	c, ok := tm_last_click(&f)
	testing.expect(t, ok && c.row == 1, "a whitespace click (no drag) selects the pressed row")
	testing.expect(t, tm_marquee_fires(&f) == 0, "a sub-threshold whitespace click draws no box")
}

@(private = "file")
tm_row1_selected :: proc(s: int, row: int) -> bool { return row == 1 }

@(test)
table_marquee_does_not_start_on_a_selected_row :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// Row 1 is selected. Pressing its whitespace (x 70) must grab — fire
	// on_row_click so the app can drag the whole group — never a marquee,
	// which would collapse the selection to that one row. Rubber-band starts
	// only from unselected space.
	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil, {}, tm_row1_selected)
	tm_frame(&f, 6, {70, 60}, true, true, tm_on_click, tm_on_marquee, nil, nil, {}, tm_row1_selected)
	c, ok := tm_last_click(&f)
	testing.expect(t, ok && c.row == 1, "pressing a selected row's whitespace grabs it (fires the click)")
	testing.expect(t, tm_marquee_fires(&f) == 0, "pressing a selected row never arms a marquee")

	// Continuing to drag still must not turn into a box.
	tm_frame(&f, 6, {70, 116}, false, true, tm_on_click, tm_on_marquee, nil, nil, {}, tm_row1_selected)
	testing.expect(t, tm_marquee_fires(&f) == 0, "dragging from a selected row stays a grab, not a box")
}

@(test)
table_marquee_empty_body_press_covers_rows :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// 3 rows → content 72 px, empty body below [96,200]. Press there and drag
	// up over rows 1-2.
	tm_frame(&f, 3, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 3, {140, 150}, true, true, tm_on_click, tm_on_marquee, nil, nil)
	testing.expect(t, tm_marquee_fires(&f) == 0, "an empty-body press arms silently")

	tm_frame(&f, 3, {40, 60}, false, true, tm_on_click, tm_on_marquee, nil, nil)
	m, ok := tm_last_marquee(&f)
	testing.expect(t, ok && m.n == 2 && m.rows[0] == 1 && m.rows[1] == 2,
		"dragging up from the empty body covers the rows it reaches (1,2)")
}

@(test)
table_marquee_click_on_empty_space_clears :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// Press+release on the empty body without dragging fires one empty
	// covered set — the deselect-on-empty-space edge.
	tm_frame(&f, 3, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 3, {140, 150}, true, true, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 3, {141, 151}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	m, ok := tm_last_marquee(&f)
	testing.expect(t, ok && m.n == 0, "a click on empty space fires an empty covered set (clear)")
	testing.expect(t, ok && m.begin, "the clear fire is flagged begin so the app re-snapshots its base")
	testing.expect(t, tm_click_fires(&f) == 0, "a click on empty space is not a row click")
}

@(test)
table_marquee_begin_flags_only_the_first_active_fire :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// The app snapshots its base selection when `begin` is set, so the flag
	// must be true on the first active fire and false on every one after —
	// otherwise a Ctrl-drag re-snapshots mid-gesture and an overshoot can't
	// be retracted.
	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 6, {140, 60}, true, true, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 6, {140, 116}, false, true, tm_on_click, tm_on_marquee, nil, nil)
	first, ok1 := tm_last_marquee(&f)
	testing.expect(t, ok1 && first.begin, "the first active fire is flagged begin")

	tm_frame(&f, 6, {140, 140}, false, true, tm_on_click, tm_on_marquee, nil, nil)
	second, ok2 := tm_last_marquee(&f)
	testing.expect(t, ok2 && !second.begin, "later fires in the same gesture are not begin")
}

@(test)
table_marquee_is_opt_in :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// on_marquee nil: a whitespace press-drag draws no band and fires no
	// marquee — today's behavior is untouched.
	tm_frame(&f, 6, {-50, -50}, false, false, nil, nil, TM_BG, TM_BORDER)
	tm_frame(&f, 6, {140, 60}, true, true, nil, nil, TM_BG, TM_BORDER)
	tm_frame(&f, 6, {140, 116}, false, true, nil, nil, TM_BG, TM_BORDER)
	testing.expect(t, tm_marquee_fires(&f) == 0, "with on_marquee nil, no marquee fires")
	testing.expect(t, !tm_has_color(&f, TM_BG), "with on_marquee nil, no band is drawn")
}

@(test)
table_marquee_draws_the_band :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, TM_BG, TM_BORDER)
	tm_frame(&f, 6, {140, 60}, true, true, tm_on_click, tm_on_marquee, TM_BG, TM_BORDER)
	testing.expect(t, !tm_has_color(&f, TM_BG), "an armed-but-not-yet-dragged press paints nothing")

	tm_frame(&f, 6, {40, 116}, false, true, tm_on_click, tm_on_marquee, TM_BG, TM_BORDER)
	testing.expect(t, tm_has_color(&f, TM_BG), "the active band paints marquee_bg")
	testing.expect(t, tm_has_color(&f, TM_BORDER),
		"the active band paints its marquee_border outline")
}

@(test)
table_marquee_latches_the_press_modifiers :: proc(t: ^testing.T) {
	f: TM_Fixture
	if !tm_setup(&f) { return }
	defer tm_teardown(&f)

	// Ctrl held at the whitespace press, released before the drag frame. The
	// stream must still carry Ctrl — the app folds additive-vs-replace off
	// the press-time intent, not whatever is held mid-drag.
	tm_frame(&f, 6, {-50, -50}, false, false, tm_on_click, tm_on_marquee, nil, nil)
	tm_frame(&f, 6, {140, 60}, true, true, tm_on_click, tm_on_marquee, nil, nil, {.Ctrl})
	tm_frame(&f, 6, {40, 116}, false, true, tm_on_click, tm_on_marquee, nil, nil, {})
	m, ok := tm_last_marquee(&f)
	testing.expect(t, ok && .Ctrl in m.mods,
		"the covered-rows stream carries the modifiers latched at the press")
}
