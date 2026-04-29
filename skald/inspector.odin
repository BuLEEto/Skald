package skald

// Debug inspector overlay. F12 toggles a small translucent panel that
// shows frame stats, widget counts, focus/hover info, and per-kind
// state entries — handy while building an app, pointless in a release.
//
// The whole file is gated on `when ODIN_DEBUG`, so `odin build -o:speed`
// (which clears ODIN_DEBUG) strips every byte of it: no panel, no F12
// handling, no state field cost beyond one `bool` in Widget_Store.
// That's the whole design: app authors can't ship a debug surface to
// users by accident because the surface literally doesn't exist in
// release binaries.
//
// The run loop calls `inspector_handle_toggle` early in each pump (to
// catch F12) and `inspector_render` at the end of the frame (so the
// panel paints over the app). Both are no-ops outside ODIN_DEBUG.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

when ODIN_DEBUG {

// inspector_handle_toggle watches for F12 in the frame's pressed set
// and flips the open flag. Also handles the pin keybind (P) and
// claims the Escape key when the panel is open so the usual
// dialog-dismiss path doesn't clash while the inspector holds focus.
// Called from the run loop after input_pump and before view.
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

// inspector_push_frame_time appends a sample to the rolling frame-time
// buffer. The run loop calls it once per render with the last frame's
// wall-clock duration in milliseconds. The ring's fixed 60 slots give
// a ~1-second FPS window at 60 fps; at lower framerates it still
// reflects recent history even if the window stretches time-wise.
inspector_push_frame_time :: proc(w: ^Widget_Store, dt_ms: f32) {
	w.inspector_frame_times[w.inspector_frame_time_idx] = dt_ms
	w.inspector_frame_time_idx = (w.inspector_frame_time_idx + 1) %
		len(w.inspector_frame_times)
}

// inspector_render draws the debug panel if open. Pulls stats from
// the renderer (batch sizes, frame count) and the widget store
// (state map, focus, hover). Runs after render_overlays so the panel
// sits above every popover and dialog, outside the normal overlay
// queue so its own rect never becomes a hover/modal gate.
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
	fg_warn  := Color{1.00, 0.74, 0.30, 1}

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

	fps, frame_ms := inspector_fps(w)
	rss_mb := inspector_rss_mb()
	kind_counts := inspector_kind_histogram(w)

	// Build the body lines.
	lines := make([dynamic]string, 0, 24, context.temp_allocator)

	fps_line_col := fg
	if frame_ms > 20 { fps_line_col = fg_warn }
	_ = fps_line_col // used below to colour one row
	append(&lines, fmt.tprintf("FPS:       %.1f   (%.2f ms)", fps, frame_ms))
	if rss_mb >= 0 {
		append(&lines, fmt.tprintf("RSS:       %.1f MB", rss_mb))
	}
	append(&lines, fmt.tprintf("Frame:     %d", w.frame))
	append(&lines, "")
	append(&lines, fmt.tprintf("Widgets:   %d", len(w.states)))
	append(&lines, fmt.tprintf("Focusable: %d", len(w.focusables)))
	append(&lines, fmt.tprintf("Overlays:  %d", len(w.overlay_rects_prev)))
	append(&lines, "")
	append(&lines, fmt.tprintf("Draw calls: %d", len(r.batch.ranges)))
	append(&lines, fmt.tprintf("Vertices:   %d", len(r.batch.vertices)))
	append(&lines, fmt.tprintf("Indices:    %d", len(r.batch.indices)))
	append(&lines, "")
	append(&lines, fmt.tprintf("Focused:  %v", w.focused_id))
	if hover_id != 0 {
		label := "Hovered"
		if w.inspector_pinned { label = "Pinned " }
		append(&lines, fmt.tprintf("%s:  %v  (%v)", label, hover_id, hover_kind))
		append(&lines,
			fmt.tprintf("  rect: %.0f,%.0f  %.0fx%.0f",
				hover_rect.x, hover_rect.y, hover_rect.w, hover_rect.h))
	} else {
		append(&lines, "Hovered:  (none)")
	}
	// Per-kind breakdown, sorted by count (desc). Only the kinds that
	// actually appear this frame, so the panel stays compact for
	// small apps and doesn't flood a 30-line list of zero rows.
	if len(kind_counts) > 0 {
		append(&lines, "")
		append(&lines, "— by kind —")
		for entry in kind_counts {
			append(&lines, fmt.tprintf("  %-14v %d", entry.kind, entry.count))
		}
	}
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
	for line, i in lines {
		if len(line) > 0 {
			col := fg
			if strings.has_prefix(line, "  ") ||
			   strings.has_prefix(line, "— ") ||
			   strings.has_prefix(line, "F12 ") {
				col = fg_dim
			}
			if i == 0 && frame_ms > 20 { col = fg_warn }
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

// inspector_fps reports the smoothed FPS and average frame time (ms)
// from the rolling buffer. Skips zero samples so the reading is
// stable from the first live frame, not "∞ fps" for the idle buffer
// slots that haven't been written yet.
@(private)
inspector_fps :: proc(w: ^Widget_Store) -> (fps: f32, avg_ms: f32) {
	sum:   f32 = 0
	count: int = 0
	for v in w.inspector_frame_times {
		if v > 0 { sum += v; count += 1 }
	}
	if count == 0 { return 0, 0 }
	avg_ms = sum / f32(count)
	if avg_ms > 0 { fps = 1000 / avg_ms }
	return
}

// inspector_rss_mb returns the process' resident-set size in MB,
// or a negative number if the reading isn't available on this
// platform. Linux reads /proc/self/statm (six space-separated
// fields; the second is resident pages). Everything else is TODO —
// returning -1 hides the row rather than showing a bogus value.
@(private)
inspector_rss_mb :: proc() -> f32 {
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
		if err != nil { return -1 }
		s := string(data)
		// Fields are " size resident shared text lib data dt " (pages).
		// Skip the first space-separated number.
		sp := strings.index_byte(s, ' ')
		if sp < 0 || sp+1 >= len(s) { return -1 }
		rest := s[sp+1:]
		sp2 := strings.index_byte(rest, ' ')
		if sp2 < 0 { return -1 }
		pages, pok := strconv.parse_i64(rest[:sp2])
		if !pok { return -1 }
		return f32(pages) * 4096.0 / (1024.0 * 1024.0)
	} else {
		return -1
	}
}

// Kind_Count is a per-kind tally used by the histogram view.
Kind_Count :: struct {
	kind:  Widget_Kind,
	count: int,
}

// inspector_kind_histogram bins every live widget by kind and returns
// a slice sorted by count descending. Skips zero buckets so the list
// stays compact. Sort is a tiny insertion pass — we have ~25 kinds
// max, so nothing fancier is justified.
@(private)
inspector_kind_histogram :: proc(w: ^Widget_Store) -> []Kind_Count {
	counts: [Widget_Kind]int
	for _, st in w.states {
		counts[st.kind] += 1
	}
	out := make([dynamic]Kind_Count, 0, len(counts), context.temp_allocator)
	for kind in Widget_Kind {
		if counts[kind] == 0 { continue }
		append(&out, Kind_Count{kind = kind, count = counts[kind]})
	}
	// Insertion sort by count desc. Small N, stable enough.
	for i := 1; i < len(out); i += 1 {
		j := i
		for j > 0 && out[j].count > out[j-1].count {
			out[j], out[j-1] = out[j-1], out[j]
			j -= 1
		}
	}
	return out[:]
}

} // when ODIN_DEBUG
