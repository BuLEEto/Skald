package skald

import "core:fmt"
import "core:math"
import "core:strings"

// Sparklines, a bar chart, and a radial gauge — the resource-monitor and
// scientific-plot widgets (CPU / memory history, a Kp bar chart, a memory-used
// donut). Canvas-backed: they pack their data into the frame arena and paint
// with draw_tris_vc / draw_triangle_strip / draw_rect, so there's no new
// renderer or layout code, and `width = 0` fills the slot like any canvas.
// The app owns the data: keep a rolling buffer per metric (sampled off-thread)
// and hand the slice over each frame. Skald draws; the app samples.

// Scale selects the Y-axis mapping. `.Log10` gives a base-10 decade axis for
// data spanning orders of magnitude; non-positive samples clamp to the floor.
Scale :: enum { Linear, Log10 }

// Ref_Band is a reference range painted behind the traces — a shaded [lo, hi]
// band with an optional edge label (flare classes, storm thresholds). `color`
// carries its own alpha, so pass a translucent tint.
Ref_Band :: struct {
	lo, hi: f32,
	color:  Color,
	label:  string,
}

// Trace is one line on a sparkline: a rolling sample buffer (oldest → newest), a
// colour ({} = theme accent), and an area-fill alpha under the line (0 = line
// only, like GNOME System Monitor; > 0 = filled, like cosmic-monitor).
Trace :: struct {
	values: []f32,
	color:  Color,
	fill:   f32,
}

// Chart_Axis is the shared axis model behind the chart widgets: value range,
// scale, grid, bands, and the optional Y-unit / X-time labels. Written once,
// used by both the sparklines and the bar chart.
@(private)
Chart_Axis :: struct {
	min, max:    f32,          // resolved bounds (decade-rounded when log)
	scale:       Scale,
	grid:        bool,
	grid_color:  Color,
	y_unit:      string,
	y_right:     bool,
	x_secs:      f32,
	x_label:     proc(secs_ago: f32) -> string,  // nil = auto (humane units)
	bands:       []Ref_Band,
	label_color: Color,
	label_size:  f32,
}

// sparkline draws one rolling time-series line (oldest → newest). `width = 0`
// fills the slot; `max = 0` auto-scales (else pins the top); `fill > 0` shades
// under the line; `grid` and the axis labels (`y_unit`/`y_right`, `x_secs`)
// default off. `scale = .Log10` gives a decade axis, `bands` shades reference
// ranges behind the line. Several lines on shared axes: `sparkline_multi`.
sparkline :: proc(
	ctx:     ^Ctx($Msg),
	values:  []f32,
	width:   f32,
	height:  f32,
	min:     f32 = 0,
	max:     f32 = 0,
	color:   Color = {},
	fill:    f32 = 0,
	grid:    bool = false,
	y_unit:  string = "",
	y_right: bool = false,
	x_secs:  f32 = 0,
	scale:   Scale = .Linear,
	bands:   []Ref_Band = nil,
	x_label: proc(secs_ago: f32) -> string = nil,
	id:      Widget_ID = 0,
) -> View {
	return sparkline_multi(ctx,
		[]Trace{ {values = values, color = color, fill = fill} },
		width, height, min = min, max = max, grid = grid,
		y_unit = y_unit, y_right = y_right, x_secs = x_secs,
		scale = scale, bands = bands, x_label = x_label, id = id)
}

@(private)
Sparkline_Data :: struct {
	axis:   Chart_Axis,
	traces: []Trace,
}

