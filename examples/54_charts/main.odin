package example_charts

import "core:fmt"
import "core:math"
import "gui:skald"

// The chart widgets: `sparkline` (one rolling series), `sparkline_multi` (several
// on shared axes), `bar_chart` (per-bar colours), and `gauge` (a radial donut).
// The flux plot shows the log axis with reference bands + an hours time axis; the
// Kp plot shows a bar chart coloured by value. All are canvas-backed and take
// their data from the app — here it's synthetic (generated once in `init`) so the
// example is portable; a real monitor would sample a rolling buffer per metric.

N :: 120

State :: struct {
	cpu:    []f32,
	mem:    []f32,
	cores:  [][]f32,
	dl, ul: []f32,
	flux:   []f32,   // log-scale series (solar X-ray flux, W/m²)
	kp:     []f32,   // bar-chart series (Kp index, 0..9)
}

Msg :: enum { Nop }

// NOAA-style G-scale colour for a Kp bar: green (quiet) → red (severe storm).
kp_color :: proc(v: f32) -> skald.Color {
	switch {
	case v >= 8: return {0.85, 0.20, 0.22, 1}   // G4–G5
	case v >= 6: return {0.95, 0.45, 0.20, 1}   // G2–G3
	case v >= 5: return {0.95, 0.75, 0.20, 1}   // G1
	case:        return {0.45, 0.75, 0.45, 1}   // below storm level
	}
}

CORE_COLORS := [4]skald.Color{
	{0.91, 0.34, 0.34, 1}, {0.95, 0.60, 0.22, 1},
	{0.38, 0.72, 0.95, 1}, {0.45, 0.80, 0.45, 1},
}

// Deterministic 0..1 pseudo-noise so the curves look organic without an RNG.
noise :: proc(i: int, seed: f32) -> f32 {
	x := math.sin(f32(i) * 12.9898 + seed * 78.233) * 43758.5453
	return x - math.floor(x)
}

series :: proc(base, amp, freq, phase, jitter, lo, hi: f32) -> []f32 {
	out := make([]f32, N)
	for i in 0 ..< N {
		t := f32(i)
		v := base + amp * math.sin(t * freq + phase)
		v += amp * 0.35 * math.sin(t * freq * 2.6 + phase * 1.7)
		v += (noise(i, phase) - 0.5) * jitter
		out[i] = clamp(v, lo, hi)
	}
	return out
}

