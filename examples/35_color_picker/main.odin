package example_color_picker

import "core:fmt"
import "gui:skald"

// Two color pickers wired to app state. The picker itself owns the
// HSV popover, an editable hex field, and the swatch trigger — the
// app only holds the current Color and the on_change callbacks.

State :: struct {
	brand:  skald.Color,
	accent: skald.Color,
}

Msg :: union {
	Brand_Picked,
	Accent_Picked,
}

Brand_Picked  :: distinct skald.Color
Accent_Picked :: distinct skald.Color

on_brand  :: proc(c: skald.Color) -> Msg { return Brand_Picked(c)  }
on_accent :: proc(c: skald.Color) -> Msg { return Accent_Picked(c) }

init :: proc() -> State {
	return State{
		brand  = skald.rgb(0x4c6ef5),
		accent = skald.rgb(0xe5484d),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Brand_Picked:  out.brand  = skald.Color(v)
	case Accent_Picked: out.accent = skald.Color(v)
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	label :: proc(th: ^skald.Theme, t: string) -> skald.View {
		return skald.text(t, th.color.fg_muted, th.font.size_sm)
	}

	preview := skald.row(
		skald.col(
			skald.rect({80, 80}, s.brand, th.radius.md),
			width = 80, height = 80,
		),
		skald.col(
			skald.rect({80, 80}, s.accent, th.radius.md),
			width = 80, height = 80,
		),
		spacing = th.spacing.md,
	)

	summary := fmt.tprintf(
		"Brand #%s   ·   Accent #%s",
		skald.color_to_hex(s.brand),
		skald.color_to_hex(s.accent),
	)

	return skald.col(
		skald.text("Skald — Color Picker", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.sm),
		skald.text(summary, th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.xl),

		preview,
		skald.spacer(th.spacing.xl),

		skald.col(
			label(th, "Brand"),
			skald.spacer(th.spacing.xs),
			skald.color_picker(ctx, s.brand, on_brand, width = 180),
			spacing = 0,
		),
		skald.spacer(th.spacing.lg),

		skald.col(
			label(th, "Accent"),
			skald.spacer(th.spacing.xs),
			skald.color_picker(ctx, s.accent, on_accent, width = 180),
			spacing = 0,
		),

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Color Picker",
		size   = {720, 600},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
