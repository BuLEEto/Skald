package example_advanced

import "core:fmt"
import "core:strings"
import "gui:skald"

// Phase 11 showcase: `tabs`, `menu` + `right_click_zone`, and explicit
// Widget_IDs via `hash_id`. The app is a toy file pane with two tabs
// ("Files" and "Trash"), a context menu per row, and move-up/down
// controls that demonstrate why explicit IDs matter for lists.
//
// What to notice:
//   * Right-clicking a file row opens the menu at the cursor position.
//     The menu is hidden from the view tree while closed; its only
//     lifecycle is in the app's update via Open_Menu / Close_Menu.
//   * Each row's move-up/move-down buttons use `hash_id(key + ":up")`
//     so per-row widget state (hover highlight, focus ring) stays
//     attached to the row across reorders, not to the tree position.
//   * Tabs: active tab is the one matching `state.tab`; the header
//     strip returns `Tab_Changed(i)` so `update` is a one-liner.

Tab :: enum { Files, Trash }

Item :: struct {
	key:  string,
	name: string,
}

State :: struct {
	tab:        Tab,
	items:      [dynamic]Item,
	trash:      [dynamic]Item,
	menu_open:  bool,
	menu_pos:   [2]f32,
	menu_key:   string,
	next_seq:   int,
}

Msg :: union {
	Tab_Changed,
	Item_Moved,
	Menu_Opened,
	Menu_Closed,
	Menu_Action_Picked,
	Restore_Clicked,
	Add_Clicked,
}

Tab_Changed        :: distinct int
Menu_Closed        :: distinct struct{}
Add_Clicked        :: distinct struct{}
Item_Moved         :: struct{ key: string, dir: int }
Menu_Opened        :: struct{ key: string, pos: [2]f32 }
Menu_Action_Picked :: distinct int
Restore_Clicked    :: distinct string

Menu_Action :: enum { Rename, Duplicate, Delete }

init :: proc() -> State {
	s: State
	s.tab = .Files
	for name in ([]string{"readme.md", "notes.txt", "todo.md", "journal.odin"}) {
		append(&s.items, make_item(name, &s.next_seq))
	}
	return s
}

make_item :: proc(name: string, seq: ^int) -> Item {
	seq^ += 1
	key := fmt.aprintf("item-%d", seq^)
	return Item{key = key, name = strings.clone(name)}
}

find_index :: proc(items: []Item, key: string) -> int {
	for it, i in items {
		if it.key == key { return i }
	}
	return -1
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Tab_Changed:
		out.tab = Tab(v)
		out.menu_open = false

	case Item_Moved:
		idx := find_index(out.items[:], v.key)
		if idx < 0 { return out, {} }
		j := idx + v.dir
		if j < 0 || j >= len(out.items) { return out, {} }
		out.items[idx], out.items[j] = out.items[j], out.items[idx]

	case Menu_Opened:
		out.menu_open = true
		out.menu_pos  = v.pos
		out.menu_key  = v.key

	case Menu_Closed:
		out.menu_open = false

	case Menu_Action_Picked:
		if !out.menu_open { return out, {} }
		idx := find_index(out.items[:], out.menu_key)
		if idx < 0 {
			out.menu_open = false
			return out, {}
		}
		switch Menu_Action(int(v)) {
		case .Rename:
			old := out.items[idx].name
			out.items[idx].name = fmt.aprintf("%s (renamed)", old)
			delete(old)
		case .Duplicate:
			copy_name := fmt.aprintf("%s (copy)", out.items[idx].name)
			new_item  := make_item(copy_name, &out.next_seq)
			delete(copy_name)
			inject_at(&out.items, idx + 1, new_item)
		case .Delete:
			removed := out.items[idx]
			ordered_remove(&out.items, idx)
			append(&out.trash, removed)
		}
		out.menu_open = false

	case Restore_Clicked:
		key := string(v)
		for it, i in out.trash {
			if it.key == key {
				ordered_remove(&out.trash, i)
				append(&out.items, it)
				break
			}
		}

	case Add_Clicked:
		append(&out.items, make_item("new file", &out.next_seq))
	}
	return out, {}
}

