package skald

import "vendor:sdl3"

// Theme is a bundle of design tokens — colors, corner radii, spacing steps,
// and font sizes — that widgets and application code consume to stay visually
// consistent. It is plain data, constructed at app startup via one of the
// `theme_*` procs, and passed down explicitly (elm/iced style) rather than
// being stored globally.
//
// The four nested groups keep the API discoverable: field access reads like
// `th.color.primary`, `th.radius.md`, `th.spacing.lg`, `th.font.size_md`.
//
// Custom themes are easy — construct a Theme literal directly, or start from
// `theme_dark` / `theme_light` and override fields.
Theme :: struct {
	color:   Theme_Colors,
	radius:  Theme_Radii,
	spacing: Theme_Spacing,
	font:    Theme_Font,
}

// Theme_Colors is the semantic palette every widget reads from. Fields
// are organized by role (surface, text, accent, state) rather than by
// shade so a light theme and a dark theme can be swapped at runtime
// without any widget reaching for a specific hex value. Custom themes
// should populate every field — widgets don't fall back to neighbors.
Theme_Colors :: struct {
	bg:         Color, // window background — the widest surface
	surface:    Color, // cards, panels, sidebars
	elevated:   Color, // popovers, menus, tooltips (above surface)
	border:     Color, // 1 px outlines between surfaces

	fg:         Color, // primary text
	fg_muted:   Color, // secondary text, captions, placeholders

	primary:    Color, // brand / call-to-action fills
	on_primary: Color, // text on a `primary` background

	// selection is the fill drawn behind selected text in editable fields.
	// Conventionally a translucent tint of `primary` so the glyph color
	// underneath remains readable.
	selection:  Color,

	success:    Color,
	warning:    Color,
	danger:     Color,
}

// Theme_Radii is a 4-step corner-radius scale plus a pill that is safe to
// pass as-is to draw_rect — the rect draw clamps the radius to the shorter
// half-extent, so any "huge" value produces a perfectly-rounded capsule.
Theme_Radii :: struct {
	sm:   f32,
	md:   f32,
	lg:   f32,
	xl:   f32,
	pill: f32,
}

// Theme_Spacing is a 5-step spacing scale in logical pixels. Widgets
// use these for internal padding and inter-widget gaps; apps use them
// for consistent spacing between their own content. Doubling roughly
// between steps (xs=4, sm=8, md=12, lg=16, xl=24) gives a familiar
// rhythm without being dogmatic.
Theme_Spacing :: struct {
	xs: f32,
	sm: f32,
	md: f32,
	lg: f32,
	xl: f32,
}

// Theme_Font carries font *sizes*; the actual typeface is the renderer's
// default font (Inter Variable) unless widgets are passed an explicit handle.
// Sizes are in pixels; a widget that wants "body text" reads `size_md`.
Theme_Font :: struct {
	size_xs:      f32,
	size_sm:      f32,
	size_md:      f32,
	size_lg:      f32,
	size_xl:      f32,
	size_display: f32,
}

// theme_dark returns the default dark theme — charcoal surfaces,
// indigo accent, cool neutral text. This is what `run` uses when no
// theme is passed.
theme_dark :: proc() -> Theme {
	// Values benchmarked against GitHub Primer and Radix Slate scales.
	// Deeper `bg` (#0f1115) gives `elevated` room to read as actually
	// elevated without a third tonal bump. True-blue primary (#3b82f6)
	// — neutral system-chrome instead of the old indigo (#4c6ef5)
	// which trends brand-coded.
	return Theme{
		color = {
			bg         = rgb(0x0f1115),
			surface    = rgb(0x17191e),
			elevated   = rgb(0x21242b),
			border     = rgb(0x2e323a),
			fg         = rgb(0xe6edf3),
			fg_muted   = rgb(0x8b95a3),
			primary    = rgb(0x3b82f6),
			on_primary = rgb(0xffffff),
			selection  = rgba(0x3b82f659), // primary @ ~0.35 alpha
			success    = rgb(0x2ea043),
			warning    = rgb(0xd29922),
			danger     = rgb(0xe5484d),
		},
		radius  = theme_default_radius(),
		spacing = theme_default_spacing(),
		font    = theme_default_font(),
	}
}

