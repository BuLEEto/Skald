package example_drag_drop

import "core:fmt"
import "gui:skald"

// In-window drag & drop: a two-pane folder manager you can drag items between.
// The point of the example is that the framework only owns two things — the
// drag gesture (`drag_source`) and the drop (`drop_target`) — while SELECTION
// and MULTI-DRAG are ordinary app state composed from the existing click
// queries. No special multi-select API:
//
//   - click           -> select just that folder           (widget_pressed)
//   - Ctrl+click       -> add / remove from the selection   (widget_pressed + mods)
//   - drag a selection -> all selected folders move together (the ghost shows N)
//   - drag unselected  -> selects it first, then drags it
//
// The trick that makes "click a selected item collapses, but drag it keeps the
// whole selection" work: `widget_clicked` is suppressed during a drag, so it
// cleanly means "clicked, not dragged."

State :: struct {
	left:     [dynamic]string,
	right:    [dynamic]string,
	selected: map[string]bool,
}

Msg :: union {
	Replace_Sel,
	Toggle_Sel,
	Move_To_Left,
	Move_To_Right,
}
Replace_Sel   :: distinct string
Toggle_Sel    :: distinct string
Move_To_Left  :: struct {}
Move_To_Right :: struct {}

init :: proc() -> State {
	s: State
	s.selected = make(map[string]bool)
	for x in ([]string{"Documents", "Downloads", "Music", "Pictures",
		"Projects", "Videos"}) {
		append(&s.left, x)
	}
	return s
}

fake_size :: proc(name: string) -> string {
	sizes := []string{"2.2 GB", "20.4 GB", "327 MB", "61.5 GB", "5.6 GB", "1.1 GB"}
	return sizes[len(name) % len(sizes)]
}

move_selected :: proc(src, dst: ^[dynamic]string, sel: map[string]bool) {
	i := 0
	for i < len(src^) {
		if src^[i] in sel {
			item := src^[i]
			ordered_remove(src, i)
			append(dst, item)
		} else {
			i += 1
		}
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Replace_Sel:
		clear(&out.selected)
		out.selected[string(v)] = true
	case Toggle_Sel:
		name := string(v)
		if name in out.selected do delete_key(&out.selected, name)
		else do out.selected[name] = true
	case Move_To_Right:
		move_selected(&out.left, &out.right, out.selected)
	case Move_To_Left:
		move_selected(&out.right, &out.left, out.selected)
	}
	return out, {}
}

// A folder tile: big icon + name + size. `lifted` styles the dragged ghost.
folder_tile :: proc(ctx: ^skald.Ctx(Msg), name, size: string, selected, lifted: bool) -> skald.View {
	th := ctx.theme
	bg := th.color.elevated if lifted else (th.color.primary if selected else skald.Color{})
	return skald.col(
		skald.text("📁", th.color.fg, 46),
		skald.text(name, th.color.fg, th.font.size_sm),
		skald.text(size, th.color.fg_muted, th.font.size_xs),
		spacing = 2, padding = th.spacing.sm, cross_align = .Center,
		bg = bg, radius = th.radius.sm)
}

pane :: proc(ctx: ^skald.Ctx(Msg), s: State, items: []string, side: string) -> skald.View {
	th := ctx.theme
	is_left := side == "left"
	accepts := "right" if is_left else "left" // a pane accepts items from the other side
	pane_id := skald.hash_id("pane-left" if is_left else "pane-right")
	hot := skald.drag_target_hot(ctx, pane_id, accepts = accepts)
	sel_count := len(s.selected)
	mods := ctx.input.modifiers

	tiles := make([dynamic]skald.View, 0, len(items), context.temp_allocator)
	for item in items {
		selected := item in s.selected
		size := fake_size(item)
		zone_id := skald.hash_id(fmt.tprintf("z-%s-%s", side, item))
		drag_id := skald.hash_id(fmt.tprintf("d-%s-%s", side, item))

		zoned := skald.zone(ctx, folder_tile(ctx, item, size, selected, false), zone_id)

		// Selection. On PRESS: Ctrl toggles; an unselected tile becomes the
		// selection; pressing an already-selected tile defers. A plain CLICK
		// that did NOT become a drag collapses the selection to that one.
		if skald.widget_pressed(ctx, zone_id) {
			if .Ctrl in mods do skald.send(ctx, Toggle_Sel(item))
			else if !selected do skald.send(ctx, Replace_Sel(item))
		}
		if skald.widget_clicked(ctx, zone_id) && .Ctrl not_in mods {
			skald.send(ctx, Replace_Sel(item))
		}

		// Ghost: an "N items" stack for a multi-selection, else this tile.
		ghost: skald.View
		if selected && sel_count > 1 {
			ghost = skald.opacity(0.92, skald.col(
				skald.text("🗂️", th.color.fg, 46),
				skald.text(fmt.tprintf("%d items", sel_count), th.color.fg, th.font.size_sm),
				spacing = 2, padding = th.spacing.sm, cross_align = .Center,
				bg = th.color.elevated, radius = th.radius.sm))
		} else {
			ghost = skald.opacity(0.9, folder_tile(ctx, item, size, false, true))
		}
		append(&tiles, skald.drag_source(ctx, zoned,
			skald.Drag_Payload{kind = side, id = 0}, ghost, id = drag_id))
	}

	// Dropping on a pane moves the selection TO that pane.
	on_drop: proc(p: skald.Drag_Payload) -> Msg
	if is_left {
		on_drop = proc(p: skald.Drag_Payload) -> Msg { return Move_To_Left{} }
	} else {
		on_drop = proc(p: skald.Drag_Payload) -> Msg { return Move_To_Right{} }
	}

	body := skald.col(
		skald.text(is_left ? "LEFT — drag →" : "RIGHT — drag ←", th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.sm),
		skald.grid(ctx, {0, 0}, ..tiles[:], spacing_x = th.spacing.sm, spacing_y = th.spacing.md),
		padding = th.spacing.md, spacing = 0, cross_align = .Stretch,
		bg = hot ? th.color.elevated : th.color.surface, radius = th.radius.md)
	return skald.drop_target(ctx, body, on_drop, id = pane_id, accepts = accepts)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(fmt.tprintf("%d selected — click / Ctrl-click to select, drag to move",
			len(s.selected)), th.color.fg, th.font.size_md),
		skald.spacer(th.spacing.sm),
		skald.flex(1, skald.row(
			skald.flex(1, pane(ctx, s, s.left[:], "left")),
			skald.flex(1, pane(ctx, s, s.right[:], "right")),
			spacing = th.spacing.md, cross_align = .Stretch,
		)),
		padding = th.spacing.lg, spacing = 0, cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Drag & Drop",
		size   = {820, 560},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
