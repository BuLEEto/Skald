package skald

// Debug inspector overlay. F12 toggles a small translucent panel that
// names the widget under the cursor — its id, kind, and computed rect —
// and outlines that widget on screen so you can match the readout to
// the thing you're pointing at. Press P to pin the readout so you can
// move the cursor away without losing what was selected.
//
// What it deliberately doesn't show: framerate, RSS, draw counts.
// Lazy redraw makes "FPS" meaningless ("0 fps" reads as "frozen" but
// is the framework working as intended), and the other counters were
// debugging-the-framework metrics, not debugging-your-app metrics.
// `bench.sh` is the right tool for perf and memory; the inspector's
// job is "which widget is this and what id did it get."
//
// The whole file is gated on `when ODIN_DEBUG`, so `odin build -o:speed`
// (which clears ODIN_DEBUG) strips every byte of it: no panel, no F12
// handling, no state field cost beyond one `bool` in Widget_Store.
//
// The run loop calls `inspector_handle_toggle` early in each pump (to
// catch F12) and `inspector_render` at the end of the frame (so the
// panel paints over the app). Both are no-ops outside ODIN_DEBUG.

import "core:fmt"

when ODIN_DEBUG {

// inspector_handle_toggle watches for F12 in the frame's pressed set
// and flips the open flag. Also handles the pin keybind (P) and
// claims it while a text input is focused so typing "p" into a field
// doesn't also flip the pin state. Called from the run loop after
// input_pump and before view.
inspector_handle_toggle :: proc(w: ^Widget_Store, input: ^Input, mouse_pos: [2]f32) {
	if .F12 in input.keys_pressed {
		w.inspector_open = !w.inspector_open
	}
	if !w.inspector_open { return }

	// P toggles the pin. We only pin when there *is* something under
	// the cursor — pinning air is a no-op, which reads correctly.
	// Skip the keybind while a text input is focused so typing "p"
	// into a field doesn't also flip the pin state.
	if .P in input.keys_pressed && !w.wants_text_input {
		if w.inspector_pinned {
			w.inspector_pinned = false
		} else {
			id, kind, rect := inspector_find_hover(w, mouse_pos)
			if id != 0 {
				w.inspector_pinned      = true
				w.inspector_pinned_id   = id
				w.inspector_pinned_kind = kind
				w.inspector_pinned_rect = rect
			}
		}
	}
}

// inspector_render draws the debug panel if open. Pulls hover info
// from the widget store and paints over every other layer (popovers,
// dialogs, toasts) so the readout sits above the app regardless.
//
// Handles its own drag interaction: a mouse press on the title row
// begins a drag, held mouse moves the panel, release ends it.
// Because this runs after widget view/render, it gets the last crack
// at the mouse state — fine, since the inspector intercepts only
// input that lands on its own rect.
inspector_render :: proc(r: ^Renderer, w: ^Widget_Store, input: ^Input) {
	if !w.inspector_open { return }

	mp := input.mouse_pos

	// Theme-ish palette tuned for readability on either light or dark
	// app bg — pure white text on near-black panel with 92 % alpha.
	panel_bg := Color{0.08, 0.08, 0.10, 0.92}
	border_c := Color{0.30, 0.70, 1.00, 0.90}
	header_bg := Color{0.14, 0.16, 0.20, 0.98}
	fg       := Color{1, 1, 1, 1}
	fg_dim   := Color{0.72, 0.76, 0.82, 1}

	fs_title  := f32(13)
	fs_body   := f32(12)
	pad       := f32(10)
	row_h     := fs_body + 4
	header_h  := fs_title + pad * 1.2

	panel_w := f32(320)

	// First frame the position is still {0,0} — remap to upper-right.
	// After that the user can drag it wherever. Clamp on every frame
	// in case the window resized since the last position save.
	fb_w := f32(r.fb_size.x)
	fb_h := f32(r.fb_size.y)
	px := w.inspector_pos.x
	py := w.inspector_pos.y
	if px == 0 && py == 0 {
		px = fb_w - panel_w - 12
		py = 12
	}

	// Pinned/hover source swap — when the user pins, the subsequent
	// frames stop chasing the cursor so they can mouse over to check
	// a specific button without the readout flipping.
	hover_id:    Widget_ID
	hover_kind:  Widget_Kind
	hover_rect:  Rect
	if w.inspector_pinned {
		hover_id   = w.inspector_pinned_id
		hover_kind = w.inspector_pinned_kind
		hover_rect = w.inspector_pinned_rect
	} else {
		hover_id, hover_kind, hover_rect = inspector_find_hover(w, mp)
	}

	// Build the body lines.
	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	if hover_id != 0 {
		label := "Hovered"
		if w.inspector_pinned { label = "Pinned " }
		append(&lines, fmt.tprintf("%s:  %v", label, hover_id))
		append(&lines, fmt.tprintf("Kind:     %v", hover_kind))
		append(&lines,
			fmt.tprintf("Rect:     %.0f, %.0f   %.0f x %.0f",
				hover_rect.x, hover_rect.y, hover_rect.w, hover_rect.h))
	} else {
		append(&lines, "Hovered:  (none)")
		append(&lines, "")
		append(&lines, "Move the cursor over a widget to inspect it.")
	}
	append(&lines, "")
	append(&lines, fmt.tprintf("Focused:  %v", w.focused_id))
	append(&lines, "")
	append(&lines, "F12 close   P pin   drag title to move")

	panel_h := header_h + f32(len(lines)) * row_h + pad

	// Clamp the panel fully on-screen each frame. Handles window
	// resizes and keeps the user from losing the panel off-screen.
	if px > fb_w - panel_w { px = fb_w - panel_w - 4 }
	if py > fb_h - panel_h { py = fb_h - panel_h - 4 }
	if px < 4 { px = 4 }
	if py < 4 { py = 4 }
	w.inspector_pos = {px, py}

	// Drag interaction: press on the title region to grab, hold to
	// move, release to drop. We store the press-relative offset so
	// the panel doesn't snap to cursor origin on grab.
	title_rect := Rect{px, py, panel_w, header_h}
	if input.mouse_pressed[.Left] && rect_contains_point(title_rect, mp) {
		w.inspector_dragging    = true
		w.inspector_drag_offset = {mp.x - px, mp.y - py}
		// Swallow the press so the app below doesn't react too.
		input.mouse_pressed[.Left] = false
	}
	if w.inspector_dragging {
		if input.mouse_buttons[.Left] {
			w.inspector_pos = {
				mp.x - w.inspector_drag_offset.x,
				mp.y - w.inspector_drag_offset.y,
			}
		} else {
			w.inspector_dragging = false
		}
	}

	// Save/restore alpha so the inspector's own translucency doesn't
	// double with any in-flight overlay fade — it paints at its own
	// fixed alpha regardless.
	saved_alpha := r.alpha_multiplier
	r.alpha_multiplier = 1

	// Panel body.
	draw_rect(r, {px, py, panel_w, panel_h}, panel_bg, 6)
	// Header strip (slightly lighter, acts as a visual drag handle).
	draw_rect(r, {px, py, panel_w, header_h}, header_bg, 6)
	// 1-px primary border.
	b: f32 = 1
	draw_rect(r, {px, py, panel_w, b}, border_c, 0)
	draw_rect(r, {px, py + panel_h - b, panel_w, b}, border_c, 0)
	draw_rect(r, {px, py + b, b, panel_h - 2*b}, border_c, 0)
	draw_rect(r, {px + panel_w - b, py + b, b, panel_h - 2*b}, border_c, 0)

	// Header label.
	ascent_title := text_ascent(r, fs_title, 0)
	header_label := "Skald inspector — F12"
	if w.inspector_pinned { header_label = "Skald inspector — F12  [pinned]" }
	draw_text(r, header_label,
		px + pad, py + pad * 0.8 + ascent_title,
		fg, fs_title, 0)

	// Body lines.
	ascent_body := text_ascent(r, fs_body, 0)
	ty := py + header_h + pad * 0.25
	for line in lines {
		if len(line) > 0 {
			col := fg
			if line == "Move the cursor over a widget to inspect it." ||
			   line == "F12 close   P pin   drag title to move" {
				col = fg_dim
			}
			draw_text(r, line, px + pad, ty + ascent_body, col, fs_body, 0)
		}
		ty += row_h
	}

	// Outline the hovered/pinned widget so you can match the panel
	// stats to the thing on screen. Four thin edges rather than a
	// fill so the widget itself stays visible underneath.
	if hover_id != 0 {
		hl := Color{0.30, 0.70, 1.00, 0.75}
		if w.inspector_pinned { hl = Color{1.00, 0.74, 0.30, 0.90} }
		hb: f32 = 2
		draw_rect(r, {hover_rect.x, hover_rect.y, hover_rect.w, hb}, hl, 0)
		draw_rect(r, {hover_rect.x, hover_rect.y + hover_rect.h - hb, hover_rect.w, hb}, hl, 0)
		draw_rect(r, {hover_rect.x, hover_rect.y + hb, hb, hover_rect.h - 2*hb}, hl, 0)
		draw_rect(r, {hover_rect.x + hover_rect.w - hb, hover_rect.y + hb, hb, hover_rect.h - 2*hb}, hl, 0)
	}

	r.alpha_multiplier = saved_alpha
}

// inspector_find_hover walks the widget store picking the smallest
// rect containing the cursor — smaller rects are almost always more
// specific (a button nested inside a card) so this picks the
// innermost widget the pointer is over, a cheap approximation of
// "the thing the user is actually pointing at."
//
// Filters the same way `rect_hovered` does at widget-code sites:
//   * If a modal is up, skip widgets outside the modal rect.
//   * If any overlay sits under the cursor, only consider widgets
//     whose rect is fully inside that overlay — a button buried
//     beneath an open dropdown shouldn't read as "hovered."
// Without these, a stale popup would hide behind its mask and the
// inspector would still claim the widget underneath was hovered.
@(private)
inspector_find_hover :: proc(w: ^Widget_Store, mp: [2]f32) -> (Widget_ID, Widget_Kind, Rect) {
	best_id:    Widget_ID
	best_kind:  Widget_Kind
	best_rect:  Rect
	best_area:  f32 = -1

	mr := w.modal_rect_prev

	for id, st in w.states {
		rr := st.last_rect
		if rr.w <= 0 || rr.h <= 0 { continue }
		if !rect_contains_point(rr, mp) { continue }

		// Modal gate: if a dialog is up, widgets outside its card
		// are blocked by the scrim.
		if mr.w > 0 && mr.h > 0 && !rect_contains_rect(mr, rr) { continue }

		// Overlay gate: if any overlay contains the cursor and
		// doesn't fully contain this widget, the widget is buried.
		buried := false
		for orr in w.overlay_rects_prev {
			if rect_contains_point(orr, mp) && !rect_contains_rect(orr, rr) {
				buried = true
				break
			}
		}
		if buried { continue }

		area := rr.w * rr.h
		if best_area < 0 || area < best_area {
			best_id    = id
			best_kind  = st.kind
			best_rect  = rr
			best_area  = area
		}
	}
	return best_id, best_kind, best_rect
}

} // when ODIN_DEBUG
