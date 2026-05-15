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
//   * Press "Seed CRLF"           → loads a string with \r\n separators
//                                   (mimicking config / JSON / network
//                                   input). text_input normalises on
//                                   assignment, so wrap kicks in cleanly
//                                   with no \r tofu and no clipped lines.

State :: struct {
	messages: [dynamic]string,
	draft:    string,
	disabled: bool,
	tz:       string,
}

Msg :: union {
	Draft_Changed,
	Send_Pressed,
	Disabled_Toggled,
	Clear_All_Pressed,
	Seed_CRLF_Pressed,
	Tz_Changed,
}

Draft_Changed     :: distinct string
Send_Pressed      :: distinct string
Disabled_Toggled  :: distinct bool
Clear_All_Pressed :: struct{}
Seed_CRLF_Pressed :: struct{}
Tz_Changed        :: distinct string

// >8 entries on purpose so the combobox dropdown exercises the
// scrollable path (max_rows defaults to 8; the rest should be
// reachable by mouse wheel or keyboard nav, not silently dropped).
TIMEZONES := [?]string{
	"Europe/London",
	"Europe/Paris",
	"Europe/Berlin",
	"Europe/Madrid",
	"Europe/Stockholm",
	"America/New_York",
	"America/Chicago",
	"America/Denver",
	"America/Los_Angeles",
	"America/Sao_Paulo",
	"Africa/Cairo",
	"Asia/Tokyo",
	"Asia/Shanghai",
	"Asia/Singapore",
	"Asia/Kolkata",
	"Australia/Sydney",
	"Pacific/Auckland",
	// Last two are deliberately wider than the trigger so the
	// dropdown's auto-grow-to-widest-label path is exercised.
	"Antarctica/DumontDUrville (UTC+10)",
	"America/Argentina/Buenos_Aires (UTC-3)",
}

// A long string with literal \r\n separators, mimicking text loaded
// from a Windows-authored config / JSON / HTTP source. Each "line" is
// deliberately wider than the composer's content area so the wrap
// path has work to do — pre-fix, the \r bytes broke build_visual_lines
// and the long lines clipped at the right edge instead of wrapping.
CRLF_SEED ::
	"This is a long Windows-flavoured line that should wrap inside the " +
	"composer because the visible width is narrower than this paragraph.\r\n" +
	"Second paragraph, also long enough that the wrap path has to break " +
	"it into multiple visual lines if the framework is treating \\r\\n " +
	"as a hard break.\r\n" +
	"Third paragraph, shorter."

// big_message synthesises a ~30 KB body of plausible English-ish text
// so the bench exercises wrap_text on something that takes real work.
// Mirrors the bug-class string size Archon saw in boc-next.
big_message :: proc() -> string {
	chunk := "Lorem ipsum dolor sit amet, consectetur adipiscing elit, " +
		"sed do eiusmod tempor incididunt ut labore et dolore magna " +
		"aliqua. Ut enim ad minim veniam, quis nostrud exercitation. "
	sb := strings.builder_make()
	for i in 0..<160 { strings.write_string(&sb, chunk) }
	return strings.to_string(sb)
}

init :: proc() -> State {
	out := State{}
	append(&out.messages, "Welcome to the chat_input smoke test.")
	append(&out.messages, "Type below and hit Enter. Shift+Enter for a newline.")
	// Tab smoke test: \t should render as 4 spaces of width, not a
	// missing-glyph tofu. Visible as the "col1 / col2 / col3" run
	// having three discrete gaps between the labels.
	append(&out.messages, "tab demo:\tcol1\tcol2\tcol3")
	// One ~30 KB message exercises the wrap_text cost path during the
	// bench, mirroring the boc-next repro. Toggle off if you just want
	// to test the chat_input controls without the perf trace.
	when #config(BENCH_BIG_MSG, false) {
		append(&out.messages, big_message())
	}
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
	case Seed_CRLF_Pressed:
		// Seed the composer with a \r\n-heavy value so we can verify
		// the framework normalises it on assignment and wraps the
		// resulting logical lines correctly.
		out.draft = strings.clone(CRLF_SEED)
	case Tz_Changed:
		out.tz = strings.clone(string(v))
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
			skald.text(msg, th.color.fg, th.font.size_md, max_width = 580),
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

	// Deliberately omit `width` so chat_input → text_input falls into
	// the width=0 stretch path. The parent column below pins a width
	// and stretches children, so chat_input gets sized via layout and
	// wraps via the `_text_input_impl` last_rect fallback. Same shape
	// as boc-next's onboarding text fields.
	composer := skald.chat_input(ctx,
		s.draft,
		proc(v: string) -> Msg { return Draft_Changed(v) },
		proc(v: string) -> Msg { return Send_Pressed(v) },
		placeholder = "Message… (Enter to send, Shift+Enter for newline)",
		max_lines   = 6,
		disabled    = s.disabled,
	)

	// Same shape as boc-next's wizard combobox: no `width`, lives
	// inside a stretching parent. Closed and open states should both
	// fill the parent width; the trigger shouldn't shrink the moment
	// the popover appears.
	tz_picker := skald.combobox(ctx,
		s.tz,
		TIMEZONES[:],
		proc(v: string) -> Msg { return Tz_Changed(v) },
		placeholder = "Timezone…",
	)

	controls := skald.row(
		skald.checkbox(ctx, s.disabled, "Disabled",
			proc(v: bool) -> Msg { return Disabled_Toggled(v) }),
		skald.spacer(th.spacing.lg),
		skald.button(ctx, "Clear all", Msg(Clear_All_Pressed{}),
			bg = th.color.surface, fg = th.color.fg_muted),
		skald.spacer(th.spacing.md),
		skald.button(ctx, "Seed CRLF", Msg(Seed_CRLF_Pressed{}),
			bg = th.color.surface, fg = th.color.fg_muted),
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
		tz_picker,
		skald.spacer(th.spacing.md),
		controls,
		width       = 660,
		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Stretch,
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
