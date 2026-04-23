package example_widgets

import "core:fmt"
import "gui:skald"

// A small settings panel that exercises the three widgets added in
// Phase 5 alongside `button`: checkbox, slider, progress.
//
// `progress` is non-interactive — its value advances automatically while
// the "Start" checkbox is on, so you can see it animate without having
// to wire up a timer API (those land in the Command/Effect phase).

State :: struct {
	dark_mode:   bool,
	running:     bool,
	volume:      f32, // 0..100, integer-stepped
	brightness:  f32, // 0..1, continuous
	progress:    f32, // 0..1, advanced while running
	tick:        int, // frame counter driving `progress` animation
	tags:        [dynamic]string,
	stars:       int, // 0..5, rating widget value
}

Msg :: union {
	Dark_Mode_Toggled,
	Running_Toggled,
	Volume_Changed,
	Brightness_Changed,
	Tick,
	Reset_Clicked,
	Tag_Removed,
	Stars_Changed,
}

Dark_Mode_Toggled  :: distinct bool
Running_Toggled    :: distinct bool
Volume_Changed     :: distinct f32
Brightness_Changed :: distinct f32
Tick               :: struct{}
Reset_Clicked      :: struct{}
Tag_Removed        :: distinct string
Stars_Changed      :: distinct int

init :: proc() -> State {
	s := State{
		dark_mode  = true,
		running    = false,
		volume     = 50,
		brightness = 0.6,
	}
	for t in ([]string{"urgent", "backend", "needs-review", "phase-17"}) {
		append(&s.tags, t)
	}
	return s
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Dark_Mode_Toggled:
		out.dark_mode = bool(v)
	case Running_Toggled:
		out.running = bool(v)
	case Volume_Changed:
		out.volume = f32(v)
	case Brightness_Changed:
		out.brightness = f32(v)
	case Tick:
		out.tick += 1
		if out.running {
			// 2% per tick → full bar in ~50 frames. The run loop doesn't
			// emit Ticks on its own (Phase 6 command/effect work), so
			// this only advances on frames where we manually fire one
			// from the view — see below.
			out.progress += 0.02
			if out.progress >= 1 {
				out.progress = 0
			}
		}
	case Reset_Clicked:
		out.progress = 0
	case Stars_Changed:
		out.stars = int(v)
	case Tag_Removed:
		target := string(v)
		for t, i in out.tags {
			if t == target {
				ordered_remove(&out.tags, i)
				break
			}
		}
	}
	return out, {}
}

on_tag_remove :: proc(label: string) -> Msg { return Tag_Removed(label) }

tag_row :: proc(ctx: ^skald.Ctx(Msg), tags: []string) -> skald.View {
	th := ctx.theme
	if len(tags) == 0 {
		return skald.text("(no tags — chips all dismissed)",
			th.color.fg_muted, th.font.size_sm)
	}
	chips := make([dynamic]skald.View, 0, len(tags), context.temp_allocator)
	for t in tags {
		append(&chips, skald.chip(ctx, t, on_tag_remove))
	}
	return skald.row(..chips[:],
		spacing     = th.spacing.sm,
		cross_align = .Center,
	)
}

on_dark       :: proc(v: bool) -> Msg { return Dark_Mode_Toggled(v)  }
on_run        :: proc(v: bool) -> Msg { return Running_Toggled(v)    }
on_volume     :: proc(v: f32)  -> Msg { return Volume_Changed(v)     }
on_brightness :: proc(v: f32)  -> Msg { return Brightness_Changed(v) }
on_stars      :: proc(v: int)  -> Msg { return Stars_Changed(v)      }

