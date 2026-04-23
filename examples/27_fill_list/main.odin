package example_fill_list

import "core:fmt"
import "gui:skald"

// Header + virtual_list that fills the remaining window height. The
// list is wrapped in `flex(1, ...)` and given a viewport with zero
// on the height axis — the new `sized()`-backed fill path hands the
// real assigned height down *this* frame, no one-frame lag.
//
// Resize the window and watch the "visible window" / "rows built this
// frame" numbers respond immediately without a blink.

ROW_COUNT   :: 50_000
ITEM_HEIGHT :: 32.0

State :: struct {
	last_built: int,
}

Msg :: union {}

init   :: proc() -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

row_key :: proc(s: ^State, i: int) -> u64 { return u64(i) }

row :: proc(ctx: ^skald.Ctx(Msg), s: ^State, i: int) -> skald.View {
	th := ctx.theme
	s.last_built += 1

	label := fmt.tprintf("Row %06d", i)
	return skald.row(
		skald.text(label, th.color.fg, th.font.size_md),
		padding     = th.spacing.sm,
		spacing     = 0,
		bg          = th.color.surface if i % 2 == 0 else th.color.elevated,
		cross_align = .Center,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	s_mut := s
	s_mut.last_built = 0

	// Zero height → take the flex parent's allocation. Width is 0 too
	// here (the column stretches us horizontally).
	list := skald.virtual_list(ctx,
		&s_mut, ROW_COUNT, ITEM_HEIGHT,
		{0, 0},
		row, row_key)

	info := fmt.tprintf("%d rows • rendered window fills the rest of the window",
		ROW_COUNT)

	return skald.col(
		skald.text("Skald — Fill-height Virtual List", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(info, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.md),
		skald.flex(1, list),
		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Fill Virtual List",
		size   = {640, 720},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
