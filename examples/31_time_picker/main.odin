package example_time_picker

import "core:fmt"
import "gui:skald"

// Three time pickers: a 15-min / 24h alarm, a 5-min / 12h meeting with
// AM/PM format, and a 1-second-step stopwatch that exercises the third
// (seconds) grid. The stopwatch feeds `time_format_24h`, which auto-
// upgrades to HH:MM:SS whenever `Time.second != 0`.

State :: struct {
	alarm:     skald.Time,
	meeting:   skald.Time,
	stopwatch: skald.Time,
}

Msg :: union {
	Alarm_Picked,
	Meeting_Picked,
	Stopwatch_Picked,
}

Alarm_Picked     :: distinct skald.Time
Meeting_Picked   :: distinct skald.Time
Stopwatch_Picked :: distinct skald.Time

on_alarm     :: proc(t: skald.Time) -> Msg { return Alarm_Picked(t)     }
on_meeting   :: proc(t: skald.Time) -> Msg { return Meeting_Picked(t)   }
on_stopwatch :: proc(t: skald.Time) -> Msg { return Stopwatch_Picked(t) }

init :: proc() -> State {
	return State{
		alarm     = skald.Time{hour = 7,  minute = 0},
		meeting   = skald.Time{hour = 14, minute = 30},
		stopwatch = skald.Time{hour = 0,  minute = 0, second = 30},
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Alarm_Picked:     out.alarm     = skald.Time(v)
	case Meeting_Picked:   out.meeting   = skald.Time(v)
	case Stopwatch_Picked: out.stopwatch = skald.Time(v)
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	label :: proc(th: ^skald.Theme, s: string) -> skald.View {
		return skald.text(s, th.color.fg_muted, th.font.size_sm)
	}

	summary := fmt.tprintf(
		"Alarm: %s   ·   Meeting: %s   ·   Stopwatch: %s",
		skald.time_format_24h(s.alarm),
		skald.time_format_12h(s.meeting),
		skald.time_format_24h(s.stopwatch),
	)

	return skald.col(
		skald.text("Skald — Time Picker", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.sm),
		skald.text(summary, th.color.fg_muted, th.font.size_md, max_width = 620),
		skald.spacer(th.spacing.xl),

		skald.col(
			label(th, "Alarm (15-min step, 24h)"),
			skald.spacer(th.spacing.xs),
			skald.time_picker(ctx, s.alarm, on_alarm,
				width       = 200,
				minute_step = 15,
			),
			spacing = 0,
		),
		skald.spacer(th.spacing.lg),

		skald.col(
			label(th, "Meeting (5-min step, 12h display)"),
			skald.spacer(th.spacing.xs),
			skald.time_picker(ctx, s.meeting, on_meeting,
				width       = 200,
				minute_step = 5,
				format      = skald.time_format_12h,
			),
			spacing = 0,
		),
		skald.spacer(th.spacing.lg),

		skald.col(
			label(th, "Stopwatch (1-min step, 1-sec step)"),
			skald.spacer(th.spacing.xs),
			skald.time_picker(ctx, s.stopwatch, on_stopwatch,
				width       = 220,
				minute_step = 1,
				second_step = 1,
			),
			spacing = 0,
		),

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Time Picker",
		size   = {720, 860},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
