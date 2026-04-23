package example_sized

import "core:fmt"
import "gui:skald"

// Smoke test for `skald.sized` — the deferred-content primitive that
// hands a widget its assigned rect at layout time. Three flavours are
// on screen:
//
//   1. A box that prints its own rect. Resize the window and the text
//      updates in the *same* frame — no one-frame lag.
//   2. A row with two deferred boxes sharing the row via flex weights.
//      Each knows its own slice.
//   3. A deferred box nested inside a deferred box — the outer passes
//      its assigned size to its builder, which builds an inner sized()
//      to prove nesting works.

State :: struct {
	counter: int,
}

Msg :: union {
	Tick,
}

Tick :: struct{}

init   :: proc() -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch _ in m {
	case Tick: out.counter += 1
	}
	return out, {}
}

// Top-level deferred builder. `size` is whatever flex gave us.
report_box :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	th := ctx.theme
	label := fmt.tprintf("assigned: %.0f × %.0f  (tick %d)",
		size.x, size.y, s.counter)

	inner := skald.col(
		skald.text(label, th.color.fg, th.font.size_md),
		width       = size.x,
		height      = size.y,
		bg          = th.color.surface,
		radius      = th.radius.md,
		padding     = th.spacing.md,
		main_align  = .Center,
		cross_align = .Center,
	)
	return inner
}

// Second-flavour builder used in each half of the split row.
half_box :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	th := ctx.theme
	label := fmt.tprintf("%.0f × %.0f", size.x, size.y)
	return skald.col(
		skald.text(label, th.color.fg, th.font.size_lg),
		width       = size.x,
		height      = size.y,
		bg          = th.color.elevated,
		radius      = th.radius.md,
		padding     = th.spacing.md,
		main_align  = .Center,
		cross_align = .Center,
	)
}

// Third-flavour — nested. Outer builder accepts its size, then builds an
// inner `sized` that reports its own (smaller, padded) size.
outer_nested :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	th := ctx.theme
	outer_label := fmt.tprintf("outer %.0f × %.0f", size.x, size.y)
	return skald.col(
		skald.text(outer_label, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.sm),
		skald.flex(1, skald.sized(ctx, s, inner_nested)),
		width       = size.x,
		height      = size.y,
		bg          = th.color.surface,
		radius      = th.radius.md,
		padding     = th.spacing.md,
		cross_align = .Stretch,
	)
}

inner_nested :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	th := ctx.theme
	label := fmt.tprintf("inner %.0f × %.0f", size.x, size.y)
	return skald.col(
		skald.text(label, th.color.primary, th.font.size_md),
		width       = size.x,
		height      = size.y,
		bg          = th.color.bg,
		radius      = th.radius.sm,
		padding     = th.spacing.md,
		main_align  = .Center,
		cross_align = .Center,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Nudge the counter each frame so we can see that the deferred
	// builder runs every frame.
	skald.send(ctx, Tick{})

	s_mut := s

	return skald.col(
		skald.text("Skald — sized() primitive", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Resize the window — deferred boxes report their assigned rect each frame.",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.lg),

		// Flavour 1: single full-width report box taking a fixed-height flex slice.
		skald.flex(1, skald.sized(ctx, &s_mut, report_box)),
		skald.spacer(th.spacing.md),

		// Flavour 2: two sized boxes sharing a flex row.
		skald.flex(1, skald.row(
			skald.flex(1, skald.sized(ctx, &s_mut, half_box)),
			skald.spacer(th.spacing.md),
			skald.flex(2, skald.sized(ctx, &s_mut, half_box)),
			cross_align = .Stretch,
		)),
		skald.spacer(th.spacing.md),

		// Flavour 3: nested sized() inside sized().
		skald.flex(1, skald.sized(ctx, &s_mut, outer_nested)),

		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — sized()",
		size   = {720, 560},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