// sparkline_multi draws several traces sharing one set of axes — net up + down,
// or every CPU core overlaid (GNOME's combined view). Same scaling rules as
// `sparkline`: `max = 0` auto-scales to the peak across all traces.
sparkline_multi :: proc(
	ctx:    ^Ctx($Msg),
	traces: []Trace,
	width:  f32,
	height: f32,
	min:    f32 = 0,
	max:    f32 = 0,
	grid:    bool = false,
	y_unit:  string = "",
	y_right: bool = false,
	x_secs:  f32 = 0,
	scale:   Scale = .Linear,
	bands:   []Ref_Band = nil,
	x_label: proc(secs_ago: f32) -> string = nil,
	id:      Widget_ID = 0,
) -> View {
	th := ctx.theme

	lo, hi := chart_bounds(traces, min, max, scale)

	// Copy traces + each sample slice into the frame arena: the caller may hand
	// us a stack-temporary slice (the view-slice-lifetime rule), and the canvas
	// draw callback runs later in the render pass.
	cp := make([]Trace, len(traces), context.temp_allocator)
	for t, i in traces {
		vc := make([]f32, len(t.values), context.temp_allocator)
		copy(vc, t.values)
		col := t.color
		if col.a == 0 { col = th.color.primary }
		cp[i] = Trace{values = vc, color = col, fill = t.fill}
	}

	data := new(Sparkline_Data, context.temp_allocator)
	data^ = Sparkline_Data{
		axis   = chart_axis(th, lo, hi, scale, grid, y_unit, y_right, x_secs, x_label, bands),
		traces = cp,
	}

	mw := width
	if mw == 0 { mw = 120 }
	return canvas(ctx, data, sparkline_draw, id = id,
		width = width, height = height, min_w = mw, min_h = height)
}

@(private)
sparkline_draw :: proc(d: ^Sparkline_Data, p: Canvas_Painter) {
	ax    := &d.axis
	plot  := chart_plot_rect(ax, p.r, p.bounds)
	ticks := chart_yticks(ax, p.r, plot)

	chart_draw_bands(ax, p.r, plot)
	chart_draw_grid(ax, p.r, plot, ticks)

	// Fills first, then lines on top, so a later trace's fill can't bury an
	// earlier trace's line.
	for t in d.traces {
		if t.fill <= 0 || len(t.values) < 2 { continue }
		n := len(t.values)
		strip := make([dynamic][2]f32, 0, n * 2, context.temp_allocator)
		for v, i in t.values {
			x := plot.x + plot.w * f32(i) / f32(n - 1)
			append(&strip, [2]f32{x, chart_y_at(ax, plot, v)})
			append(&strip, [2]f32{x, plot.y + plot.h})
		}
		fc := t.color
		fc.a = t.fill
		draw_triangle_strip(p.r, strip[:], fc)
	}

	for t in d.traces {
		n := len(t.values)
		if n < 2 { continue }
		pts := make([][2]f32, n, context.temp_allocator)
		for v, i in t.values {
			x := plot.x + plot.w * f32(i) / f32(n - 1)
			pts[i] = {x, chart_y_at(ax, plot, v)}
		}
		aa_polyline(p.r, pts, 1.6, t.color)
	}

	chart_draw_labels(ax, p.r, plot, ticks)
}

// bar_chart draws vertical bars from `values` (oldest → newest). `width = 0`
// fills the slot; `max = 0` auto-scales (else pins the top). Bars use `color`,
// or `color_of(v)` for a per-bar colour (storm level, alert band); `gap` is the
// pixel spacing, and negative data draws below a zero baseline.
bar_chart :: proc(
	ctx:      ^Ctx($Msg),
	values:   []f32,
	width:    f32,
	height:   f32,
	min:      f32 = 0,
	max:      f32 = 0,
	color:    Color = {},
	color_of: proc(v: f32) -> Color = nil,
	gap:      f32 = 1,
	grid:     bool = false,
	y_unit:   string = "",
	y_right:  bool = false,
	x_secs:   f32 = 0,
	id:       Widget_ID = 0,
) -> View {
	th := ctx.theme

	hi := max
	if hi <= 0 {
		for v in values { if v > hi { hi = v } }
		hi *= 1.1
		if hi <= 0 { hi = 1 }
	}

	base := color
	if base.a == 0 { base = th.color.primary }

	// Copy values + resolve per-bar colours into the frame arena (the canvas draw
	// runs later this frame; the caller's slice may be a stack temporary).
	vc := make([]f32, len(values), context.temp_allocator)
	copy(vc, values)
	cols := make([]Color, len(values), context.temp_allocator)
	for v, i in values {
		c := color_of != nil ? color_of(v) : base
		if c.a == 0 { c = base }
		cols[i] = c
	}

	data := new(Bar_Chart_Data, context.temp_allocator)
	data^ = Bar_Chart_Data{
		axis   = chart_axis(th, min, hi, .Linear, grid, y_unit, y_right, x_secs, nil, nil),
		values = vc,
		colors = cols,
		gap    = gap,
	}

	mw := width
	if mw == 0 { mw = 120 }
	return canvas(ctx, data, bar_chart_draw, id = id,
		width = width, height = height, min_w = mw, min_h = height)
}

