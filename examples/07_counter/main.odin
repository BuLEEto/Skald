package example_counter

import "core:fmt"
import "gui:skald"

// A minimal end-to-end elm-style app. The view produces three buttons;
// each button carries a Msg value that the framework delivers to `update`
// on click. `update` returns a new State, and the next frame re-renders
// with it — no mutation, no hidden state.
State :: struct {
	count: int,
}

Msg :: enum {
	Inc,
	Dec,
	Reset,
}

init :: proc() -> State { return {count = 0} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	switch m {
	case .Inc:   return {count = s.count + 1}, {}
	case .Dec:   return {count = s.count - 1}, {}
	case .Reset: return {count = 0}, {}
	}
	return s, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// The label owns its own centered display of the count. `tprintf`
	// allocates into `context.temp_allocator`, which `run` drains each
	// frame, so we don't need to free anything.
	label := fmt.tprintf("Count: %d", s.count)

	return skald.col(
		skald.text(label, th.color.fg, th.font.size_display),

		skald.spacer(th.spacing.xl),

		skald.row(
			skald.button(ctx, "−", Msg.Dec,
				color = th.color.surface, fg = th.color.fg, width = 64),
			skald.button(ctx, "Reset", Msg.Reset,
				color = th.color.surface, fg = th.color.fg_muted, width = 96),
			skald.button(ctx, "+", Msg.Inc,
				color = th.color.primary, fg = th.color.on_primary, width = 64),
			spacing     = th.spacing.md,
			cross_align = .Center,
		),

		spacing     = th.spacing.md,
		padding     = th.spacing.xl,
		main_align  = .Center,
		cross_align = .Center,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Counter",
		size   = {640, 400},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
