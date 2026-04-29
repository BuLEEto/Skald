package example_views

import "gui:skald"

State :: struct {}
Msg   :: struct {}

init   :: proc()                 -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text("Skald",              th.color.fg,       th.font.size_display),
		skald.text("declarative views",  th.color.fg_muted, th.font.size_lg),

		skald.spacer(th.spacing.lg),

		skald.row(
			swatch(th.color.primary, th),
			swatch(th.color.success, th),
			swatch(th.color.warning, th),
			swatch(th.color.danger,  th),
			spacing = th.spacing.sm,
		),

		skald.spacer(th.spacing.lg),

		// A clipped sub-tree — the inner column is taller than the clip, so
		// the last row gets cut off by the scissor.
		skald.clip({300, 56},
			skald.col(
				labeled_bar("primary", th.color.primary,  th),
				labeled_bar("success", th.color.success,  th),
				labeled_bar("warning", th.color.warning,  th),
				labeled_bar("danger",  th.color.danger,   th),
				spacing = th.spacing.xs,
			),
		),

		spacing = th.spacing.md,
		padding = th.spacing.xl,
	)
}

// swatch returns a small rounded color block — used to demo row layout.
swatch :: proc(color: skald.Color, th: ^skald.Theme) -> skald.View {
	return skald.rect({80, 48}, color, th.radius.md)
}

// labeled_bar returns a row with a colored dot and a text label. Used to
// populate the clipped column so overflow is easy to see.
labeled_bar :: proc(label: string, color: skald.Color, th: ^skald.Theme) -> skald.View {
	return skald.row(
		skald.rect({16, 16}, color, th.radius.sm),
		skald.text(label, th.color.fg, th.font.size_md),
		spacing = th.spacing.sm,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Views",
		size   = {960, 600},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
