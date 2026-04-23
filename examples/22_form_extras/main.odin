package example_form_extras

import "core:fmt"
import "core:strings"
import "gui:skald"

// Phase 14 close-out #2: the six pre-Phase-15 form-control extras, all
// on one screen so the shapes are easy to compare:
//
//   * divider — hairline between sections.
//   * link — text-styled clickable for "Reset to defaults".
//   * number_input — typeable numeric field with +/- steppers (servings, price).
//   * segmented — mutually-exclusive tabs (view mode).
//   * text_input with invalid + error — email field validates on every
//     keystroke; border + helper line flip to danger when malformed.
//   * toast — bottom-center snackbar emitted after "Save".

View_Mode :: enum { Grid, List, Timeline }

State :: struct {
	mode:        View_Mode,
	servings:    f64,
	price:       f64,
	email:       string,
	email_dirty: bool, // has the user typed yet? skip validation until then
	toast_open:  bool,
	toast_msg:   string,
}

Msg :: union {
	Mode_Set,
	Servings_Changed,
	Price_Changed,
	Email_Changed,
	Save_Pressed,
	Reset_Pressed,
	Toast_Closed,
}

Mode_Set         :: distinct int
Servings_Changed :: distinct f64
Price_Changed    :: distinct f64
Email_Changed    :: distinct string
Save_Pressed     :: struct {}
Reset_Pressed    :: struct {}
Toast_Closed     :: struct {}

init :: proc() -> State {
	return State{
		mode     = .Grid,
		servings = 2,
		price    = 9.99,
		email    = strings.clone(""),
	}
}

// Very loose email check: one '@' somewhere in the middle with at least
// one '.' after it. Good enough for demoing the invalid+error flags;
// real apps plug in a stricter validator.
email_valid :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	at := strings.index_byte(s, '@')
	if at <= 0 || at >= len(s) - 1 { return false }
	domain := s[at+1:]
	dot := strings.index_byte(domain, '.')
	if dot <= 0 || dot >= len(domain) - 1 { return false }
	return true
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Mode_Set:
		out.mode = View_Mode(int(v))
	case Servings_Changed:
		out.servings = f64(v)
	case Price_Changed:
		out.price = f64(v)
	case Email_Changed:
		out.email       = strings.clone(string(v))
		out.email_dirty = true
	case Save_Pressed:
		out.toast_open = true
		if email_valid(out.email) {
			out.toast_msg = strings.clone(fmt.tprintf(
				"Saved: %d servings at $%.2f, notify %s",
				int(out.servings), out.price, out.email))
		} else {
			out.toast_msg = strings.clone(
				"Fix the email before saving.")
		}
	case Reset_Pressed:
		out.servings    = 2
		out.price       = 9.99
		out.mode        = .Grid
		out.email       = strings.clone("")
		out.email_dirty = false
		out.toast_open  = false
	case Toast_Closed:
		out.toast_open = false
	}
	return out, {}
}

on_mode     :: proc(i: int)    -> Msg { return Mode_Set(i) }
on_servings :: proc(v: f64)    -> Msg { return Servings_Changed(v) }
on_price    :: proc(v: f64)    -> Msg { return Price_Changed(v) }
on_email    :: proc(v: string) -> Msg { return Email_Changed(v) }
on_close    :: proc()          -> Msg { return Toast_Closed{} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	show_email_error := s.email_dirty && !email_valid(s.email)

	toast_kind: skald.Toast_Kind = .Success
	if show_email_error && s.toast_open { toast_kind = .Danger }

	return skald.col(
		skald.text("Skald — Form Extras",
			th.color.fg, th.font.size_xl),
		skald.text("divider · link · number_input · segmented · invalid text_input · toast",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.md),

		// --- View mode: segmented control ---
		skald.text("View mode",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.segmented(ctx,
			options   = []string{"Grid", "List", "Timeline"},
			selected  = int(s.mode),
			on_change = on_mode,
		),

		skald.spacer(th.spacing.md),
		skald.divider(ctx),
		skald.spacer(th.spacing.md),

		// --- Numbers: stacked form_rows. One `label_width = 120` threads
		// both rows so the two number_inputs line up flush regardless of
		// label length; bump the single constant to scale the whole form.
		skald.form_row(ctx, "Servings",
			skald.number_input(ctx,
				value     = s.servings,
				on_change = on_servings,
				step      = 1,
				min_value = 1,
				max_value = 99,
				decimals  = 0,
				width     = 140,
			),
			label_width = 120),
		skald.spacer(th.spacing.sm),
		skald.form_row(ctx, "Price ($)",
			skald.number_input(ctx,
				value     = s.price,
				on_change = on_price,
				step      = 0.5,
				min_value = 0,
				max_value = 9999,
				decimals  = 2,
				width     = 160,
			),
			label_width = 120),

		skald.spacer(th.spacing.md),
		skald.divider(ctx),
		skald.spacer(th.spacing.md),

		// --- Email with inline validation ---
		skald.text("Email to notify",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.text_input(ctx,
			value       = s.email,
			on_change   = on_email,
			placeholder = "you@example.com",
			width       = 320,
			invalid     = show_email_error,
			error       = "Enter a valid email like name@host.tld",
		),

		skald.spacer(th.spacing.lg),

		// --- Actions: button + link ---
		skald.row(
			skald.button(ctx, "Save", Save_Pressed{}),
			skald.spacer(th.spacing.md),
			skald.link(ctx, "Reset to defaults", Reset_Pressed{}),
			cross_align = .Center,
		),

		skald.spacer(th.spacing.xl),

		// --- Toast (bottom-center, app-owned visibility) ---
		// dismiss_after = 3.0 fires on_close 3 s after the toast becomes
		// visible; the app's update handles the msg exactly like an
		// explicit close-button click. Set 0 (or omit) for manual-only
		// dismissal.
		skald.toast(ctx,
			visible       = s.toast_open,
			message       = s.toast_msg,
			on_close      = on_close,
			kind          = toast_kind,
			anchor        = .Bottom_Center,
			dismiss_after = 3.0,
		),

		padding = th.spacing.xl,
		spacing = 0,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Form Extras",
		size   = {720, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
