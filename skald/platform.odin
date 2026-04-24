package skald

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

// X11-specific title workaround lives in platform_title_linux.odin; a
// no-op stub with the same signature lives in platform_title_other.odin
// for Windows / macOS. Filename-based build tags keep cross-platform
// compilation honest — vendor:x11 only ships on Linux, so any reference
// to it outside a Linux-tagged file would fail to build elsewhere.

// Window wraps a native SDL3 window and tracks its current framebuffer size
// plus the latest input snapshot. A window is created with `window_open` and
// destroyed with `window_close`.
//
// Two coordinate systems are tracked:
//
//   - `size_logical` is the size the framework renders into. All widget
//     sizes, spacing values, font sizes, mouse coordinates — everything the
//     app code sees — are in logical pixels ("dp"). The theme constants
//     (padding, radii, font sizes) are authored in logical pixels and stay
//     visually consistent across displays.
//
//   - `size_px` is the backing framebuffer size in physical pixels. The
//     Vulkan swapchain is configured at this size; the viewport covers
//     the whole thing; scissor rects are emitted in physical pixels.
//     Only the renderer boundary cares about it.
//
// `scale` is `size_px / size_logical` — the ratio SDL3 reports for the
// current display. On a standard 1× monitor it's 1.0; on a HiDPI display
// honoring the user's OS scaling setting, it'll be 1.25, 1.5, 2.0, etc.
// Glyphs are rasterized at `logical_size * scale` so text stays crisp at
// any scale.
Window :: struct {
	handle:       ^sdl3.Window,
	size_px:      [2]u32, // backing framebuffer size in physical pixels
	size_logical: [2]u32, // window size in logical pixels (what the app draws into)
	scale:        f32,    // size_px / size_logical — OS display scale factor
	should_close: bool,   // set true when the user closes the window
	resized:      bool,   // set true on the frame a resize occurred

	// system_theme_changed is edge-triggered: true for exactly one frame
	// after the OS flips appearance preference (macOS/Windows live; some
	// Linux DEs). Cleared at the top of the next `window_pump`. The run
	// loop consults `App.on_system_theme_change` to turn it into a msg;
	// apps that don't care ignore the flag entirely.
	system_theme_changed: bool,

	// had_events is set true whenever window_pump processed any SDL event
	// this frame. The run loop uses it to decide whether to rebuild the
	// view and render, or skip the frame entirely — saves battery/GPU on
	// idle windows. Cleared at the top of the next `window_pump`.
	had_events:   bool,

	input:        Input,  // populated by window_pump — logical-pixel space
}

// window_open initializes SDL3 (if not already) and creates the app
// window. Returns ok=false on SDL error. `extra_flags` overrides the
// default optional flag set (`{.RESIZABLE}`) — `.VULKAN` and
// `.HIGH_PIXEL_DENSITY` are always OR'd in because the renderer and
// DPI scaling contract both require them. Zero `extra_flags` preserves
// the default behavior.
window_open :: proc(title: string, size: Size, initial: Window_State = {}, extra_flags: sdl3.WindowFlags = {}) -> (w: Window, ok: bool) {
	if !sdl3.Init({.VIDEO}) {
		fmt.eprintfln("skald: SDL.Init failed: %s", sdl3.GetError())
		return
	}

	// Apply the caller's persisted window size if they supplied one;
	// otherwise fall back to App.size. Zero means "unset" — consistent
	// with the rest of the Skald API.
	open_w, open_h := size.x, size.y
	if initial.size.x > 0 { open_w = initial.size.x }
	if initial.size.y > 0 { open_h = initial.size.y }

	flags: sdl3.WindowFlags = {.VULKAN, .HIGH_PIXEL_DENSITY}
	if extra_flags == {} {
		flags |= {.RESIZABLE}
	} else {
		flags |= extra_flags
	}

	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	handle := sdl3.CreateWindow(ctitle, open_w, open_h, flags)
	if handle == nil {
		fmt.eprintfln("skald: SDL.CreateWindow failed: %s", sdl3.GetError())
		return
	}
	set_utf8_window_title(handle, title)

	// Restore window position if the app supplied one. {0, 0} means
	// "let the WM pick" (SDL centers by default), so we only call
	// SetWindowPosition when at least one coordinate is non-zero.
	if initial.pos.x != 0 || initial.pos.y != 0 {
		sdl3.SetWindowPosition(handle, initial.pos.x, initial.pos.y)
	}
	if initial.maximized {
		sdl3.MaximizeWindow(handle)
	}

	w = Window{handle = handle}
	window_refresh_size(&w)
	ok = true
	return
}

