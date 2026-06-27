package example_charts

import "core:fmt"
import "core:math"
import "gui:skald"

// Sparklines + gauge: the resource-monitor widgets. `sparkline` draws one rolling
// series, `sparkline_multi` several on shared axes, and `gauge` a radial donut.
// All three are canvas-backed and take their data from the app — here it's
// synthetic (generated once in `init`) so the example is portable; a real
// monitor would keep a rolling buffer per metric sampled from the OS.

N :: 120

State :: struct {
	cpu:    []f32,
	mem:    []f32,
	cores:  [][]f32,
	dl, ul: []f32,
}

Msg :: enum { Nop }

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
	return State{
		cpu   = series(40, 30, 0.09, 0.0, 22, 0, 100),
		mem   = series(56, 6, 0.04, 2.0, 4, 0, 100),
		cores = cores,
		dl    = series(1.1e6, 0.9e6, 0.13, 0.5, 0.8e6, 0, 4e6),
		ul    = series(2.2e5, 1.8e5, 0.17, 2.4, 1.5e5, 0, 1e6),
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

	return skald.scroll(ctx, {620, 740},
		skald.col(
			skald.text("Charts — sparkline / gauge", th.color.fg, th.font.size_lg),
			cpu, cores, mem, net,
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
