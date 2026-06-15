#+build linux
package skald

import "core:os"
import "core:sys/posix"

// prefer_native_wayland nudges SDL3 to use its native Wayland driver
// instead of XWayland on a Wayland session. On a Wayland desktop BOTH
// WAYLAND_DISPLAY and DISPLAY are set (the compositor runs XWayland for
// X11 compat), and SDL3 with no SDL_VIDEODRIVER picks x11 — so the app
// runs as an XWayland client. That mis-maps pointer input on outputs at
// negative layout coordinates (a monitor left of the primary gets no
// hover/click, keyboard-only) and desyncs server-side decorations on
// tile/maximize. Native Wayland avoids both.
//
// Process-scoped (in-process setenv), and only when the user hasn't
// already chosen a driver: if WAYLAND_DISPLAY is unset (a real X11
// session) this is a no-op and SDL keeps picking x11; if either env name
// is already set (a dev forcing x11/XWayland, or a Wayland resize-lag
// workaround) we leave their choice alone. Must run before sdl3.Init,
// which reads the env once when the video subsystem comes up.
@(private)
prefer_native_wayland :: proc() {
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" do return
	if os.get_env("SDL_VIDEODRIVER",  context.temp_allocator) != "" do return
	if os.get_env("SDL_VIDEO_DRIVER", context.temp_allocator) != "" do return
	posix.setenv("SDL_VIDEODRIVER", "wayland", false)
}