// window_current_state returns the window's position, size, and
// maximised flag in logical pixels — the shape that
// `App.initial_window_state` expects. Apps call this from their
// `on_window_state_change` callback (or at shutdown) to persist
// the geometry between launches.
window_current_state :: proc(w: ^Window) -> Window_State {
	px, py: i32
	sw, sh: i32
	sdl3.GetWindowPosition(w.handle, &px, &py)
	sdl3.GetWindowSize(w.handle, &sw, &sh)
	flags := sdl3.GetWindowFlags(w.handle)
	return Window_State{
		pos       = {px, py},
		size      = {sw, sh},
		maximized = .MAXIMIZED in flags,
	}
}

// window_refresh_size queries SDL for the current logical + physical sizes
// and recomputes `scale`. Called once at window_open and again whenever SDL
// reports a resize or pixel-density change.
@(private)
window_refresh_size :: proc(w: ^Window) {
	lw, lh: i32
	pw, ph: i32
	sdl3.GetWindowSize(w.handle, &lw, &lh)
	sdl3.GetWindowSizeInPixels(w.handle, &pw, &ph)
	if lw <= 0 { lw = 1 }
	if lh <= 0 { lh = 1 }
	if pw <= 0 { pw = lw }
	if ph <= 0 { ph = lh }
	w.size_logical = {u32(lw), u32(lh)}
	w.size_px      = {u32(pw), u32(ph)}
	// Prefer the vertical ratio if they somehow disagree — aspect ratios
	// line up on every real display; a non-square scale is a platform
	// misreport, not something we want to honor.
	sx := f32(pw) / f32(lw)
	sy := f32(ph) / f32(lh)
	w.scale = (sx + sy) * 0.5
	if w.scale < 1 { w.scale = 1 }
}

// window_close destroys the window and shuts SDL3 down. Safe to call once.
window_close :: proc(w: ^Window) {
	if w.handle != nil {
		sdl3.DestroyWindow(w.handle)
		w.handle = nil
	}
	sdl3.Quit()
}