@(private)
Bar_Chart_Data :: struct {
	axis:   Chart_Axis,
	values: []f32,
	colors: []Color,
	gap:    f32,
}

@(private)
bar_chart_draw :: proc(d: ^Bar_Chart_Data, p: Canvas_Painter) {
	ax    := &d.axis
	plot  := chart_plot_rect(ax, p.r, p.bounds)
	ticks := chart_yticks(ax, p.r, plot)

	chart_draw_bands(ax, p.r, plot)
	chart_draw_grid(ax, p.r, plot, ticks)

	n := len(d.values)
	if n > 0 {
		gap := d.gap
		bw  := (plot.w - gap * f32(n - 1)) / f32(n)
		if bw < 1 { gap = 0; bw = plot.w / f32(n) }         // too many bars for the width
		base_y := chart_y_at(ax, plot, clamp(0, ax.min, ax.max))
		for v, i in d.values {
			x   := plot.x + f32(i) * (bw + gap)
			y   := chart_y_at(ax, plot, v)
			top := min(y, base_y)
			bot := max(y, base_y)
			if bot - top < 0.5 { continue }
			draw_rect(p.r, {x, top, bw, bot - top}, d.colors[i], 0)
		}
	}

	chart_draw_labels(ax, p.r, plot, ticks)
}

// --- shared axis machinery (bounds, layout, ticks, grid, bands, labels) -------

// chart_bounds resolves the [lo, hi] value range: honour pinned min/max, else
// auto-scale to the data — 10 % headroom for linear, decade-rounded for log.
@(private)
chart_bounds :: proc(traces: []Trace, min, max: f32, scale: Scale) -> (lo, hi: f32) {
	if scale == .Log10 {
		dmin, dmax := f32(1e30), f32(0)
		for t in traces {
			for v in t.values {
				if v > 0 && v < dmin { dmin = v }
				if v > dmax { dmax = v }
			}
		}
		hi = max
		if hi <= 0 { hi = dmax > 0 ? math.pow(f32(10), math.ceil(math.log10(dmax))) : 1 }
		lo = min
		if lo <= 0 { lo = dmin < 1e30 ? math.pow(f32(10), math.floor(math.log10(dmin))) : hi / 1000 }
		if lo >= hi { lo = hi / 10 }
		return
	}
	hi = max
	if hi <= 0 {
		for t in traces {
			for v in t.values { if v > hi { hi = v } }
		}
		hi *= 1.1
		if hi <= 0 { hi = 1 }
	}
	lo = min
	return
}

