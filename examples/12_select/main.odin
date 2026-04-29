package example_select

import "core:fmt"
import "core:strings"
import "gui:skald"

// Three dropdowns driving a tiny preferences card: theme flavor, text
// density, and default font. Exercises overlay rendering plus multiple
// concurrent selects (only one open at a time, since outside-click
// dismiss fires the moment the user commits to another trigger).

State :: struct {
	theme:   string,
	density: string,
	font:    string,
}

Msg :: union {
	Theme_Changed,
	Density_Changed,
	Font_Changed,
}

Theme_Changed   :: distinct string
Density_Changed :: distinct string
Font_Changed    :: distinct string

on_theme   :: proc(v: string) -> Msg { return Theme_Changed(clone(v))   }
on_density :: proc(v: string) -> Msg { return Density_Changed(clone(v)) }
on_font    :: proc(v: string) -> Msg { return Font_Changed(clone(v))    }

// The option labels live in temp memory (Msg strings travel through
// the frame arena). Clone into the persistent allocator so the value
// can be held in State across frames.
clone :: proc(s: string) -> string {
	out, _ := strings.clone(s)
	return out
}

init :: proc() -> State {
	return {
		theme   = clone("Midnight"),
		density = clone("Comfortable"),
		font    = clone("Inter"),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Theme_Changed:
		delete(out.theme)
		out.theme = string(v)
	case Density_Changed:
		delete(out.density)
		out.density = string(v)
	case Font_Changed:
		delete(out.font)
		out.font = string(v)
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	themes    := []string{"Midnight", "Aurora", "Solarized", "Nord"}
	densities := []string{"Compact", "Comfortable", "Spacious"}
	fonts     := []string{"Inter", "JetBrains Mono", "Fira Sans", "IBM Plex"}

	label :: proc(th: ^skald.Theme, s: string) -> skald.View {
		return skald.text(s, th.color.fg_muted, th.font.size_sm)
	}

	// Each row stacks a caption over its select. The selects go near
	// the end of the tree because their option-list buttons are only
	// built when open, which shifts positional Widget_IDs of any
	// siblings that follow — see the note on `select`.
	summary := fmt.tprintf(
		"Theme: %s · Density: %s · Font: %s",
		s.theme, s.density, s.font,
	)

	return skald.col(
		skald.text("Preferences", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.sm),
		skald.text(summary, th.color.fg_muted, th.font.size_md,
			max_width = 520),
		skald.spacer(th.spacing.xl),

		skald.col(
			label(th, "Theme"),
			skald.spacer(th.spacing.xs),
			skald.select(ctx, s.theme, themes, on_theme, width = 240),
			spacing = 0,
		),
		skald.spacer(th.spacing.lg),

		skald.col(
			label(th, "Density"),
			skald.spacer(th.spacing.xs),
			skald.select(ctx, s.density, densities, on_density, width = 240),
			spacing = 0,
		),
		skald.spacer(th.spacing.lg),

		skald.col(
			label(th, "Font"),
			skald.spacer(th.spacing.xs),
			skald.select(ctx, s.font, fonts, on_font, width = 240),
			spacing = 0,
		),

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Select",
		size   = {720, 560},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
