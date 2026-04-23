package example_split

import "core:fmt"
import "core:strings"
import "gui:skald"

// Phase 14 close-out: the split-pane widget. Three panes in a nested
// IDE-style layout prove the important properties:
//
//   * outer split (.Row)   — sidebar | (editor / console)
//   * inner split (.Column) — editor stacked above console
//
// State is the two pane sizes, owned by the app. Drag a divider, the
// widget emits on_resize, update stores the new value, next frame
// feeds it back. Same event-only contract as sliders and the table
// column resize handle (Phase 13).
//
// The status bar at the bottom displays the live sizes so you can see
// the donor model in action: growing the sidebar shrinks the right
// side by the same delta, and the outer split's parent area stays
// invariant.

State :: struct {
	sidebar_w:  f32, // width of the left pane in the outer Row split
	editor_h:   f32, // height of the upper pane in the inner Column split
	message:    string,
}

Msg :: union {
	Sidebar_Resized,
	Editor_Resized,
}

Sidebar_Resized :: distinct f32
Editor_Resized  :: distinct f32

init :: proc() -> State {
	return State{
		sidebar_w = 200,
		editor_h  = 280,
		message   = strings.clone("Drag a divider — the other pane donates its space, total stays invariant."),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Sidebar_Resized:
		out.sidebar_w = f32(v)
	case Editor_Resized:
		out.editor_h = f32(v)
	}
	return out, {}
}

on_sidebar :: proc(v: f32) -> Msg { return Sidebar_Resized(v) }
on_editor  :: proc(v: f32) -> Msg { return Editor_Resized(v)  }

// Small pane helper: a colored card with a two-line label so the split
// geometry reads clearly at a glance. `View_Text` is a single-line
// glyph run — to break lines we stack two text nodes in a column.
pane :: proc(
	ctx:    ^skald.Ctx(Msg),
	title:  string,
	hint:   string,
	bg:     skald.Color,
) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(title, th.color.fg,       th.font.size_md),
		skald.spacer(th.spacing.xs),
		skald.text(hint,  th.color.fg_muted, th.font.size_sm),
		padding     = th.spacing.md,
		bg          = bg,
		radius      = 6,
		main_align  = .Start,
		cross_align = .Start,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	sidebar := pane(ctx, "Sidebar", "drag the right edge",  th.color.surface)
	editor  := pane(ctx, "Editor",  "drag the bottom edge", th.color.elevated)
	console := pane(ctx, "Console", "drag the top divider", th.color.surface)

	inner := skald.split(ctx,
		first      = editor,
		second     = console,
		first_size = s.editor_h,
		direction  = .Column,
		on_resize  = on_editor,
		min_first  = 80,
		min_second = 80,
	)

	outer := skald.split(ctx,
		first      = sidebar,
		second     = inner,
		first_size = s.sidebar_w,
		direction  = .Row,
		on_resize  = on_sidebar,
		min_first  = 120,
		min_second = 200,
	)

	status := fmt.tprintf("sidebar = %d px   editor = %d px",
		int(s.sidebar_w), int(s.editor_h))

	return skald.col(
		skald.text("Skald — Split Panes", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(s.message, th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.md),

		skald.flex(1, outer),

		skald.spacer(th.spacing.md),
		skald.text(status, th.color.fg_muted, th.font.size_sm),

		padding     = th.spacing.xl,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Split Panes",
		size   = {960, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
