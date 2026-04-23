#+build linux
package skald

import "vendor:sdl3"
import X "vendor:x11/xlib"

// set_utf8_window_title sets _NET_WM_NAME on X11 windows as UTF8_STRING.
//
// SDL3 (at least 3.2.10) only writes the legacy WM_NAME property, which
// is defined as ISO 8859-1. Window managers like xfwm4 honor that
// strictly and display UTF-8 bytes as Latin-1 → mojibake. Setting
// _NET_WM_NAME ourselves makes every modern WM display the title
// correctly. No-op on Wayland, where titles are UTF-8 natively.
@(private)
set_utf8_window_title :: proc(handle: ^sdl3.Window, title: string) {
	if sdl3.GetCurrentVideoDriver() != "x11" {
		return
	}
	props := sdl3.GetWindowProperties(handle)
	display := cast(^X.Display)sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_X11_DISPLAY_POINTER, nil)
	xwin    := cast(X.Window)sdl3.GetNumberProperty(props, sdl3.PROP_WINDOW_X11_WINDOW_NUMBER, 0)
	if display == nil || xwin == 0 {
		return
	}
	net_wm_name := X.InternAtom(display, "_NET_WM_NAME", false)
	utf8_string := X.InternAtom(display, "UTF8_STRING",  false)
	X.ChangeProperty(
		display, xwin, net_wm_name, utf8_string,
		8, X.PropModeReplace, raw_data(title), i32(len(title)),
	)
}