// chart_axis packs a resolved Chart_Axis: theme colours + a frame-arena deep
// copy of the bands (labels included — the canvas draw runs later this frame).
@(private)
chart_axis :: proc(th: ^Theme, lo, hi: f32, scale: Scale, grid: bool, y_unit: string,
                   y_right: bool, x_secs: f32, x_label: proc(secs_ago: f32) -> string,
                   bands: []Ref_Band) -> Chart_Axis {
	gc := th.color.border
	gc.a *= 0.6
	bc: []Ref_Band
	if len(bands) > 0 {
		bc = make([]Ref_Band, len(bands), context.temp_allocator)
		for band, i in bands {
			bc[i] = band
			bc[i].label = strings.clone(band.label, context.temp_allocator)
		}
	}
	return Chart_Axis{
		min = lo, max = hi, scale = scale, grid = grid, grid_color = gc,
		y_unit = y_unit, y_right = y_right, x_secs = x_secs, x_label = x_label,
		bands = bc, label_color = th.color.fg_muted, label_size = th.font.size_sm,
	}
}

// chart_y_show: draw the Y value labels/gutter on demand when a unit is set, and
// always for a log axis (its decade labels are the whole point).
@(private)
chart_y_show :: proc(ax: ^Chart_Axis) -> bool {
	return ax.y_unit != "" || ax.scale == .Log10
}

// chart_y_at maps a data value to a pixel Y inside `plot`, honouring the scale.
@(private)
chart_y_at :: proc(ax: ^Chart_Axis, plot: Rect, v: f32) -> f32 {
	f: f32
	if ax.scale == .Log10 {
		span := math.log10(ax.max) - math.log10(ax.min)
		if span <= 0 { span = 1 }
		vv := v > 0 ? v : ax.min
		f = clamp((math.log10(vv) - math.log10(ax.min)) / span, 0, 1)
	} else {
		rng := ax.max - ax.min
		if rng <= 0 { rng = 1 }
		f = clamp((v - ax.min) / rng, 0, 1)
	}
	return plot.y + plot.h * (1 - f)
}

// chart_plot_rect insets the widget bounds by the label gutters (Y values on the
// left or right, X time labels along the bottom) and returns the plot area.
@(private)
chart_plot_rect :: proc(ax: ^Chart_Axis, r: ^Renderer, b: Rect) -> Rect {
	fs := ax.label_size
	y_gutter: f32 = 0
	if chart_y_show(ax) {
		lab := ax.scale == .Log10 ? chart_fmt_log(ax.max) : chart_fmt_num(ax.max)
		w, _ := measure_text(r, fmt.tprintf("%s%s", lab, ax.y_unit), fs)
		if ax.scale == .Log10 {
			w2, _ := measure_text(r, fmt.tprintf("%s%s", chart_fmt_log(ax.min), ax.y_unit), fs)
			if w2 > w { w = w2 }
		}
		y_gutter = w + 6
	}
	x_gutter: f32 = 0
	if ax.x_secs > 0 {
		_, lh := measure_text(r, "0", fs)
		x_gutter = lh + 4
	}
	plot_x := b.x + y_gutter            // labels on the left by default
	if ax.y_right { plot_x = b.x }
	return Rect{plot_x, b.y, max(b.w - y_gutter, 1), max(b.h - x_gutter, 1)}
}

@(private)
Chart_Tick :: struct { frac: f32, label: string }

