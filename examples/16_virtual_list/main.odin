package example_virtual_list

import "core:fmt"
import "core:strings"
import "gui:skald"

// Phase 12 showcase: `virtual_list` rendering 10_000 rows without
// building a view tree for all of them. The trick is that every
// frame only builds the visible window + a small overscan —
// scrolling down doesn't increase the work per frame, it just
// shifts which row indices the builder is asked for.
//
// What to notice:
//   * The row counter (`rows built`) stays small and bounded even
//     with a million rows, because virtual_list only calls the
//     builder for the visible range.
//   * Starring a row updates state keyed by index. The ★ button
//     uses `hash_id` so its press/focus state belongs to the row
//     identity, not to the position in the view tree — critical
//     because scrolling changes which index is at tree-position N.

ROW_COUNT   :: 10_000
ITEM_HEIGHT :: 44.0

State :: struct {
	liked:       map[int]bool,
	last_built:  int, // diagnostic: how many rows we built last frame
}

Msg :: union {
	Fav_Toggled,
}

Fav_Toggled :: distinct int

init :: proc() -> State {
	return State{liked = make(map[int]bool)}
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

// row_key returns the stable id for the row at index `i`. Here the
// list is synthetic (no reorder or filter) so index *is* the stable
// id — returning `u64(i)` is the honest answer.
row_key :: proc(s: ^State, i: int) -> u64 { return u64(i) }

row :: proc(ctx: ^skald.Ctx(Msg), s: ^State, i: int) -> skald.View {
	th := ctx.theme
	s.last_built += 1

	label := fmt.tprintf("Row %d — %s", i, sample_label(i))

	star := "☆"
	color := th.color.surface
	if s.liked[i] {
		star = "★"
		color = th.color.primary
	}

	// Per-row stable id: hash of the index so star state sticks to
	// the row even as scrolling changes the tree position.
	key := fmt.tprintf("row-%d-fav", i)
	fav_id := skald.hash_id(strings.clone(key, context.temp_allocator))

	return skald.row(
		skald.text(label, th.color.fg, th.font.size_md),
		skald.spacer(0),
		skald.button(ctx, star, Fav_Toggled(i),
			id    = fav_id,
			color = color,
			fg    = th.color.fg,
			width = 40),
		width       = 560,
		padding     = th.spacing.sm,
		spacing     = th.spacing.md,
		bg          = th.color.surface,
		radius      = th.radius.sm,
		cross_align = .Center,
	)
}

sample_label :: proc(i: int) -> string {
	// Synthesize a varied-looking label per index so the list
	// doesn't just read as "Row N Row N Row N".
	words := []string{
		"notes", "ideas", "recipe", "inbox", "draft",
		"todo", "meeting", "spec", "bug", "feature",
		"readme", "journal", "migration", "rfc", "sketch",
	}
	w := words[i %% len(words)]
	return fmt.tprintf("%s-%d.md", w, i / len(words))
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Reset the per-frame diagnostic counter before the list
	// builder fires. The row builder bumps it on each call; after
	// virtual_list returns, `last_built` holds the count for this
	// frame and we display it in the header.
	s_mut := s
	s_mut.last_built = 0

	// NOTE: virtual_list calls `row` once per visible index,
	// mutating s_mut.last_built. The closure would be nicer here,
	// but Odin procs don't capture — so row_builder takes the
	// state pointer explicitly.
	list := skald.virtual_list(ctx,
		&s_mut,
		ROW_COUNT,
		ITEM_HEIGHT,
		{600, 440},
		row,
		row_key,
	)

	info := fmt.tprintf("%d rows total • %d built this frame • %d liked",
		ROW_COUNT, s_mut.last_built, len(s_mut.liked))

	return skald.col(
		skald.text("Skald — Virtualized List", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Scroll through 10 000 rows; only the visible window is built.",
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

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Virtual List",
		size   = {700, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
