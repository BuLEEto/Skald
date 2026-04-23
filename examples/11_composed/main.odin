package example_composed

import "core:fmt"
import "gui:skald"

// Composition demo. The parent app hosts two independent Counter
// instances plus a scoreboard that sums them. Each sub-component owns
// its own state slot and emits its own `Counter_Msg`; `skald.map_msg`
// translates those into the parent's tagged `Msg` so `update` handles
// them through the usual elm pipeline.
//
// The point: neither the Counter component nor the host app knows about
// the other's Msg type. That's what makes sub-components reusable.

State :: struct {
	left:  Counter_State,
	right: Counter_State,
}

Msg :: union {
	Left_Msg,
	Right_Msg,
}

// Each wrapper is a distinct typedef over Counter_Msg. Using distinct
// types (rather than struct wrappers) keeps the union variants tagged
// while the payload value is still just a Counter_Msg enum, so update
// can forward it straight through with a cast.
Left_Msg  :: distinct Counter_Msg
Right_Msg :: distinct Counter_Msg

wrap_left  :: proc(m: Counter_Msg) -> Msg { return Left_Msg(m)  }
wrap_right :: proc(m: Counter_Msg) -> Msg { return Right_Msg(m) }

init :: proc() -> State {
	return {
		left  = counter_init("Team A"),
		right = counter_init("Team B"),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Left_Msg:  out.left  = counter_update(out.left,  Counter_Msg(v))
	case Right_Msg: out.right = counter_update(out.right, Counter_Msg(v))
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	total := s.left.value + s.right.value
	scoreboard := skald.col(
		skald.text("Total", th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.xs),
		skald.text(fmt.tprintf("%d", total), th.color.fg, th.font.size_xl),
		cross_align = .Center,
	)

	return skald.col(
		scoreboard,
		skald.spacer(th.spacing.xl),
		skald.row(
			skald.map_msg(ctx, s.left,  counter_view, wrap_left),
			skald.map_msg(ctx, s.right, counter_view, wrap_right),
			spacing     = th.spacing.lg,
			cross_align = .Stretch,
		),
		padding     = th.spacing.xl,
		main_align  = .Center,
		cross_align = .Center,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Composed",
		size   = {640, 440},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
