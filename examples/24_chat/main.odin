package example_chat

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "gui:skald"

// Phase 17 showcase: `virtual_list` in variable-height mode. 10 000
// chat-style messages with wrapped bodies of wildly varying length —
// one-liners, short replies, several-paragraph rants. Every row
// measures to its own intrinsic height; only the visible window is
// built and measured each frame.
//
// What to notice:
//   * Row heights differ — the scrollbar thumb is proportional to
//     measured content, not an artificial fixed-height approximation.
//   * "rows built this frame" stays small regardless of total row
//     count. Dragging the scrollbar jumps to the target area without
//     materializing the skipped rows.
//   * Starring a message keys off its stable id, so the marker
//     follows the *message* across scrolls — not the tree position.

ROW_COUNT :: 10_000
ROW_WIDTH :: 540.0
EST_ROW_H :: 72.0

State :: struct {
	msgs:       []Message,
	liked:      map[int]bool,
	last_built: int,
}

Message :: struct {
	author: string,
	body:   string,
}

Msg :: union {
	Fav_Toggled,
}

Fav_Toggled :: distinct int

init :: proc() -> State {
	return State{
		msgs  = generate_messages(ROW_COUNT),
		liked = make(map[int]bool),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Fav_Toggled:
		idx := int(v)
		if out.liked[idx] { delete_key(&out.liked, idx) }
		else              { out.liked[idx] = true       }
	}
	return out, {}
}

// Messages never reorder in this demo — index is the stable key.
row_key :: proc(s: ^State, i: int) -> u64 { return u64(i) }

row :: proc(ctx: ^skald.Ctx(Msg), s: ^State, i: int) -> skald.View {
	th := ctx.theme
	s.last_built += 1

	msg := s.msgs[i]

	star := "☆"
	star_bg := th.color.surface
	if s.liked[i] {
		star = "★"
		star_bg = th.color.primary
	}

	// Stable id: hash per message index so starred state sticks
	// with the message even after scrolling reshuffles the tree.
	fav_key := fmt.tprintf("msg-%d-fav", i)
	fav_id  := skald.hash_id(strings.clone(fav_key, context.temp_allocator))

	// Wrap at ROW_WIDTH minus padding + avatar + star button + gaps.
	// The text node's measured height is what virtual_list will cache.
	AVATAR_SIZE :: f32(32)
	text_w := ROW_WIDTH - 2 * th.spacing.md - AVATAR_SIZE - th.spacing.md - 48 - th.spacing.md

	initials := ""
	if len(msg.author) > 0 {
		first := msg.author[0]
		if first >= 'a' && first <= 'z' { first -= 32 }
		initials = fmt.tprintf("%c", first)
	}

	header := skald.row(
		skald.text(msg.author, th.color.fg, th.font.size_md),
		skald.spacer(0),
		skald.text(fmt.tprintf("#%d", i), th.color.fg_muted, th.font.size_sm),
		width       = text_w,
		spacing     = th.spacing.sm,
		cross_align = .Center,
	)

	body := skald.text(msg.body, th.color.fg_muted, th.font.size_md, 0, text_w)

	middle := skald.col(
		header,
		skald.spacer(th.spacing.xs),
		body,
		spacing     = 0,
		cross_align = .Start,
	)

	return skald.row(
		skald.avatar(ctx, initials, size = AVATAR_SIZE),
		skald.spacer(th.spacing.md),
		middle,
		skald.spacer(th.spacing.md),
		skald.button(ctx, star, Fav_Toggled(i),
			id    = fav_id,
			color = star_bg,
			fg    = th.color.fg,
			width = 48),
		width       = ROW_WIDTH,
		padding     = th.spacing.md,
		spacing     = 0,
		bg          = th.color.surface,
		radius      = th.radius.sm,
		cross_align = .Start,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	s_mut := s
	s_mut.last_built = 0

	list := skald.virtual_list(ctx,
		&s_mut,
		ROW_COUNT,
		0,                     // item_height unused in variable mode
		{ROW_WIDTH + 20, 460}, // viewport — extra width for the scrollbar
		row,
		row_key,
		variable_height  = true,
		estimated_height = EST_ROW_H,
		focusable        = true,
	)

	info := fmt.tprintf("%d messages • %d built this frame • %d liked",
		ROW_COUNT, s_mut.last_built, len(s_mut.liked))

	return skald.col(
		skald.text("Skald — Variable-height Virtualization",
			th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("10 000 chat-style messages, each wrapping to its own height.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.md),
		skald.text(info, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.sm),
		list,
		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Start,
	)
}

// generate_messages builds a deterministic corpus keyed off a fixed
// seed so repeat runs look identical — picks an author from a small
// pool and concatenates 1-6 sentence fragments for the body. The
// fragment pool is intentionally varied in length so wrapped heights
// span a meaningful range.
generate_messages :: proc(n: int) -> []Message {
	authors := []string{
		"ada", "lovelace", "grace", "hopper", "margaret",
		"hamilton", "katherine", "johnson", "annie", "easley",
	}
	fragments := []string{
		"Just pushed the fix.",
		"Can we sync after lunch?",
		"LGTM — merging now.",
		"I spent most of the morning chasing a heisenbug in the scheduler; turns out the instrumentation was introducing the race we were trying to measure. Classic.",
		"👀",
		"Updating the doc.",
		"The new renderer is noticeably smoother on HiDPI — font atlases look crisp all the way up to 200%. Very happy with where this landed.",
		"Moving this to next sprint.",
		"Let's pair on it tomorrow morning, I've got a block from 9:30 to 11.",
		"Done.",
		"I think we should reconsider the API here. The current shape encodes three different lifetimes, and the callers that use it wrong tend to fail silently instead of loudly. A smaller surface with a bit more boilerplate would be a net win for maintenance.",
		"Fixed in main.",
		"Had a look at the flame graph — 60% of the frame is stuck in the layout pass. Most of that is re-measuring text that didn't change. We should cache measurements keyed on (string, size, max_width).",
		"Deploying to staging.",
		"Scrollbar highlight on hover now matches the rest of the palette, nice catch.",
		"Why is the CI matrix running each job twice?",
		"Shipping the v1 today, follow-up polish next week.",
	}

	rand.reset(0x5EED_1_1_5)

	out := make([]Message, n)
	for i in 0..<n {
		a := authors[rand.int_max(len(authors))]

		sentences := 1 + rand.int_max(5)
		sb := strings.builder_make()
		for j in 0..<sentences {
			if j > 0 { strings.write_string(&sb, " ") }
			strings.write_string(&sb, fragments[rand.int_max(len(fragments))])
		}

		out[i] = Message{
			author = strings.clone(a),
			body   = strings.to_string(sb),
		}
	}
	return out
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Variable-height Virtual List",
		size   = {680, 700},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
