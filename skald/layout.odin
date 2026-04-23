package skald

import "core:math"

// layout.odin is Phase 4's constraint-driven layout walker. Every View has
// two sizes: its *intrinsic* size (what the node would take if unconstrained)
// and its *assigned* size (what its parent hands down after flex and
// alignment have been resolved). `view_size` reports the former; `render_view`
// consumes the latter.
//
// Stacks do the real work. On entry they have an assigned size from their
// parent; from that they subtract padding and spacing, measure non-flex
// children intrinsically, hand the remainder to flex children in proportion
// to their weights, then position each child according to `main_align` and
// `cross_align`.

// view_size returns a view's intrinsic (unconstrained) pixel size. Text is
// measured against the renderer's fontstash context; stacks recurse to
// aggregate children. `View_Flex` reports its child's intrinsic — weights
// only matter once a parent stack has leftover space to distribute.
view_size :: proc(r: ^Renderer, v: View) -> [2]f32 {
	switch vv in v {
	case View_Rect:
		return vv.size

	case View_Gradient_Rect:
		return vv.size

	case View_Text:
		if vv.max_width > 0 {
			lines := wrap_text(r, vv.str, vv.max_width, vv.size, vv.font)
			_, lh := measure_text(r, "", vv.size, vv.font)
			return {vv.max_width, lh * f32(len(lines))}
		}
		w, h := measure_text(r, vv.str, vv.size, vv.font)
		return {w, h}

	case View_Stack:
		// If the stack declares an explicit width/height, use it directly
		// (the equivalent of SizedBox / Container(width:...)). This is
		// what lets a parent row know how wide a "220-px sidebar" is
		// regardless of what fill-axis sentinels its children use.
		if vv.width > 0 && vv.height > 0 { return {vv.width, vv.height} }

		main:  f32 = 0
		cross: f32 = 0
		for child, i in vv.children {
			cs := view_size(r, child)
			axis_main  := vv.direction == .Column ? cs.y : cs.x
			axis_cross := vv.direction == .Column ? cs.x : cs.y

			// Spacers are main-axis only, so ignore their cross contribution.
			_, is_spacer := child.(View_Spacer)
			if !is_spacer { cross = max(cross, axis_cross) }

			main += axis_main
			if i < len(vv.children) - 1 { main += vv.spacing }
		}
		main  += 2 * vv.padding
		cross += 2 * vv.padding

		out_x, out_y: f32
		if vv.direction == .Column { out_x, out_y = cross, main }
		else                        { out_x, out_y = main, cross }
		if vv.width  > 0 { out_x = vv.width  }
		if vv.height > 0 { out_y = vv.height }
		return {out_x, out_y}

	case View_Clip:
		return vv.size

	case View_Spacer:
		return {vv.size, vv.size}

	case View_Flex:
		return view_size(r, vv.child^)

	case View_Button:
		tw, lh := measure_text(r, vv.label, vv.font_size)
		w: f32 = vv.width
		if w == 0 { w = tw + 2 * vv.padding.x }
		return {w, lh + 2 * vv.padding.y}

	case View_Text_Input:
		// The builder already resolved height from font_size + padding;
		// width comes in as an explicit value (text inputs always declare
		// one — there's no sensible "fit-content" for an editable field).
		return {vv.width, vv.height}

	case View_Checkbox:
		w: f32 = vv.box_size
		h: f32 = vv.box_size
		if len(vv.label) > 0 {
			tw, lh := measure_text(r, vv.label, vv.font_size)
			w += vv.gap + tw
			if lh > h { h = lh }
		}
		return {w, h}

	case View_Radio:
		w: f32 = vv.box_size
		h: f32 = vv.box_size
		if len(vv.label) > 0 {
			tw, lh := measure_text(r, vv.label, vv.font_size)
			w += vv.gap + tw
			if lh > h { h = lh }
		}
		return {w, h}

	case View_Toggle:
		w: f32 = vv.track_w
		h: f32 = vv.track_h
		if len(vv.label) > 0 {
			tw, lh := measure_text(r, vv.label, vv.font_size)
			w += vv.gap + tw
			if lh > h { h = lh }
		}
		return {w, h}

	case View_Slider:
		return {vv.width, vv.height}

	case View_Progress:
		return {vv.width, vv.height}

	case View_Spinner:
		return {vv.size, vv.size}

	case View_Scroll:
		return vv.size

	case View_Select:
		// Same height recipe as button (font + vertical padding).
		h := vv.font_size + 2 * vv.padding.y
		w: f32 = vv.width
		if w == 0 { w = 160 }
		return {w, h}

	case View_Overlay:
		// Overlays float — they don't contribute intrinsic size to the
		// parent layout. The child's size is used only by the post-pass
		// placement logic in render_overlays.
		return {0, 0}

	case View_Tooltip:
		// Passthrough: the tooltip is a layout-invisible wrapper that
		// adds a hover-delayed bubble but shouldn't change the size
		// the child would've claimed on its own.
		return view_size(r, vv.child^)

	case View_Zone:
		// Passthrough — the zone only exists so the renderer can
		// record the child's rect for hit-testing.
		return view_size(r, vv.child^)

	case View_Dialog:
		// Dialog floats; it queues scrim + card into the overlay list
		// at render time and contributes no size to the parent layout.
		return {0, 0}

	case View_Image:
		// Image claims whatever size the builder computed. A zero on
		// either axis means "fill the assigned axis" (same sentinel
		// convention as View_Rect and View_Stack) — useful for e.g. a
		// hero image that should stretch to the column's width.
		return vv.size

	case View_Split:
		// Split has no intrinsic size — it's designed to be used with
		// Stretch/flex so it claims whatever the parent gives it. If a
		// caller places it in a Start-aligned row with no flex wrap, it
		// collapses to zero; wrap it in `flex(1, split(...))` or give
		// its parent an explicit size.
		return {0, 0}

	case View_Link:
		w, h := measure_text(r, vv.label, vv.font_size)
		return {w, h}

	case View_Toast:
		// Viewport-pinned: contributes nothing to the parent layout.
		return {0, 0}

	case View_Deferred:
		// Deferred nodes aren't measured against their content — they
		// rely on the parent's flex / stretch to hand them a size at
		// render time. The `min` is what they contribute to the parent
		// intrinsic so a Start-aligned column with no flex still
		// reserves at least that much room.
		return vv.min

	case View_Canvas:
		// Size is declared by the app. Zero on an axis means "fill the
		// assigned extent on that axis" — the layout walker hands the
		// final rect in through render_view. The parent's intrinsic
		// measurement has nothing to pull from the user's draw proc, so
		// we fall back to `min` when the declared size is zero.
		w := vv.size.x == 0 ? vv.min.x : vv.size.x
		h := vv.size.y == 0 ? vv.min.y : vv.size.y
		return {w, h}
	}
	return {0, 0}
}

