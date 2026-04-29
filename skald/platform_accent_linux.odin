#+build linux
package skald

import "core:os"
import "core:strings"

// system_accent_color queries the desktop environment for the user's
// chosen accent colour. Tries GNOME first (`gsettings`) since it ships
// with the most-installed DE; KDE falls through via the XDG color
// scheme parsing planned for v2.x.
//
// Returns `(Color, true)` when a value is available; `(Color{}, false)`
// otherwise. Callers (`theme_system`) use the false branch to keep the
// framework's own primary, which is already accessible.
//
// Implementation notes:
//   - GNOME 47+ exposes `org.gnome.desktop.interface accent-color` as
//     a named string ("blue", "purple", …). We map names to RGB hex.
//   - GNOME < 47 has no public accent-color setting; this returns false
//     there. Most distros are on 47+ as of 2026.
//   - We deliberately don't shell out to a long-running process — the
//     gsettings binary returns instantly and exits.
@(private)
system_accent_color :: proc() -> (Color, bool) {
	state, stdout, _, err := os.process_exec(
		os.Process_Desc{
			command = []string{"gsettings", "get", "org.gnome.desktop.interface", "accent-color"},
		},
		context.allocator,
	)
	defer delete(stdout, context.allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return {}, false
	}
	// `gsettings get` returns the value as a quoted string with a
	// trailing newline, e.g. `'blue'\n`. Trim both.
	s := strings.trim_space(string(stdout))
	s = strings.trim(s, "'")
	if len(s) == 0 { return {}, false }

	// GNOME's documented accent-color names. Source values are the
	// `@accent_bg_color` variables from libadwaita's stylesheet; what
	// the user actually sees in apps that respect the setting.
	switch s {
	case "blue":   return rgb(0x3584e4), true
	case "teal":   return rgb(0x2190a4), true
	case "green":  return rgb(0x3a944a), true
	case "yellow": return rgb(0xc88800), true
	case "orange": return rgb(0xed5b00), true
	case "red":    return rgb(0xe62d42), true
	case "pink":   return rgb(0xd56199), true
	case "purple": return rgb(0x9141ac), true
	case "slate":  return rgb(0x6f8396), true
	}
	return {}, false
}
