package example_composed

import "core:fmt"
import "gui:skald"

// A reusable counter component. Its view proc has the same shape as any
// top-level `App.view` — `proc(state, ctx) -> View` — which is exactly
// what `skald.map_msg` needs to embed it inside a larger app. The
// component knows nothing about the host Msg type; the host provides a
// transform that wraps `Counter_Msg` values as they bubble up.

Counter_State :: struct {
	value: int,
	label: string, // display header for this instance ("Left", "Right", etc.)
}

Counter_Msg :: enum {
	Inc,
	Dec,
	Reset,
}

counter_init :: proc(label: string) -> Counter_State {
	return {value = 0, label = label}
}

counter_update :: proc(s: Counter_State, m: Counter_Msg) -> Counter_State {
	out := s
	switch m {
	case .Inc:   out.value += 1
	case .Dec:   out.value -= 1
	case .Reset: out.value  = 0
	}
	return out
}

counter_view :: proc(s: Counter_State, ctx: ^skald.Ctx(Counter_Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(s.label, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.text(fmt.tprintf("%d", s.value), th.color.fg, th.font.size_display),
		skald.spacer(th.spacing.md),
		skald.row(
			skald.button(ctx, "−", Counter_Msg.Dec,
				color = th.color.surface, fg = th.color.fg, width = 48),
			skald.button(ctx, "Reset", Counter_Msg.Reset,
				color = th.color.surface, fg = th.color.fg_muted, width = 80),
			skald.button(ctx, "+", Counter_Msg.Inc,
				color = th.color.primary, fg = th.color.on_primary, width = 48),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		),
		spacing     = 0,
		padding     = th.spacing.lg,
		cross_align = .Center,
		bg          = th.color.elevated,
		radius      = th.radius.md,
	)
}
