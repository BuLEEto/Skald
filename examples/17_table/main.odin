package example_table

import "core:fmt"
import "core:slice"
import "core:strings"
import "gui:skald"

// Phase 13 showcase: `skald.table` with multi-select, sortable
// columns, resizable columns, and keyboard navigation. 5 000
// synthetic file rows.
//
// Column interactions (all opt-in per column via Table_Column
// flags, and the table only delivers events — the app owns the
// storage for sort direction, widths, and selection):
//   * Click a sortable column header to sort; click again to
//     flip direction. Sorted column shows ▲ or ▼.
//   * Drag the thin divider at a resizable column's right edge
//     to resize. Columns can't shrink below 40 px.
//
// Mouse selection:
//   * Plain click       — select only this row, set anchor.
//   * Ctrl-click        — toggle this row, anchor moves to it.
//   * Shift-click       — select the inclusive visible range
//                         from anchor to this row.
//
// Keyboard (after Tabbing into the table or clicking any row):
//   * Up / Down         — move focus and select.
//   * Shift + Up/Down   — extend selection.
//   * PageUp / PageDown — move by a viewport's worth of rows.
//   * Home / End        — jump to first / last.
//   * Enter / Space     — "open" the focused row; status line
//                         at the bottom shows the last file
//                         that was opened.
//
// The anchor is a *visible* row position, so Shift-range follows
// the current sort order. Re-sorting clears the anchor (the anchor
// row's visible position has likely moved). Selection itself is
// keyed by source row, so it survives re-sorting.

ROW_COUNT  :: 5000
ROW_HEIGHT :: 30.0

DEFAULT_WIDTHS :: [4]f32{0, 90, 140, 120} // 0 = flex

State :: struct {
	widths:         [4]f32,
	sorted:         [dynamic]int, // sorted[visible_row] = source_row
	sort_col:       int,          // -1 = unsorted
	sort_asc:       bool,
	selected:       map[int]bool, // keyed by source row
	anchor_visible: int,
	focus_visible:  int, // cursor row for keyboard nav; -1 = no focus
	opened:         string, // last row opened via Enter/Space, for the status line
	last_built:     int,
}

Msg :: union {
	Row_Clicked,
	Sort_Changed,
	Col_Resized,
	Row_Activated,
}

Row_Clicked   :: struct { row: int, mods: skald.Modifiers }
Sort_Changed  :: struct { col: int, asc: bool }
Col_Resized   :: struct { col: int, width: f32 }
Row_Activated :: distinct int

init :: proc() -> State {
	s: State
	s.widths         = DEFAULT_WIDTHS
	s.sort_col       = -1
	s.sort_asc       = true
	s.selected       = make(map[int]bool)
	s.anchor_visible = -1
	s.focus_visible  = -1
	s.sorted         = make([dynamic]int, ROW_COUNT)
	for i in 0..<ROW_COUNT { s.sorted[i] = i }
	return s
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Row_Clicked:   apply_click(&out, v.row, v.mods)
	case Sort_Changed:  apply_sort(&out, v.col, v.asc)
	case Col_Resized:   out.widths[v.col] = v.width
	case Row_Activated:
		// The table fires activate with a *visible* row index, same
		// convention as clicks. file_name returns a temp-arena string;
		// clone into the heap and free the previous value because
		// `opened` persists across frames.
		src := out.sorted[int(v)]
		if len(out.opened) > 0 { delete(out.opened) }
		out.opened = strings.clone(file_name(src))
	}
	return out, {}
}

apply_click :: proc(s: ^State, visible_row: int, mods: skald.Modifiers) {
	src := s.sorted[visible_row]

	// Focus follows the latest interacted row in every case, so
	// keyboard arrows and the focus-ring visual stay in sync with
	// what the user just touched.
	s.focus_visible = visible_row

	// Shift without an anchor falls back to single-select.
	if .Shift in mods && s.anchor_visible >= 0 {
		lo, hi := s.anchor_visible, visible_row
		if lo > hi { lo, hi = hi, lo }
		clear(&s.selected)
		for v in lo..=hi { s.selected[s.sorted[v]] = true }
		return
	}

	if .Ctrl in mods {
		if s.selected[src] { delete_key(&s.selected, src) }
		else               { s.selected[src] = true       }
		s.anchor_visible = visible_row
		return
	}

	clear(&s.selected)
	s.selected[src] = true
	s.anchor_visible = visible_row
}

apply_sort :: proc(s: ^State, col: int, asc: bool) {
	s.sort_col       = col
	s.sort_asc       = asc
	// Visible positions change on re-sort, so both anchor and
	// keyboard focus are invalidated — neither refers to the same
	// row it did a frame ago.
	s.anchor_visible = -1
	s.focus_visible  = -1

	for i in 0..<ROW_COUNT { s.sorted[i] = i }

	// Per-column less-predicates. `slice.sort_by` can't close over
	// `col`, so we switch once up front and pick the dedicated proc.
	less: proc(a, b: int) -> bool
	switch col {
	case 0: less = less_name
	case 1: less = less_size
	case 2: less = less_mtime
	case 3: less = less_kind
	case:   return
	}
	if asc { slice.sort_by(s.sorted[:], less)         }
	else   { slice.reverse_sort_by(s.sorted[:], less) }
}

