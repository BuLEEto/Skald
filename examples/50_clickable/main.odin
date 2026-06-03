package example_clickable

// clickable — make arbitrary content behave like a button.
//
// `clickable` wraps any view so it fires a Msg on click: left only, or
// left + right. Unlike `button` (which takes a label string) it wraps a
// whole view — an image, a card, a row.
//
// It draws NOTHING of its own, so hover / pressed / focus visuals are the
// app's job: read the query layer (`widget_hovered`, `widget_active`,
// `widget_has_focus`) on the same id and style the child before wrapping
// it. The `tile` helper below is the canonical pattern.

import "core:fmt"
import "core:strings"
import "gui:skald"

State :: struct {
	log:      string,
	dot_mode: int, // 0 neutral · 1 left · 2 right
	dot_gen:  int, // bumps each click so a stale reset can't clear a newer one
}

Msg :: union { Opened, Menu, Row_Select, Row_Open, Dot_Left, Dot_Right, Dot_Reset }
Opened     :: distinct int
Menu       :: distinct int
Row_Select :: struct{}
Row_Open   :: struct{}
Dot_Left   :: struct{}
Dot_Right  :: struct{}
Dot_Reset  :: distinct int // carries the generation it was scheduled for

set_log :: proc(s: ^State, m: string) { delete(s.log); s.log = strings.clone(m) }

init :: proc() -> State {
	return { log = strings.clone("left-click / Enter to open · right-click for a menu · Tab to move focus") }
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Opened:     set_log(&out, fmt.tprintf("tile %d opened  (left / Enter)", int(v)))
	case Menu:       set_log(&out, fmt.tprintf("tile %d menu    (right-click)", int(v)))
	case Row_Select: set_log(&out, "row: single-click → select")
	case Row_Open:   set_log(&out, "row: double-click → open")
	case Dot_Left:
		out.dot_mode = 1; out.dot_gen += 1
		set_log(&out, "circle: LEFT  (fills primary, clears in 2.5s)")
		return out, skald.cmd_delay(2.5, Msg(Dot_Reset(out.dot_gen)))
	case Dot_Right:
		out.dot_mode = 2; out.dot_gen += 1
		set_log(&out, "circle: RIGHT (fills danger, clears in 2.5s)")
		return out, skald.cmd_delay(2.5, Msg(Dot_Reset(out.dot_gen)))
	case Dot_Reset:
		// only clear if no newer click happened since this reset was scheduled
		if int(v) == out.dot_gen { out.dot_mode = 0; set_log(&out, "circle reset") }
	}
	return out, {}
}

// tile is a clickable card whose background tracks hover / focus / pressed
// through the query layer — the standard way to give a clickable its look.
tile :: proc(ctx: ^skald.Ctx(Msg), n: int, label: string, disabled: bool) -> skald.View {
	th := ctx.theme
	id := skald.hash_id(fmt.tprintf("tile-%d", n))

	bg := th.color.surface
	if !disabled {
		if skald.widget_hovered(ctx, id)       { bg = th.color.elevated }
		if skald.widget_has_focus(ctx, id)     { bg = th.color.selection }  // focus ring
		if skald.widget_active(ctx, id, .Left) { bg = th.color.primary }    // pressed
	}
	fg := th.color.fg_muted if disabled else th.color.fg

	body := skald.col(
		skald.text("◆", fg, th.font.size_lg),
		skald.spacer(th.spacing.xs),
		skald.text(label, fg, th.font.size_sm),
		padding = th.spacing.md, bg = bg, radius = th.radius.md,
		width = 130, cross_align = .Center,
	)

	if disabled {
		return skald.clickable(ctx, body, Opened(n), id = id, disabled = true)
	}
	return skald.clickable(ctx, body, Opened(n), Menu(n), id = id) // left + right
}

// dbl_row drops past `clickable` to the raw `zone` + queries to split
// single- from double-click — the capability `clickable` doesn't expose.
dbl_row :: proc(ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	id := skald.hash_id("dbl-row")
	bg := th.color.surface
	if skald.widget_hovered(ctx, id) { bg = th.color.elevated }

	body := skald.col(skald.text("▤  single = select · double = open", th.color.fg, th.font.size_md),
		padding = th.spacing.md, bg = bg, radius = th.radius.md, width = 300)
	z := skald.zone(ctx, body, id)
	if skald.widget_clicked(ctx, id, .Left) {
		if skald.widget_click_count(ctx, id, .Left) >= 2 { skald.send(ctx, Row_Open{}) }
		else                                             { skald.send(ctx, Row_Select{}) }
	}
	return z
}

// dot is a clickable circle (just `rect` with a full corner radius) wired to
// left AND right. Feedback comes from STATE (which click last fired) so it's
// reliable — unlike the transient pressed-flash, which lazy redraw can skip.
dot :: proc(ctx: ^skald.Ctx(Msg), mode: int) -> skald.View {
	th := ctx.theme
	id := skald.hash_id("dot")
	c := th.color.surface
	switch mode {
	case 1: c = th.color.primary
	case 2: c = th.color.danger
	case:   if skald.widget_hovered(ctx, id) { c = th.color.elevated }
	}
	return skald.clickable(ctx, skald.rect({56, 56}, c, radius = 28), Dot_Left{}, Dot_Right{}, id = id, focusable = false)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text("clickable tiles", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.row(
			tile(ctx, 1, "Open / Menu", false),
			tile(ctx, 2, "Open / Menu", false),
			tile(ctx, 3, "Disabled",    true),
			spacing = th.spacing.md,
		),
		skald.spacer(th.spacing.lg),
		skald.text("Raw zone (the engine under clickable):", th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		dbl_row(ctx),
		skald.spacer(th.spacing.lg),
		skald.text("A clickable shape — left fills primary, right fills danger:", th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		dot(ctx, s.dot_mode),
		skald.spacer(th.spacing.lg),
		skald.text(fmt.tprintf("→ %s", s.log), th.color.primary, th.font.size_md),
		padding = th.spacing.xl, cross_align = .Start, spacing = 0,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — clickable",
		size   = {560, 540},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
