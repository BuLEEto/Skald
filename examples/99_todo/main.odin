package example_todo

import "core:strings"
import "gui:skald"

State :: struct {
	draft: string,
	items: [dynamic]string,
}

Msg :: union {
	Draft_Changed,
	Add_Clicked,
	Remove_Clicked,
}

Draft_Changed  :: distinct string
Add_Clicked    :: struct {}
Remove_Clicked :: distinct int

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Draft_Changed:
		delete(out.draft)
		out.draft = strings.clone(string(v))
	case Add_Clicked:
		if len(out.draft) == 0 { return out, {} }
		append(&out.items, strings.clone(out.draft))
		delete(out.draft)
		out.draft = strings.clone("")
	case Remove_Clicked:
		i := int(v)
		if i < 0 || i >= len(out.items) { return out, {} }
		delete(out.items[i])
		ordered_remove(&out.items, i)
	}
	return out, {}
}

on_draft :: proc(v: string) -> Msg { return Draft_Changed(v) }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows: [dynamic]skald.View
	rows.allocator = context.temp_allocator

	for item, i in s.items {
		remove_msg := Remove_Clicked(i)
		append(&rows, skald.row(
			skald.text(item, th.color.fg, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "×", remove_msg, width = 32,
				color = th.color.danger, fg = th.color.on_primary),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		))
	}

	return skald.col(
		skald.text("Todo", th.color.fg, th.font.size_lg),
		skald.row(
			skald.flex(1, skald.text_input(ctx, s.draft, on_draft,
				placeholder = "What needs doing?")),
			skald.button(ctx, "Add", Add_Clicked{}, width = 80,
				color = th.color.primary, fg = th.color.on_primary),
			spacing = th.spacing.sm,
		),
		skald.col(..rows[:], spacing = th.spacing.xs),
		padding = th.spacing.lg,
		spacing = th.spacing.md,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Todo",
		size   = {480, 600},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
