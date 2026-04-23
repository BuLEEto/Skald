package example_canvas

// Canvas + stroke-renderer smoke test. Drag the mouse (or use a pen)
// inside the grid to draw a pressure-varying stroke. Mouse drags come
// in at frame rate with constant pressure=0.5; pen drags carry real
// pressure from SDL3 and modulate the ribbon width. Pressing "Clear"
// wipes the canvas.
//
// This validates draw_stroke and draw_triangle_strip in a real usage
// pattern. It's not the full paint app — no layers, no brushes, no
// undo. That arrives in the paint showcase.

import "gui:skald"

Stroke :: struct {
	color:   skald.Color,
	width:   f32,
	samples: [dynamic]skald.Stroke_Sample,
}

State :: struct {
	strokes:   [dynamic]Stroke,
	drawing:   bool,
	last_pos:  [2]f32,
	// Snapshotted-per-frame cursor / pen state so the paint callback
	// can render a brush preview at hover time. These don't persist
	// across frames — `view` refreshes them into a temp-arena copy
	// before handing the canvas its `user` pointer.
	hover_pos:      [2]f32,
	hover_inside:   bool,
	pen_active:     bool,
	pen_pressure:   f32,
	pen_eraser:     bool,
}

Msg :: union {
	Begin,
	Sample,
	End,
	Clear,
}

Begin  :: struct { pos: [2]f32, pressure: f32, eraser: bool }
Sample :: struct { pos: [2]f32, pressure: f32 }
End    :: struct {}
Clear  :: struct {}

// Latches which device the user is currently driving with. Flipped by
// concrete signals only — a real mouse motion flips to mouse, a pen
// event flips to pen — and otherwise persists. Without this latch the
// brush preview blinks between mouse and pen positions whenever the
// tablet fails to fire PEN_PROXIMITY_OUT (common with HUION on X11),
// because every idle frame re-reads the stuck-true `pen_in_proximity`
// and swings the ring back to the pen's last-known coord.
@(private="file") mouse_is_driver: bool = false

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Begin:
		color := skald.rgb(0x4ea3ff)
		if v.eraser { color = skald.rgb(0x1a1d23) } // "erase" = draw background colour
		stroke := Stroke{
			color   = color,
			width   = 10,
			samples = make([dynamic]skald.Stroke_Sample),
		}
		append(&stroke.samples, skald.Stroke_Sample{pos = v.pos, pressure = v.pressure})
		append(&out.strokes, stroke)
		out.drawing  = true
		out.last_pos = v.pos

	case Sample:
		if !out.drawing || len(out.strokes) == 0 { return out, {} }
		// Skip tiny sub-pixel moves — they blow up the sample count
		// without adding visible detail.
		dx := v.pos.x - out.last_pos.x
		dy := v.pos.y - out.last_pos.y
		if dx * dx + dy * dy < 1 { return out, {} }
		s_top := &out.strokes[len(out.strokes) - 1]
		append(&s_top.samples, skald.Stroke_Sample{pos = v.pos, pressure = v.pressure})
		out.last_pos = v.pos

	case End:
		out.drawing = false

	case Clear:
		for stroke in out.strokes { delete(stroke.samples) }
		clear(&out.strokes)
		out.drawing = false
	}
	return out, {}
}

paint :: proc(s: ^State, p: skald.Canvas_Painter) {
	skald.draw_rect(p.r, p.bounds, skald.rgb(0x1a1d23), 0)

	grid := skald.rgba(0xffffff18)
	step: f32 = 32
	y := p.bounds.y
	for ; y < p.bounds.y + p.bounds.h; y += step {
		skald.draw_rect(p.r, skald.Rect{p.bounds.x, y, p.bounds.w, 1}, grid, 0)
	}
	x := p.bounds.x
	for ; x < p.bounds.x + p.bounds.w; x += step {
		skald.draw_rect(p.r, skald.Rect{x, p.bounds.y, 1, p.bounds.h}, grid, 0)
	}

	for stroke in s.strokes {
		skald.draw_stroke(p.r, stroke.samples[:], stroke.width, stroke.color)
	}

	// Brush preview: small crosshair with a gap at the centre so the
	// exact aim pixel is never covered. Size stays fixed; pressure
	// fades alpha only — aim is stable, feedback is continuous.
	// Eraser flips the tint to red.
	if s.hover_inside {
		base := [3]f32{0x4e/255.0, 0xa3/255.0, 0xff/255.0}
		if s.pen_active && s.pen_eraser {
			base = {0xff/255.0, 0x4b/255.0, 0x4b/255.0}
		}
		pressure: f32 = 0.5
		if s.pen_active { pressure = clamp(s.pen_pressure, 0, 1) }
		alpha := 0.4 + 0.6 * pressure
		tint  := skald.Color{base.x, base.y, base.z, alpha}
		gap:   f32 = 3
		arm:   f32 = 6
		thick: f32 = 2
		ht    := thick * 0.5
		cx, cy := s.hover_pos.x, s.hover_pos.y
		// Left, right, top, bottom arms.
		skald.draw_rect(p.r,
			skald.Rect{cx - gap - arm, cy - ht, arm, thick}, tint, ht)
		skald.draw_rect(p.r,
			skald.Rect{cx + gap, cy - ht, arm, thick}, tint, ht)
		skald.draw_rect(p.r,
			skald.Rect{cx - ht, cy - gap - arm, thick, arm}, tint, ht)
		skald.draw_rect(p.r,
			skald.Rect{cx - ht, cy + gap, thick, arm}, tint, ht)
	}
}

