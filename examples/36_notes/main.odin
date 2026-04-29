package example_notes

import "core:fmt"
import "core:strings"
import "gui:skald"

// A small notes app exercised end-to-end on the 1.0 API: menu bar with
// keyboard shortcuts, split pane for sidebar + editor, search-filtered
// list, single-line title, wrapping multi-line body. In-memory only —
// the persistence round-trip is already covered by `23_editor`, so
// skipping it here keeps the showcase focused on the widget surface.
//
// All string payloads on the Msg union are frame-arena strings; we
// clone them into persistent storage in update before stashing on
// State. Same rule as every other widget example.

Note :: struct {
	title: string, // owned
	body:  string, // owned
}

State :: struct {
	notes:     [dynamic]Note,
	selected:  int, // -1 when nothing selected
	search:    string, // owned
	sidebar_w: f32,
}

Msg :: union {
	New_Note_Clicked,
	Delete_Note_Clicked,
	Clear_All_Clicked,

	Note_Selected,
	Title_Changed,
	Body_Changed,
	Search_Changed,
	Search_Submitted,
	Sidebar_Resized,
}

New_Note_Clicked    :: struct{}
Delete_Note_Clicked :: struct{}
Clear_All_Clicked   :: struct{}

Note_Selected   :: distinct int
Title_Changed   :: distinct string
Body_Changed    :: distinct string
Search_Changed  :: distinct string
Search_Submitted :: struct {}
Sidebar_Resized :: distinct f32

init :: proc() -> State {
	s := State{
		selected  = 0,
		search    = strings.clone(""),
		sidebar_w = 240,
	}
	seed :: proc(title, body: string) -> Note {
		return Note{title = strings.clone(title), body = strings.clone(body)}
	}
	append(&s.notes, seed("Shopping list",
		"- bread\n- olives\n- black pepper\n- tomatoes\n"))
	append(&s.notes, seed("Release checklist",
		"1. Tag 1.0 on the main branch.\n2. Build examples on Linux + macOS + Windows.\n3. Smoke-run the widget gallery.\n4. Post the announcement.\n"))
	append(&s.notes, seed("Ideas",
		"Syntax-highlighted editor widget. Inline markdown renderer. Chart primitives.\n"))
	return s
}

// Frame-arena list of indices into state.notes that match the current
// search. Returned order preserves the underlying array so row clicks
// translate back to real indices.
filtered_indices :: proc(s: State) -> []int {
	out := make([dynamic]int, 0, len(s.notes), context.temp_allocator)
	q := strings.to_lower(s.search, context.temp_allocator)
	for n, i in s.notes {
		if len(q) == 0 {
			append(&out, i)
			continue
		}
		tl := strings.to_lower(n.title, context.temp_allocator)
		bl := strings.to_lower(n.body,  context.temp_allocator)
		if strings.contains(tl, q) || strings.contains(bl, q) {
			append(&out, i)
		}
	}
	return out[:]
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {

	case New_Note_Clicked:
		n := Note{
			title = strings.clone("Untitled"),
			body  = strings.clone(""),
		}
		append(&out.notes, n)
		out.selected = len(out.notes) - 1

	case Delete_Note_Clicked:
		if out.selected < 0 || out.selected >= len(out.notes) { return out, {} }
		old := out.notes[out.selected]
		delete(old.title)
		delete(old.body)
		ordered_remove(&out.notes, out.selected)
		if out.selected >= len(out.notes) { out.selected = len(out.notes) - 1 }

	case Clear_All_Clicked:
		for n in out.notes {
			delete(n.title)
			delete(n.body)
		}
		clear(&out.notes)
		out.selected = -1

	case Note_Selected:
		i := int(v)
		if i >= 0 && i < len(out.notes) { out.selected = i }

	case Title_Changed:
		if out.selected < 0 || out.selected >= len(out.notes) { return out, {} }
		delete(out.notes[out.selected].title)
		out.notes[out.selected].title = strings.clone(string(v))

	case Body_Changed:
		if out.selected < 0 || out.selected >= len(out.notes) { return out, {} }
		delete(out.notes[out.selected].body)
		out.notes[out.selected].body = strings.clone(string(v))

	case Search_Changed:
		delete(out.search)
		out.search = strings.clone(string(v))

	case Search_Submitted:
		// Filtering already happens on every keystroke; Enter is a
		// no-op here. A real app might focus the first match.

	case Sidebar_Resized:
		out.sidebar_w = f32(v)
	}
	return out, {}
}

on_title    :: proc(v: string) -> Msg { return Title_Changed(v)   }
on_body     :: proc(v: string) -> Msg { return Body_Changed(v)    }
on_search   :: proc(v: string) -> Msg { return Search_Changed(v)  }
on_sidebar  :: proc(v: f32)    -> Msg { return Sidebar_Resized(v) }

