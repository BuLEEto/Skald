package example_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

// Minimal async text editor built on the Phase 15 persistence API:
// cmd_open_file_dialog / cmd_save_file_dialog ask the OS for a path,
// cmd_read_file / cmd_write_file stream the contents. Nothing here
// blocks the frame loop — every interaction round-trips back as a Msg.
//
//   Open  → cmd_open_file_dialog → Open_Chosen (path) → cmd_read_file → File_Read_OK
//   Save  → (if path set) cmd_write_file → File_Saved_OK / _Err
//   Save  → (no path)    cmd_save_file_dialog → Save_Chosen → cmd_write_file
//   New   → clear buffer, forget path
//
// The dirty flag goes true on every user keystroke and false after a
// successful save or after Open replaces the buffer. Save success /
// failure posts a transient toast that auto-dismisses after 3s.

State :: struct {
	path:       string, // "" when the buffer has never been saved
	contents:   string, // persistent, owned
	dirty:      bool,
	busy:       bool,   // true while a read/write is in flight

	toast_msg:     string,
	toast_kind:    skald.Toast_Kind,
	toast_visible: bool,
}

Msg :: union {
	Text_Changed,

	New_Clicked,
	Open_Clicked,
	Save_Clicked,
	Save_As_Clicked,

	Open_Chosen,
	Save_Chosen,
	Dialog_Cancelled,

	File_Dropped,

	File_Read_OK,
	File_Read_Err,
	File_Saved_OK,
	File_Saved_Err,

	Toast_Closed,
}

Text_Changed :: distinct string

New_Clicked     :: struct{}
Open_Clicked    :: struct{}
Save_Clicked    :: struct{}
Save_As_Clicked :: struct{}

Open_Chosen      :: distinct string
Save_Chosen      :: distinct string
Dialog_Cancelled :: struct{}

File_Dropped :: distinct string  // persistent-heap clone of the dropped path

File_Read_OK   :: struct { path: string, contents: string }
File_Read_Err  :: distinct string
File_Saved_OK  :: struct{}
File_Saved_Err :: distinct string

Toast_Closed :: struct{}

// Filter list shared between Open and Save As. The pattern uses SDL3's
// semicolon-separated extension syntax — "*" means "any file".
FILTERS := []skald.File_Filter{
	{"Text files", "txt;md;log"},
	{"All files",  "*"},
}

init :: proc() -> State {
	return {
		path     = strings.clone(""),
		contents = strings.clone(""),
	}
}

// on_open_result translates the File_Dialog_Result into the app's Msg
// union. Runs during drain_io, before update, so the path string
// (which skald handed us on the persistent heap) is still live.
on_open_result :: proc(r: skald.File_Dialog_Result) -> Msg {
	if r.cancelled { return Dialog_Cancelled{} }
	return Open_Chosen(r.path)
}

on_save_result :: proc(r: skald.File_Dialog_Result) -> Msg {
	if r.cancelled { return Dialog_Cancelled{} }
	return Save_Chosen(r.path)
}

// on_read_result takes ownership of r.bytes (the docs require the
// handler to clone or free) — we stuff the cloned string directly
// into File_Read_OK so update doesn't have to re-allocate.
on_read_result :: proc(r: skald.File_Read_Result) -> Msg {
	if r.err != .None {
		return File_Read_Err(fmt.aprintf("read failed: %v", r.err))
	}
	// Normalize CRLF → LF. Files written on Windows (or edited there
	// and committed without a .gitattributes) carry `\r\n`; fontstash
	// has no glyph for `\r` so it renders as a tofu box at every line
	// end. Strip on load; save writes plain `\n`.
	raw, _ := strings.clone_from_bytes(r.bytes)
	delete(r.bytes)
	contents, allocated := strings.replace_all(raw, "\r\n", "\n")
	if allocated { delete(raw) }
	return File_Read_OK{
		path     = strings.clone(r.path),
		contents = contents,
	}
}

