package example_scroll

import "core:fmt"
import "gui:skald"

// Two-pane inbox layout: scrollable message list on the left, detail
// pane on the right. Exercises the Phase 6 scroll container against a
// realistic amount of content (80 rows).
//
// Each row is itself a themed button so click anywhere selects — the
// whole row is the hit target. Multi-line labels aren't supported yet,
// so rows flatten "From — Subject" into a single line.

Message :: struct {
	from:    string,
	subject: string,
	body:    string,
}

State :: struct {
	messages: [dynamic]Message,
	selected: int,
}

Msg :: union {
	Select_Message,
}

Select_Message :: distinct int

init :: proc() -> State {
	msgs: [dynamic]Message
	senders := []string{
		"Ada Lovelace", "Grace Hopper", "Alan Turing", "Donald Knuth",
		"Edsger Dijkstra", "Barbara Liskov", "Linus Torvalds",
		"Margaret Hamilton", "Ken Thompson", "Dennis Ritchie",
	}
	subjects := []string{
		"Re: pipeline layout",
		"Design review notes",
		"Deploy pinned for Friday",
		"Budget request",
		"Question about the docs",
		"Welcome aboard",
		"Meeting moved to Thursday",
		"Can you review this patch?",
	}
	bodies := []string{
		"Thanks for the write-up. The constraint solver bit is the part I wanted to dig into — can we find 20 minutes tomorrow?",
		"Left inline notes. Most are cosmetic, but the two on the error path are worth a look before this goes out.",
		"Holding the deploy until Friday morning so the mobile team finishes their release branch. No action needed on your end.",
		"Attached the revised numbers. Ops flagged the Q3 projection; I've footnoted the adjustment.",
		"Quick one — where do the widget IDs get reset? I'm seeing them stick across frames when a row is removed.",
		"Welcome aboard! I've set up your access to the wiki and added you to the #eng channel. Holler with any questions.",
		"Pushed Thursday 2pm so the design review can finish on Wednesday. Calendar invite incoming.",
		"If you get a spare hour, could you cast an eye over the flex distribution in stack_render? I'm not sure I've handled the Stretch case right when there's a single flex sibling.",
	}
	for i in 0..<80 {
		append(&msgs, Message{
			from    = senders[i % len(senders)],
			subject = fmt.aprintf("%s (#%d)", subjects[i % len(subjects)], i + 1),
			body    = bodies[i % len(bodies)],
		})
	}
	return {messages = msgs, selected = 0}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Select_Message:
		out.selected = int(v)
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	items := make([dynamic]skald.View, 0, len(s.messages) + 2, context.temp_allocator)
	append(&items, skald.text("Inbox", th.color.fg, th.font.size_lg))
	append(&items, skald.spacer(th.spacing.sm))
	for msg, i in s.messages {
		selected := i == s.selected
		row_bg := th.color.bg
		if selected { row_bg = th.color.surface }

		label := fmt.tprintf("%s  ·  %s", msg.from, msg.subject)
		append(&items, skald.button(ctx, label, Select_Message(i),
			color     = row_bg,
			fg        = th.color.fg,
			radius    = th.radius.sm,
			padding   = {th.spacing.md, th.spacing.sm},
			font_size = th.font.size_sm,
			width     = 280,
		))
	}

	list := skald.col(..items[:], spacing = 2, padding = th.spacing.md)
	left := skald.scroll(ctx, {300, 560}, list)

	selected_msg := Message{from = "—", subject = "(no message selected)", body = ""}
	if s.selected >= 0 && s.selected < len(s.messages) {
		selected_msg = s.messages[s.selected]
	}

	// Window is 900 wide; left pane takes 300 and the details pane gets
	// the rest. Subtract the column's own padding on both sides so the
	// wrapped body doesn't visually bump the right edge.
	body_wrap := f32(900 - 300) - 2 * th.spacing.xl
	details := skald.col(
		skald.text(selected_msg.subject, th.color.fg, th.font.size_xl,
			max_width = body_wrap),
		skald.spacer(th.spacing.sm),
		skald.text(fmt.tprintf("From: %s", selected_msg.from),
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.lg),
		skald.text(selected_msg.body, th.color.fg, th.font.size_md,
			max_width = body_wrap),
		padding = th.spacing.xl,
	)

	return skald.row(
		left,
		skald.flex(1, details),
		spacing     = 0,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Scroll",
		size   = {900, 580},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