// chart_yticks builds the Y grid/label ticks (fraction from the top + formatted
// label): adaptive-density evenly-spaced fractions for a linear axis, one per
// decade (thinned to fit the height) for log.
@(private)
chart_yticks :: proc(ax: ^Chart_Axis, r: ^Renderer, plot: Rect) -> []Chart_Tick {
	fs := ax.label_size
	_, lh := measure_text(r, "0", fs)
	out := make([dynamic]Chart_Tick, 0, 8, context.temp_allocator)

	if ax.scale == .Log10 {
		lmin := math.log10(ax.min)
		lmax := math.log10(ax.max)
		span := lmax - lmin
		if span <= 0 { span = 1 }
		lo_k := int(math.ceil(lmin))
		hi_k := int(math.floor(lmax))
		decades := hi_k - lo_k + 1
		if decades < 1 { decades = 1 }
		fit := max(int(plot.h / (lh * 1.6)), 1)
		step := (decades + fit - 1) / fit                   // ceil(decades / fit)
		if step < 1 { step = 1 }
		for k := hi_k; k >= lo_k; k -= step {
			frac := (lmax - f32(k)) / span                  // 0 at top (max)
			val  := math.pow(f32(10), f32(k))
			lab  := fmt.tprintf("%s%s", chart_fmt_log(val), ax.y_unit)
			append(&out, Chart_Tick{frac = clamp(frac, 0, 1), label = lab})
		}
	} else {
		// Adaptive Y tick density so a short chart doesn't cram its labels: 5 needs
		// real height, otherwise fall back to 3 then 2.
		fracs := []f32{0, 1}
		switch {
		case plot.h >= lh * 7.5: fracs = []f32{0, 0.25, 0.5, 0.75, 1}
		case plot.h >= lh * 4:   fracs = []f32{0, 0.5, 1}
		}
		rng := ax.max - ax.min
		for frac in fracs {
			val := ax.max - rng * frac
			lab := fmt.tprintf("%s%s", chart_fmt_num(val), ax.y_unit)
			append(&out, Chart_Tick{frac = frac, label = lab})
		}
	}
	return out[:]
}

@(private)
chart_draw_grid :: proc(ax: ^Chart_Axis, r: ^Renderer, plot: Rect, ticks: []Chart_Tick) {
	if !ax.grid { return }
	for t in ticks {
		y := plot.y + plot.h * t.frac
		draw_rect(r, {plot.x, y, plot.w, 1}, ax.grid_color, 0)
	}
}

// chart_draw_bands paints the reference bands behind the data — translucent
// [lo, hi] fills with an optional top-edge label, clipped to the plot area.
@(private)
chart_draw_bands :: proc(ax: ^Chart_Axis, r: ^Renderer, plot: Rect) {
	if len(ax.bands) == 0 { return }
	fs  := ax.label_size
	asc := text_ascent(r, fs)
	for band in ax.bands {
		y_lo := chart_y_at(ax, plot, band.lo)
		y_hi := chart_y_at(ax, plot, band.hi)
		top  := clamp(min(y_lo, y_hi), plot.y, plot.y + plot.h)
		bot  := clamp(max(y_lo, y_hi), plot.y, plot.y + plot.h)
		if bot - top < 0.5 { continue }
		draw_rect(r, {plot.x, top, plot.w, bot - top}, band.color, 0)
		if band.label != "" {
			draw_text(r, band.label, plot.x + 3, top + asc + 1, ax.label_color, fs)
		}
	}
}

// chart_draw_labels draws the Y value labels (centred on each tick) and the X
// time labels (span..0, newest at right, humane units unless `x_label` is set).
@(private)
chart_draw_labels :: proc(ax: ^Chart_Axis, r: ^Renderer, plot: Rect, ticks: []Chart_Tick) {
	fs  := ax.label_size
	asc := text_ascent(r, fs)
	if chart_y_show(ax) {
		for t in ticks {
			tw, lh := measure_text(r, t.label, fs)
			ly := plot.y + plot.h * t.frac - lh * 0.5
			ly  = clamp(ly, plot.y, plot.y + plot.h - lh)
			lx := plot.x - 4 - tw                     // left gutter, right-aligned (default)
			if ax.y_right { lx = plot.x + plot.w + 4 } // right gutter, left-aligned
			draw_text(r, t.label, lx, ly + asc, ax.label_color, fs)
		}
	}
	if ax.x_secs > 0 {
		by := plot.y + plot.h + asc + 1
		xticks := []f32{0, 0.5, 1}
		for frac in xticks {
			secs_ago := ax.x_secs * (1 - frac)
			s: string
			if ax.x_label != nil {
				s = ax.x_label(secs_ago)
			} else if frac >= 0.999 {
				s = "0"
			} else {
				s = chart_fmt_secs(secs_ago)
			}
			tw, _ := measure_text(r, s, fs)
			x := plot.x + plot.w * frac
			if      frac >= 0.999 { x -= tw }        // right-align newest
			else if frac >  0.001 { x -= tw * 0.5 }  // centre the middles
			draw_text(r, s, x, by, ax.label_color, fs)
		}
	}
}

