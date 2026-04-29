#+build windows
package skald

import win "core:sys/windows"

// win32_user_locale_name returns the user's default locale in the
// BCP-47 form Windows uses (e.g. "en-GB", "en-US", "ja-JP"). Called
// from date_locale_style after LC_TIME and LANG come up empty, which
// they do on a default Windows install — neither env var is set unless
// the user or their shell adds it. Returns "" on API failure.
//
// LOCALE_SNAME (= 0x5c) asks for the BCP-47 tag; LOCALE_NAME_USER_DEFAULT
// (= nil) means "the current user's selection in Settings".
@(private)
win32_user_locale_name :: proc() -> string {
	LOCALE_SNAME :: win.LCTYPE(0x0000005c)
	buf: [win.LOCALE_NAME_MAX_LENGTH]u16
	n := win.GetLocaleInfoEx(nil, LOCALE_SNAME, &buf[0], i32(len(buf)))
	if n <= 1 { return "" } // 0 = failure, 1 = just the null terminator
	return win.wstring_to_utf8(win.wstring(&buf[0]), int(n - 1)) or_else ""
}
