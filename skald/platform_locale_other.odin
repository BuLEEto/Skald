#+build !windows
package skald

// win32_user_locale_name is a Windows-only sniff. On every other
// platform, LC_TIME / LANG are the canonical source (set by the shell
// or login profile), so we return "" here and let date_locale_style
// fall through to its ISO default if both env vars are empty.
@(private)
win32_user_locale_name :: proc() -> string {
	return ""
}
