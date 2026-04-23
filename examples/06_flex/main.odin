package example_flex

import "gui:skald"

State :: struct {}
Msg   :: struct {}

init   :: proc()                 -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

// The demo is a familiar three-zone chrome: a fixed-height header bar,
// a fixed-height footer bar, and a flex-1 body between them. The body is
// itself a row: a 220-px sidebar on the left, a flex-1 main panel on the
// right. Resize the window and the flex zones grow or shrink; the fixed
// zones keep their pixel sizes.
view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		header(th),
		skald.flex(1, body(th)),
		footer(th),
		cross_align = .Stretch,
	)
}

header :: proc(th: ^skald.Theme) -> skald.View {
	return skald.row(
		skald.text("Skald — Flex",       th.color.fg,       th.font.size_lg),
		skald.text("declarative layout", th.color.fg_muted, th.font.size_sm),
		height      = 56,
		padding     = th.spacing.lg,
		main_align  = .Space_Between,
		cross_align = .Center,
		bg          = th.color.elevated,
	)
}

body :: proc(th: ^skald.Theme) -> skald.View {
	return skald.row(
		sidebar(th),
		skald.flex(1, main_panel(th)),
		spacing     = th.spacing.md,
		padding     = th.spacing.md,
		cross_align = .Stretch,
	)
}

sidebar :: proc(th: ^skald.Theme) -> skald.View {
	return skald.col(
		nav_entry("Dashboard", th.color.primary, th),
		nav_entry("Projects",  th.color.fg,      th),
		nav_entry("Team",      th.color.fg,      th),
		nav_entry("Settings",  th.color.fg,      th),
		width       = 220,
		padding     = th.spacing.md,
		spacing     = th.spacing.xs,
		cross_align = .Stretch,
		bg          = th.color.surface,
		radius      = th.radius.lg,
	)
}

nav_entry :: proc(label: string, color: skald.Color, th: ^skald.Theme) -> skald.View {
	return skald.row(
		skald.rect({10, 10}, color, th.radius.pill),
		skald.text(label, color, th.font.size_md),
		spacing     = th.spacing.sm,
		padding     = th.spacing.sm,
		cross_align = .Center,
	)
}

main_panel :: proc(th: ^skald.Theme) -> skald.View {
	return skald.col(
		skald.text("Welcome back",                    th.color.fg,       th.font.size_display),
		skald.text("Everything builds on flex now.",  th.color.fg_muted, th.font.size_md),

		skald.spacer(th.spacing.lg),

		skald.text("Space_Between distributes leftover main-axis space as gaps:",
			th.color.fg_muted, th.font.size_sm),
		chip_row(th),

		skald.spacer(th.spacing.lg),

		skald.text("Flex weights 1 : 2 : 1 — the middle bar is twice as wide as each outer bar:",
			th.color.fg_muted, th.font.size_sm),
		weight_row(th),

		spacing     = th.spacing.md,
		padding     = th.spacing.xl,
		cross_align = .Stretch,
		bg          = th.color.surface,
		radius      = th.radius.lg,
	)
}

chip_row :: proc(th: ^skald.Theme) -> skald.View {
	return skald.row(
		chip("primary", th.color.primary, th),
		chip("success", th.color.success, th),
		chip("warning", th.color.warning, th),
		chip("danger",  th.color.danger,  th),
		main_align  = .Space_Between,
		cross_align = .Center,
	)
}

chip :: proc(label: string, color: skald.Color, th: ^skald.Theme) -> skald.View {
	return skald.row(
		skald.rect({12, 12}, color, th.radius.pill),
		skald.text(label, th.color.fg, th.font.size_md),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	)
}

weight_row :: proc(th: ^skald.Theme) -> skald.View {
	return skald.row(
		skald.flex(1, skald.rect({0, 36}, th.color.primary, th.radius.sm)),
		skald.flex(2, skald.rect({0, 36}, th.color.success, th.radius.sm)),
		skald.flex(1, skald.rect({0, 36}, th.color.warning, th.radius.sm)),
		spacing = th.spacing.sm,
	)
}

footer :: proc(th: ^skald.Theme) -> skald.View {
	return skald.row(
		skald.text("status: ok", th.color.fg_muted, th.font.size_sm),
		skald.text("skald v0.4", th.color.fg_muted, th.font.size_sm),
		height      = 40,
		padding     = th.spacing.md,
		main_align  = .Space_Between,
		cross_align = .Center,
		bg          = th.color.elevated,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Flex",
		size   = {1100, 700},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
