package example_menu_bar

import "core:fmt"
import "gui:skald"

// Shows `menu_bar` with File / Edit / Help menus, per-item keyboard
// shortcuts, disabled rows, and separators. Each item dispatches a Msg
// that appends a line to a rolling activity log so you can see both
// mouse clicks and hotkey presses flowing through the same path.

State :: struct {
	count:        int,
	log:          [8]string,
	show_grid:    bool,
	word_wrap:    bool,
	show_sidebar: bool,
}

Msg :: union {
	New_Clicked,
	Open_Clicked,
	Save_Clicked,
	Save_As_Clicked,
	Quit_Clicked,
	Undo_Clicked,
	Redo_Clicked,
	Cut_Clicked,
	Copy_Clicked,
	Paste_Clicked,
	About_Clicked,
	Toggle_Grid,
	Toggle_Wrap,
	Toggle_Sidebar,
}

New_Clicked     :: struct{}
Open_Clicked    :: struct{}
Save_Clicked    :: struct{}
Save_As_Clicked :: struct{}
Quit_Clicked    :: struct{}
Undo_Clicked    :: struct{}
Redo_Clicked    :: struct{}
Cut_Clicked     :: struct{}
Copy_Clicked    :: struct{}
Paste_Clicked   :: struct{}
About_Clicked   :: struct{}
Toggle_Grid     :: struct{}
Toggle_Wrap     :: struct{}
Toggle_Sidebar  :: struct{}

init :: proc() -> State { return State{} }

log_line :: proc(s: ^State, msg: string) {
	s.count += 1
	line := fmt.aprintf("%03d  %s", s.count, msg)
	for i := len(s.log) - 1; i > 0; i -= 1 { s.log[i] = s.log[i-1] }
	s.log[0] = line
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch _ in m {
	case New_Clicked:     log_line(&out, "File → New")
	case Open_Clicked:    log_line(&out, "File → Open")
	case Save_Clicked:    log_line(&out, "File → Save")
	case Save_As_Clicked: log_line(&out, "File → Save As")
	case Quit_Clicked:    log_line(&out, "File → Quit")
	case Undo_Clicked:    log_line(&out, "Edit → Undo")
	case Redo_Clicked:    log_line(&out, "Edit → Redo")
	case Cut_Clicked:     log_line(&out, "Edit → Cut")
	case Copy_Clicked:    log_line(&out, "Edit → Copy")
	case Paste_Clicked:   log_line(&out, "Edit → Paste")
	case About_Clicked:   log_line(&out, "Help → About")
	case Toggle_Grid:
		out.show_grid = !out.show_grid
		log_line(&out, fmt.tprintf("View → Show Grid: %v", out.show_grid))
	case Toggle_Wrap:
		out.word_wrap = !out.word_wrap
		log_line(&out, fmt.tprintf("View → Word Wrap: %v", out.word_wrap))
	case Toggle_Sidebar:
		out.show_sidebar = !out.show_sidebar
		log_line(&out, fmt.tprintf("View → Show Sidebar: %v", out.show_sidebar))
	}
	return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	menu := skald.menu_bar(ctx, []skald.Menu_Entry(Msg){
		{
			label = "File",
			items = []skald.Menu_Item(Msg){
				{label = "New",     shortcut = {.N, {.Ctrl}}, msg = New_Clicked{}},
				{label = "Open…",   shortcut = {.O, {.Ctrl}}, msg = Open_Clicked{}},
				{label = "Save",    shortcut = {.S, {.Ctrl}}, msg = Save_Clicked{}},
				{label = "Save As…", shortcut = {.S, {.Ctrl, .Shift}}, msg = Save_As_Clicked{}},
				{separator = true},
				{label = "Quit",    shortcut = {.Q, {.Ctrl}}, msg = Quit_Clicked{}},
			},
		},
		{
			label = "Edit",
			items = []skald.Menu_Item(Msg){
				{label = "Undo",  shortcut = {.Z, {.Ctrl}}, msg = Undo_Clicked{}},
				{label = "Redo",  shortcut = {.Y, {.Ctrl}}, msg = Redo_Clicked{}},
				{separator = true},
				{label = "Cut",   shortcut = {.X, {.Ctrl}}, msg = Cut_Clicked{}},
				{label = "Copy",  shortcut = {.C, {.Ctrl}}, msg = Copy_Clicked{}},
				{label = "Paste", shortcut = {.V, {.Ctrl}}, msg = Paste_Clicked{},
				 disabled = s.count == 0},
			},
		},
		{
			label = "View",
			items = []skald.Menu_Item(Msg){
				{label = "Show Grid",    msg = Toggle_Grid{},    checked = s.show_grid},
				{label = "Word Wrap",    msg = Toggle_Wrap{},    checked = s.word_wrap},
				{label = "Show Sidebar", msg = Toggle_Sidebar{}, checked = s.show_sidebar},
			},
		},
		{
			label = "Help",
			items = []skald.Menu_Item(Msg){
				{label = "About", msg = About_Clicked{}},
			},
		},
	})

	log_rows := make([dynamic]skald.View, 0, 8, context.temp_allocator)
	for line in s.log {
		if line == "" { continue }
		append(&log_rows, skald.text(line, th.color.fg_muted, th.font.size_sm))
	}
	if len(log_rows) == 0 {
		append(&log_rows,
			skald.text("Click a menu or press a shortcut — actions land here.",
				th.color.fg_muted, th.font.size_sm))
	}

	return skald.col(
		menu,
		skald.spacer(th.spacing.lg),
		skald.text("Skald — Menu Bar", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.sm),
		skald.text(
			"Try Ctrl+N, Ctrl+S, Ctrl+Shift+S, or hover between File / Edit / Help while one is open.",
			th.color.fg_muted, th.font.size_sm, max_width = 560,
		),
		skald.spacer(th.spacing.lg),
		skald.col(..log_rows[:], spacing = th.spacing.xs),
		padding     = th.spacing.lg,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Menu Bar",
		size   = {640, 480},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
