package example_context_menu

// context_menu — right-click a view to pop a menu attached to the cursor.
//
// `context_menu(ctx, child, items, on_select)` wraps any view; a right-press
// inside it opens a popover listing `items`, and `on_select(i)` fires for the
// row clicked. Escape or an outside click dismisses; clicks on the menu's
// padding are inert (the menu stays open).
//
// Here it wraps a `table` so this reads like a file manager: right-clicking a
// row selects it (via the table's `on_row_context`) AND opens the menu, so the
// menu's action targets the row under the cursor — the desktop convention.

import "core:fmt"
import "gui:skald"

File :: struct { name: string, size: string }

State :: struct {
	files:    []File,
	sel:      int, // selected row, -1 = none
	last_act: int, // last menu action index, -1 = none
}

Msg :: union { Row_Click, Row_Context, Menu_Action }
Row_Click   :: distinct int
Row_Context :: distinct int
Menu_Action :: distinct int

ITEMS := []string{"Open", "Cut", "Copy", "Rename", "Delete"}

FILES := []File{
	{"report.pdf",        "2.4 MB"},
	{"budget.xlsx",       "88 KB"},
	{"photo.png",         "5.1 MB"},
	{"notes.txt",         "3 KB"},
	{"archive.zip",       "120 MB"},
	{"presentation.pptx", "14 MB"},
}

init :: proc() -> State {
	return { files = FILES, sel = -1, last_act = -1 }
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Row_Click:   out.sel = int(v)
	case Row_Context: out.sel = int(v)               // right-click selects the row
	case Menu_Action: out.last_act = int(v)          // then the menu acts on it
	}
	return out, {}
}

on_row_click   :: proc(row: int, mods: skald.Modifiers) -> Msg { return Row_Click(row) }
on_row_context :: proc(row: int) -> Msg { return Row_Context(row) }
on_menu        :: proc(i: int) -> Msg { return Menu_Action(i) }
row_key        :: proc(s: State, row: int) -> u64 { return u64(row) }
is_selected    :: proc(s: State, row: int) -> bool { return row == s.sel }

row_builder :: proc(ctx: ^skald.Ctx(Msg), s: State, row: int) -> []skald.View {
	th := ctx.theme
	cells := make([]skald.View, 2, context.temp_allocator)
	cells[0] = skald.text(s.files[row].name, th.color.fg, th.font.size_md)
	cells[1] = skald.text(s.files[row].size, th.color.fg_muted, th.font.size_md)
	return cells
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	cols := []skald.Table_Column{
		{label = "Name", width = 260},
		{label = "Size", width = 120, align = .End},
	}

	files := skald.table(ctx, s, cols, len(s.files), 30, {0, 0},
		row_builder, row_key, on_row_click, is_selected, nil, nil, nil,
		on_row_context = on_row_context,
		hairline = true)

	// The whole file list is the right-click target.
	listing := skald.context_menu(ctx, files, ITEMS, on_menu, width = 180)

	sel_name := s.sel >= 0 ? s.files[s.sel].name : "(none)"
	act_name := s.last_act >= 0 ? ITEMS[s.last_act] : "(none)"

	return skald.col(
		skald.text("Files — right-click a row", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(
			fmt.tprintf("selected: %s        last action: %s", sel_name, act_name),
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.md),
		skald.flex(1, listing),
		padding     = th.spacing.xl,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Context Menu",
		size   = {560, 480},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
