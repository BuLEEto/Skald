#+build !linux
package skald

// Drag-OUT (request 019) is a Wayland-only feature; on non-Linux platforms the
// entry points are no-ops. Cross-app DnD on X11/Windows/macOS would be a
// separate protocol (XDND / OLE / NSDragging) — out of scope. In-window DnD
// (Layer 1) works everywhere regardless.

import sdl3 "vendor:sdl3"

dragout_init :: proc(win: ^sdl3.Window) {}
dragout_pump :: proc() {}
dragout_in_progress :: proc() -> bool { return false }
dragout_start_native :: proc(win: ^sdl3.Window, mimes: []string, data: []u8,
                             icon_px: []u8 = nil, icon_w: int = 0, icon_h: int = 0,
                             hotspot_x: int = 0, hotspot_y: int = 0) -> bool { return false }
