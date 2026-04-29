package example_collapsible

import "core:fmt"
import "gui:skald"

// Three post-Phase-17 additions in one screen:
//
//   * collapsible — disclosure section with a rotating chevron. Click
//     the header (or focus + Space/Enter) to toggle. App owns the
//     open flag, same event-only pattern as tabs/segmented.
//   * number_input — now typeable. Click into the field and type a
//     number; +/- steppers still work on the side. Live parse emits
//     on_change for every valid parse; blur reformats to canonical
//     `%.*f` so the display stays tidy.
//   * skald.shortcut — app-level keyboard shortcut. This demo binds
//     Ctrl-R to Reset; press it from anywhere in the window.

State :: struct {
	general_open:  bool,
	limits_open:   bool,
	advanced_open: bool,

	name:      string,
	capacity:  f64,
	min_fill:  f64,
	max_fill:  f64,
	retries:   f64,
	multiplier: f64,
}

Msg :: union {
	General_Toggled,
	Limits_Toggled,
	Advanced_Toggled,
	Name_Changed,
	Capacity_Changed,
	Min_Fill_Changed,
	Max_Fill_Changed,
	Retries_Changed,
	Multiplier_Changed,
	Reset_Pressed,
}

General_Toggled    :: distinct bool
Limits_Toggled     :: distinct bool
Advanced_Toggled   :: distinct bool
Name_Changed       :: distinct string
Capacity_Changed   :: distinct f64
Min_Fill_Changed   :: distinct f64
Max_Fill_Changed   :: distinct f64
Retries_Changed    :: distinct f64
Multiplier_Changed :: distinct f64
Reset_Pressed      :: struct {}

init :: proc() -> State {
	return State{
		general_open = true,  // Start with the first section expanded
		name         = "",
		capacity     = 100,
		min_fill     = 10,
		max_fill     = 90,
		retries      = 3,
		multiplier   = 1.5,
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case General_Toggled:    out.general_open  = bool(v)
	case Limits_Toggled:     out.limits_open   = bool(v)
	case Advanced_Toggled:   out.advanced_open = bool(v)
	case Name_Changed:
		// text_input payloads live in the frame arena — clone to keep.
		delete(out.name)
		out.name = clone_string(string(v))
	case Capacity_Changed:   out.capacity   = f64(v)
	case Min_Fill_Changed:   out.min_fill   = f64(v)
	case Max_Fill_Changed:   out.max_fill   = f64(v)
	case Retries_Changed:    out.retries    = f64(v)
	case Multiplier_Changed: out.multiplier = f64(v)
	case Reset_Pressed:
		delete(out.name)
		out = init()
	}
	return out, {}
}

clone_string :: proc(s: string) -> string {
	if len(s) == 0 { return "" }
	buf := make([]u8, len(s))
	copy(buf, transmute([]u8)s)
	return string(buf)
}

on_general  :: proc(v: bool)   -> Msg { return General_Toggled(v) }
on_limits   :: proc(v: bool)   -> Msg { return Limits_Toggled(v) }
on_advanced :: proc(v: bool)   -> Msg { return Advanced_Toggled(v) }
on_name     :: proc(v: string) -> Msg { return Name_Changed(v) }
on_capacity :: proc(v: f64)    -> Msg { return Capacity_Changed(v) }
on_min_fill :: proc(v: f64)    -> Msg { return Min_Fill_Changed(v) }
on_max_fill :: proc(v: f64)    -> Msg { return Max_Fill_Changed(v) }
on_retries  :: proc(v: f64)    -> Msg { return Retries_Changed(v) }
on_mult     :: proc(v: f64)    -> Msg { return Multiplier_Changed(v) }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Ctrl-R resets. Fires anywhere, regardless of focus.
	skald.shortcut(ctx, {.R, {.Ctrl}}, Reset_Pressed{})

	general := skald.col(
		skald.form_row(ctx, "Name",
			skald.text_input(ctx, s.name, on_name, width = 260,
				placeholder = "Bucket name"),
			label_width = 120),
		skald.spacer(th.spacing.sm),
		skald.form_row(ctx, "Capacity",
			skald.number_input(ctx,
				value = s.capacity, on_change = on_capacity,
				step = 10, min_value = 0, max_value = 10_000,
				decimals = 0, width = 160),
			label_width = 120),
		padding = th.spacing.md,
	)

	limits := skald.col(
		skald.form_row(ctx, "Min fill",
			skald.number_input(ctx,
				value = s.min_fill, on_change = on_min_fill,
				step = 1, min_value = 0, max_value = 100,
				decimals = 0, width = 160),
			label_width = 120),
		skald.spacer(th.spacing.sm),
		skald.form_row(ctx, "Max fill",
			skald.number_input(ctx,
				value = s.max_fill, on_change = on_max_fill,
				step = 1, min_value = 0, max_value = 100,
				decimals = 0, width = 160),
			label_width = 120),
		padding = th.spacing.md,
	)

	advanced := skald.col(
		skald.form_row(ctx, "Retries",
			skald.number_input(ctx,
				value = s.retries, on_change = on_retries,
				step = 1, min_value = 0, max_value = 10,
				decimals = 0, width = 160),
			label_width = 120),
		skald.spacer(th.spacing.sm),
		skald.form_row(ctx, "Multiplier",
			skald.number_input(ctx,
				value = s.multiplier, on_change = on_mult,
				step = 0.1, min_value = 0.1, max_value = 10,
				decimals = 2, width = 160),
			label_width = 120),
		padding = th.spacing.md,
	)

	readout := fmt.tprintf(
		"name=%q  capacity=%.0f  min/max=%.0f/%.0f  retries=%.0f  mult=%.2f",
		s.name, s.capacity, s.min_fill, s.max_fill, s.retries, s.multiplier)

	children := make([dynamic]skald.View, 0, 8, context.temp_allocator)
	append(&children,
		skald.text("Skald — Collapsible & typeable numbers",
			th.color.fg, th.font.size_xl),
		skald.text("Click a section header to expand. " +
			"Click into any numeric field to type directly.",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.md),
	)

	// Show an alert when limits are inverted — demonstrates inline
	// validation feedback.
	if s.min_fill > s.max_fill {
		append(&children,
			skald.alert(ctx, "Limits are inverted",
				"Min fill is greater than max fill — adjust the Limits section.",
				tone = .Warning),
			skald.spacer(th.spacing.md),
		)
	}

	append(&children,
		skald.list_frame(ctx,
			skald.collapsible(ctx, "General",
				s.general_open, on_general, general),
			skald.collapsible(ctx, "Limits",
				s.limits_open, on_limits, limits),
			skald.collapsible(ctx, "Advanced",
				s.advanced_open, on_advanced, advanced),
		),
		skald.spacer(th.spacing.lg),
		skald.text(readout, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.sm),
		skald.row(
			skald.button(ctx, "Reset", Reset_Pressed{}),
			skald.spacer(th.spacing.sm),
			skald.text("or", th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.kbd(ctx, "Ctrl"),
			skald.spacer(th.spacing.xs),
			skald.text("+", th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.kbd(ctx, "R"),
			cross_align = .Center,
		),
	)

	return skald.col(..children[:],
		padding     = th.spacing.lg,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — 25_collapsible",
		size   = {640, 620},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
