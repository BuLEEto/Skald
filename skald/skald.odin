/*
Package skald: a modern declarative GUI framework for Odin desktop apps.

Skald targets Linux, macOS, and Windows. Rendering runs on Vulkan 1.3 via
`vendor:vulkan`; windowing and input run on SDL3 via `vendor:sdl3`.

This file defines the small shared types used throughout the package.
Public API lives in:

  - platform.odin — window + input event loop
  - renderer.odin — GPU device, surface, and frame lifecycle
  - app.odin      — high-level `run` entry point used by applications

The framework is in an early bootstrap phase. The current public surface is
intentionally small: a window that opens, clears to a color, and exits on
request. Future phases add a retained/reconciled view tree, widgets, layout,
theming, and async commands.
*/
package skald

import "core:fmt"
import "core:math"

// VERSION is the framework version as a human-readable string. Bumped
// per release; apps can read it (e.g. for "About" dialogs) so they
// always reflect what they were actually linked against instead of a
// compile-time guess. Uses semantic-version-ish notation — major.minor
// [.patch][-qualifier].
VERSION :: "1.0.0"

// Color is a linear-space RGBA color with straight (non-premultiplied) alpha
// in the range [0, 1]. Construct from sRGB hex via `rgb(0xRRGGBB)` /
// `rgba(0xRRGGBBAA)`, or build in linear space directly with `Color{...}`.
Color :: [4]f32

// Size is a width/height pair measured in logical pixels.
Size :: [2]i32

// Point is an (x, y) coordinate in logical pixels.
Point :: [2]i32

// Rect is an axis-aligned rectangle in pixel coordinates, origin top-left.
// w and h extend to the right and down from (x, y).
Rect :: struct { x, y, w, h: f32 }

// rgb converts an sRGB 0xRRGGBB hex value into a linear Color with alpha=1.
// This is the expected way to write colors in Skald: designers and CSS
// values are in sRGB, but the renderer works in linear space so alpha
// blending and anti-aliasing produce correct results.
rgb :: proc(hex: u32) -> Color {
	r := f32((hex >> 16) & 0xFF) / 255.0
	g := f32((hex >>  8) & 0xFF) / 255.0
	b := f32( hex        & 0xFF) / 255.0
	return {srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b), 1}
}

// rgba converts an sRGB 0xRRGGBBAA hex value into a linear Color. Alpha is
// not part of the sRGB curve and is treated as a plain [0, 1] value.
rgba :: proc(hex: u32) -> Color {
	r := f32((hex >> 24) & 0xFF) / 255.0
	g := f32((hex >> 16) & 0xFF) / 255.0
	b := f32((hex >>  8) & 0xFF) / 255.0
	a := f32( hex        & 0xFF) / 255.0
	return {srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b), a}
}

// srgb_to_linear applies the sRGB → linear transfer function to a single
// channel value. Exposed for callers that need it in custom pipelines.
srgb_to_linear :: proc(c: f32) -> f32 {
	if c <= 0.04045 { return c / 12.92 }
	return math.pow((c + 0.055) / 1.055, 2.4)
}

// color_lighten mixes `c` toward white by `t` ∈ [0, 1]. Alpha is preserved.
// The math runs in linear space (the same space the renderer blends in)
// so tints look uniform across dark and light themes.
color_lighten :: proc(c: Color, t: f32) -> Color {
	return {
		c[0] + (1 - c[0]) * t,
		c[1] + (1 - c[1]) * t,
		c[2] + (1 - c[2]) * t,
		c[3],
	}
}

// color_darken mixes `c` toward black by `t` ∈ [0, 1]. Alpha is preserved.
color_darken :: proc(c: Color, t: f32) -> Color {
	return {
		c[0] * (1 - t),
		c[1] * (1 - t),
		c[2] * (1 - t),
		c[3],
	}
}

