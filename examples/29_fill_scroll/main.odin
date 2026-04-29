package example_fill_scroll

import "core:fmt"
import "gui:skald"

// Non-virtualized `scroll` given a {0, 0} viewport so it fills the flex
// parent's allocation. Content is a tall column of static rows — proves
// the `sized()` migration onto `scroll` works the same way it does on
// `virtual_list` and `table`.

ROW_COUNT :: 200

State :: struct{}
Msg   :: union {}

init   :: proc() -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	rows := make([dynamic]skald.View, 0, ROW_COUNT, context.temp_allocator)
	for i in 0..<ROW_COUNT {
		label := fmt.tprintf("Row %03d  —  lorem ipsum dolor sit amet", i)
		append(&rows, skald.row(
			skald.text(label, th.color.fg, th.font.size_md),
			padding     = th.spacing.sm,
			spacing     = 0,
			bg          = th.color.surface if i % 2 == 0 else th.color.elevated,
			cross_align = .Center,
		))
	}

	content := skald.col(..rows[:],
		padding = 0, spacing = 0, cross_align = .Stretch)

	// Zero size → fill. Wrap in flex(1, ...) to actually get an allocation.
	sc := skald.scroll(ctx, {0, 0}, content)

	return skald.col(
		skald.text("Skald — Fill-height Scroll", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("scroll() with viewport {0,0} inside flex(1, …).",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.md),
		skald.flex(1, sc),
		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Fill Scroll",
		size   = {640, 560},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