// window_pump polls all pending SDL events and updates the window state.
// Call once per frame before rendering. Sets `should_close` when the user
// clicks close or presses Escape, `resized` when the framebuffer size
// changed this frame, and populates `input` with mouse position, button
// edges, scroll delta, and any text input received this frame.
window_pump :: proc(w: ^Window) {
	w.resized              = false
	w.system_theme_changed = false
	w.had_events           = false
	input_reset_edges(&w.input)

	// SDL3 delivers mouse + drop coordinates already in logical window
	// units — the same space the framework lays out in. No per-event
	// scaling needed; HiDPI is handled exclusively at the renderer
	// boundary via `scale`.

	e: sdl3.Event
	for sdl3.PollEvent(&e) {
		w.had_events = true
		#partial switch e.type {
		case .QUIT:
			w.should_close = true

		case .KEY_DOWN:
			input_apply_modifiers(&w.input, e.key.mod)
			if k, ok := sdl_scancode_to_key(e.key.scancode); ok {
				// keys_pressed tracks any down event including auto-repeat,
				// so holding Backspace/arrows deletes/moves repeatedly. The
				// held-set only latches on the initial press so that a
				// repeat doesn't look like a fresh discrete key event.
				w.input.keys_pressed += {k}
				if !e.key.repeat { w.input.keys_down += {k} }
			}

		case .KEY_UP:
			input_apply_modifiers(&w.input, e.key.mod)
			if k, ok := sdl_scancode_to_key(e.key.scancode); ok {
				w.input.keys_released += {k}
				w.input.keys_down     -= {k}
			}

		case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED,
		     .WINDOW_DISPLAY_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
			window_refresh_size(w)
			w.resized = true

		case .MOUSE_MOTION:
			nx := e.motion.x
			ny := e.motion.y
			w.input.mouse_delta.x += nx - w.input.mouse_pos.x
			w.input.mouse_delta.y += ny - w.input.mouse_pos.y
			w.input.mouse_pos = {nx, ny}
			// Distinguish a real mouse from SDL's pen/touch synthesis
			// so apps that need the distinction (canvas cursor-hide,
			// pressure fallback, etc) can tell them apart. Synthetic
			// events carry sentinel `which` IDs.
			if e.motion.which != sdl3.PEN_MOUSEID &&
			   e.motion.which != sdl3.TOUCH_MOUSEID {
				w.input.mouse_physical_moved = true
			}

		case .MOUSE_BUTTON_DOWN:
			if btn, ok := sdl_button_to_enum(e.button.button); ok {
				w.input.mouse_buttons[btn]     = true
				w.input.mouse_pressed[btn]     = true
				w.input.mouse_click_count[btn] = u8(e.button.clicks)
				w.input.mouse_pos = {e.button.x, e.button.y}
			}

		case .MOUSE_BUTTON_UP:
			if btn, ok := sdl_button_to_enum(e.button.button); ok {
				w.input.mouse_buttons[btn] = false
				w.input.mouse_released[btn] = true
				w.input.mouse_pos = {e.button.x, e.button.y}
			}

		case .MOUSE_WHEEL:
			w.input.scroll.x += e.wheel.x
			w.input.scroll.y += e.wheel.y

		case .TEXT_INPUT:
			// SDL3 guarantees `text` is UTF-8 and valid for the lifetime
			// of the event — we clone into the frame arena so callers
			// can hold the resulting string for the whole frame.
			s := strings.clone_from_cstring(e.text.text, context.temp_allocator)
			if len(w.input.text) == 0 {
				w.input.text = s
			} else {
				w.input.text = strings.concatenate({w.input.text, s}, context.temp_allocator)
			}

		case .DROP_BEGIN:
			// A new drag has entered the window. Latch so drop targets
			// can render hover feedback between now and DROP_COMPLETE.
			w.input.drag_active = true

		case .DROP_POSITION:
			// Cursor moving over the window while files are held. SDL
			// delivers window-logical coords — same space the framework
			// already uses, so no scaling needed.
			w.input.drag_active = true
			w.input.drag_pos    = {e.drop.x, e.drop.y}

		case .DROP_FILE:
			// The user released over the window. `data` is a UTF-8
			// cstring owned by SDL for the duration of event dispatch,
			// so clone into the frame arena before the next PollEvent.
			// A single drop of N files delivers N DROP_FILE events
			// back-to-back — we accumulate into one slice that the
			// drop_zone builder reads on this frame.
			if e.drop.data != nil {
				path := strings.clone_from_cstring(e.drop.data, context.temp_allocator)
				files := make([dynamic]string, 0, len(w.input.dropped_files) + 1,
					context.temp_allocator)
				for existing in w.input.dropped_files {
					append(&files, existing)
				}
				append(&files, path)
				w.input.dropped_files = files[:]
				w.input.drop_pos      = {e.drop.x, e.drop.y}
			}

		case .DROP_COMPLETE:
			// End of the drag — clear latch so paints go back to normal.
			// dropped_files itself stays populated for this frame so the
			// builder sees it; input_reset_edges will wipe it on the
			// next pump.
			w.input.drag_active = false
			w.input.drag_pos    = {0, 0}

		case .PEN_PROXIMITY_IN:
			w.input.pen_in_proximity = true

		case .PEN_PROXIMITY_OUT:
			w.input.pen_in_proximity = false
			w.input.pen_down         = false
			w.input.pen_eraser       = false
			// Drop the held-button set — SDL won't necessarily send
			// button-up events when the pen leaves proximity.
			w.input.pen_buttons_down = {}

		case .PEN_DOWN:
			w.input.pen_down     = true
			w.input.pen_pressed  = true
			w.input.pen_pos      = {e.ptouch.x, e.ptouch.y}
			w.input.pen_eraser   = e.ptouch.eraser
			// Pens without pressure reporting still need to produce a
			// visible stroke — default to full pressure and let any
			// subsequent PEN_AXIS event override it.
			if w.input.pen_pressure == 0 { w.input.pen_pressure = 1 }
			pen_sample_push(&w.input)

		case .PEN_UP:
			w.input.pen_pos      = {e.ptouch.x, e.ptouch.y}
			// Push the final-contact sample BEFORE flipping pen_down
			// false so the recorded trajectory ends at the lift-off
			// position with down=true — apps replay the sample stream
			// as if the pen were still drawing right up to the edge.
			pen_sample_push(&w.input)
			w.input.pen_down     = false
			w.input.pen_released = true

		case .PEN_MOTION:
			w.input.pen_pos = {e.pmotion.x, e.pmotion.y}
			pen_sample_push(&w.input)

		case .PEN_BUTTON_DOWN:
			// SDL numbers buttons from 1; our array is indexed from 0.
			idx := int(e.pbutton.button) - 1
			if idx >= 0 && idx < len(w.input.pen_buttons_down) {
				w.input.pen_buttons_down[idx]    = true
				w.input.pen_buttons_pressed[idx] = true
			}
			w.input.pen_pos = {e.pbutton.x, e.pbutton.y}
			pen_sample_push(&w.input)

		case .PEN_BUTTON_UP:
			idx := int(e.pbutton.button) - 1
			if idx >= 0 && idx < len(w.input.pen_buttons_down) {
				w.input.pen_buttons_down[idx]     = false
				w.input.pen_buttons_released[idx] = true
			}
			w.input.pen_pos = {e.pbutton.x, e.pbutton.y}
			pen_sample_push(&w.input)

		case .PEN_AXIS:
			w.input.pen_pos = {e.paxis.x, e.paxis.y}
			#partial switch e.paxis.axis {
			case .PRESSURE: w.input.pen_pressure = e.paxis.value
			case .XTILT:    w.input.pen_tilt.x   = e.paxis.value
			case .YTILT:    w.input.pen_tilt.y   = e.paxis.value
			}
			pen_sample_push(&w.input)

		case .SYSTEM_THEME_CHANGED:
			// OS appearance flipped (user toggled dark mode in Settings).
			// Edge flag; run loop turns it into a Msg via
			// `App.on_system_theme_change`. Intentionally not coalesced
			// with a value — apps that care re-query `system_theme()`
			// inside their callback.
			w.system_theme_changed = true
		}
	}
}

