package example_multi_window

// Exercise for Skald's multi-window support. The main window has one
// button that spawns a second OS window via `cmd_open_window`; the
// second window renders its own view (with a close button that fires
// `cmd_close_window`). A single `app.view` proc renders both — it
// dispatches on `ctx.window` to pick which tree belongs to which window.

import "core:fmt"
import "gui:skald"

State :: struct {
	popover_open: bool,
	popover_id:   skald.Window_Id,
	open_count:   int,
}

Msg :: union {
	Open_Popover,
	Popover_Opened,
	Close_Popover,
	Popover_Closed,
}

Open_Popover   :: struct {}
Popover_Opened :: struct { id: skald.Window_Id }
Close_Popover  :: struct {}
Popover_Closed :: struct { id: skald.Window_Id }

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Open_Popover:
		// Guard: only one popover at a time in this demo. A real app
		// could open any number.
		if out.popover_open { return out, {} }
		out.open_count += 1
		return out, skald.cmd_open_window(
			{
				title = fmt.tprintf("Popover #%d", out.open_count),
				size  = {320, 220},
			},
			on_popover_opened,
			on_close = on_popover_closed,
		)

	case Popover_Opened:
		out.popover_open = true
		out.popover_id   = v.id

	case Close_Popover:
		// App asks the runtime to tear the window down. The on_close
		// callback (Popover_Closed) will follow right after — so we
		// DON'T mutate popover_open here; we let Popover_Closed do it.
		if !out.popover_open { return out, {} }
		return out, skald.cmd_close_window(Msg, out.popover_id)

	case Popover_Closed:
		// Fires for BOTH paths: app-issued cmd_close_window AND the
		// user clicking the popover's native X. One handler covers
		// both so the main window's state always reflects reality.
		if v.id == out.popover_id {
			out.popover_open = false
			out.popover_id   = skald.Window_Id(nil)
		}
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Every call to `view` is for exactly one window. We discriminate
	// by comparing `ctx.window` against ids we know. Main-window view
	// is the default: if we don't recognise the id, we fall through
	// to rendering it here.
	if s.popover_open && ctx.window == s.popover_id {
		return skald.col(
			skald.text("Hello from a second OS window.",
				th.color.fg, th.font.size_lg),
			skald.spacer(th.spacing.md),
			skald.text("Each window owns its own widget store — focus,",
				th.color.fg_muted, th.font.size_md),
			skald.text("modal rects, and input are fully scoped.",
				th.color.fg_muted, th.font.size_md),
			skald.flex(1, skald.spacer(0)),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Close", Close_Popover{}),
				cross_align = .Center,
			),
			padding     = th.spacing.lg,
			spacing     = th.spacing.sm,
			cross_align = .Stretch,
		)
	}

	// Main window.
	button_label := "Open popover window" if !s.popover_open else "Popover already open"
	return skald.col(
		skald.text("Multi-window demo", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.md),
		skald.text("Click the button to spawn a second OS window.",
			th.color.fg_muted, th.font.size_md),
		skald.text("Each window has its own Vulkan swapchain + widget",
			th.color.fg_muted, th.font.size_md),
		skald.text("store but shares the device, pipeline, and fonts.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.lg),
		skald.button(ctx, button_label, Open_Popover{}),
		padding     = th.spacing.lg,
		spacing     = th.spacing.sm,
		cross_align = .Start,
	)
}

on_popover_opened :: proc(id: skald.Window_Id) -> Msg {
	return Popover_Opened{id = id}
}

on_popover_closed :: proc(id: skald.Window_Id) -> Msg {
	return Popover_Closed{id = id}
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — multi-window",
		size   = {640, 420},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
