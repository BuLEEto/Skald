#+build !linux
package skald

// Stub: only Linux/X11 needs the explicit ARGB-visual selection. On
// Windows and macOS, transparent Vulkan windows work out of the box —
// the OS chooses an alpha-capable surface format automatically.
@(private)
pick_argb_visual_for_x11 :: proc() -> bool { return false }