// render_view walks `v` and emits draw calls. `origin` is the top-left
// corner in window pixels; `size` is the assigned size handed down by the
// parent (equals the view's intrinsic size for leaf nodes inside a
// Main_Align.Start stack without flex siblings — but differs for flex
// children and Stretch cross alignment).
render_view :: proc(r: ^Renderer, v: View, origin: [2]f32, size: [2]f32) {
	switch vv in v {
	case View_Rect:
		// A zero on either axis means "fill the assigned size on that
		// axis" — lets `rect({0, 48}, ...)` make a horizontal bar that
		// stretches to its parent's width, or a cross-axis Stretch in a
		// column give a rect its full width.
		w := vv.size.x == 0 ? size.x : vv.size.x
		h := vv.size.y == 0 ? size.y : vv.size.y
		draw_rect(r, {origin.x, origin.y, w, h}, vv.color, vv.radius)

	case View_Gradient_Rect:
		w := vv.size.x == 0 ? size.x : vv.size.x
		h := vv.size.y == 0 ? size.y : vv.size.y
		draw_gradient_rect(r, {origin.x, origin.y, w, h},
			vv.c_tl, vv.c_tr, vv.c_br, vv.c_bl, vv.radius)

	case View_Text:
		// draw_text takes a baseline y — offset by ascent so the view's
		// top edge aligns with `origin.y`, matching what view_size reports.
		ascent := text_ascent(r, vv.size, vv.font)
		if vv.max_width > 0 {
			lines := wrap_text(r, vv.str, vv.max_width, vv.size, vv.font)
			_, lh := measure_text(r, "", vv.size, vv.font)
			y := origin.y
			for line in lines {
				draw_text(r, line, origin.x, y + ascent, vv.color, vv.size, vv.font)
				y += lh
			}
		} else {
			draw_text(r, vv.str, origin.x, origin.y + ascent, vv.color, vv.size, vv.font)
		}

	case View_Stack:
		stack_render(r, vv, origin, size)

	case View_Clip:
		push_clip(r, {origin.x, origin.y, vv.size.x, vv.size.y})
		render_view(r, vv.child^, origin, vv.size)
		pop_clip(r)

	case View_Spacer:
		// Contributes to layout via view_size; nothing to draw.

	case View_Flex:
		// Outside a Stack a flex wrapper just forwards its assigned size.
		// Inside a Stack the parent has already accounted for the weight
		// and put the distributed size into `size`.
		render_view(r, vv.child^, origin, size)

	case View_Button:
		// Record the rendered rect so next frame's builder can hit-test
		// against it. nil when the renderer is driven outside the App
		// loop (e.g. the imperative 02_shapes example).
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		bg := vv.color
		if vv.pressed        { bg = color_tint(bg, 0.15) }
		else if vv.hover     { bg = color_tint(bg, 0.08) }

		draw_rect(r, {origin.x, origin.y, size.x, size.y}, bg, vv.radius)

		if vv.focused {
			draw_focus_ring(r,
				{origin.x, origin.y, size.x, size.y},
				vv.radius, vv.color_focus, bg)
		}

		tw, lh := measure_text(r, vv.label, vv.font_size)
		tx: f32
		switch vv.text_align {
		case .Start:    tx = origin.x + vv.padding.x
		case .End:      tx = origin.x + size.x - tw - vv.padding.x
		case .Center, .Stretch: tx = origin.x + (size.x - tw) / 2
		}
		ty := origin.y + (size.y - lh) / 2
		ascent := text_ascent(r, vv.font_size, 0)

		// Clip the label to the button rect so a label wider than the
		// button can't spill into neighbouring widgets. Tight buttons
		// (icon column in a list row, constrained flex cell) rely on
		// this — without it, over-long text visually punches through
		// the next button's background.
		push_clip(r, {origin.x, origin.y, size.x, size.y})
		draw_text(r, vv.label, tx, ty + ascent, vv.fg, vv.font_size, 0)
		pop_clip(r)

	case View_Text_Input:
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		// Body: filled rect. Every input renders a 1-px hairline border so
		// it stays visually distinct from the page background even under
		// low-contrast palettes (light theme's surface ≈ bg). Focused and
		// invalid states replace that hairline with the accent colour.
		draw_rect(r, {origin.x, origin.y, size.x, size.y}, vv.color_bg, vv.radius)
		{
			border_c := vv.color_border_idle
			if border_c[3] == 0 { border_c = vv.color_border }
			if vv.focused || vv.invalid { border_c = vv.color_border }
			b: f32 = 1
			// top + bottom + left + right as four thin rects — cheaper
			// than a real stroke and perfectly sharp on any DPI.
			draw_rect(r, {origin.x,               origin.y,               size.x, b}, border_c, 0)
			draw_rect(r, {origin.x,               origin.y + size.y - b,  size.x, b}, border_c, 0)
			draw_rect(r, {origin.x,               origin.y + b,           b,      size.y - 2*b}, border_c, 0)
			draw_rect(r, {origin.x + size.x - b,  origin.y + b,           b,      size.y - 2*b}, border_c, 0)
		}

		// Content region (everything inside the padding).
		ix := origin.x + vv.padding.x
		iy := origin.y + vv.padding.y
		iw := size.x - 2 * vv.padding.x
		ih := size.y - 2 * vv.padding.y
		if iw <= 0 || ih <= 0 { return }

		// Search-mode clear affordance: reserve a column in the right
		// padding for the `×` glyph and shrink `iw` so the caret/
		// selection/text don't run under it. Drawn *after* the main text
		// pass so it sits visually on top of the field surface.
		clear_w: f32 = 0
		if vv.show_clear {
			clear_w = vv.font_size + vv.padding.x * 0.5
			iw = max(0, iw - clear_w)
		}

		// Clip the text so an overfull string can't render past the
		// rounded edges. The current field doesn't scroll horizontally
		// yet — the caret just parks at the right margin if you type
		// past it; a future revision will maintain a scroll offset.
		// Explicit pop rather than `defer` so the multiline branch can
		// drop out of the clip before painting the scrollbar, which
		// sits in the right-padding column past `iw`.
		push_clip(r, {ix, iy, iw, ih})

		display      := vv.text
		display_col  := vv.color_fg
		if len(display) == 0 && !vv.focused && len(vv.placeholder) > 0 {
			display     = vv.placeholder
			display_col = vv.color_placeholder
		}

		_, lh := measure_text(r, display, vv.font_size)
		ascent := text_ascent(r, vv.font_size, 0)

		if !vv.multiline {
			// Single-line: vertically center. measure_text returns the
			// font's line height, which we use as the glyph box for
			// centering.
			ty := iy + (ih - lh) / 2

			// Selection highlight goes underneath the glyphs so the text
			// stays legible inside the selection color. Skip when the
			// placeholder is showing — there's nothing selectable there.
			if vv.focused && vv.selection_anchor != vv.cursor_pos && len(vv.text) > 0 {
				lo := vv.selection_anchor
				hi := vv.cursor_pos
				if lo > hi { lo, hi = hi, lo }
				lo = clamp(lo, 0, len(vv.text))
				hi = clamp(hi, 0, len(vv.text))
				x_lo: f32 = 0
				x_hi: f32 = 0
				if lo > 0 { x_lo, _ = measure_text(r, vv.text[:lo], vv.font_size) }
				if hi > 0 { x_hi, _ = measure_text(r, vv.text[:hi], vv.font_size) }
				draw_rect(r,
					{ix + x_lo, ty, x_hi - x_lo, lh},
					vv.color_selection, 0)
			}

			if len(display) > 0 {
				draw_text(r, display, ix, ty + ascent, display_col, vv.font_size, 0)
			}

			// Caret: measure the prefix up to cursor_pos to locate its x.
			// Drawn even on an empty buffer so focus is visible before the
			// user types.
			if vv.focused {
				cw: f32 = 0
				if vv.cursor_pos > 0 && vv.cursor_pos <= len(vv.text) {
					cw, _ = measure_text(r, vv.text[:vv.cursor_pos], vv.font_size)
				}
				caret_w: f32 = 1.5
				draw_rect(r,
					{ix + cw, ty, caret_w, lh},
					vv.color_caret, 0)
			}

			pop_clip(r)

			// Search-mode `×`. Drawn outside the text clip so the glyph
			// paints at full opacity even when a long query would have
			// scissored it. Hover tint mirrors the fg/fg_muted split from
			// View_Link's focused-state convention — subtle on rest,
			// confident on point.
			if vv.show_clear {
				glyph_col := vv.color_placeholder
				if vv.clear_hovered { glyph_col = vv.color_fg }
				gw, glh := measure_text(r, "×", vv.font_size)
				gx := ix + iw + (clear_w - gw) / 2
				gy := iy + (ih - glh) / 2
				ascent := text_ascent(r, vv.font_size, 0)
				draw_text(r, "×", gx, gy + ascent, glyph_col, vv.font_size, 0)
			}
		} else {
			// Multiline: top-aligned, one glyph run per visual line (the
			// builder hands us a Visual_Line table that collapses to one
			// entry per \n-separated chunk when wrap is off, or more when
			// soft-wrap splits a long run). Scrolled by vv.scroll_y.
			// Selection highlight rebuilt per visual line so wrapping
			// selections paint correctly across break boundaries. The
			// push_clip above scissors lines above and below the visible
			// window — cheaper than binary-searching the table.
			sel_lo, sel_hi: int
			has_sel := vv.focused && vv.selection_anchor != vv.cursor_pos && len(vv.text) > 0
			if has_sel {
				sel_lo = vv.selection_anchor
				sel_hi = vv.cursor_pos
				if sel_lo > sel_hi { sel_lo, sel_hi = sel_hi, sel_lo }
				sel_lo = clamp(sel_lo, 0, len(vv.text))
				sel_hi = clamp(sel_hi, 0, len(vv.text))
			}

			base_y := iy - vv.scroll_y

			if len(vv.text) == 0 {
				// Empty buffer: show placeholder (if any) and draw the
				// caret at the origin so focus is still visible.
				if len(display) > 0 && display_col.a != 0 {
					draw_text(r, display, ix, iy + ascent, display_col, vv.font_size, 0)
				}
				if vv.focused {
					draw_rect(r, {ix, iy, 1.5, lh}, vv.color_caret, 0)
				}
			} else {
				for vl, vli in vv.visual_lines {
					line_y := base_y + f32(vli) * lh
					i := vl.start
					j := vl.end

					// Selection highlight on this visual line, clipped to
					// [vl.start, vl.end]. Hard-\n line ends also paint a
					// small trailing strip so a selection that crosses
					// the newline reads visually as "through the break".
					// Soft-wrap breaks don't need the strip — the visual
					// flow to the next line already signals continuity.
					line_ends_hard := j < len(vv.text) && vv.text[j] == '\n'
					if has_sel && sel_hi > i && sel_lo <= j {
						lo := max(sel_lo, i)
						hi := min(sel_hi, j)
						x_lo: f32 = 0
						x_hi: f32 = 0
						if lo > i { x_lo, _ = measure_text(r, vv.text[i:lo], vv.font_size) }
						if hi > i { x_hi, _ = measure_text(r, vv.text[i:hi], vv.font_size) }
						if line_ends_hard && sel_hi > j {
							x_hi += vv.font_size * 0.4
						}
						if x_hi > x_lo {
							draw_rect(r,
								{ix + x_lo, line_y, x_hi - x_lo, lh},
								vv.color_selection, 0)
						}
					}

					// Glyphs for this visual line. The slice excludes any
					// space consumed by a wrap break, so `text[vl.start:vl.end]`
					// is exactly what should render.
					if j > i {
						draw_text(r, vv.text[i:j], ix, line_y + ascent,
							display_col, vv.font_size, 0)
					}

					// Caret on this visual line.
					if vv.focused && vv.cursor_pos >= i && vv.cursor_pos <= j {
						// When the caret sits exactly on a break shared
						// with the next visual line, prefer drawing it at
						// the start of the next line (skip here) so the
						// user doesn't see a ghost caret at the right edge
						// of the prior line.
						draw_here := true
						if vv.cursor_pos == j && vli + 1 < len(vv.visual_lines) {
							next_start := vv.visual_lines[vli + 1].start
							if next_start == j && !line_ends_hard {
								draw_here = false
							}
						}
						if draw_here {
							cw: f32 = 0
							if vv.cursor_pos > i {
								cw, _ = measure_text(r,
									vv.text[i:vv.cursor_pos], vv.font_size)
							}
							draw_rect(r, {ix + cw, line_y, 1.5, lh}, vv.color_caret, 0)
						}
					}
				}
			}

			pop_clip(r)

			// Scrollbar thumb on the right, drawn outside the content
			// clip so it sits in the right-padding column (past iw).
			// Only shown when content exceeds viewport; matches the
			// View_Scroll aesthetic so the two readers look native
			// together.
			if vv.content_h > ih {
				bar_w: f32 = 4
				bar_x := origin.x + size.x - bar_w - 3
				bar_y := iy + 1
				bar_h := ih - 2
				max_off := vv.content_h - ih
				ratio  := ih / vv.content_h
				thumb_h := bar_h * ratio
				if thumb_h < 16       { thumb_h = 16 }
				if thumb_h > bar_h    { thumb_h = bar_h }
				thumb_t := vv.scroll_y / max_off
				thumb_y := bar_y + (bar_h - thumb_h) * thumb_t

				// Same tint ramp as View_Scroll so the two readers feel
				// native together — active drag strongest, idle hover
				// lighter, resting unchanged.
				thumb_col := vv.color_thumb
				if vv.sb_dragging   { thumb_col = color_tint(thumb_col, 0.25) }
				else if vv.sb_hover { thumb_col = color_tint(thumb_col, 0.12) }

				draw_rect(r, {bar_x, thumb_y, bar_w, thumb_h},
					thumb_col, bar_w / 2)
			}
		}

	case View_Checkbox:
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		// Vertically center the box within the widget row so a taller
		// label text still lines up with the box's mid.
		box_y := origin.y + (size.y - vv.box_size) / 2
		box_r := Rect{origin.x, box_y, vv.box_size, vv.box_size}
		radius := vv.box_size * 0.25

		bg := vv.color_box
		if vv.checked { bg = vv.color_fill }
		if vv.pressed {
			bg = color_tint(bg, 0.12)
		} else if vv.hover {
			bg = color_tint(bg, 0.06)
		}
		draw_rect(r, {box_r.x, box_r.y, box_r.w, box_r.h}, bg, radius)
		if vv.focused {
			draw_focus_ring(r,
				{box_r.x, box_r.y, box_r.w, box_r.h},
				radius, vv.color_focus, bg)
		}
		if !vv.checked {
			// Unfilled outline: draw a slightly inset bg-colored rect to
			// give the border a 1-px ring without a dedicated stroke path.
			b: f32 = 1
			draw_rect(r, {box_r.x, box_r.y, box_r.w, b},                 vv.color_border, 0)
			draw_rect(r, {box_r.x, box_r.y + box_r.h - b, box_r.w, b},   vv.color_border, 0)
			draw_rect(r, {box_r.x, box_r.y + b, b, box_r.h - 2*b},       vv.color_border, 0)
			draw_rect(r, {box_r.x + box_r.w - b, box_r.y + b, b, box_r.h - 2*b}, vv.color_border, 0)
		} else {
			// ✓ drawn as a glyph so it picks up the text pipeline's AA
			// and scales with the font system, no bespoke stroke code.
			mark := "✓"
			tw, lh := measure_text(r, mark, vv.font_size)
			tx := box_r.x + (box_r.w - tw) / 2
			ty := box_r.y + (box_r.h - lh) / 2
			ascent := text_ascent(r, vv.font_size, 0)
			draw_text(r, mark, tx, ty + ascent, vv.color_check, vv.font_size, 0)
		}

		if len(vv.label) > 0 {
			_, lh := measure_text(r, vv.label, vv.font_size)
			ty := origin.y + (size.y - lh) / 2
			ascent := text_ascent(r, vv.font_size, 0)
			draw_text(r, vv.label,
				box_r.x + vv.box_size + vv.gap,
				ty + ascent,
				vv.color_fg, vv.font_size, 0)
		}

	case View_Radio:
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		box_y := origin.y + (size.y - vv.box_size) / 2
		box_r := Rect{origin.x, box_y, vv.box_size, vv.box_size}
		// Fully-rounded corner makes the SDF quad render as a disc —
		// no dedicated circle primitive needed.
		radius := vv.box_size * 0.5

		bg := vv.color_bg
		if vv.pressed {
			bg = color_tint(bg, 0.12)
		} else if vv.hover {
			bg = color_tint(bg, 0.06)
		}
		draw_rect(r, {box_r.x, box_r.y, box_r.w, box_r.h}, bg, radius)
		if vv.focused {
			draw_focus_ring(r,
				{box_r.x, box_r.y, box_r.w, box_r.h},
				radius, vv.color_focus, bg)
		}
		// No explicit outline ring — earlier versions stacked a
		// border-coloured disc under an inset bg disc, but the two
		// SDF edges don't blend cleanly and the disc reads as jagged.
		// The filled bg (theme `surface` against the panel's darker
		// bg) is enough contrast to see the control; focus + dot
		// carry the state cues.
		if vv.selected {
			// Inner filled dot. 50% of the outer diameter reads as
			// "selected" without touching the outline.
			dot_size := vv.box_size * 0.5
			dx := box_r.x + (box_r.w - dot_size) / 2
			dy := box_r.y + (box_r.h - dot_size) / 2
			draw_rect(r, {dx, dy, dot_size, dot_size},
				vv.color_dot, dot_size * 0.5)
		}

		if len(vv.label) > 0 {
			_, lh := measure_text(r, vv.label, vv.font_size)
			ty := origin.y + (size.y - lh) / 2
			ascent := text_ascent(r, vv.font_size, 0)
			draw_text(r, vv.label,
				box_r.x + vv.box_size + vv.gap,
				ty + ascent,
				vv.color_fg, vv.font_size, 0)
		}

	case View_Toggle:
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		// Vertically center the track in the widget row — label can
		// be taller at larger font sizes, and the control should sit
		// aligned with the text baseline area either way.
		track_y := origin.y + (size.y - vv.track_h) / 2
		track_x := origin.x
		radius  := vv.track_h * 0.5

		bg := vv.color_off
		if vv.on { bg = vv.color_on }
		if vv.pressed {
			bg = color_tint(bg, 0.12)
		} else if vv.hover {
			bg = color_tint(bg, 0.06)
		}
		draw_rect(r, {track_x, track_y, vv.track_w, vv.track_h}, bg, radius)
		if vv.focused {
			draw_focus_ring(r,
				{track_x, track_y, vv.track_w, vv.track_h},
				radius, vv.color_focus, bg)
		}

		// Knob — square with full-corner radius, so it renders as a
		// circle via the SDF pipeline. Positioned flush-left when off
		// and flush-right when on; `knob_pad` keeps it from kissing
		// the track edge on either side.
		knob_d := vv.track_h - 2 * vv.knob_pad
		if knob_d < 1 { knob_d = 1 }
		knob_x: f32 = track_x + vv.knob_pad
		if vv.on {
			knob_x = track_x + vv.track_w - vv.knob_pad - knob_d
		}
		knob_y := track_y + vv.knob_pad
		draw_rect(r, {knob_x, knob_y, knob_d, knob_d},
			vv.color_knob, knob_d * 0.5)

		if len(vv.label) > 0 {
			_, lh := measure_text(r, vv.label, vv.font_size)
			ty := origin.y + (size.y - lh) / 2
			ascent := text_ascent(r, vv.font_size, 0)
			draw_text(r, vv.label,
				track_x + vv.track_w + vv.gap,
				ty + ascent,
				vv.color_fg, vv.font_size, 0)
		}

	case View_Slider:
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		// Track runs centered vertically, with `thumb_r` left+right of
		// content so the thumb center can reach the visual ends.
		inset := vv.thumb_r
		track_y := origin.y + (size.y - vv.track_h) / 2
		track_x := origin.x + inset
		track_w := size.x - 2 * inset
		if track_w < 1 { track_w = 1 }

		// Background bed (full track).
		draw_rect(r, {track_x, track_y, track_w, vv.track_h},
			vv.color_track, vv.track_h / 2)

		// Filled portion up to the current value.
		span := vv.max_value - vv.min_value
		t: f32 = 0
		if span > 0 { t = (vv.value - vv.min_value) / span }
		if t < 0 { t = 0 }
		if t > 1 { t = 1 }
		draw_rect(r, {track_x, track_y, track_w * t, vv.track_h},
			vv.color_fill, vv.track_h / 2)

		// Thumb: filled disc (primary color outer, on_primary inner for
		// contrast). draw_rect with radius half the shorter edge gives a
		// perfect circle; the renderer clamps oversized radii.
		cx := track_x + track_w * t
		cy := track_y + vv.track_h / 2
		d  := vv.thumb_r * 2

		// Focus ring drawn *first* so the thumb paints over it, leaving
		// a clean accent halo around the disc. Outlining the whole
		// widget would be less legible — the track is mostly empty bed.
		if vv.focused {
			ring_r := vv.thumb_r + 3
			ring_d := ring_r * 2
			draw_rect(r, {cx - ring_r, cy - ring_r, ring_d, ring_d},
				vv.color_focus, ring_r)
		}

		// Outer ring (primary fill).
		draw_rect(r, {cx - vv.thumb_r, cy - vv.thumb_r, d, d},
			vv.color_fill, vv.thumb_r)
		// Inner dot.
		inner_r := vv.thumb_r - 2
		if inner_r < 1 { inner_r = 1 }
		draw_rect(r, {cx - inner_r, cy - inner_r, inner_r * 2, inner_r * 2},
			vv.color_thumb, inner_r)

	case View_Progress:
		w := size.x if vv.width == 0 else vv.width
		h := vv.height
		draw_rect(r, {origin.x, origin.y, w, h}, vv.color_bg, vv.radius)
		if vv.chip > 0 {
			// Indeterminate: clip a moving chip to the bar. chip_pos is
			// the left edge of the chip in [-chip, 1]; clamp to the
			// visible strip so the tail doesn't stick out past the
			// rounded end caps.
			lo := vv.chip_pos
			hi := vv.chip_pos + vv.chip
			if lo < 0 { lo = 0 }
			if hi > 1 { hi = 1 }
			if hi > lo {
				draw_rect(r,
					{origin.x + w * lo, origin.y, w * (hi - lo), h},
					vv.color_fill, vv.radius)
			}
		} else {
			t := vv.value
			if t < 0 { t = 0 }
			if t > 1 { t = 1 }
			draw_rect(r, {origin.x, origin.y, w * t, h}, vv.color_fill, vv.radius)
		}

	case View_Spinner:
		// Eight dots evenly spaced around a ring. The rotating `phase`
		// shifts which dot reads as the leading edge; alpha falls off
		// quadratically behind it so the user perceives motion rather
		// than a static ring.
		N :: 8
		dot_r  := vv.size * 0.12
		ring_r := vv.size * 0.5 - dot_r
		cx := origin.x + vv.size * 0.5
		cy := origin.y + vv.size * 0.5
		for i in 0..<N {
			ang := f32(i) / f32(N) * 2.0 * math.PI
			x := cx + ring_r * math.cos(ang)
			y := cy + ring_r * math.sin(ang)
			// Distance (in ring-turns) behind the leading dot. Wrap so
			// the leader is "newest" (t=0) and the dot just before it
			// is "oldest" (t≈1). Tint alpha quadratically.
			t := f32(i)/f32(N) - vv.phase
			t = t - math.floor(t)
			a := (1.0 - t) * (1.0 - t)
			c := vv.color
			c[3] *= a
			draw_rect(r, {x - dot_r, y - dot_r, dot_r*2, dot_r*2}, c, dot_r)
		}

	case View_Scroll:
		// Zero on either axis means "fill the assigned size" — the
		// parent stack's flex / Stretch rules decide the viewport
		// extent. Wrap in `flex(1, scroll(...))` inside a col to have
		// the list grow with the window.
		vp_w := vv.size.x if vv.size.x > 0 else size.x
		vp_h := vv.size.y if vv.size.y > 0 else size.y
		vp := Rect{origin.x, origin.y, vp_w, vp_h}
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id, vp)
		}

		// Scrollbar gutter reservation. The bar lives in the right 8 px
		// (6 track + 2 inset, see the render block below); without this
		// the child would lay out flush to the right viewport edge and
		// any right-aligned content (list row Spawn buttons, checkboxes)
		// would be painted underneath the bar.
		SCROLLBAR_GUTTER :: f32(10) // bar_w (6) + inset (2) + 2 px breathing room

		// Measure the child at the viewport's width. view_size returns
		// the intrinsic height the content wants; subtracting the
		// viewport height gives the usable scroll range.
		content_size := view_size(r, vv.content^)
		// If the child is narrower than the viewport, keep it at its
		// intrinsic width; if wider, let it lay out at its own width
		// (clipped by the scroll rect). No horizontal scrolling yet.
		child_w := max(content_size.x, vp_w)
		child_h := content_size.y

		max_off := child_h - vp_h
		if max_off < 0 { max_off = 0 }
		off := vv.offset_y
		if off < 0        { off = 0 }
		if off > max_off  { off = max_off }

		// When the bar will render, shrink the child layout width so
		// right-aligned content clears the gutter.
		if max_off > 0 && child_w > SCROLLBAR_GUTTER {
			child_w -= SCROLLBAR_GUTTER
		}

		// Write the clamped offset and content height back to widget
		// state. `scroll_y` needs writing because a rapid wheel tick
		// can leave the pre-clamp value well out of range; `content_h`
		// lets next frame's builder reconstruct scrollbar geometry for
		// hit-testing clicks without re-measuring the child tree.
		if r.widgets != nil {
			st := r.widgets.states[vv.id]
			st.scroll_y  = off
			st.content_h = child_h
			r.widgets.states[vv.id] = st
		}

		push_clip(r, vp)
		render_view(r, vv.content^, {origin.x, origin.y - off}, {child_w, child_h})
		pop_clip(r)

		// Scrollbar: only shown when content exceeds the viewport. The
		// bar is a 6-px strip pinned to the right edge; the thumb
		// height is proportional to the viewport/content ratio. The
		// builder drives hit-testing and drag via cached content_h
		// from last frame, so the thumb is fully clickable.
		if max_off > 0 {
			bar_w: f32 = 6
			bar_x := origin.x + vp_w - bar_w - 2
			bar_y := origin.y + 2
			bar_h := vp_h - 4
			draw_rect(r, {bar_x, bar_y, bar_w, bar_h},
				vv.track_color, bar_w / 2)

			ratio := vp_h / child_h
			thumb_h := bar_h * ratio
			if thumb_h < 16 { thumb_h = 16 } // minimum tap target
			if thumb_h > bar_h { thumb_h = bar_h }
			thumb_t := off / max_off // 0..1
			thumb_y := bar_y + (bar_h - thumb_h) * thumb_t

			// Tint on hover/press so the scrollbar feels like a live
			// control. Active (dragging) gets the strongest tint,
			// matching native scrollbar convention.
			thumb_col := vv.thumb_color
			if vv.dragging         { thumb_col = color_tint(thumb_col, 0.25) }
			else if vv.hover_thumb { thumb_col = color_tint(thumb_col, 0.12) }
			draw_rect(r, {bar_x, thumb_y, bar_w, thumb_h},
				thumb_col, bar_w / 2)
		}

	case View_Select:
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		bg := vv.color_bg
		if vv.hover { bg = color_tint(bg, 0.08) }
		draw_rect(r, {origin.x, origin.y, size.x, size.y}, bg, vv.radius)

		if vv.focused || vv.open {
			draw_focus_ring(r,
				{origin.x, origin.y, size.x, size.y},
				vv.radius, vv.color_focus, bg)
		} else {
			b: f32 = 1
			draw_rect(r, {origin.x,              origin.y,              size.x, b}, vv.color_border, 0)
			draw_rect(r, {origin.x,              origin.y + size.y - b, size.x, b}, vv.color_border, 0)
			draw_rect(r, {origin.x,              origin.y + b,          b,      size.y - 2*b}, vv.color_border, 0)
			draw_rect(r, {origin.x + size.x - b, origin.y + b,          b,      size.y - 2*b}, vv.color_border, 0)
		}

		display     := vv.value
		display_col := vv.color_fg
		if len(display) == 0 {
			display     = vv.placeholder
			display_col = vv.color_placeholder
		}

		ix := origin.x + vv.padding.x
		iy := origin.y + vv.padding.y
		iw := size.x - 2 * vv.padding.x
		// Caret geometry: a downward-pointing triangle drawn as four
		// stacked 1-px rows, each 2 px narrower than the one above.
		// Rendering it ourselves (instead of a Unicode glyph) avoids
		// the "font missing this code point" fallback rectangle that
		// shipped when we used ▾ — Inter has the glyph, but fontstash's
		// measurement of it was inconsistent across sizes.
		caret_w: f32 = 8
		caret_h: f32 = 4
		caret_x := origin.x + size.x - vv.padding.x - caret_w
		caret_y := origin.y + (size.y - caret_h) / 2

		_, lh := measure_text(r, display, vv.font_size)
		ty := iy + (size.y - 2*vv.padding.y - lh) / 2
		ascent := text_ascent(r, vv.font_size, 0)

		// Label (clipped so overflow doesn't escape into the caret area).
		label_w := iw - caret_w - 6
		if label_w < 0 { label_w = 0 }
		push_clip(r, {ix, iy, label_w, size.y - 2*vv.padding.y})
		draw_text(r, display, ix, ty + ascent, display_col, vv.font_size, 0)
		pop_clip(r)

		// Caret triangle. Each row is 1 px tall and shrinks by 2 px
		// total (1 px on each side) as it descends, giving a crisp ▼
		// that reads the same on any DPI.
		for i: f32 = 0; i < caret_h; i += 1 {
			row_w := caret_w - 2 * i
			if row_w < 1 { break }
			draw_rect(r,
				{caret_x + i, caret_y + i, row_w, 1},
				vv.color_caret, 0)
		}

	case View_Overlay:
		// Measure the child now so the post-pass has the intrinsic
		// size. Compute the natural placement relative to the anchor;
		// if it'd overflow the bottom (for .Below) or top (for .Above),
		// flip. Everything queued; actual draw happens in render_overlays.
		cs := view_size(r, vv.child^)
		x := vv.anchor.x + vv.offset.x
		y: f32
		switch vv.placement {
		case .Below:
			y = vv.anchor.y + vv.anchor.h + vv.offset.y
			if y + cs.y > f32(r.fb_size.y) && vv.anchor.y - cs.y >= 0 {
				y = vv.anchor.y - cs.y - vv.offset.y
			}
		case .Above:
			y = vv.anchor.y - cs.y - vv.offset.y
			if y < 0 && vv.anchor.y + vv.anchor.h + cs.y <= f32(r.fb_size.y) {
				y = vv.anchor.y + vv.anchor.h + vv.offset.y
			}
		}
		// Clamp horizontally so the overlay doesn't spill off screen —
		// common when a dropdown sits near the right edge of the window.
		if x + cs.x > f32(r.fb_size.x) { x = f32(r.fb_size.x) - cs.x }
		if x < 0                       { x = 0 }

		op := vv.opacity
		if op == 0 { op = 1 } // legacy call sites that don't set opacity
		append(&r.overlays, Overlay_Entry{
			origin        = {x, y},
			size          = cs,
			child         = vv.child^,
			shadow_radius = 8,
			opacity       = op,
		})

	case View_Tooltip:
		// Render the child first so the tooltip state can latch against
		// its actual rect. Stamp the widget record with (origin, size) —
		// the builder hit-tests this for the next frame's hover.
		render_view(r, vv.child^, origin, size)
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		// Bubble contents only get queued when the builder decided the
		// hover has lasted long enough. Geometry: measure the text, wrap
		// it in a padded rounded-rect, anchor under the child with a
		// small gap. render_overlays will auto-flip `.Below` to `.Above`
		// if the bubble would overflow the framebuffer.
		if !vv.show || len(vv.text) == 0 { return }

		// Split on '\n' so multi-line tooltip text actually wraps at the
		// newline instead of rendering the glyph (fontstash draws a tofu
		// box for control chars). Measure each line individually and take
		// the widest one for bubble width; height scales with line count.
		lines := make([dynamic]string, 0, 4, context.temp_allocator)
		{
			start := 0
			for i in 0..<len(vv.text) {
				if vv.text[i] == '\n' {
					append(&lines, vv.text[start:i])
					start = i + 1
				}
			}
			append(&lines, vv.text[start:])
		}
		max_w: f32 = 0
		_, lh := measure_text(r, "", vv.font_size)
		for line in lines {
			lw, _ := measure_text(r, line, vv.font_size)
			if lw > max_w { max_w = lw }
		}
		bubble_w := max_w + 2 * vv.padding.x
		bubble_h := lh * f32(len(lines)) + 2 * vv.padding.y

		anchor := Rect{origin.x, origin.y, size.x, size.y}

		// Horizontally center the bubble under the child, clamped to
		// the framebuffer by render_overlays' own clamp logic.
		bx := anchor.x + (anchor.w - bubble_w) / 2
		by := anchor.y + anchor.h + 4
		if by + bubble_h > f32(r.fb_size.y) && anchor.y - bubble_h - 4 >= 0 {
			by = anchor.y - bubble_h - 4
		}
		if bx + bubble_w > f32(r.fb_size.x) { bx = f32(r.fb_size.x) - bubble_w }
		if bx < 0                           { bx = 0 }

		children := make([]View, len(lines), context.temp_allocator)
		for line, i in lines {
			children[i] = View_Text{str = line, color = vv.color_fg, size = vv.font_size}
		}
		bubble := View_Stack{
			direction   = .Column,
			width       = bubble_w,
			height      = bubble_h,
			bg          = vv.color_bg,
			radius      = vv.radius,
			main_align  = .Center,
			cross_align = .Center,
			children    = children,
		}
		append(&r.overlays, Overlay_Entry{
			origin        = {bx, by},
			size          = {bubble_w, bubble_h},
			child         = bubble,
			shadow_radius = vv.radius,
			opacity       = 1,
		})

	case View_Zone:
		// Passthrough render + rect-record. The child paints itself;
		// the zone just stamps the bounding rect so next frame's
		// builder can hit-test clicks against it.
		render_view(r, vv.child^, origin, size)
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

	case View_Dialog:
		if !vv.open { return }

		// Any popover overlays queued before the dialog (select drop-
		// downs, pickers, menus…) belong to widgets that built earlier
		// in the tree with stale `open = true`. The dialog's builder
		// sweeps those widgets' state flags, but their view trees —
		// including the View_Overlay nodes that already queued here —
		// can't be retroactively unbuilt. Clearing the queue strips
		// them so nothing peeks out from under the scrim on the
		// dialog-open frame. Overlays queued LATER (e.g. a picker
		// inside the dialog card) are not affected because they
		// append after this point during render.
		clear(&r.overlays)

		// Scrim spans the framebuffer. Enqueued first so the card,
		// queued after, draws on top of it.
		fb_w := f32(r.fb_size.x)
		fb_h := f32(r.fb_size.y)
		scrim_child := View_Rect{
			size   = {fb_w, fb_h},
			color  = vv.color_scrim,
			radius = 0,
		}
		append(&r.overlays, Overlay_Entry{
			origin  = {0, 0},
			size    = {fb_w, fb_h},
			child   = scrim_child,
			opacity = 1,
		})

		// Card size: intrinsic child + padding, capped by max_width
		// and the framebuffer. `width` forces a fixed width when
		// non-zero.
		cs := view_size(r, vv.child^)
		card_w := cs.x + 2 * vv.padding
		if vv.width > 0 { card_w = vv.width }
		if vv.max_width > 0 && card_w > vv.max_width { card_w = vv.max_width }
		if card_w > fb_w - 16 { card_w = fb_w - 16 }
		card_h := cs.y + 2 * vv.padding
		if card_h > fb_h - 16 { card_h = fb_h - 16 }

		// Center the card in the framebuffer. The content child gets
		// the inner rect (after padding) as its assigned size — which
		// stretches any flex/stretch content inside to the card width.
		card_x := (fb_w - card_w) / 2
		card_y := (fb_h - card_h) / 2

		// Stamp the card rect for next-frame focus trap + backdrop
		// click detection. Widget_Store.modal_rect was cleared at the
		// top of the frame; setting it here re-arms those systems.
		if r.widgets != nil {
			r.widgets.modal_rect = Rect{card_x, card_y, card_w, card_h}
			widget_record_rect(r.widgets, vv.id,
				Rect{card_x, card_y, card_w, card_h})
		}

		// Compose the card: a Stack with bg + radius wrapping the
		// child at the inner padded position. Using a Stack (rather
		// than manually emitting rect + child) keeps the renderer
		// single-pass and lets the child pick up stretch/flex against
		// the card width the same way it would inside any container.
		content_children := make([]View, 1, context.temp_allocator)
		content_children[0] = vv.child^
		card := View_Stack{
			direction   = .Column,
			padding     = vv.padding,
			width       = card_w,
			height      = card_h,
			bg          = vv.color_bg,
			radius      = vv.radius,
			cross_align = .Stretch,
			children    = content_children,
		}
		append(&r.overlays, Overlay_Entry{
			origin        = {card_x, card_y},
			size          = {card_w, card_h},
			child         = card,
			shadow_radius = 8,
			opacity       = 1,
		})

	case View_Image:
		// Zero-axis sentinel mirrors View_Rect: fills the assigned size
		// on that axis, so `image(path, width=0)` expands to the column.
		w := vv.size.x == 0 ? size.x : vv.size.x
		h := vv.size.y == 0 ? size.y : vv.size.y
		box := Rect{origin.x, origin.y, w, h}

		entry := image_cache_get(r, vv.path)
		if entry == nil {
			// Decode failure — draw a magenta placeholder so the bad
			// path is visually obvious without crashing.
			draw_rect(r, box, {1, 0, 1, 1}, 0)
			return
		}
		pos, uv := image_fit_rects(box, f32(entry.width), f32(entry.height), vv.fit)
		// Clip to the declared box so `.None` with a larger native size
		// (or any future fit that extends past the slot) can't bleed
		// into neighboring widgets. Matches CSS `object-fit` behavior.
		push_clip(r, box)
		batch_push_image(r, entry.dset, pos, uv, vv.tint)
		pop_clip(r)

	case View_Split:
		// Record the container rect so next frame's builder can hit-
		// test the divider and clamp drags against the main-axis size.
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		// Clamp first_size to the visible range so the second pane is
		// never negative, even if the app feeds back a value from a
		// larger prior size (e.g. the window just shrunk). Doesn't
		// emit an on_resize — layout clamping is a one-frame visual
		// correction; the next drag will write a clean value back.
		dt := vv.divider_thickness
		first := vv.first_size

		// Divider visual — a thin pill centered in the hit zone, with
		// a small inset on the main axis so its caps don't butt up
		// against any rounded pane corners the children paint (same
		// pattern as the table column resize handle in Phase 13). The
		// full `dt`-wide strip is still the *hit* target; only the
		// visible stripe is the pill.
		div_visual: f32 = 2                  // visible stripe thickness
		end_inset:  f32 = 8                  // axial inset per end

		div_col := vv.color_divider
		if vv.pressed    { div_col = vv.color_divider_pressed }
		else if vv.hover { div_col = vv.color_divider_hover   }

		switch vv.direction {
		case .Row:
			main := size.x
			if first > main - dt { first = main - dt }
			if first < 0         { first = 0 }
			second_main := main - first - dt
			if second_main < 0 { second_main = 0 }

			render_view(r, vv.first^,  origin,                           {first,       size.y})
			render_view(r, vv.second^, {origin.x + first + dt, origin.y}, {second_main, size.y})

			// Clamp the axial inset so panes under ~16 px tall still
			// show a visible handle.
			inset := end_inset
			if size.y < inset * 2 + 8 { inset = max(0, (size.y - 8) * 0.5) }
			px := origin.x + first + (dt - div_visual) * 0.5
			py := origin.y + inset
			draw_rect(r, {px, py, div_visual, size.y - inset*2},
				div_col, div_visual * 0.5)

		case .Column:
			main := size.y
			if first > main - dt { first = main - dt }
			if first < 0         { first = 0 }
			second_main := main - first - dt
			if second_main < 0 { second_main = 0 }

			render_view(r, vv.first^,  origin,                           {size.x, first})
			render_view(r, vv.second^, {origin.x, origin.y + first + dt}, {size.x, second_main})

			inset := end_inset
			if size.x < inset * 2 + 8 { inset = max(0, (size.x - 8) * 0.5) }
			px := origin.x + inset
			py := origin.y + first + (dt - div_visual) * 0.5
			draw_rect(r, {px, py, size.x - inset*2, div_visual},
				div_col, div_visual * 0.5)
		}

	case View_Link:
		if r.widgets != nil {
			widget_record_rect(r.widgets, vv.id,
				Rect{origin.x, origin.y, size.x, size.y})
		}

		col := vv.color
		if vv.hover || vv.focused { col = vv.color_hover }

		ascent := text_ascent(r, vv.font_size, 0)
		tw, lh := measure_text(r, vv.label, vv.font_size)
		tx := origin.x
		ty := origin.y

		draw_text(r, vv.label, tx, ty + ascent, col, vv.font_size, 0)

		if vv.focused {
			// Two-px outline so the link's focus ring matches the
			// thickness used by button/checkbox/radio/toggle/select —
			// consistent focus styling across every interactive widget.
			// Hollow (four rects) rather than fill-inset because links
			// paint over whatever panel bg the caller supplies, which
			// draw_focus_ring's inner redraw would cover up.
			pad:  f32 = 2
			b:    f32 = 2
			rx := tx - pad
			ry := ty - pad
			rw := tw + 2*pad
			rh := lh + 2*pad
			fc := vv.color_focus
			draw_rect(r, {rx,          ry,          rw, b},          fc, 0)
			draw_rect(r, {rx,          ry + rh - b, rw, b},          fc, 0)
			draw_rect(r, {rx,          ry + b,      b,  rh - 2*b},   fc, 0)
			draw_rect(r, {rx + rw - b, ry + b,      b,  rh - 2*b},   fc, 0)
		}

		if vv.underline {
			uy := ty + ascent + 2
			if uy + 1 > ty + lh { uy = ty + lh - 1 }
			draw_rect(r, {tx, uy, tw, 1}, col, 0)
		}

	case View_Toast:
		if !vv.visible || vv.child == nil { return }

		fb_w := f32(r.fb_size.x)
		fb_h := f32(r.fb_size.y)

		cs := view_size(r, vv.child^)
		// Clamp to the framebuffer minus twice the margin so a too-wide
		// message doesn't disappear past the edge on small windows.
		cw := cs.x
		ch := cs.y
		max_w := fb_w - 2 * vv.margin
		if max_w < 0 { max_w = 0 }
		if cw > max_w { cw = max_w }

		x, y: f32
		switch vv.anchor {
		case .Top_Left:       x = vv.margin;                y = vv.margin
		case .Top_Center:     x = (fb_w - cw) / 2;          y = vv.margin
		case .Top_Right:      x = fb_w - cw - vv.margin;    y = vv.margin
		case .Bottom_Left:    x = vv.margin;                y = fb_h - ch - vv.margin
		case .Bottom_Center:  x = (fb_w - cw) / 2;          y = fb_h - ch - vv.margin
		case .Bottom_Right:   x = fb_w - cw - vv.margin;    y = fb_h - ch - vv.margin
		}

		append(&r.overlays, Overlay_Entry{
			origin        = {x, y},
			size          = {cw, ch},
			child         = vv.child^,
			shadow_radius = 8,
			opacity       = 1,
		})

	case View_Deferred:
		// The parent stack has already sized us via flex / stretch /
		// explicit extent — `size` is the rect we were assigned. Hand
		// that to the caller's builder to materialise the subtree and
		// render it in our slot. The subtree itself is arbitrary and
		// may include further deferred nodes (nesting works because we
		// just recurse through render_view).
		if vv.trampoline == nil { return }
		child := vv.trampoline(vv.ctx, vv.data, vv.build_raw, size)
		render_view(r, child, origin, size)

	case View_Canvas:
		if vv.draw == nil { return }
		// Fill sentinels: zero on either axis adopts the parent's
		// assigned extent. Matches View_Rect / View_Image / View_Stack.
		w := vv.size.x == 0 ? size.x : vv.size.x
		h := vv.size.y == 0 ? size.y : vv.size.y
		bounds := Rect{origin.x, origin.y, w, h}
		// Record this frame's rect so next frame's view can hit-test
		// against it via widget_last_rect(ctx, id).
		if r.widgets != nil && vv.id != 0 {
			widget_record_rect(r.widgets, vv.id, bounds)
		}
		// Scissor the callback's draws to the canvas rect. Without this
		// a runaway `draw_rect` could paint over neighbour widgets.
		push_clip(r, bounds)
		vv.draw(vv.user, Canvas_Painter{r = r, bounds = bounds})
		pop_clip(r)
	}
}