@(private)
sdl_button_to_enum :: proc(b: u8) -> (Mouse_Button, bool) {
	switch b {
	case sdl3.BUTTON_LEFT:   return .Left,   true
	case sdl3.BUTTON_MIDDLE: return .Middle, true
	case sdl3.BUTTON_RIGHT:  return .Right,  true
	}
	return .Left, false
}

// sdl_scancode_to_key maps the SDL3 scancode space down to the editing-only
// `Key` enum. Anything outside the set returns ok=false so the main pump
// can ignore it — typed characters already arrive via TEXT_INPUT and we
// don't want them double-counted here.
@(private)
sdl_scancode_to_key :: proc(s: sdl3.Scancode) -> (Key, bool) {
	#partial switch s {
	case .BACKSPACE: return .Backspace, true
	case .DELETE:    return .Delete,    true
	case .LEFT:      return .Left,      true
	case .RIGHT:     return .Right,     true
	case .UP:        return .Up,        true
	case .DOWN:      return .Down,      true
	case .HOME:      return .Home,      true
	case .END:       return .End,       true
	case .PAGEUP:    return .Page_Up,   true
	case .PAGEDOWN:  return .Page_Down, true
	case .RETURN, .KP_ENTER, .RETURN2:
		return .Enter, true
	case .TAB:       return .Tab,       true
	case .ESCAPE:    return .Escape,    true
	case .SPACE:     return .Space,     true
	case .A: return .A, true
	case .B: return .B, true
	case .C: return .C, true
	case .D: return .D, true
	case .E: return .E, true
	case .F: return .F, true
	case .G: return .G, true
	case .H: return .H, true
	case .I: return .I, true
	case .J: return .J, true
	case .K: return .K, true
	case .L: return .L, true
	case .M: return .M, true
	case .N: return .N, true
	case .O: return .O, true
	case .P: return .P, true
	case .Q: return .Q, true
	case .R: return .R, true
	case .S: return .S, true
	case .T: return .T, true
	case .U: return .U, true
	case .V: return .V, true
	case .W: return .W, true
	case .X: return .X, true
	case .Y: return .Y, true
	case .Z: return .Z, true
	case ._0: return .N0, true
	case ._1: return .N1, true
	case ._2: return .N2, true
	case ._3: return .N3, true
	case ._4: return .N4, true
	case ._5: return .N5, true
	case ._6: return .N6, true
	case ._7: return .N7, true
	case ._8: return .N8, true
	case ._9: return .N9, true
	case .F1:  return .F1,  true
	case .F2:  return .F2,  true
	case .F3:  return .F3,  true
	case .F4:  return .F4,  true
	case .F5:  return .F5,  true
	case .F6:  return .F6,  true
	case .F7:  return .F7,  true
	case .F8:  return .F8,  true
	case .F9:  return .F9,  true
	case .F10: return .F10, true
	case .F11: return .F11, true
	case .F12: return .F12, true
	}
	return .Backspace, false
}

// window_set_text_input toggles SDL3's text-input mode. Text-entry widgets
// call this via the run loop each frame based on whether any widget claimed
// focus. When off, SDL suppresses TEXT_INPUT events (and on mobile hides
// the soft keyboard), so keystrokes that don't belong to a focused field
// don't clutter the input snapshot.
window_set_text_input :: proc(w: ^Window, on: bool) {
	active := sdl3.TextInputActive(w.handle)
	if on && !active {
		_ = sdl3.StartTextInput(w.handle)
	} else if !on && active {
		_ = sdl3.StopTextInput(w.handle)
	}
}