rect_contains :: proc(r: skald.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Stable ID so the canvas's rect survives tree reshuffles (there's
	// only one canvas here, but this is the right pattern).
	cid := skald.hash_id("paint-canvas")

	// Previous-frame bounds, recorded by the renderer last time the
	// canvas rendered. First frame this is zero — clicks are ignored
	// until the canvas has laid out at least once.
	last := skald.widget_get(ctx, cid, .Canvas).last_rect

	// Post input Msgs based on edges. The canvas widget itself is a
	// pure renderer — it doesn't know about events. Posting from view
	// is the normal pattern for custom-input areas.
	//
	// For pen input we walk ctx.input.pen_samples (every SDL event this
	// frame, in order) rather than reading the frame-end snapshot. At
	// 60 Hz with a 200–1000 Hz stylus, the snapshot drops most of the
	// trajectory and the rendered stroke looks like it "picks up speed"
	// between samples; iterating the buffer recovers the real path.
	if last.w > 0 {
		pen_used := len(ctx.input.pen_samples) > 0 || ctx.input.pen_released
		if pen_used {
			// Iterate every SDL pen event from this frame. down=true
			// samples feed the stroke; down=false samples are
			// proximity hover and get ignored. The End trigger is the
			// frame-level pen_released edge — PEN_UP pushes a final
			// sample with down=true at the lift-off position so the
			// rendered stroke reaches the release point.
			began := s.drawing
			for sample in ctx.input.pen_samples {
				if !sample.down { continue }
				inside := rect_contains(last, sample.pos.x, sample.pos.y)
				if !began {
					if inside {
						skald.send(ctx, Begin{
							pos      = sample.pos,
							pressure = sample.pressure,
							eraser   = sample.eraser,
						})
						began = true
					}
				} else {
					skald.send(ctx, Sample{
						pos      = sample.pos,
						pressure = sample.pressure,
					})
				}
			}
			if began && ctx.input.pen_released {
				skald.send(ctx, End{})
			}
		}

		// Mouse fallback only when the pen isn't steering the canvas
		// this frame. `pen_used` covers live pen events; `pen_down`
		// covers the held-but-quiet case.
		if !pen_used && !ctx.input.pen_down {
			if ctx.input.mouse_pressed[.Left] && rect_contains(last,
				ctx.input.mouse_pos.x, ctx.input.mouse_pos.y) {
				skald.send(ctx, Begin{pos = ctx.input.mouse_pos, pressure = 0.5})
			} else if ctx.input.mouse_buttons[.Left] && s.drawing {
				skald.send(ctx, Sample{pos = ctx.input.mouse_pos, pressure = 0.5})
			} else if ctx.input.mouse_released[.Left] && s.drawing {
				skald.send(ctx, End{})
			}
		}
	}

	snap := new(State, context.temp_allocator)
	snap^ = s

	// Update the input-source latch from this frame's signals. A pen
	// event reclaims the canvas; a real mouse motion hands it back.
	// If neither fires, the latch persists — which is what kills the
	// blink when `pen_in_proximity` is stuck on and only the mouse
	// is actually moving.
	if len(ctx.input.pen_samples) > 0 || ctx.input.pen_pressed {
		mouse_is_driver = false
	}
	if ctx.input.mouse_physical_moved {
		mouse_is_driver = true
	}

	prefer_pen := !mouse_is_driver &&
		(ctx.input.pen_in_proximity || ctx.input.pen_down)
	if prefer_pen {
		snap.pen_active   = true
		snap.pen_pressure = ctx.input.pen_pressure
		snap.pen_eraser   = ctx.input.pen_eraser
		snap.hover_pos    = ctx.input.pen_pos
		snap.hover_inside = last.w > 0 && rect_contains(last,
			ctx.input.pen_pos.x, ctx.input.pen_pos.y)
	} else {
		snap.pen_active   = false
		snap.hover_pos    = ctx.input.mouse_pos
		snap.hover_inside = last.w > 0 && rect_contains(last,
			ctx.input.mouse_pos.x, ctx.input.mouse_pos.y)
	}

	// Hide the OS cursor while hovering inside the canvas — our
	// brush preview *is* the cursor. Leaving the OS arrow visible
	// makes it look like two reticles competing for the aim point.
	skald.cursor_set_visible(!snap.hover_inside)

	return skald.col(
		skald.row(
			skald.text("drag mouse or pen to stroke • pen carries pressure",
				th.color.fg_muted, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Clear", Clear{}, color = th.color.surface, fg = th.color.fg),
			padding     = th.spacing.md,
			spacing     = th.spacing.md,
			cross_align = .Center,
		),
		skald.flex(1, skald.canvas(ctx, snap, paint, id = cid)),
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Canvas + strokes",
		size   = {960, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