note_row :: proc(
	ctx:      ^skald.Ctx(Msg),
	note:     Note,
	index:    int,
	selected: bool,
) -> skald.View {
	th := ctx.theme

	title := note.title
	if len(title) == 0 { title = "Untitled" }

	bg_color    := th.color.surface
	title_color := th.color.fg
	if selected {
		bg_color    = th.color.primary
		title_color = th.color.on_primary
	}

	return skald.button(ctx, title, Note_Selected(index),
		color      = bg_color,
		fg         = title_color,
		text_align = .Start,
		width      = 0,
		id         = skald.hash_id(fmt.tprintf("note-row-{}", index)),
	)
}

note_list :: proc(ctx: ^skald.Ctx(Msg), s: State, width: f32) -> skald.View {
	th := ctx.theme

	indices := filtered_indices(s)

	if len(indices) == 0 {
		msg := "No notes yet — press Ctrl+N to add one."
		if len(s.search) > 0 { msg = fmt.tprintf("No matches for \"%s\".", s.search) }
		return skald.col(
			skald.spacer(th.spacing.md),
			skald.text(msg, th.color.fg_muted, th.font.size_sm, max_width = width - 2 * th.spacing.md),
			padding     = th.spacing.md,
			cross_align = .Start,
		)
	}

	rows := make([dynamic]skald.View, 0, len(indices), context.temp_allocator)
	for i in indices {
		append(&rows, note_row(ctx, s.notes[i], i, i == s.selected))
		append(&rows, skald.spacer(th.spacing.xs))
	}

	return skald.col(..rows[:], cross_align = .Stretch, width = width)
}

sidebar_view :: proc(ctx: ^skald.Ctx(Msg), s: State, width: f32) -> skald.View {
	th := ctx.theme

	search := skald.search_field(ctx, s.search, on_search,
		on_submit   = proc() -> Msg { return Search_Submitted{} },
		placeholder = "Search notes",
		width       = width - 2 * th.spacing.md,
	)

	new_btn := skald.button(ctx, "+ New note", New_Note_Clicked{},
		width = width - 2 * th.spacing.md)

	list := note_list(ctx, s, width - 2 * th.spacing.md)

	// Scroll the list area only — the search box and "new" button stay
	// pinned top/bottom. Fill the remaining vertical room with flex.
	scroll_h: f32 = 0 // zero = take what flex gives us (fill mode)

	return skald.col(
		search,
		skald.spacer(th.spacing.md),
		skald.flex(1, skald.scroll(ctx,
			{width - 2 * th.spacing.md, scroll_h},
			list)),
		skald.spacer(th.spacing.md),
		new_btn,
		padding     = th.spacing.md,
		cross_align = .Start,
		bg          = th.color.bg,
	)
}

editor_view :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	if s.selected < 0 || s.selected >= len(s.notes) {
		return skald.col(
			skald.text("No note selected",
				th.color.fg_muted, th.font.size_lg),
			skald.spacer(th.spacing.sm),
			skald.text("Press Ctrl+N or click \"+ New note\" in the sidebar.",
				th.color.fg_muted, th.font.size_sm),
			padding     = th.spacing.xl,
			main_align  = .Center,
			cross_align = .Center,
		)
	}

	n := s.notes[s.selected]

	title := skald.text_input(ctx, n.title, on_title,
		width     = 0,
		font_size = th.font.size_xl,
		id        = skald.hash_id("note-title"),
	)

	body := skald.text_input(ctx, n.body, on_body,
		multiline = true,
		wrap      = true,
		width     = 0,
		height    = 0, // fill
		id        = skald.hash_id("note-body"),
	)

	return skald.col(
		title,
		skald.spacer(th.spacing.md),
		skald.flex(1, body),
		padding     = th.spacing.lg,
		cross_align = .Stretch,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	menu := skald.menu_bar(ctx, []skald.Menu_Entry(Msg){
		{
			label = "File",
			items = []skald.Menu_Item(Msg){
				{label = "New note",     shortcut = {.N, {.Ctrl}}, msg = New_Note_Clicked{}},
				{label = "Delete note",  shortcut = {.D, {.Ctrl}}, msg = Delete_Note_Clicked{},
				 disabled = s.selected < 0},
				{separator = true},
				{label = "Clear all",    msg = Clear_All_Clicked{},
				 disabled = len(s.notes) == 0},
			},
		},
	})

	split := skald.split(ctx,
		first      = sidebar_view(ctx, s, s.sidebar_w),
		second     = editor_view(ctx, s),
		first_size = s.sidebar_w,
		on_resize  = on_sidebar,
		min_first  = 180,
		min_second = 360,
	)

	return skald.col(
		menu,
		skald.flex(1, split),
		spacing     = 0,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Notes",
		size   = {960, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
