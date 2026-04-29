package example_wrap_row

// wrap_row + responsive demo. Resize the window to see:
//   • The full-width chip strip reflows onto more lines as the window
//     narrows (wrap_row wraps when the next chip wouldn't fit).
//   • The 280 px panel always wraps the same way — width is fixed.
//   • The bottom section flips between a stacked "narrow" layout and a
//     two-column "wide" layout at 700 px (responsive picks based on
//     the slot's assigned width, not the window's).

import "gui:skald"

Tag :: struct { label: string, tone: skald.Badge_Tone }

State :: struct {}
Msg   :: struct {}

@(rodata)
TAGS := []Tag{
	{"odin",         .Primary},
	{"vulkan",       .Primary},
	{"sdl3",         .Primary},
	{"declarative",  .Neutral},
	{"elm",          .Neutral},
	{"layout",       .Neutral},
	{"sdf",          .Success},
	{"async",        .Success},
	{"multi-window", .Success},
	{"linux",        .Warning},
	{"macos",        .Warning},
	{"windows",      .Warning},
	{"theming",      .Danger},
	{"i18n",         .Danger},
	{"a11y",         .Neutral},
	{"benchmarks",   .Neutral},
}

init   :: proc()                 -> State                          { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg))    { return s, {} }

build_chips :: proc(ctx: ^skald.Ctx(Msg)) -> []skald.View {
	out := make([dynamic]skald.View, 0, len(TAGS), context.temp_allocator)
	for t in TAGS {
		append(&out, skald.badge(ctx, t.label, tone = t.tone))
	}
	return out[:]
}

// Same content in both panes — wide spreads it horizontally, narrow
// stacks it. Nothing disappears; the responsive container just picks a
// different shape for the slot it was given.

narrow_pane :: proc(ctx: ^skald.Ctx(Msg), s: ^State) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.rect({0, 100}, color = th.color.primary, radius = th.radius.md),
		skald.text("Narrow — content stacked", th.color.fg, th.font.size_md),
		skald.text(
			"Below 700 px the three status rects line up under the hero rather than beside it.",
			th.color.fg_muted, th.font.size_sm,
		),
		skald.row(
			skald.flex(1, skald.rect({0, 56}, color = th.color.success, radius = th.radius.md)),
			skald.flex(1, skald.rect({0, 56}, color = th.color.warning, radius = th.radius.md)),
			skald.flex(1, skald.rect({0, 56}, color = th.color.danger,  radius = th.radius.md)),
			spacing = th.spacing.sm,
		),
		spacing     = th.spacing.sm,
		cross_align = .Stretch,
	)
}

wide_pane :: proc(ctx: ^skald.Ctx(Msg), s: ^State) -> skald.View {
	th := ctx.theme
	return skald.row(
		skald.flex(1, skald.col(
			skald.rect({0, 140}, color = th.color.primary, radius = th.radius.md),
			skald.text("Wide — hero + side panel", th.color.fg, th.font.size_md),
			skald.text(
				"At 700 px and up the three status rects sit beside the hero in a sidebar column.",
				th.color.fg_muted, th.font.size_sm,
			),
			spacing     = th.spacing.sm,
			cross_align = .Stretch,
		)),
		skald.spacer(th.spacing.lg),
		skald.col(
			skald.rect({200, 60}, color = th.color.success, radius = th.radius.md),
			skald.rect({200, 60}, color = th.color.warning, radius = th.radius.md),
			skald.rect({200, 60}, color = th.color.danger,  radius = th.radius.md),
			spacing = th.spacing.sm,
		),
		cross_align = .Start,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	full := skald.col(
		skald.text("Full-width wrap_row (resize the window)", th.color.fg, th.font.size_md),
		skald.spacer(th.spacing.sm),
		skald.wrap_row(..build_chips(ctx), spacing = th.spacing.sm, line_spacing = th.spacing.sm),
		spacing = th.spacing.xs,
		cross_align = .Stretch,
	)

	panel := skald.col(
		skald.text("Inside a 280 px panel", th.color.fg, th.font.size_md),
		skald.spacer(th.spacing.sm),
		skald.wrap_row(
			..build_chips(ctx),
			spacing      = th.spacing.sm,
			line_spacing = th.spacing.sm,
			width        = 280,
			padding      = th.spacing.sm,
			bg           = th.color.elevated,
			radius       = th.radius.md,
		),
		spacing = th.spacing.xs,
	)

	state_local := s
	resp := skald.col(
		skald.text("responsive(threshold = 700) — flips at 700 px", th.color.fg, th.font.size_md),
		skald.spacer(th.spacing.sm),
		skald.responsive(ctx, &state_local, 700, narrow_pane, wide_pane),
		spacing = th.spacing.xs,
		cross_align = .Stretch,
	)

	return skald.col(
		full,
		skald.spacer(th.spacing.lg),
		panel,
		skald.spacer(th.spacing.lg),
		resp,
		padding     = th.spacing.lg,
		spacing     = th.spacing.md,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — wrap_row + responsive",
		size   = {960, 600},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