// render_overlays drains the overlay list queued during the main
// render_view pass and draws each entry on top of the existing frame.
// Called by `run` after the tree renders and before `frame_end`.
//
// Processing uses an index cursor rather than a range-for so overlays
// that enqueue further overlays (nested sub-menus, tooltips inside a
// popover) are picked up in the same frame without extra plumbing.
render_overlays :: proc(r: ^Renderer) {
	i := 0
	for i < len(r.overlays) {
		e := r.overlays[i]

		// Opacity fade: popover builders animate `anim_t` toward 1 on
		// open and 0 on close; that value is piped here via
		// `e.opacity`. 0 suppresses the overlay entirely so drop
		// shadows and clip push don't leak. Nested overlays (e.g. a
		// tooltip inside a popover) multiply: save and restore.
		opacity := e.opacity
		if opacity == 0 && e.shadow_radius > 0 {
			// Opacity 0 + non-zero shadow radius still renders — that's
			// the "just a shadow" case, used by nothing in-tree but
			// valid if a future widget wants it. Guard so fully-faded
			// entries with no shadow can early-out.
		}
		if opacity <= 0 {
			i += 1
			continue
		}
		saved_alpha := r.alpha_multiplier
		r.alpha_multiplier = saved_alpha * opacity

		// Soft drop shadow beneath the popover card. shadow_radius == 0
		// opts out (used by dialog scrims and other full-screen entries
		// that shouldn't cast one). Blur + offset are hardcoded to match
		// a light-from-above convention; apps that want a different
		// depth feel can stamp their own via `draw_shadow` before
		// returning their view.
		if e.shadow_radius > 0 {
			draw_shadow(r,
				Rect{e.origin.x, e.origin.y, e.size.x, e.size.y},
				e.shadow_radius,
				16,                          // blur, px
				Color{0, 0, 0, 0.28},        // shadow tint
				{0, 4},                      // offset: light from above
			)
		}
		render_view(r, e.child, e.origin, e.size)

		r.alpha_multiplier = saved_alpha
		i += 1
	}
}