on_tab       :: proc(i: int) -> Msg { return Tab_Changed(i) }
on_menu_pick :: proc(i: int) -> Msg { return Menu_Action_Picked(i) }
on_dismiss   :: proc() -> Msg       { return Menu_Closed{} }

file_row :: proc(ctx: ^skald.Ctx(Msg), it: Item) -> skald.View {
	th := ctx.theme

	// Stable per-row IDs. Without these, the move-up/down buttons'
	// hover state would belong to the position in the list rather
	// than to the row itself — reordering would drag highlight
	// across neighboring rows.
	up_id   := skald.hash_id(strings.concatenate({it.key, ":up"},   context.temp_allocator))
	down_id := skald.hash_id(strings.concatenate({it.key, ":down"}, context.temp_allocator))
	zone_id := skald.hash_id(strings.concatenate({it.key, ":zone"}, context.temp_allocator))

	row_body := skald.row(
		skald.text(it.name, th.color.fg, th.font.size_md),
		skald.spacer(0),
		skald.button(ctx, "↑", Item_Moved{key = it.key, dir = -1},
			id = up_id, color = th.color.surface, fg = th.color.fg, width = 32),
		skald.button(ctx, "↓", Item_Moved{key = it.key, dir = 1},
			id = down_id, color = th.color.surface, fg = th.color.fg, width = 32),
		width       = 520,
		padding     = th.spacing.sm,
		spacing     = th.spacing.xs,
		bg          = th.color.surface,
		radius      = th.radius.sm,
		cross_align = .Center,
	)

	// The right-click msg bakes in the row key and the current
	// cursor pos. On the frame the right-press fires, mouse_pos
	// is the click pixel — good enough to anchor the menu.
	return skald.right_click_zone(ctx, row_body,
		Menu_Opened{key = it.key, pos = ctx.input.mouse_pos},
		id = zone_id)
}

files_panel :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	rows := make([dynamic]skald.View, 0, len(s.items) + 2, context.temp_allocator)
	append(&rows, skald.button(ctx, "+ Add file", Add_Clicked{},
		color = th.color.primary, fg = th.color.fg))
	append(&rows, skald.spacer(th.spacing.sm))
	for it in s.items {
		append(&rows, file_row(ctx, it))
	}

	list := skald.col(..rows[:], spacing = th.spacing.xs, cross_align = .Stretch)

	if !s.menu_open {
		return list
	}

	menu_view := skald.menu(ctx,
		[]string{"Rename", "Duplicate", "Delete"},
		on_menu_pick,
		on_dismiss = on_dismiss,
	)
	anchor := skald.Rect{s.menu_pos.x, s.menu_pos.y, 1, 1}

	return skald.col(
		list,
		skald.overlay(anchor, menu_view, .Below, {0, 0}),
	)
}

trash_panel :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	if len(s.trash) == 0 {
		return skald.text("Trash is empty.", th.color.fg_muted, th.font.size_md)
	}
	rows := make([dynamic]skald.View, 0, len(s.trash), context.temp_allocator)
	for it in s.trash {
		append(&rows, skald.row(
			skald.text(it.name, th.color.fg_muted, th.font.size_md),
			skald.spacer(0),
			skald.button(ctx, "Restore", Restore_Clicked(it.key),
				id    = skald.hash_id(strings.concatenate({it.key, ":restore"}, context.temp_allocator)),
				color = th.color.surface,
				fg    = th.color.fg),
			width       = 520,
			padding     = th.spacing.sm,
			spacing     = th.spacing.md,
			bg          = th.color.surface,
			radius      = th.radius.sm,
			cross_align = .Center,
		))
	}
	return skald.col(..rows[:], spacing = th.spacing.xs, cross_align = .Stretch)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	panel: skald.View
	switch s.tab {
	case .Files: panel = files_panel(s, ctx)
	case .Trash: panel = trash_panel(s, ctx)
	}

	return skald.col(
		skald.text("Skald — Tabs, Menus, Explicit IDs", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Right-click a row to open a context menu.",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.md),

		skald.tabs(ctx,
			[]string{"Files", "Trash"},
			int(s.tab),
			on_tab),

		skald.spacer(th.spacing.md),
		panel,

		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Advanced",
		size   = {700, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