// pen_sample_push snapshots the current pen scalar state into the
// per-frame trajectory list. Called from each pen event handler so the
// buffer reflects every SDL-reported position, not just the last one.
// The shared helper avoids repeating the same field-copy six times.
//
// Same-position samples are *coalesced* with the previous entry: SDL
// typically delivers PEN_DOWN then PEN_AXIS(pressure) at the identical
// coordinate, and PEN_MOTION is frequently trailed by PEN_AXIS when
// the pressure channel updates mid-stroke. Without coalescing the
// first sample of every stroke carries stale pressure (whatever was
// latched from proximity or the previous frame) which paints a wide
// first stamp — visible as a hairy tuft at stroke starts. Coalescing
// keeps the final pressure/tilt/eraser value observed at that point,
// giving each position exactly one sample with its real hardware data.
@(private)
pen_sample_push :: proc(in_: ^Input) {
	s := Pen_Sample{
		pos      = in_.pen_pos,
		pressure = in_.pen_pressure,
		tilt     = in_.pen_tilt,
		eraser   = in_.pen_eraser,
		down     = in_.pen_down,
	}
	n := len(in_.pen_samples)
	if n > 0 {
		last := &in_.pen_samples[n - 1]
		// Overwrite when position + down state match — this is the
		// MOTION/AXIS pair case. We deliberately don't compare
		// pressure/tilt/eraser; the whole point is to let later events
		// at the same position refine those fields.
		if last.pos == s.pos && last.down == s.down {
			last^ = s
			return
		}
	}
	append(&in_.pen_samples, s)
}

// cursor_set_visible toggles the OS mouse cursor. Paint / drawing apps
// typically hide the cursor while a stylus is in proximity or while
// the user is actively drawing inside a canvas, so the in-app brush
// preview isn't fighting the system pointer glyph. The setting is
// global to the process; a widget that hides the cursor is responsible
// for restoring it when its condition goes away.
cursor_set_visible :: proc(visible: bool) {
	if visible {
		_ = sdl3.ShowCursor()
	} else {
		_ = sdl3.HideCursor()
	}
}

// clipboard_set writes `text` to the system clipboard. UTF-8 in, UTF-8 out.
// Returns true on success; callers typically don't branch on the result — a
// clipboard failure is not actionable from inside the UI.
clipboard_set :: proc(text: string) -> bool {
	c := strings.clone_to_cstring(text, context.temp_allocator)
	return sdl3.SetClipboardText(c)
}

// clipboard_get reads the system clipboard as UTF-8 and clones it into
// `context.temp_allocator` so the result is safe for the rest of the frame.
// Returns "" when the clipboard is empty or a non-text payload is present.
// SDL allocates the returned buffer on the heap; we free it back immediately
// so the SDL allocator isn't leaked regardless of clipboard traffic volume.
//
// We don't gate on HasClipboardText: on Windows it can return false while
// GetClipboardText still succeeds (SDL3 tracks the text availability via
// a cached flag that isn't always in sync with CF_UNICODETEXT changes from
// other apps). GetClipboardText itself returns an empty string on failure,
// so the cheaper check is "did we get anything back?"
//
// We also normalize CRLF → LF: Windows apps put `\r\n` on the clipboard and
// fontstash renders `\r` as a tofu box at every line end.
clipboard_get :: proc() -> string {
	raw := sdl3.GetClipboardText()
	if raw == nil { return "" }
	defer sdl3.free(raw)
	// Clone first so the output lives past sdl3.free; then strip CR in
	// place. replace_all can return the unmodified source when there's
	// nothing to replace, which would point at the SDL buffer we're
	// about to free — cloning up front sidesteps that.
	cloned := strings.clone_from_cstring(cstring(raw), context.temp_allocator)
	if len(cloned) == 0 { return "" }
	out, _ := strings.replace_all(cloned, "\r\n", "\n", context.temp_allocator)
	return out
}

@(private)
input_apply_modifiers :: proc(in_: ^Input, mod: sdl3.Keymod) {
	m: Modifiers
	if .LSHIFT in mod || .RSHIFT in mod { m += {.Shift} }
	if .LCTRL  in mod || .RCTRL  in mod { m += {.Ctrl}  }
	if .LALT   in mod || .RALT   in mod { m += {.Alt}   }
	if .LGUI   in mod || .RGUI   in mod { m += {.Super} }
	in_.modifiers = m
}
