package skald

// theme_system picks `theme_dark()` or `theme_light()` based on the OS
// preference, then — if the OS exposes a user-chosen accent colour —
// recomputes the theme's primary-derived shades from that accent. This
// is the entrypoint for "make Skald apps look native" without an app
// having to plumb anything per-platform.
//
//     skald.run(skald.App(State, Msg){
//         theme = skald.theme_system(),  // matches OS dark/light + accent
//         on_system_theme_change = on_theme_change,
//         ...
//     })
//
// `Unknown` system themes (Linux DEs that don't publish a preference)
// fall back to dark — apps that want a different default should call
// `theme_light()` directly. The accent fetch is best-effort per platform
// (see `system_accent_color`); when it fails the theme keeps Skald's
// own primary, which is already tuned to read against both backgrounds.
theme_system :: proc() -> Theme {
	base: Theme
	if system_theme() == .Light {
		base = theme_light()
	} else {
		base = theme_dark()
	}
	if accent, ok := system_accent_color(); ok {
		base = theme_with_primary(base, accent)
	}
	return base
}

// theme_with_primary returns a copy of `base` with the primary accent
// swapped to `accent` and every primary-derived shade recomputed (the
// `selection` translucent fill, `on_primary` text contrast). The other
// semantic colours — `surface`, `border`, `success`, `warning`, `danger`
// — stay intentional because they're tuned against the layer hierarchy
// and accessibility contrast, not the brand.
//
// Useful as a building block for `theme_system` and for apps that want
// to expose a "set accent colour" preference.
theme_with_primary :: proc(base: Theme, accent: Color) -> Theme {
	t := base
	t.color.primary = accent

	// `on_primary` must read on top of the accent. Pick white when the
	// accent is dark enough, black otherwise. Threshold tuned against
	// Material's "primary container" accessibility table.
	if color_luma(accent) < 0.5 {
		t.color.on_primary = Color{1, 1, 1, 1}
	} else {
		t.color.on_primary = Color{0, 0, 0, 1}
	}

	// `selection` is the accent at low alpha — same convention used by
	// `theme_dark()` / `theme_light()` (~0.25–0.35 alpha).
	sel := accent
	sel[3] = 0.30
	t.color.selection = sel

	return t
}
