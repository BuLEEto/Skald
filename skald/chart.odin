package skald

import "core:fmt"
import "core:math"

// Sparklines + a radial gauge — the resource-monitor widgets (CPU / memory
// history, a memory-used donut). Canvas-backed: they pack their data into the
// frame arena and paint with draw_tris_vc / draw_triangle_strip, so there's no
// new renderer or layout code, and `width = 0` fills the slot like any canvas.
// The app owns the data: keep a rolling buffer per metric (sampled off-thread)
// and hand the slice over each frame. Skald draws; the app samples.

// Trace is one line on a sparkline: a rolling sample buffer (oldest → newest), a
// colour ({} = theme accent), and an area-fill alpha under the line (0 = line
// only, like GNOME System Monitor; > 0 = filled, like cosmic-monitor).
Trace :: struct {
	values: []f32,
	color:  Color,
	fill:   f32,
}

// sparkline draws one rolling time-series line (oldest → newest). `width = 0`
// fills the slot; `max = 0` auto-scales to the peak (else pins the top, e.g. 100
// for a % axis); `fill > 0` shades under the line. `grid` and the axis labels
// (`y_unit`, left or `y_right`; `x_secs` time axis) default off. For several
// lines on one graph use `sparkline_multi`.
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
	id:      Widget_ID = 0,
) -> View {
	return sparkline_multi(ctx,
		[]Trace{ {values = values, color = color, fill = fill} },
		width, height, min = min, max = max, grid = grid,
		y_unit = y_unit, y_right = y_right, x_secs = x_secs, id = id)
}

@(private)
Sparkline_Data :: struct {
	traces:      []Trace,
	min, max:    f32,
	grid:        bool,
	grid_color:  Color,
	y_unit:      string,
	y_right:     bool,
	x_secs:      f32,
	label_color: Color,
	label_size:  f32,
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
	id:      Widget_ID = 0,
) -> View {
	th := ctx.theme

	// Auto-scale: the largest sample across every trace, with a floor so a flat
	// zero series doesn't divide by zero (and leaves a little headroom).
	hi := max
	if hi <= 0 {
		for t in traces {
			for v in t.values { if v > hi { hi = v } }
		}
		hi *= 1.1
		if hi <= 0 { hi = 1 }
	}

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

	gc := th.color.border
	gc.a *= 0.6

	data := new(Sparkline_Data, context.temp_allocator)
	data^ = Sparkline_Data{
		traces = cp, min = min, max = hi, grid = grid, grid_color = gc,
		y_unit = y_unit, y_right = y_right, x_secs = x_secs,
		label_color = th.color.fg_muted, label_size = th.font.size_sm,
	}

	mw := width
	if mw == 0 { mw = 120 }
	return canvas(ctx, data, sparkline_draw, id = id,
		width = width, height = height, min_w = mw, min_h = height)
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

@(private)
sparkline_draw :: proc(d: ^Sparkline_Data, p: Canvas_Painter) {
	b   := p.bounds
	rng := d.max - d.min
	if rng <= 0 { rng = 1 }

	fs  := d.label_size
	asc := text_ascent(p.r, fs)

	// Reserve gutters for axis labels (only when requested) and inset the plot.
	y_gutter: f32 = 0
	if d.y_unit != "" {
		w, _ := measure_text(p.r, fmt.tprintf("%s%s", chart_fmt_num(d.max), d.y_unit), fs)
		y_gutter = w + 6
	}
	x_gutter: f32 = 0
	if d.x_secs > 0 {
		_, lh := measure_text(p.r, "0", fs)
		x_gutter = lh + 4
	}
	plot_x := b.x + y_gutter            // labels on the left by default
	if d.y_right { plot_x = b.x }
	plot := Rect{plot_x, b.y, max(b.w - y_gutter, 1), max(b.h - x_gutter, 1)}

	// Adaptive Y tick density so a short chart doesn't cram its labels: 5 needs
	// real height, otherwise fall back to 3 then 2. The grid follows the labels.
	_, lh0 := measure_text(p.r, "0", fs)
	yticks := []f32{0, 1}
	switch {
	case plot.h >= lh0 * 7.5: yticks = []f32{0, 0.25, 0.5, 0.75, 1}
	case plot.h >= lh0 * 4:   yticks = []f32{0, 0.5, 1}
	}
	xticks := []f32{0, 0.5, 1}

	if d.grid {
		for frac in yticks {
			y := plot.y + plot.h * frac
			draw_rect(p.r, {plot.x, y, plot.w, 1}, d.grid_color, 0)
		}
	}

	y_at :: proc(plot: Rect, v, mn, rng: f32) -> f32 {
		f := clamp((v - mn) / rng, 0, 1)
		return plot.y + plot.h * (1 - f)
	}

	// Fills first, then lines on top, so a later trace's fill can't bury an
	// earlier trace's line.
	for t in d.traces {
		if t.fill <= 0 || len(t.values) < 2 { continue }
		n := len(t.values)
		strip := make([dynamic][2]f32, 0, n * 2, context.temp_allocator)
		for v, i in t.values {
			x := plot.x + plot.w * f32(i) / f32(n - 1)
			append(&strip, [2]f32{x, y_at(plot, v, d.min, rng)})
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
			pts[i] = {x, y_at(plot, v, d.min, rng)}
		}
		aa_polyline(p.r, pts, 1.6, t.color)
	}

	// Value-axis labels, centred on each grid line (clamped to the plot band).
	if d.y_unit != "" {
		for frac in yticks {
			s := fmt.tprintf("%s%s", chart_fmt_num(d.max - rng * frac), d.y_unit)
			tw, lh := measure_text(p.r, s, fs)
			ly := plot.y + plot.h * frac - lh * 0.5
			ly = clamp(ly, plot.y, plot.y + plot.h - lh)
			lx := plot.x - 4 - tw                     // left gutter, right-aligned (default)
			if d.y_right { lx = plot.x + plot.w + 4 } // right gutter, left-aligned
			draw_text(p.r, s, lx, ly + asc, d.label_color, fs)
		}
	}
	// Time labels along the bottom: span..0, newest at the right.
	if d.x_secs > 0 {
		by := plot.y + plot.h + asc + 1
		for frac in xticks {
			s := frac >= 0.999 ? "0" : fmt.tprintf("%.0fs", d.x_secs * (1 - frac))
			tw, _ := measure_text(p.r, s, fs)
			x := plot.x + plot.w * frac
			if      frac >= 0.999 { x -= tw }        // right-align newest
			else if frac >  0.001 { x -= tw * 0.5 }  // centre the middles
			draw_text(p.r, s, x, by, d.label_color, fs)
		}
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
