package example_dialog

import "core:fmt"
import "core:strings"
import "gui:skald"

// Phase 14 showcase (second half): the dialog widget. Two flavors are
// demoed together because they exercise different parts of the modal
// contract:
//
//   * "Delete" confirm dialog — tiny, two-button, on_dismiss wired to
//     Cancel. Proves Escape reaches Cancel, that clicks on the backdrop
//     do NOT reach the list buttons behind it (the run-loop preprocessor
//     eats them), and that a backdrop click does *not* close the dialog
//     (macOS/GNOME sheet behavior — accidental clicks shouldn't lose
//     typed input).
//
//   * "Sign in" dialog — a form-shaped dialog containing text inputs
//     and focus targets, so Tab cycles *inside* the card (the focus
//     trap). A "Sign in" button reports success via a banner.
//
// State is deliberately mundane; the interesting part is the three
// moving pieces the framework gates: scrim click, Escape, and Tab
// filtering by modal_rect.

State :: struct {
	files:        [dynamic]string,
	confirm_open: bool,
	confirm_key:  int, // which file the confirm targets

	signin_open:  bool,
	email:        string,
	password:     string,
	remember:     bool,
	last_signin:  string,
}

Msg :: union {
	Ask_Delete,
	Cancel_Delete,
	Confirm_Delete,

	Open_Signin,
	Cancel_Signin,
	Submit_Signin,

	Email_Changed,
	Password_Changed,
	Remember_Toggled,
}

Ask_Delete       :: distinct int
Cancel_Delete    :: struct{}
Confirm_Delete   :: struct{}

Open_Signin      :: struct{}
Cancel_Signin    :: struct{}
Submit_Signin    :: struct{}

Email_Changed    :: distinct string
Password_Changed :: distinct string
Remember_Toggled :: distinct bool

init :: proc() -> State {
	files := make([dynamic]string, 0, 4)
	append(&files,
		strings.clone("quarterly-report.pdf"),
		strings.clone("roadmap-2026.md"),
		strings.clone("receipts-backup.zip"),
		strings.clone("design-notes.txt"),
	)
	return {
		files       = files,
		confirm_key = -1,
		email       = strings.clone(""),
		password    = strings.clone(""),
		last_signin = strings.clone(""),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Ask_Delete:
		out.confirm_open = true
		out.confirm_key  = int(v)
	case Cancel_Delete:
		out.confirm_open = false
		out.confirm_key  = -1
	case Confirm_Delete:
		if out.confirm_key >= 0 && out.confirm_key < len(out.files) {
			// Real apps would free the string; this demo lets it leak
			// for brevity (the demo process is short-lived).
			ordered_remove(&out.files, out.confirm_key)
		}
		out.confirm_open = false
		out.confirm_key  = -1

	case Open_Signin:
		out.signin_open = true
	case Cancel_Signin:
		out.signin_open = false
	case Submit_Signin:
		delete(out.last_signin)
		out.last_signin = strings.clone(
			fmt.tprintf("Signed in as %s (remember=%v)",
				out.email, out.remember))
		out.signin_open = false

	case Email_Changed:
		delete(out.email)
		out.email = strings.clone(string(v))
	case Password_Changed:
		delete(out.password)
		out.password = strings.clone(string(v))
	case Remember_Toggled:
		out.remember = bool(v)
	}
	return out, {}
}

on_email    :: proc(v: string) -> Msg { return Email_Changed(v) }
on_password :: proc(v: string) -> Msg { return Password_Changed(v) }
on_remember :: proc(v: bool)   -> Msg { return Remember_Toggled(v) }

on_cancel_delete  :: proc() -> Msg { return Cancel_Delete{} }
on_cancel_signin  :: proc() -> Msg { return Cancel_Signin{} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	file_rows := make([dynamic]skald.View, 0, len(s.files),
		context.temp_allocator)
	for name, i in s.files {
		append(&file_rows, skald.row(
			skald.text(name, th.color.fg, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Delete", Ask_Delete(i),
				id = skald.hash_id(fmt.tprintf("delete:%d", i))),
			cross_align = .Center,
			spacing     = th.spacing.md,
		))
	}

	banner: skald.View
	if len(s.last_signin) > 0 {
		banner = skald.col(
			skald.text(s.last_signin,
				th.color.success, th.font.size_md),
			skald.spacer(th.spacing.lg),
		)
	} else {
		banner = skald.spacer(0)
	}

	return skald.col(
		skald.text("Skald — Dialogs", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Escape or an explicit button dismisses; backdrop clicks are blocked but don't close.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.lg),

		banner,

		skald.row(
			skald.button(ctx, "Sign in…", Open_Signin{}),
			spacing = th.spacing.sm,
		),
		skald.spacer(th.spacing.lg),

		skald.text("Files", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.col(..file_rows[:],
			spacing = th.spacing.xs,
		),

		// Confirm dialog. Tiny — title, body, two buttons. The whole
		// thing lives inline in the view tree; dialog() returns an
		// empty spacer when s.confirm_open is false, so this node
		// contributes nothing to the main-column layout when closed.
		skald.dialog(ctx,
			open       = s.confirm_open,
			on_dismiss = on_cancel_delete,
			content    = skald.col(
				skald.text("Delete file?",
					th.color.fg, th.font.size_lg),
				skald.spacer(th.spacing.sm),
				skald.text(
					(s.files[s.confirm_key] if s.confirm_key >= 0 && s.confirm_key < len(s.files) else ""),
					th.color.fg_muted, th.font.size_md),
				skald.spacer(th.spacing.xs),
				skald.text("This cannot be undone.",
					th.color.fg_muted, th.font.size_md),
				skald.spacer(th.spacing.lg),
				skald.row(
					skald.flex(1, skald.spacer(0)),
					skald.button(ctx, "Cancel", Cancel_Delete{}),
					skald.spacer(th.spacing.sm),
					skald.button(ctx, "Delete", Confirm_Delete{}),
					cross_align = .Center,
				),
			),
		),

		// Sign-in dialog. Forms-shaped, so Tab should cycle between
		// the two text inputs + checkbox + two buttons (five stops)
		// and *not* escape to the main-tree "Sign in…" / Delete
		// buttons underneath.
		skald.dialog(ctx,
			open       = s.signin_open,
			on_dismiss = on_cancel_signin,
			content    = skald.col(
				skald.text("Sign in",
					th.color.fg, th.font.size_lg),
				skald.spacer(th.spacing.sm),
				skald.text("Enter your credentials to continue.",
					th.color.fg_muted, th.font.size_md),
				skald.spacer(th.spacing.lg),

				skald.text("Email", th.color.fg_muted, th.font.size_sm),
				skald.spacer(th.spacing.xs),
				skald.text_input(ctx, s.email, on_email,
					placeholder = "you@example.com",
					width       = 360),
				skald.spacer(th.spacing.md),

				skald.text("Password", th.color.fg_muted, th.font.size_sm),
				skald.spacer(th.spacing.xs),
				skald.text_input(ctx, s.password, on_password,
					placeholder = "your password",
					width       = 360,
					password    = true),
				skald.spacer(th.spacing.md),

				skald.checkbox(ctx, s.remember, "Remember me", on_remember),
				skald.spacer(th.spacing.lg),

				skald.row(
					skald.flex(1, skald.spacer(0)),
					skald.button(ctx, "Cancel", Cancel_Signin{}),
					skald.spacer(th.spacing.sm),
					skald.button(ctx, "Sign in", Submit_Signin{}),
					cross_align = .Center,
				),
			),
		),

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Dialogs",
		size   = {560, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