// theme_light returns the companion light theme, same accents.
//
// Tonal ladder (inverted vs. dark): bg is the brightest layer (body),
// surface is slightly recessed (cards, input fields), elevated pops
// back to white so popovers/dropdowns stand out against both. Without
// the surface→elevated split, every flat light UI runs into
// "the menu is invisible on the input it anchors to" — Skald avoids
// that by keeping the layer colors actually different.
theme_light :: proc() -> Theme {
	// GitHub Primer-flavored palette. The pro convention (verified
	// against Primer, Radix, Material 3, IBM Carbon) is `bg=white,
	// surface=subtle-grey`: the body is white, cards and inputs
	// recess slightly into grey. Popovers pop back up to white with a
	// shadow — the `elevated` slot keeps the same white but the
	// widget renderer stacks a soft shadow to separate them. Cards
	// rely on hairline borders (not bg contrast) for edges, because
	// the surface-to-bg delta is intentionally tiny. Primary is
	// Primer's link blue — readable on white, passes AA.
	return Theme{
		color = {
			bg         = rgb(0xffffff),
			surface    = rgb(0xf6f8fa),
			elevated   = rgb(0xffffff),
			border     = rgb(0xd0d7de),
			fg         = rgb(0x1f2328),
			fg_muted   = rgb(0x59636e),
			primary    = rgb(0x0969da),
			on_primary = rgb(0xffffff),
			selection  = rgba(0x0969da40), // primary @ ~0.25 alpha
			success    = rgb(0x1a7f37),
			warning    = rgb(0x9a6700),
			danger     = rgb(0xcf222e),
		},
		radius  = theme_default_radius(),
		spacing = theme_default_spacing(),
		font    = theme_default_font(),
	}
}

@(private)
theme_default_radius :: proc() -> Theme_Radii {
	return {sm = 4, md = 8, lg = 12, xl = 16, pill = 9999}
}

@(private)
theme_default_spacing :: proc() -> Theme_Spacing {
	return {xs = 4, sm = 8, md = 12, lg = 16, xl = 24}
}

@(private)
theme_default_font :: proc() -> Theme_Font {
	return {
		size_xs      = 11,
		size_sm      = 13,
		size_md      = 14,
		size_lg      = 18,
		size_xl      = 24,
		size_display = 36,
	}
}

// System_Theme reports the user's OS-level appearance preference. The
// framework itself does not pick a theme — apps query this and wire
// their own policy (match the OS, honor a per-app override, etc.). Ship
// value: the framework exposes the signal; app owns the decision.
//
// `Unknown` is returned on platforms that don't publish a preference
// (some Linux DEs) — apps should treat it as "pick a sensible default."
System_Theme :: enum u8 {
	Unknown,
	Light,
	Dark,
}

// system_theme queries the OS's current appearance preference via SDL3.
// Safe to call after `run` has opened the window; returns `.Unknown`
// before SDL is initialized or when the platform can't report it.
//
//     app := skald.App(State, Msg){
//         theme = skald.theme_light() if skald.system_theme() == .Light
//                 else skald.theme_dark(),
//         ...
//     }
//
// To react to live changes (user flips OS dark mode while the app is
// running), set `App.on_system_theme_change` — the runtime fires it
// with the new value when SDL emits `SDL_EVENT_SYSTEM_THEME_CHANGED`.
system_theme :: proc() -> System_Theme {
	switch sdl3.GetSystemTheme() {
	case .LIGHT: return .Light
	case .DARK:  return .Dark
	case .UNKNOWN: return .Unknown
	}
	return .Unknown
}
