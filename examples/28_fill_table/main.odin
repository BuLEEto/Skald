package example_fill_table

import "core:fmt"
import "gui:skald"

// Header + `table` that fills the remaining window height. Proves the
// table migration onto `sized()` — viewport of `{0, 0}` means "take my
// flex parent's allocation" and is resolved this frame, not next.

ROW_COUNT  :: 20_000
ROW_HEIGHT :: 28.0

State :: struct{}
Msg   :: union {}

init   :: proc() -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

row_key :: proc(s: ^State, row: int) -> u64 { return u64(row) }

build_row :: proc(ctx: ^skald.Ctx(Msg), s: ^State, row: int) -> []skald.View {
	th := ctx.theme
	cells := make([]skald.View, 3, context.temp_allocator)
	cells[0] = skald.text(fmt.tprintf("%06d", row), th.color.fg_muted, th.font.size_sm)
	cells[1] = skald.text(fmt.tprintf("item-%d.bin", row), th.color.fg, th.font.size_sm)
	cells[2] = skald.text(fmt.tprintf("%d KB", (row * 37) %% 9000 + 12),
		th.color.fg_muted, th.font.size_sm)
	return cells
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	s_mut := s

	cols := []skald.Table_Column{
		{label = "id",   width = 100, align = .Start},
		{label = "name", width = 0,   align = .Start}, // flex
		{label = "size", width = 120, align = .End},
	}

	// Fill mode: viewport {0, 0} + flex(1, ...) wrapper.
	tbl := skald.table(ctx,
		&s_mut, cols, ROW_COUNT, ROW_HEIGHT,
		{0, 0},
		build_row,
		row_key,
		nil, nil, nil, nil, nil,
	)

	return skald.col(
		skald.text("Skald — Fill-height Table", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(fmt.tprintf("%d rows — viewport {{0,0}} + flex(1,…) resizes with the window.",
			ROW_COUNT), th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.md),
		skald.flex(1, tbl),
		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Fill Table",
		size   = {820, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