@(private)
chart_fmt_num :: proc(v: f32) -> string {
	av := abs(v)
	switch {
	case av >= 1e9: return fmt.tprintf("%.1fG", v / 1e9)
	case av >= 1e6: return fmt.tprintf("%.1fM", v / 1e6)
	case av >= 1e3: return fmt.tprintf("%.0fk", v / 1e3)
	case:           return fmt.tprintf("%.0f", v)
	}
}

// chart_fmt_log labels a base-10 decade for the log Y axis: "1", "10", "1k" for
// non-negative powers, "1e-6" for small ones. Avoids superscript glyphs (not in
// the bundled font).
@(private)
chart_fmt_log :: proc(v: f32) -> string {
	if v <= 0 { return "0" }
	e := int(math.round(math.log10(v)))
	switch {
	case e == 0:          return "1"
	case e > 0 && e <= 3: return chart_fmt_num(v)
	case:                 return fmt.tprintf("1e%d", e)
	}
}

// chart_fmt_secs formats a "seconds ago" X label in humane units, stepping
// s → m → h → d by magnitude so a multi-day window reads "3d", not "259200s".
@(private)
chart_fmt_secs :: proc(s: f32) -> string {
	switch {
	case s < 90:     return fmt.tprintf("%.0fs", s)
	case s < 5400:   return fmt.tprintf("%.0fm", s / 60)     // < 90 min
	case s < 172800: return fmt.tprintf("%.0fh", s / 3600)   // < 48 h
	case:            return fmt.tprintf("%.0fd", s / 86400)
	}
}

// --- anti-aliased vector helpers (feathered alpha-0 fringe; see draw_tris_vc) ---

@(private) AA_FEATHER :: f32(1.0)

@(private)
Chart_Verts :: struct {
	p: [dynamic][2]f32,
	c: [dynamic][4]f32,
}

@(private)
chart_quad :: proc(v: ^Chart_Verts, a, b, c, e: [2]f32, ca, cb, cc, ce: [4]f32) {
	append(&v.p, a, b, c, a, c, e)
	append(&v.c, ca, cb, cc, ca, cc, ce)
}

// aa_polyline draws an open polyline of uniform `width` as feathered segment
// quads: a solid core flanked by two alpha-0 fringes one feather wide. Joins
// overlap (no mitre) — invisible under the fringe for sparkline-shaped data.
@(private)
aa_polyline :: proc(r: ^Renderer, pts: [][2]f32, width: f32, color: Color) {
	n := len(pts)
	if n < 2 { return }
	hw   := width * 0.5
	core := [4]f32{color.r, color.g, color.b, color.a}
	edge := [4]f32{color.r, color.g, color.b, 0}

	v: Chart_Verts
	v.p.allocator = context.temp_allocator
	v.c.allocator = context.temp_allocator

	for i in 0 ..< n - 1 {
		a := pts[i]
		b := pts[i + 1]
		dx := b.x - a.x
		dy := b.y - a.y
		l  := math.sqrt(dx * dx + dy * dy)
		if l < 1e-6 { continue }
		nx := -dy / l
		ny :=  dx / l
		co := [2]f32{nx * hw, ny * hw}
		ce := [2]f32{nx * (hw + AA_FEATHER), ny * (hw + AA_FEATHER)}
		chart_quad(&v, a + co, b + co, b - co, a - co, core, core, core, core)         // core
		chart_quad(&v, a + ce, b + ce, b + co, a + co, edge, edge, core, core)         // top fringe
		chart_quad(&v, a - co, b - co, b - ce, a - ce, core, core, edge, edge)         // bottom fringe
	}
	draw_tris_vc(r, v.p[:], v.c[:])
}