on_write_result :: proc(r: skald.File_Write_Result) -> Msg {
	if r.err != .None {
		return File_Saved_Err(fmt.aprintf("save failed: %v", r.err))
	}
	return File_Saved_OK{}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {

	case Text_Changed:
		delete(out.contents)
		out.contents = strings.clone(string(v))
		out.dirty    = true
		return out, {}

	case New_Clicked:
		delete(out.path);     out.path     = strings.clone("")
		delete(out.contents); out.contents = strings.clone("")
		out.dirty = false
		return out, {}

	case Open_Clicked:
		if out.busy { return out, {} }
		return out, skald.cmd_open_file_dialog(FILTERS, on_open_result)

	case Save_Clicked:
		if out.busy { return out, {} }
		if len(out.path) == 0 {
			return out, skald.cmd_save_file_dialog(FILTERS, on_save_result)
		}
		out.busy = true
		return out, skald.cmd_write_file(
			out.path, transmute([]u8) out.contents, on_write_result)

	case Save_As_Clicked:
		if out.busy { return out, {} }
		return out, skald.cmd_save_file_dialog(FILTERS, on_save_result)

	case Open_Chosen:
		// The path was cloned onto the persistent heap by the runtime.
		// We hold a reference here via `v`, hand the same string to
		// cmd_read_file (which clones it again internally), and own
		// the original — tuck it away so File_Read_OK can overwrite.
		out.busy = true
		path := string(v)
		return out, skald.cmd_read_file(path, on_read_result)

	case Save_Chosen:
		out.busy = true
		delete(out.path)
		out.path = strings.clone(string(v))
		// Now that we know the path, write the current buffer.
		return out, skald.cmd_write_file(
			out.path, transmute([]u8) out.contents, on_write_result)

	case Dialog_Cancelled:
		return out, {}

	case File_Dropped:
		if out.busy { return out, {} }
		out.busy = true
		// The Msg payload is a persistent clone produced in on_dropped
		// below; cmd_read_file clones it again internally. We hold
		// onto `v` only for this call — File_Read_OK hands the path
		// forward onto state.
		path := string(v)
		return out, skald.cmd_read_file(path, on_read_result)

	case File_Read_OK:
		delete(out.path);     out.path     = v.path
		delete(out.contents); out.contents = v.contents
		out.dirty = false
		out.busy  = false
		return out, {}

	case File_Read_Err:
		out.busy = false
		return out, cmd_show_toast(&out, string(v), .Danger)

	case File_Saved_OK:
		out.busy  = false
		out.dirty = false
		return out, cmd_show_toast(&out, fmt.aprintf("Saved %s", base_name(out.path)), .Success)

	case File_Saved_Err:
		out.busy = false
		return out, cmd_show_toast(&out, string(v), .Danger)

	case Toast_Closed:
		out.toast_visible = false
		delete(out.toast_msg); out.toast_msg = strings.clone("")
		return out, {}
	}
	return out, {}
}

// cmd_show_toast is a helper shared by every branch that wants to
// surface a transient message. It mutates the state in place to flip
// the banner on and returns the follow-up cmd_delay that hides it
// 3 seconds later — two effects in one call site keeps the update
// switch readable.
cmd_show_toast :: proc(s: ^State, msg: string, kind: skald.Toast_Kind) -> skald.Command(Msg) {
	delete(s.toast_msg)
	s.toast_msg     = strings.clone(msg) // cmd_delay outlives the frame arena
	s.toast_kind    = kind
	s.toast_visible = true
	return skald.cmd_delay(3.0, Msg(Toast_Closed{}))
}

base_name :: proc(path: string) -> string {
	if len(path) == 0 { return "Untitled" }
	return filepath.base(path)
}

on_text :: proc(v: string) -> Msg { return Text_Changed(v) }

// on_dropped fires from the drop_zone builder with the files slice
// (frame-arena lifetime). We only open the first file — a drop of
// multiple files into a single-buffer editor doesn't have an obvious
// meaning, so v1 just picks the first and ignores the rest. Clone
// to persistent storage so the Msg survives into update.
on_dropped :: proc(files: []string) -> Msg {
	if len(files) == 0 { return Dialog_Cancelled{} }
	return File_Dropped(strings.clone(files[0]))
}

title_text :: proc(s: State) -> string {
	name  := base_name(s.path)
	dirty := "" if !s.dirty else " •"
	return fmt.tprintf("%s%s", name, dirty)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	toolbar := skald.row(
		skald.button(ctx, "New",     New_Clicked{},     width = 80),
		skald.button(ctx, "Open",    Open_Clicked{},    width = 80),
		skald.button(ctx, "Save",    Save_Clicked{},    width = 80,
			color = th.color.primary, fg = th.color.fg),
		skald.button(ctx, "Save As…", Save_As_Clicked{}, width = 120),
		skald.spacer(th.spacing.md),
		skald.text(title_text(s), th.color.fg, th.font.size_md),
		spacing = th.spacing.sm,
	)

	drop_id := skald.hash_id("editor-drop")
	hover   := skald.drag_over(ctx, drop_id)

	// While a drag is overhead, paint an accent border around the
	// editor by swapping its border color via the text_input API.
	// The drop_zone itself is a visual passthrough — all the tint
	// lives on the field.
	border_color: skald.Color = {}
	if hover { border_color = th.color.primary }

	editor := skald.drop_zone(ctx,
		skald.text_input(ctx, s.contents, on_text,
			width     = 720,
			height    = 420,
			multiline = true,
			wrap      = true,
			disabled = s.busy,
			border    = border_color,
		),
		on_dropped,
		id = drop_id,
	)

	toast := skald.toast(ctx,
		s.toast_visible,
		s.toast_msg,
		kind     = s.toast_kind,
		anchor   = .Bottom_Center,
		on_close = proc() -> Msg { return Toast_Closed{} },
	)

	return skald.col(
		toolbar,
		skald.spacer(th.spacing.md),
		editor,
		toast,
		spacing     = 0,
		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Editor",
		size   = {800, 620},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
