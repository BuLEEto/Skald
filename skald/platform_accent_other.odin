#+build !linux
package skald

// system_accent_color returns the OS-chosen accent colour on platforms
// where Skald has wired up the per-platform fetch. Currently
// implemented for Linux (GNOME `gsettings`); macOS and Windows return
// `(Color{}, false)` — `theme_system` keeps Skald's own primary on
// those platforms until `NSColor.controlAccentColor` and the
// `UISettings`/Win32 accent fetch land. See `docs/v2-design.md`.
@(private)
system_accent_color :: proc() -> (Color, bool) {
	return {}, false
}