@(private)
Gauge_Data :: struct {
	value:     f32,
	thickness: f32,
	color:     Color,
	track:     Color,
}

// gauge draws a radial donut filled clockwise from the top to `value` (0..1) —
// the "memory used 53 %" ring in a resource monitor. `size` is the diameter;
// `thickness = 0` picks a proportional ring width. Centre it under a value label
// with `stack(gauge(...), text("53%"))`; the gauge itself is just the ring.
gauge :: proc(
	ctx:       ^Ctx($Msg),
	value:     f32,
	size:      f32 = 64,
	thickness: f32 = 0,
	color:     Color = {},
	track:     Color = {},
	id:        Widget_ID = 0,
) -> View {
	th := ctx.theme
	c := color
	if c.a == 0 { c = th.color.primary }
	tr := track
	if tr.a == 0 { tr = th.color.surface }
	thick := thickness
	if thick == 0 { thick = size * 0.16 }

	d := new(Gauge_Data, context.temp_allocator)
	d^ = Gauge_Data{value = clamp(value, 0, 1), thickness = thick, color = c, track = tr}
	return canvas(ctx, d, gauge_draw, id = id,
		width = size, height = size, min_w = size, min_h = size)
}

@(private)
gauge_draw :: proc(d: ^Gauge_Data, p: Canvas_Painter) {
	b  := p.bounds
	cx := b.x + b.w * 0.5
	cy := b.y + b.h * 0.5
	r_out := min(b.w, b.h) * 0.5
	r_in  := r_out - d.thickness
	if r_in < 0 { r_in = 0 }

	top := f32(-math.PI * 0.5)
	aa_ring(p.r, cx, cy, r_in, r_out, top, top + math.TAU, d.track) // full track
	if d.value > 0 {
		aa_ring(p.r, cx, cy, r_in, r_out, top, top + d.value * math.TAU, d.color)
	}
}

// aa_ring tessellates an annular sector [a0, a1] into feathered geometry: a
// solid band between r_in and r_out, with an alpha-0 fringe on the outer and
// inner edges so the curve anti-aliases (see draw_tris_vc).
@(private)
aa_ring :: proc(r: ^Renderer, cx, cy, r_in, r_out, a0, a1: f32, color: Color) {
	if a1 <= a0 || r_out <= 0 { return }
	steps := int((a1 - a0) / math.TAU * 96)
	if steps < 3 { steps = 3 }
	core := [4]f32{color.r, color.g, color.b, color.a}
	edge := [4]f32{color.r, color.g, color.b, 0}
	r_ie := max(r_in - AA_FEATHER, 0)

	v: Chart_Verts
	v.p.allocator = context.temp_allocator
	v.c.allocator = context.temp_allocator

	at :: proc(cx, cy, cs, sn, rad: f32) -> [2]f32 { return {cx + cs * rad, cy + sn * rad} }

	p_oe, p_oc, p_ic, p_ie: [2]f32
	for i in 0 ..= steps {
		t  := a0 + (a1 - a0) * f32(i) / f32(steps)
		cs := math.cos(t)
		sn := math.sin(t)
		oe := at(cx, cy, cs, sn, r_out + AA_FEATHER)
		oc := at(cx, cy, cs, sn, r_out)
		ic := at(cx, cy, cs, sn, r_in)
		ie := at(cx, cy, cs, sn, r_ie)
		if i > 0 {
			chart_quad(&v, p_oe, oe, oc, p_oc, edge, edge, core, core) // outer fringe
			chart_quad(&v, p_oc, oc, ic, p_ic, core, core, core, core) // solid band
			chart_quad(&v, p_ic, ic, ie, p_ie, core, core, edge, edge) // inner fringe
		}
		p_oe, p_oc, p_ic, p_ie = oe, oc, ic, ie
	}
	draw_tris_vc(r, v.p[:], v.c[:])
}