// step_from_progress maps a 0..1 progress value to one of four discrete
// stepper stages so the step indicator advances in sync with the load bar.
step_from_progress :: proc(p: f32) -> int {
	switch {
	case p <  0.25: return 0
	case p <  0.50: return 1
	case p <  0.90: return 2
	}
	return 3
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Advance `progress` by posting a Tick every frame. Poor man's
	// animation driver — good enough to demonstrate a moving bar without
	// pulling in the Command/Effect machinery, which is a later phase.
	skald.send(ctx, Tick{})

	CONTROL_W :: 360

	labeled_slider :: proc(
		ctx:       ^skald.Ctx(Msg),
		label:     string,
		readout:   string,
		value:     f32,
		on_change: proc(v: f32) -> Msg,
		min_value, max_value, step: f32,
	) -> skald.View {
		th := ctx.theme
		// Explicit row width so the flex spacer has space to push the
		// readout to the far edge. A content-sized row would have no
		// leftover main-axis room for flex to distribute.
		return skald.col(
			skald.row(
				skald.text(label, th.color.fg, th.font.size_md),
				skald.flex(1, skald.spacer(0)),
				skald.text(readout, th.color.fg_muted, th.font.size_md),
				width       = CONTROL_W,
				cross_align = .Center,
			),
			skald.spacer(th.spacing.xs),
			skald.slider(ctx, value, on_change,
				min_value = min_value, max_value = max_value, step = step, width = CONTROL_W),
		)
	}

	vol_label := fmt.tprintf("%d", int(s.volume))
	bright_label := fmt.tprintf("%.2f", s.brightness)
	prog_label := fmt.tprintf("%d%%", int(s.progress * 100))

	return skald.col(
		skald.text("Skald — Widgets", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.lg),

		skald.checkbox(ctx, s.dark_mode, "Use dark mode", on_dark),
		skald.spacer(th.spacing.md),

		skald.checkbox(ctx, s.running, "Simulate load", on_run),
		skald.spacer(th.spacing.lg),

		skald.col(
			skald.section_header(ctx, "Controls"),
			width       = CONTROL_W,
			cross_align = .Stretch,
		),
		skald.spacer(th.spacing.md),

		labeled_slider(ctx, "Volume", vol_label, s.volume, on_volume,
			0, 100, 1),
		skald.spacer(th.spacing.lg),

		labeled_slider(ctx, "Brightness", bright_label, s.brightness, on_brightness,
			0, 1, 0),
		skald.spacer(th.spacing.lg),

		skald.row(
			skald.text("Loading", th.color.fg, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.text(prog_label, th.color.fg_muted, th.font.size_md),
			width       = CONTROL_W,
			cross_align = .Center,
		),
		skald.spacer(th.spacing.xs),
		skald.progress(ctx, s.progress, width = CONTROL_W, height = 8),
		skald.spacer(th.spacing.md),

		skald.row(
			skald.text("Working…", th.color.fg, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.text("indeterminate", th.color.fg_muted, th.font.size_md),
			width       = CONTROL_W,
			cross_align = .Center,
		),
		skald.spacer(th.spacing.xs),
		skald.progress(ctx, 0, width = CONTROL_W, height = 8,
			indeterminate = true),
		skald.spacer(th.spacing.xl),

		skald.col(
			skald.stepper(ctx,
				{"Connect", "Fetch", "Parse", "Render"},
				current = step_from_progress(s.progress)),
			width       = CONTROL_W,
			cross_align = .Stretch,
		),

		skald.spacer(th.spacing.xl),

		skald.row(
			skald.text("Rate this build", th.color.fg, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.rating(ctx, s.stars, on_stars, max_value = 5, size = 20),
			width       = CONTROL_W,
			cross_align = .Center,
		),
		skald.spacer(th.spacing.xl),

		skald.row(
			skald.badge(ctx, "3"),
			skald.badge(ctx, "New",   tone = .Success),
			skald.badge(ctx, "Beta",  tone = .Warning),
			skald.badge(ctx, "Error", tone = .Danger),
			skald.badge(ctx, "42",    tone = .Neutral),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		),
		skald.spacer(th.spacing.md),

		tag_row(ctx, s.tags[:]),

		skald.spacer(th.spacing.xl),

		skald.row(
			skald.button(ctx, "Reset", Reset_Clicked{},
				color = th.color.surface, fg = th.color.fg_muted, width = 120),
		),

		spacing     = 0,
		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Widgets",
		size   = {640, 560},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
