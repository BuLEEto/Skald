package example_chat_input

import "core:fmt"
import "core:strings"
import "gui:skald"

// Smoke test for `chat_input` — the multiline composer with
// Enter=submit / Shift+Enter=newline / Ctrl+Enter=submit semantics.
//
// What to verify by hand:
//   * Type "hello" + Enter        → appears in the list, composer clears.
//   * Type a word, Shift+Enter,
//     another word, Enter         → both lines submit as one message.
//   * Type a word + Ctrl+Enter    → submits (Slack/Discord muscle memory).
//   * Press Enter with empty box  → nothing happens (no empty messages).
//   * Hold Enter to paste many
//     newlines, then submit       → box grows up to ~6 lines then scrolls
//                                   internally; submit still works.
//   * Toggle the "Disabled" check → composer goes muted, keys do nothing.

State :: struct {
	messages: [dynamic]string,
	draft:    string,
	disabled: bool,
}

Msg :: union {
	Draft_Changed,
	Send_Pressed,
	Disabled_Toggled,
	Clear_All_Pressed,
}

Draft_Changed     :: distinct string
Send_Pressed      :: distinct string
Disabled_Toggled  :: distinct bool
Clear_All_Pressed :: struct{}

init :: proc() -> State {
	out := State{}
	append(&out.messages, "Welcome to the chat_input smoke test.")
	append(&out.messages, "Type below and hit Enter. Shift+Enter for a newline.")
	return out
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Draft_Changed:
		out.draft = strings.clone(string(v))
	case Send_Pressed:
		append(&out.messages, strings.clone(string(v)))
		out.draft = ""
	case Disabled_Toggled:
		out.disabled = bool(v)
	case Clear_All_Pressed:
		clear(&out.messages)
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Render the message list inside a scroll view so a backlog of
	// submissions doesn't push the composer off-screen.
	rows := make([dynamic]skald.View, 0, len(s.messages), context.temp_allocator)
	for msg, i in s.messages {
		bg := th.color.surface
		if i % 2 == 1 { bg = th.color.elevated }
		append(&rows, skald.row(
			skald.text(msg, th.color.fg, th.font.size_md),
			width   = 600,
			padding = th.spacing.sm,
			bg      = bg,
			radius  = th.radius.sm,
		))
		append(&rows, skald.spacer(th.spacing.xs))
	}

	list := skald.scroll(ctx,
		{620, 360},
		skald.col(..rows[:], spacing = 0, cross_align = .Start),
	)

	composer := skald.chat_input(ctx,
		s.draft,
		proc(v: string) -> Msg { return Draft_Changed(v) },
		proc(v: string) -> Msg { return Send_Pressed(v) },
		placeholder = "Message… (Enter to send, Shift+Enter for newline)",
		width       = 600,
		max_lines   = 6,
		disabled    = s.disabled,
	)

	controls := skald.row(
		skald.checkbox(ctx, s.disabled, "Disabled",
			proc(v: bool) -> Msg { return Disabled_Toggled(v) }),
		skald.spacer(th.spacing.lg),
		skald.button(ctx, "Clear all", Msg(Clear_All_Pressed{}),
			color = th.color.surface, fg = th.color.fg_muted),
		spacing     = th.spacing.md,
		cross_align = .Center,
	)

	stats := fmt.tprintf("%d messages • draft: %d chars",
		len(s.messages), len(s.draft))

	return skald.col(
		skald.text("chat_input smoke test",
			th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(stats, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.md),
		list,
		skald.spacer(th.spacing.md),
		composer,
		skald.spacer(th.spacing.md),
		controls,
		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — chat_input",
		size   = {720, 720},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