// color_tint returns a tint of `c` that moves *away* from the color's
// dominant end of the luminance range: bright colours get darker, dim
// colours get lighter. Use this instead of a one-directional lighten /
// darken for hover + press states so the effect stays visible under both
// the dark and light themes — a white surface tinted brighter is a no-op.
color_tint :: proc(c: Color, t: f32) -> Color {
	// Rec. 709 luma; alpha ignored.
	lum := c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
	if lum > 0.5 { return color_darken(c, t) }
	return color_lighten(c, t)
}

// color_mix blends `a` toward `b` by `t` (0..1). Alpha is blended too.
// Used for "soft" variants — e.g. a badge's background is `primary`
// mixed 10–15 % toward `surface`, which gives a subtle accent fill that
// reads against either theme without needing translucent layers.
color_mix :: proc(a, b: Color, t: f32) -> Color {
	t := clamp(t, 0, 1)
	return {
		a[0] * (1 - t) + b[0] * t,
		a[1] * (1 - t) + b[1] * t,
		a[2] * (1 - t) + b[2] * t,
		a[3] * (1 - t) + b[3] * t,
	}
}

// color_luma returns the Rec. 709 luminance of `c` in [0, 1]. Alpha
// is ignored. Handy for "dark-or-light fill?" decisions like picking
// a focus-ring color that contrasts against a button's own bg.
color_luma :: proc(c: Color) -> f32 {
	return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
}

// track_color_for returns a subtle recessed grey that stays visible
// against any surface-colored parent. Formula: mix `fg` 8 % into
// `surface` — tiny-but-real contrast in both palettes. Used as the
// at-rest fill for controls that would otherwise vanish into a
// surface-bg card (progress/slider tracks, unselected radios, toggle
// "off" tracks, stepper "todo" discs, disabled buttons). Cached at
// the theme level — widgets call this instead of repeating the mix
// at every site so the knob is a single formula.
track_color_for :: proc(theme: Theme) -> Color {
	return color_mix(theme.color.fg, theme.color.surface, 0.92)
}

// selected_inactive_bg_for returns the background color for a row that
// is "selected but its container has lost focus" — dimmer than the live
// primary-filled selection, but still visibly distinct from the default
// row bg. In dark theme `elevated` is one tonal step above `surface`
// so it suffices; in light theme `elevated == surface`, so fall back to
// a faint primary mix. Used by `table` and `tree`.
selected_inactive_bg_for :: proc(theme: Theme) -> Color {
	if theme.color.elevated == theme.color.surface {
		return color_mix(theme.color.primary, theme.color.surface, 0.88)
	}
	return theme.color.elevated
}

// focus_ring_for returns a focus-ring color that stays visible on
// `bg`. For neutral fills (surface, bg, transparent) it returns the
// accent `primary` — the standard blue ring. For fills that *are*
// one of the accent slots (primary/danger/success/warning), using
// primary would paint blue-on-blue, so it swaps in `on_primary`
// (the text-on-accent color) for visible contrast.
//
// Use this instead of reaching for `th.color.primary` directly when
// the widget's background might itself be an accent color. The
// common case — focused inputs / selects / checkboxes on a surface —
// stays identical to before.
focus_ring_for :: proc(theme: Theme, bg: Color) -> Color {
	if bg == theme.color.primary ||
	   bg == theme.color.danger  ||
	   bg == theme.color.success ||
	   bg == theme.color.warning {
		return theme.color.on_primary
	}
	return theme.color.primary
}

// HSV stores a color in hue-saturation-value space. `h` is in degrees
// [0, 360); `s` and `v` are in [0, 1]. Used by `color_picker` internally
// and exposed for apps that want to drive pickers from their own state.
HSV :: struct {
	h: f32,
	s: f32,
	v: f32,
}