// Sort keys — derived directly from the row index so we don't need
// to materialize a full dataset just to sort 5 000 rows. The key
// procs mirror the display procs (file_name etc.) below.
size_kb    :: proc(i: int) -> int { return (i * 2777) %% 9973 }
mtime_key  :: proc(i: int) -> int { return (i %% 12) * 32 + (i %% 28) }

less_name  :: proc(a, b: int) -> bool { return file_name(a) < file_name(b) }
less_size  :: proc(a, b: int) -> bool { return size_kb(a)   < size_kb(b)   }
less_mtime :: proc(a, b: int) -> bool { return mtime_key(a) < mtime_key(b) }
less_kind  :: proc(a, b: int) -> bool { return file_kind(a) < file_kind(b) }

// Synthetic file data keyed by row index.
file_name :: proc(i: int) -> string {
	kinds := []string{"note", "draft", "spec", "todo", "readme", "sketch"}
	return fmt.tprintf("%s-%04d.md", kinds[i %% len(kinds)], i)
}
file_size :: proc(i: int) -> string {
	return fmt.tprintf("%d KB", size_kb(i))
}
file_mtime :: proc(i: int) -> string {
	months := []string{"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.tprintf("%s %02d 2026", months[i %% 12], (i %% 28) + 1)
}
file_kind :: proc(i: int) -> string {
	kinds := []string{"markdown", "text", "config", "odin", "image"}
	return kinds[i %% len(kinds)]
}

build_row :: proc(ctx: ^skald.Ctx(Msg), s: ^State, visible: int) -> []skald.View {
	th := ctx.theme
	s.last_built += 1

	src := s.sorted[visible]

	cells := make([]skald.View, 4, context.temp_allocator)
	cells[0] = skald.text(file_name(src),  th.color.fg,       th.font.size_sm)
	cells[1] = skald.text(file_size(src),  th.color.fg_muted, th.font.size_sm)
	cells[2] = skald.text(file_mtime(src), th.color.fg_muted, th.font.size_sm)
	cells[3] = skald.text(file_kind(src),  th.color.fg_muted, th.font.size_sm)
	return cells
}

// row_key maps the currently-visible row to the stable source row,
// so widget state inside cells (hover, focus, expanded flags) sticks
// to the *file* across re-sorts rather than to the visible position.
// This is the reason the column is called "Name" in one order and
// then "Name" again after re-sorting yet the focus ring didn't jump
// to a different row — the scope salt followed the source row.
row_key :: proc(s: ^State, visible: int) -> u64 { return u64(s.sorted[visible]) }

on_row      :: proc(row: int, mods: skald.Modifiers) -> Msg { return Row_Clicked{row, mods}   }
on_sort     :: proc(col: int, asc: bool)             -> Msg { return Sort_Changed{col, asc}   }
on_resize   :: proc(col: int, width: f32)            -> Msg { return Col_Resized{col, width}  }
on_activate :: proc(row: int)                        -> Msg { return Row_Activated(row)       }

row_is_selected :: proc(s: ^State, visible: int) -> bool {
	return s.selected[s.sorted[visible]]
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	s_mut := s
	s_mut.last_built = 0

	cols := []skald.Table_Column{
		{label = "Name",     width = s.widths[0], flex = 3, align = .Start,
			sortable = true, resizable = false},
		{label = "Size",     width = s.widths[1],           align = .End,
			sortable = true, resizable = true},
		{label = "Modified", width = s.widths[2],           align = .Start,
			sortable = true, resizable = true},
		{label = "Kind",     width = s.widths[3],           align = .Start,
			sortable = true, resizable = true},
	}

	tbl := skald.table(ctx, &s_mut, cols, ROW_COUNT, ROW_HEIGHT,
		{720, 480}, build_row,
		row_key,
		on_row,
		row_is_selected,
		on_sort,
		on_resize,
		on_activate,
		sort_column    = s.sort_col,
		sort_ascending = s.sort_asc,
		focus_row      = s.focus_visible,
	)

	info := fmt.tprintf("%d rows • %d built this frame • %d selected",
		ROW_COUNT, s_mut.last_built, len(s_mut.selected))

	opened_line := "Open a row with Enter or Space."
	if s.opened != "" {
		opened_line = fmt.tprintf("Opened: %s", s.opened)
	}

	return skald.col(
		skald.text("Skald — Table", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Click headers to sort. Drag dividers to resize. Click / Ctrl / Shift rows. Arrows / PageUp-Down / Home / End / Enter for keyboard nav.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.md),
		skald.text(info, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.sm),
		tbl,
		skald.spacer(th.spacing.sm),
		skald.text(opened_line, th.color.fg_muted, th.font.size_sm),
		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Table",
		size   = {820, 700},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
