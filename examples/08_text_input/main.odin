package example_text_input

import "core:fmt"
import "core:strings"
import "gui:skald"

// A two-field form demonstrating Phase 5's text_input widget. It showcases
// the elm round-trip: each keystroke becomes a Msg carrying the new full
// string, update copies that string into state, and the next frame's view
// reflects it (plus the live "Hello, {name}" greeting derived from state).
//
// Focus moves by clicking between the two inputs. Tab-to-next-field,
// selection, and clipboard shortcuts are on the Phase 5 follow-up list.

State :: struct {
	name:           string,
	email:          string,
	query:          string,
	last_submitted: string,
}

Msg :: union {
	Name_Changed,
	Email_Changed,
	Query_Changed,
	Query_Submitted,
	Clear_Clicked,
}

Name_Changed    :: distinct string
Email_Changed   :: distinct string
Query_Changed   :: distinct string
Query_Submitted :: struct{}
Clear_Clicked   :: struct{}

init :: proc() -> State {
	// Seed as clones so the first `update` has owned memory to delete —
	// keeps the free/clone pattern uniform with every subsequent edit.
	return {
		name           = strings.clone(""),
		email          = strings.clone(""),
		query          = strings.clone(""),
		last_submitted = strings.clone(""),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Name_Changed:
		delete(out.name)
		out.name = strings.clone(string(v))
	case Email_Changed:
		delete(out.email)
		out.email = strings.clone(string(v))
	case Query_Changed:
		delete(out.query)
		out.query = strings.clone(string(v))
	case Query_Submitted:
		delete(out.last_submitted)
		out.last_submitted = strings.clone(out.query)
	case Clear_Clicked:
		delete(out.name)
		delete(out.email)
		delete(out.query)
		delete(out.last_submitted)
		out.name           = strings.clone("")
		out.email          = strings.clone("")
		out.query          = strings.clone("")
		out.last_submitted = strings.clone("")
	}
	return out, {}
}

// Constructors the text_input widgets use to wrap a new string into the
// right Msg variant. Passed by handle so the builder stays allocation-free
// aside from the payload string it builds.
on_name          :: proc(s: string) -> Msg { return Name_Changed(s)  }
on_email         :: proc(s: string) -> Msg { return Email_Changed(s) }
on_query         :: proc(s: string) -> Msg { return Query_Changed(s) }
on_query_submit  :: proc()          -> Msg { return Query_Submitted{} }

submitted_line :: proc(s: State) -> string {
	if s.last_submitted == "" {
		return "Press Enter in the filter to submit a query."
	}
	return fmt.tprintf("Last submitted: %s", s.last_submitted)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	greeting_text: string
	if len(s.name) > 0 {
		greeting_text = fmt.tprintf("Hello, %s.", s.name)
	} else {
		greeting_text = "Type your name below."
	}

	field_row :: proc(label: string, field: skald.View, th: ^skald.Theme) -> skald.View {
		return skald.col(
			skald.text(label, th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			field,
			spacing = 0,
		)
	}

	return skald.col(
		skald.text("Skald — Text Input", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(greeting_text, th.color.fg_muted, th.font.size_md),

		skald.spacer(th.spacing.xl),

		field_row("Name",
			skald.text_input(ctx, s.name, on_name, placeholder = "e.g. Ada Lovelace", width = 360),
			th),

		skald.spacer(th.spacing.md),

		field_row("Email",
			skald.text_input(ctx, s.email, on_email, placeholder = "you@example.com", width = 360),
			th),

		skald.spacer(th.spacing.md),

		// `search_field` wraps `text_input` with `search = true` and a
		// required Enter-submit callback. Typing updates the query
		// incrementally via `on_change`; pressing Enter fires
		// `on_submit`, which the app uses to commit the "last
		// submitted" value shown below the field.
		field_row("Filter",
			skald.search_field(ctx, s.query, on_query, on_query_submit, width = 360),
			th),

		skald.spacer(th.spacing.sm),
		skald.text(submitted_line(s), th.color.fg_muted, th.font.size_sm),

		skald.spacer(th.spacing.xl),

		skald.row(
			skald.button(ctx, "Clear", Clear_Clicked{},
				color = th.color.surface, fg = th.color.fg_muted, width = 120),
			spacing = th.spacing.md,
		),

		spacing     = 0,
		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Text Input",
		size   = {640, 520},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