// hsv_to_rgb converts an HSV triple to a linear Color with alpha=1. The
// formula matches the standard sRGB-space HSV definition; we apply the
// sRGB→linear transfer on each channel before returning so the result
// blends correctly in the rest of the pipeline. `h` is wrapped modulo 360.
hsv_to_rgb :: proc(hsv: HSV) -> Color {
	h := hsv.h
	for h < 0    { h += 360 }
	for h >= 360 { h -= 360 }
	s := clamp(hsv.s, 0, 1)
	v := clamp(hsv.v, 0, 1)

	c := v * s
	x := c * (1 - abs(math_fmod(h / 60, 2) - 1))
	m := v - c

	r1, g1, b1: f32
	switch {
	case h <  60: r1, g1, b1 = c, x, 0
	case h < 120: r1, g1, b1 = x, c, 0
	case h < 180: r1, g1, b1 = 0, c, x
	case h < 240: r1, g1, b1 = 0, x, c
	case h < 300: r1, g1, b1 = x, 0, c
	case:         r1, g1, b1 = c, 0, x
	}
	return {
		srgb_to_linear(r1 + m),
		srgb_to_linear(g1 + m),
		srgb_to_linear(b1 + m),
		1,
	}
}

// rgb_to_hsv is the inverse of `hsv_to_rgb`. Takes a linear Color and
// returns HSV computed in sRGB space — the input's channels are encoded
// back to sRGB before the hexcone math so picking a value and round-
// tripping it lands on the same HSV (modulo float rounding).
rgb_to_hsv :: proc(c: Color) -> HSV {
	r := linear_to_srgb(c[0])
	g := linear_to_srgb(c[1])
	b := linear_to_srgb(c[2])

	mx := max(r, g, b)
	mn := min(r, g, b)
	d  := mx - mn

	h: f32 = 0
	if d > 0 {
		switch mx {
		case r: h = 60 * math_fmod((g - b) / d, 6)
		case g: h = 60 * ((b - r) / d + 2)
		case b: h = 60 * ((r - g) / d + 4)
		}
		if h < 0 { h += 360 }
	}
	s: f32 = 0
	if mx > 0 { s = d / mx }
	return HSV{h = h, s = s, v = mx}
}

// color_to_hex encodes a linear Color to a 6-digit sRGB hex string
// (no alpha). Uppercase, no leading '#'. Allocates in the temp arena.
color_to_hex :: proc(c: Color) -> string {
	return fmt.tprintf("%02X%02X%02X",
		linear_to_srgb_byte(c[0]),
		linear_to_srgb_byte(c[1]),
		linear_to_srgb_byte(c[2]),
	)
}

// hex_to_color parses "RRGGBB" or "#RRGGBB" (case-insensitive) into a
// linear Color with alpha=1. Returns `(color, true)` on success; on any
// parse failure returns `({}, false)` and the caller should fall back to
// the previous value. Whitespace is tolerated around the input.
hex_to_color :: proc(s: string) -> (Color, bool) {
	str := s
	// Trim whitespace.
	for len(str) > 0 && (str[0] == ' ' || str[0] == '\t') { str = str[1:] }
	for len(str) > 0 && (str[len(str)-1] == ' ' || str[len(str)-1] == '\t') {
		str = str[:len(str)-1]
	}
	if len(str) > 0 && str[0] == '#' { str = str[1:] }
	if len(str) != 6 { return {}, false }

	parse_nib :: proc(ch: u8) -> (u8, bool) {
		switch {
		case ch >= '0' && ch <= '9': return ch - '0',      true
		case ch >= 'a' && ch <= 'f': return ch - 'a' + 10, true
		case ch >= 'A' && ch <= 'F': return ch - 'A' + 10, true
		}
		return 0, false
	}
	hex: u32 = 0
	for i in 0..<6 {
		n, ok := parse_nib(str[i])
		if !ok { return {}, false }
		hex = (hex << 4) | u32(n)
	}
	return rgb(hex), true
}

@(private)
math_fmod :: proc(x, y: f32) -> f32 {
	return x - y * math.floor(x / y)
}

@(private)
linear_to_srgb :: proc(c: f32) -> f32 {
	l := clamp(c, 0, 1)
	if l <= 0.0031308 { return l * 12.92 }
	return 1.055 * math.pow(l, 1.0/2.4) - 0.055
}

