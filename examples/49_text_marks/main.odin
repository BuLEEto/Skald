package example_text_marks

// Spell-check squiggles + a fix menu, built on `text_input`'s `marks`
// parameter and the `text_input_offset_at` / `text_input_offset_rect`
// accessors.
//
// IMPORTANT — where the accessors run: they take `ctx`, and only `view`
// has `ctx` (update does not). So resolve a click in `view` (read the
// right-click off `ctx.input`, call the accessors against last frame's
// rendered geometry — a click lands on what's already on screen) and
// `send` the result as a Msg. `update` just stores popover state.
//
//   right-click a squiggled word
//     -> offset_at(mouse)  : which byte was hit
//     -> find the misspelling under it
//     -> offset_rect(start) : screen rect to anchor the menu under the word
//     -> overlay(anchor, menu)
//     -> pick a suggestion  : replace the range in the buffer

import "core:strings"
import "gui:skald"

// Toy checker: a fixed bad -> good table. A real app swaps this for its
// own scanner (a real editor runs a pure-Odin one, debounced like autosave).
DICT := [][2]string{
	{"teh", "the"},
	{"recieve", "receive"},
	{"seperate", "separate"},
	{"definately", "definitely"},
}

Misspelling :: struct { start, end: int, fix: string }

scan :: proc(text: string) -> []Misspelling {
	out := make([dynamic]Misspelling, context.temp_allocator)
	for pair in DICT {
		bad, good := pair[0], pair[1]
		from := 0
		for {
			i := strings.index(text[from:], bad)
			if i < 0 { break }
			s := from + i
			append(&out, Misspelling{start = s, end = s + len(bad), fix = good})
			from = s + len(bad)
		}
	}
	return out[:]
}

State :: struct {
	text:    string,
	// Fix popover (anchored at the word's offset_rect).
	open:    bool,
	anchor:  skald.Rect,
	lo, hi:  int,
	fix:     string,
}

Msg :: union { Edited, Open_Fix, Apply, Dismiss }
Edited   :: distinct string
Open_Fix :: struct { anchor: skald.Rect, lo, hi: int, fix: string }
Apply    :: struct{}
Dismiss  :: struct{}

on_text    :: proc(v: string) -> Msg { return Edited(v) }
on_pick    :: proc(i: int) -> Msg { return i == 0 ? Msg(Apply{}) : Msg(Dismiss{}) }
on_dismiss :: proc() -> Msg { return Dismiss{} }

init :: proc() -> State {
	return State{
		text = strings.clone("I will recieve teh files and seperate them. Definately re-check teh spelling before we send it, so the whole thing reads clean."),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Edited:
		delete(out.text); out.text = strings.clone(string(v))
		out.open = false
	case Open_Fix:
		out.open = true
		out.anchor, out.lo, out.hi, out.fix = v.anchor, v.lo, v.hi, v.fix
	case Apply:
		if out.lo < out.hi && out.hi <= len(out.text) {
			fixed := strings.concatenate({out.text[:out.lo], out.fix, out.text[out.hi:]})
			delete(out.text); out.text = fixed
		}
		out.open = false
	case Dismiss:
		out.open = false
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	misspellings := scan(s.text)

	// A stable id for the editor. Use hash_id (not a raw int like
	// Widget_ID(1)) — unscoped auto-ids are small sequential ints, so a raw
	// explicit id can collide with one; hash_id sets a high bit that can't.
	editor_id := skald.hash_id("text-marks-editor")

	// One squiggle per misspelling. {} colour = theme default (red).
	marks := make([dynamic]skald.Text_Mark, context.temp_allocator)
	for ms in misspellings {
		append(&marks, skald.Text_Mark{start = ms.start, end = ms.end}) // .Squiggle default
	}

	// Resolve a right-click HERE (view has ctx); bake the hit into a Msg.
	if ctx.input.mouse_pressed[.Right] {
		if off, ok := skald.text_input_offset_at(ctx, editor_id, ctx.input.mouse_pos); ok {
			for ms in misspellings {
				if off >= ms.start && off < ms.end {
					rect, _ := skald.text_input_offset_rect(ctx, editor_id, ms.start)
					skald.send(ctx, Open_Fix{anchor = rect, lo = ms.start, hi = ms.end, fix = ms.fix})
					break
				}
			}
		}
	}

	editor := skald.text_input(ctx, s.text, on_text,
		id        = editor_id,
		width     = 540,
		height    = 220,
		multiline = true,
		wrap      = true,
		marks     = marks[:],
	)

	root := skald.col(
		skald.text("Right-click a red-squiggled word to fix it.",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.sm),
		editor,
		padding     = th.spacing.lg,
		spacing     = 0,
		cross_align = .Start,
	)

	if !s.open { return root }

	// Fix menu, anchored just under the word via its offset_rect. `menu`
	// dismisses itself on click-away; overlays render in a top z-pass, so
	// it sits over the editor regardless of tree position.
	items := []string{
		strings.concatenate({"Replace with \"", s.fix, "\""}, context.temp_allocator),
		"Ignore",
	}
	menu := skald.menu(ctx, items, on_pick, on_dismiss = on_dismiss)
	return skald.col(root, skald.overlay(s.anchor, menu, .Below, {0, 2}))
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Text marks (spell-check)",
		size   = {620, 360},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
