#+build !linux
package skald

import "vendor:sdl3"

// set_utf8_window_title is a no-op on non-Linux targets. SDL3 writes the
// window title through the native OS API (SetWindowTextW on Windows,
// NSWindow.title on macOS), both of which are UTF-8 / UTF-16 correct —
// the X11 _NET_WM_NAME workaround in the Linux-tagged sibling file is
// only needed because X11 window managers still honor the legacy
// Latin-1 WM_NAME property strictly.
@(private)
set_utf8_window_title :: proc(handle: ^sdl3.Window, title: string) {
	// intentionally empty
}
