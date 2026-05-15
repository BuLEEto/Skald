package example_theme_follow

import "core:fmt"
import "gui:skald"

// Live theme swap — both directions:
//
//  - **Follow OS**: seeds from `system_theme()` and re-applies on
//    `on_system_theme_change` so flipping dark/light in System
//    Settings updates the running window.
//
//  - **Custom palettes**: a row of swatches picks Dark, Light, Ocean,
//    Forest, or Rosewood. Selecting a custom palette pins it; the OS
//    callback is ignored until "Follow OS" is reselected.
//
// Both paths route through `cmd_set_theme` from `update` — the
// canonical way to swap palettes mid-session.

Palette :: enum {
	Follow_OS,
	Dark,
	Light,
	Ocean,
	Forest,
	Rosewood,
}

State :: struct {
	palette:   Palette,
	sys_theme: skald.System_Theme,
}

Msg :: union {
	OS_Theme_Changed,
	Palette_Picked,
	Demo_Clicked,
}

OS_Theme_Changed :: distinct skald.System_Theme
Palette_Picked   :: distinct Palette
Demo_Clicked     :: struct{}

on_os_theme_change :: proc(t: skald.System_Theme) -> Msg {
	return OS_Theme_Changed(t)
}

theme_for :: proc(p: Palette, sys: skald.System_Theme) -> skald.Theme {
	switch p {
	case .Follow_OS:
		return skald.theme_light() if sys == .Light else skald.theme_dark()
	case .Dark:
		return skald.theme_dark()
	case .Light:
		return skald.theme_light()
	case .Ocean:
		t := skald.theme_dark()
		t.color.bg         = skald.rgb(0x0a1a26)
		t.color.surface    = skald.rgb(0x102633)
		t.color.elevated   = skald.rgb(0x163342)
		t.color.primary    = skald.rgb(0x4cc9f0)
		t.color.on_primary = skald.rgb(0x06141d)
		return t
	case .Forest:
		t := skald.theme_dark()
		t.color.bg         = skald.rgb(0x0f1a14)
		t.color.surface    = skald.rgb(0x172821)
		t.color.elevated   = skald.rgb(0x1f342c)
		t.color.primary    = skald.rgb(0x6fcf97)
		t.color.on_primary = skald.rgb(0x0a1410)
		return t
	case .Rosewood:
		t := skald.theme_light()
		t.color.bg         = skald.rgb(0xfbf0ee)
		t.color.surface    = skald.rgb(0xf5e1de)
		t.color.elevated   = skald.rgb(0xffffff)
		t.color.primary    = skald.rgb(0xb4404e)
		t.color.on_primary = skald.rgb(0xffffff)
		return t
	}
	return skald.theme_dark()
}

palette_name :: proc(p: Palette) -> string {
	switch p {
	case .Follow_OS: return "Follow OS"
	case .Dark:      return "Dark"
	case .Light:     return "Light"
	case .Ocean:     return "Ocean"
	case .Forest:    return "Forest"
	case .Rosewood:  return "Rosewood"
	}
	return "?"
}

init :: proc() -> State {
	return State{
		palette   = .Follow_OS,
		sys_theme = skald.system_theme(),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case OS_Theme_Changed:
		out.sys_theme = skald.System_Theme(v)
		// Only react when the user has chosen "Follow OS". Once a
		// custom palette is pinned we leave it alone.
		if out.palette == .Follow_OS {
			return out, skald.cmd_set_theme(Msg, theme_for(.Follow_OS, out.sys_theme))
		}
	case Palette_Picked:
		out.palette = Palette(v)
		return out, skald.cmd_set_theme(Msg, theme_for(out.palette, out.sys_theme))
	case Demo_Clicked:
		// no-op — the demo buttons exist only to show the palette's
		// `primary` / `on_primary` slots.
	}
	return out, {}
}

swatch_button :: proc(ctx: ^skald.Ctx(Msg), p: Palette, current: Palette) -> skald.View {
	th := ctx.theme
	if p == current {
		return skald.button(ctx, palette_name(p), Palette_Picked(p))
	}
	// Non-selected swatches render in the muted `surface` fill so the
	// active palette stands out as the only primary-coloured chip.
	return skald.button(
		ctx, palette_name(p), Palette_Picked(p),
		bg = th.color.surface,
		fg    = th.color.fg,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	header := skald.col(
		skald.text("Skald — Live Theme Swap", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(
			fmt.tprintf("OS reports: %v   ·   showing: %s",
				s.sys_theme, palette_name(s.palette)),
			th.color.fg_muted, th.font.size_sm,
		),
	)

	picker := skald.row(
		swatch_button(ctx, .Follow_OS, s.palette),
		swatch_button(ctx, .Dark,      s.palette),
		swatch_button(ctx, .Light,     s.palette),
		swatch_button(ctx, .Ocean,     s.palette),
		swatch_button(ctx, .Forest,    s.palette),
		swatch_button(ctx, .Rosewood,  s.palette),
		spacing = th.spacing.sm,
	)

	// A small representative gallery so palette swaps are visible across
	// surface / primary / border / fg-muted slots at the same time.
	gallery := skald.col(
		skald.text("Sample widgets", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.row(
			skald.button(ctx, "Primary", Demo_Clicked{}),
			skald.button(ctx, "Another", Demo_Clicked{}),
			spacing = th.spacing.sm,
		),
		skald.spacer(th.spacing.sm),
		skald.text(
			"Body copy renders against `color.fg` over `color.bg`. " +
			"Cards float above on `color.surface` / `color.elevated`. " +
			"Pick a swatch above to see every surface update at once.",
			th.color.fg_muted, th.font.size_sm,
			max_width = 540,
		),
	)

	return skald.col(
		header,
		skald.spacer(th.spacing.lg),
		picker,
		skald.spacer(th.spacing.lg),
		gallery,
		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	sys := skald.system_theme()
	skald.run(skald.App(State, Msg){
		title  = "Skald — Theme Hotswap",
		size   = {640, 380},
		theme  = theme_for(.Follow_OS, sys),
		init   = init,
		update = update,
		view   = view,
		on_system_theme_change = on_os_theme_change,
	})
}
