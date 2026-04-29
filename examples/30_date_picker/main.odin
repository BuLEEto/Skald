package example_date_picker

import "core:fmt"
import "gui:skald"

// Two date pickers exercising the calendar popover: one unconstrained,
// one bounded to a specific 6-week range to verify min/max greying +
// click-swallowing on disabled cells. Selected values echo into a
// summary line so the round-trip through `on_change` is visible.

State :: struct {
	birthday: skald.Date,
	deadline: skald.Date,
}

Msg :: union {
	Birthday_Picked,
	Deadline_Picked,
}

Birthday_Picked :: distinct skald.Date
Deadline_Picked :: distinct skald.Date

on_birthday :: proc(d: skald.Date) -> Msg { return Birthday_Picked(d) }
on_deadline :: proc(d: skald.Date) -> Msg { return Deadline_Picked(d) }

init :: proc() -> State {
	return {}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Birthday_Picked: out.birthday = skald.Date(v)
	case Deadline_Picked: out.deadline = skald.Date(v)
	}
	return out, {}
}

format_or :: proc(d: skald.Date, unset: string) -> string {
	if d.year == 0 && d.month == 0 && d.day == 0 { return unset }
	return skald.date_format(d)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	label :: proc(th: ^skald.Theme, s: string) -> skald.View {
		return skald.text(s, th.color.fg_muted, th.font.size_sm)
	}

	summary := fmt.tprintf(
		"Birthday: %s   ·   Deadline: %s",
		format_or(s.birthday, "—"),
		format_or(s.deadline, "—"),
	)

	return skald.col(
		skald.text("Skald — Date Picker", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.sm),
		skald.text(summary, th.color.fg_muted, th.font.size_md, max_width = 620),
		skald.spacer(th.spacing.xl),

		skald.col(
			label(th, "Birthday (unbounded)"),
			skald.spacer(th.spacing.xs),
			skald.date_picker(ctx, s.birthday, on_birthday,
				width = 240,
				placeholder = "Pick a birthday",
			),
			spacing = 0,
		),
		skald.spacer(th.spacing.lg),

		skald.col(
			label(th, "Deadline (Apr 10 – May 15, 2026)"),
			skald.spacer(th.spacing.xs),
			skald.date_picker(ctx, s.deadline, on_deadline,
				width       = 240,
				placeholder = "Pick a deadline",
				min_date    = skald.Date{2026, 4, 10},
				max_date    = skald.Date{2026, 5, 15},
			),
			spacing = 0,
		),

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Date Picker",
		size   = {720, 600},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
