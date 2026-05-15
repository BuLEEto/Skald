package example_emoji_picker

import "core:fmt"
import "core:strings"
import "gui:skald"

MAX_RECENTS :: 8

State :: struct {
	draft:       string,         // chat-style message draft
	recents:     [dynamic]string,
	last_copied: string,         // most recently picked emoji
}

Msg :: union {
	Pick_Emoji,
	Draft_Changed,
}

Pick_Emoji    :: struct { emoji: string }
Draft_Changed :: struct { value: string }

@(private) fonts_ready: bool

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	s := s
	switch v in m {
	case Pick_Emoji:
		emoji := strings.clone(v.emoji)
		// Append the picked emoji to the message draft. The text_input
		// widget reads `s.draft` each frame, so the inserted character
		// shows up immediately.
		new_draft := strings.concatenate({s.draft, emoji})
		if len(s.draft) > 0 { delete(s.draft) }
		s.draft = new_draft
		// Drop the emoji on the system clipboard so the user can paste
		// it into any other app.
		skald.clipboard_set(emoji)
		if len(s.last_copied) > 0 { delete(s.last_copied) }
		s.last_copied = strings.clone(emoji)
		// De-duplicate then push to the front. Cap to MAX_RECENTS so the
		// slice doesn't grow without bound.
		for r, i in s.recents {
			if r == emoji { delete(s.recents[i]); ordered_remove(&s.recents, i); break }
		}
		inject_at(&s.recents, 0, emoji)
		for len(s.recents) > MAX_RECENTS {
			delete(s.recents[len(s.recents)-1])
			pop(&s.recents)
		}
	case Draft_Changed:
		if len(s.draft) > 0 { delete(s.draft) }
		s.draft = strings.clone(v.value)
	}
	return s, {}
}

on_pick   :: proc(e: string) -> Msg { return Pick_Emoji{emoji = e} }
on_change :: proc(v: string) -> Msg { return Draft_Changed{value = v} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	if !fonts_ready && ctx.renderer != nil {
		skald.font_use_default_emoji(ctx.renderer)
		fonts_ready = true
	}

	hint: string
	if len(s.last_copied) > 0 {
		hint = fmt.tprintf("%s copied to the clipboard — paste with Ctrl+V.", s.last_copied)
	} else {
		hint = "Pick an emoji: it's inserted into the draft and copied to the system clipboard."
	}

	composer := skald.row(
		skald.emoji_picker(ctx, on_pick, recents = s.recents[:]),
		skald.spacer(th.spacing.sm),
		skald.text_input(
			ctx, s.draft, on_change,
			placeholder  = "Write a message…",
			width        = 560,
			clear_button = true,
		),
		cross_align = .Center,
	)

	return skald.col(
		skald.text("Emoji picker", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.md),
		skald.text(
			"Compose a chat message. The picker appends emojis to the draft and copies each one to the system clipboard.",
			th.color.fg_muted, th.font.size_sm, max_width = 620),
		skald.spacer(th.spacing.lg),
		composer,
		skald.spacer(th.spacing.sm),
		skald.text(hint, th.color.fg_muted, th.font.size_sm),
		padding = th.spacing.xl,
		spacing = th.spacing.sm,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Emoji Picker",
		size   = {720, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