// draw_focus_ring paints a 2-px accent outline that respects the widget's
// corner radius. We don't have an SDF stroke primitive, so the ring is
// emulated as "repaint the whole rect in the ring color, then inset the
// widget's fill on top" — two SDF rounded-rect draws instead of four
// sharp-cornered strips. Callers pass the fill color they just drew
// under the widget (the bg) so the inset layer matches.
@(private)
draw_focus_ring :: proc(r: ^Renderer, rr: Rect, radius: f32, ring: Color, fill: Color) {
	w: f32 = 2
	draw_rect(r, {rr.x, rr.y, rr.w, rr.h}, ring, radius)
	inner_r := radius - w
	if inner_r < 0 { inner_r = 0 }
	draw_rect(r,
		{rr.x + w, rr.y + w, rr.w - 2*w, rr.h - 2*w},
		fill, inner_r)
}

// stack_render is the one place that implements flex distribution and
// main/cross alignment. It runs in one linear pass over the children:
// measure → distribute remainder to flex → place each child.
@(private)
stack_render :: proc(r: ^Renderer, s: View_Stack, origin: [2]f32, size: [2]f32) {
	// Background (if any) renders at the stack's full assigned size, so it
	// covers the padded gutter as well as the content area.
	if s.bg[3] > 0 {
		draw_rect(r, {origin.x, origin.y, size.x, size.y}, s.bg, s.radius)
	}

	n := len(s.children)
	if n == 0 { return }

	inner := [2]f32{size.x - 2 * s.padding, size.y - 2 * s.padding}
	inner_main  := s.direction == .Column ? inner.y : inner.x
	inner_cross := s.direction == .Column ? inner.x : inner.y

	// Per-child assigned sizes. Start with intrinsics, then overwrite the
	// main axis for flex children after we know the remainder.
	sizes   := make([][2]f32, n, context.temp_allocator)
	weights := make([]f32,    n, context.temp_allocator)

	non_flex_main: f32 = 0
	total_weight:  f32 = 0

	for child, i in s.children {
		#partial switch c in child {
		case View_Flex:
			weights[i] = c.weight
			total_weight += c.weight
			sizes[i] = view_size(r, c.child^)
		case:
			cs := view_size(r, child)
			sizes[i] = cs
			non_flex_main += s.direction == .Column ? cs.y : cs.x
		}
	}

	total_spacing: f32 = 0
	if n > 1 { total_spacing = s.spacing * f32(n - 1) }

	remaining := inner_main - non_flex_main - total_spacing
	if remaining < 0 { remaining = 0 }

	// Distribute remaining main-axis space among flex children.
	if total_weight > 0 {
		for i in 0..<n {
			if weights[i] > 0 {
				share := remaining * (weights[i] / total_weight)
				if s.direction == .Column { sizes[i].y = share }
				else                      { sizes[i].x = share }
			}
		}
	}

	// Main alignment only has leftover to distribute when there are no
	// flex children. With flex children, `remaining` has already been
	// consumed.
	lead:      f32 = 0
	extra_gap: f32 = 0
	if total_weight == 0 && remaining > 0 {
		switch s.main_align {
		case .Start:
			// leading offset 0; leftover trails naturally at the end.
		case .Center:
			lead = remaining / 2
		case .End:
			lead = remaining
		case .Space_Between:
			if n > 1 { extra_gap = remaining / f32(n - 1) }
			else     { lead = remaining / 2 }
		case .Space_Around:
			lead = remaining / f32(n * 2)
			extra_gap = remaining / f32(n)
		}
	}

	cursor := [2]f32{origin.x + s.padding, origin.y + s.padding}
	if s.direction == .Column { cursor.y += lead }
	else                      { cursor.x += lead }

	for child, i in s.children {
		// Stretch expands the cross axis to the stack's inner cross.
		if s.cross_align == .Stretch {
			if s.direction == .Column { sizes[i].x = inner_cross }
			else                      { sizes[i].y = inner_cross }
		}

		child_cross := s.direction == .Column ? sizes[i].x : sizes[i].y
		cross_offset: f32 = 0
		switch s.cross_align {
		case .Start, .Stretch:
			cross_offset = 0
		case .Center:
			cross_offset = (inner_cross - child_cross) / 2
		case .End:
			cross_offset = inner_cross - child_cross
		}

		child_origin := cursor
		if s.direction == .Column { child_origin.x += cross_offset }
		else                      { child_origin.y += cross_offset }

		render_view(r, child, child_origin, sizes[i])

		step := s.direction == .Column ? sizes[i].y : sizes[i].x
		if s.direction == .Column { cursor.y += step } else { cursor.x += step }
		if i < n - 1 {
			gap := s.spacing + extra_gap
			if s.direction == .Column { cursor.y += gap } else { cursor.x += gap }
		}
	}
}
