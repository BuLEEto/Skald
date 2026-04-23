package example_stopwatch

import "core:fmt"
import "core:time"
import "gui:skald"

// Stopwatch driven by the Phase 9 Command/Effect system. The point is to
// demonstrate `cmd_delay` as a recurring timer: each `Tick` schedules the
// next one, so the chain stays alive while running and stops the moment
// a Tick lands with `running = false`.
//
// Elapsed time is measured against the wall clock (`time.now()`), not by
// counting Ticks, so pauses and frame jitter don't drift the readout.

State :: struct {
	running:      bool,
	elapsed_ns:   i64,
	last_tick_ns: i64,
}

Msg :: enum {
	Toggle,
	Reset,
	Tick,
}

TICK_SECONDS :: f32(1.0 / 60.0)

init :: proc() -> State {
	return {}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch m {
	case .Toggle:
		if out.running {
			// Pausing — fold the final slice into elapsed so the readout
			// reflects time right up to the click.
			out.elapsed_ns += time.now()._nsec - out.last_tick_ns
			out.running = false
			return out, {}
		}
		out.running = true
		out.last_tick_ns = time.now()._nsec
		return out, skald.cmd_delay(TICK_SECONDS, Msg.Tick)

	case .Reset:
		out.elapsed_ns = 0
		out.last_tick_ns = time.now()._nsec
		return out, {}

	case .Tick:
		// A stray Tick can arrive one frame after Pause — the delay was
		// already in flight when Toggle fired. Drop it.
		if !out.running {
			return out, {}
		}
		now_ns := time.now()._nsec
		out.elapsed_ns += now_ns - out.last_tick_ns
		out.last_tick_ns = now_ns
		return out, skald.cmd_delay(TICK_SECONDS, Msg.Tick)
	}
	return out, {}
}

format_elapsed :: proc(ns: i64) -> string {
	total_ms := ns / 1_000_000
	minutes  := total_ms / 60_000
	seconds  := (total_ms / 1000) % 60
	millis   := total_ms % 1000
	return fmt.tprintf("%02d:%02d.%03d", minutes, seconds, millis)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	toggle_label := "Start"
	if s.running { toggle_label = "Pause" }

	toggle_color := th.color.primary
	if s.running { toggle_color = th.color.surface }

	// Proper fix is tabular figures (OpenType `tnum`), which fontstash
	// doesn't expose. Anchor the readout to the left edge of a fixed-
	// width box instead: minutes/seconds barely change, so only the
	// trailing milliseconds wobble, and the outer layout stays still.
	readout := skald.col(
		skald.text(format_elapsed(s.elapsed_ns), th.color.fg, th.font.size_display),
		width       = 320,
		cross_align = .Start,
	)

	return skald.col(
		skald.text("Stopwatch", th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.sm),
		readout,
		skald.spacer(th.spacing.xl),
		skald.row(
			skald.button(ctx, toggle_label, Msg.Toggle,
				color = toggle_color, fg = th.color.fg, width = 140),
			skald.button(ctx, "Reset", Msg.Reset,
				color = th.color.surface, fg = th.color.fg_muted, width = 140),
			spacing = th.spacing.md,
		),
		padding     = th.spacing.xl,
		main_align  = .Center,
		cross_align = .Center,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Stopwatch",
		size   = {520, 360},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
