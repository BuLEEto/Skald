#+build linux
package skald

import "core:fmt"
import "core:strings"
import "vendor:sdl3"
import X "vendor:x11/xlib"

// pick_argb_visual_for_x11 finds a 32-bit ARGB X11 visual on the default
// screen and tells SDL3 to use it for the next created window via
// `SDL_HINT_VIDEO_X11_WINDOW_VISUALID`.
//
// Why we need this: SDL3 creates the X window before Vulkan picks a
// swapchain format, so the visual it chooses determines whether the
// resulting framebuffer has an alpha channel. SDL3's `.TRANSPARENT`
// flag handles this correctly for OpenGL (it picks an FBConfig with
// alpha bits) but not for Vulkan — Vulkan windows go through a
// different code path that defaults to a 24-bit RGB visual. The
// resulting X window has Depth: 24 and any framebuffer alpha is
// silently discarded at window-pixel level, regardless of what we
// render or what compositeAlpha mode the swapchain advertises.
//
// We bridge the gap by enumerating visuals with `XGetVisualInfo`,
// filtering for depth=32 + a true-colour class (TrueColor=4 or
// DirectColor=5), and setting the visual ID as a hint before
// `SDL_CreateWindow`. SDL3 then creates the X window with that visual
// and the framebuffer ends up 32-bit ARGB. Combined with our
// alpha=0 clear and POST_MULTIPLIED compositeAlpha, transparency
// works end-to-end on xfwm4 / KWin / Mutter / picom.
//
// No-op outside X11. Returns false if no 32-bit ARGB visual is
// available — most desktops have one but headless / minimal X
// servers might not, in which case the window stays opaque and the
// caller's `.TRANSPARENT` is silently a no-op.
@(private)
pick_argb_visual_for_x11 :: proc() -> bool {
	if sdl3.GetCurrentVideoDriver() != "x11" { return false }

	display := X.OpenDisplay(nil)
	if display == nil { return false }
	defer X.CloseDisplay(display)

	// XGetVisualInfo with an empty mask returns *every* visual on the
	// server. We filter manually for depth=32 + TrueColor/DirectColor —
	// the X11 visual classes that store colour as separate R/G/B
	// channels (which is what an ARGB visual is). PseudoColor / GrayScale
	// won't have alpha at all.
	template: X.XVisualInfo
	count: i32
	infos := X.GetVisualInfo(display, X.VisualInfoMask{}, &template, &count)
	if infos == nil || count == 0 { return false }
	defer X.Free(infos)

	TRUE_COLOR    :: 4
	DIRECT_COLOR  :: 5

	chosen_id: X.VisualID = 0
	for i in 0 ..< int(count) {
		v := infos[i]
		if v.depth != 32 { continue }
		if v.class != TRUE_COLOR && v.class != DIRECT_COLOR { continue }
		// red/green/blue masks together must NOT cover all 32 bits — the
		// remaining bits are the alpha channel. A visual with depth=32
		// but RGB masks summing to 32 is a 24-bit-RGB-padded-to-32 visual
		// (no alpha), no use to us.
		used := v.red_mask | v.green_mask | v.blue_mask
		if used == 0xffffffff { continue }
		chosen_id = v.visualid
		break
	}
	if chosen_id == 0 { return false }

	// SDL_HINT_VIDEO_X11_WINDOW_VISUALID accepts a decimal or hex string;
	// we feed hex with `0x` prefix so it's unambiguous.
	hint := fmt.aprintf("0x%x", u64(chosen_id), allocator = context.temp_allocator)
	chint := strings.clone_to_cstring(hint, context.temp_allocator)
	sdl3.SetHint(sdl3.HINT_VIDEO_X11_WINDOW_VISUALID, chint)
	return true
}