init :: proc() -> State {
	cores := make([][]f32, 4)
	for i in 0 ..< 4 {
		cores[i] = series(28 + f32(i) * 6, 22, 0.10 + f32(i) * 0.015, f32(i) * 1.3, 18, 0, 100)
	}
	// X-ray flux: build it in log space (a quiet B/C background with an M-class
	// flare bump) so it spans several decades — the case the log axis is for.
	flux := make([]f32, N)
	for i in 0 ..< N {
		t := f32(i)
		e := -6.6 + 0.4 * math.sin(t * 0.05) + (noise(i, 3.0) - 0.5) * 0.4
		e += 1.9 * math.exp(-((t - 78) * (t - 78)) / 120)   // the flare
		flux[i] = math.pow(10, e)
	}

	// Kp index: eight 3-hour samples building into a storm.
	kp := []f32{2, 3, 2, 4, 5, 6, 7, 5}
	kp_buf := make([]f32, len(kp))
	copy(kp_buf, kp)

	return State{
		cpu   = series(40, 30, 0.09, 0.0, 22, 0, 100),
		mem   = series(56, 6, 0.04, 2.0, 4, 0, 100),
		cores = cores,
		dl    = series(1.1e6, 0.9e6, 0.13, 0.5, 0.8e6, 0, 4e6),
		ul    = series(2.2e5, 1.8e5, 0.17, 2.4, 1.5e5, 0, 1e6),
		flux  = flux,
		kp    = kp_buf,
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

card :: proc(ctx: ^skald.Ctx(Msg), title, value: string, body: skald.View) -> skald.View {
	th := ctx.theme
	header: skald.View =
		value == "" \
		? skald.text(title, th.color.fg, th.font.size_md) \
		: skald.row(
			skald.text(title, th.color.fg, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.text(value, th.color.fg_muted, th.font.size_md),
			cross_align = .Center,
		)
	return skald.col(
		header, body,
		spacing = th.spacing.sm, padding = th.spacing.lg,
		bg = th.color.surface, radius = th.radius.md,
		cross_align = .Stretch, width = 580,
	)
}

last :: proc(s: []f32) -> f32 { return len(s) > 0 ? s[len(s) - 1] : 0 }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// CPU — one filled trace, fixed 0–100 %, value axis (left) + time axis.
	cpu := card(ctx, "CPU", fmt.tprintf("%.0f%%", last(s.cpu)),
		skald.sparkline(ctx, s.cpu, 0, 120, max = 100, fill = 0.18,
			grid = true, y_unit = "%", x_secs = 60))

	// Per-core — four lines on shared axes.
	traces := make([dynamic]skald.Trace, context.temp_allocator)
	for c, i in s.cores {
		append(&traces, skald.Trace{values = c, color = CORE_COLORS[i]})
	}
	cores := card(ctx, "Per-core", "",
		skald.sparkline_multi(ctx, traces[:], 0, 90, max = 100, grid = true, y_unit = "%"))

	// Memory — history line + a donut gauge with the % beneath it.
	mem_c := skald.Color{0.45, 0.80, 0.45, 1}
	mem := card(ctx, "Memory", fmt.tprintf("%.0f%% used", last(s.mem)),
		skald.row(
			skald.flex(1, skald.sparkline(ctx, s.mem, 0, 96,
				max = 100, color = mem_c, fill = 0.18, grid = true, y_unit = "%")),
			skald.col(
				skald.gauge(ctx, last(s.mem) / 100, 80, color = mem_c),
				skald.text(fmt.tprintf("%.0f%%", last(s.mem)), th.color.fg, th.font.size_md),
				cross_align = .Center, spacing = 4,
			),
			spacing = th.spacing.lg, cross_align = .Center,
		))

	// Network — two auto-scaled traces (no fixed max), right-side axis.
	net_traces := []skald.Trace{
		{values = s.dl, color = CORE_COLORS[2]},
		{values = s.ul, color = CORE_COLORS[1]},
	}
	net := card(ctx, "Network", "↓ download   ↑ upload",
		skald.sparkline_multi(ctx, net_traces, 0, 90, grid = true, y_unit = "B/s", y_right = true))

	// X-ray flux — log axis with flare-class reference bands, over a 6-hour window
	// so the time labels read in hours, not raw seconds.
	flare_bands := []skald.Ref_Band{
		{lo = 1e-7, hi = 1e-6, color = {0.45, 0.75, 0.45, 0.14}, label = "B"},
		{lo = 1e-6, hi = 1e-5, color = {0.95, 0.75, 0.20, 0.14}, label = "C"},
		{lo = 1e-5, hi = 1e-4, color = {0.95, 0.45, 0.20, 0.16}, label = "M"},
		{lo = 1e-4, hi = 1e-3, color = {0.85, 0.20, 0.22, 0.18}, label = "X"},
	}
	flux := card(ctx, "Solar X-ray flux", fmt.tprintf("%.0e W/m²", last(s.flux)),
		skald.sparkline(ctx, s.flux, 0, 130, min = 1e-8, max = 1e-3, scale = .Log10,
			bands = flare_bands, fill = 0.10, grid = true, y_unit = "", x_secs = 6 * 3600))

	// Kp index — a bar chart, one bar per 3-hour sample, coloured by storm level.
	kp := card(ctx, "Planetary Kp", fmt.tprintf("Kp %.0f", last(s.kp)),
		skald.bar_chart(ctx, s.kp, 0, 110, max = 9, color_of = kp_color,
			gap = 4, grid = true, y_unit = ""))

	return skald.scroll(ctx, {620, 740},
		skald.col(
			skald.text("Charts — sparkline / bar / gauge", th.color.fg, th.font.size_lg),
			cpu, cores, mem, net, flux, kp,
			spacing = th.spacing.lg, padding = th.spacing.xl, cross_align = .Start,
		))
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Charts",
		size   = {660, 780},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
