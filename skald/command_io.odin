package skald

import "base:runtime"
import "core:c"
import "core:nbio"
import "core:strings"
import "vendor:sdl3"

// Command_IO wires Phase 9's Command/Effect system into `core:nbio` so
// `update` can describe async file / socket work declaratively and get
// the result back as a regular Msg. The runtime owns the event loop:
// `run` calls `nbio.acquire_thread_event_loop` once, ticks it each
// frame with a zero timeout, and drains completed operations into the
// msg queue before update runs.
//
// The big design knot is type erasure. nbio's callbacks are plain
// `proc(user_data: rawptr, ...)` signatures with no way to carry the
// app's Msg type through the rawptr. Rather than wrestle with that
// per-callback, we have nbio write into a pending-result slot (an
// untyped struct) and do the typed Msg conversion back in `run`, where
// Msg is statically known. Each in-flight op stores the user's
// `on_result` proc and a pointer to its pending slot; the per-frame
// drain walks the list, dispatches completed slots, and frees both.
//
// Allocation: in-flight storage, pending slots, and the cloned path
// string all live on `context.allocator` (the persistent heap). The
// op outlives the frame arena by definition. Successful reads return
// bytes allocated by nbio on that same heap; the Msg handler is
// responsible for freeing or cloning the buffer into its own state.

// File_Read_Result is what `cmd_read_file`'s handler receives. `err ==
// .None` means success — `bytes` is a fresh heap allocation the caller
// now owns. On failure, `bytes` is empty. `path` is echoed back so a
// single handler can fan across multiple concurrent reads without the
// app having to pair result-to-request itself.
File_Read_Result :: struct {
	path:  string,
	bytes: []u8,
	err:   nbio.FS_Error,
}

// File_Write_Result is what `cmd_write_file`'s handler receives.
// `err == .None` means every byte landed on disk and the file handle
// was closed cleanly. `path` is echoed back so one handler can service
// multiple concurrent writes (e.g. two editor buffers saving at once).
File_Write_Result :: struct {
	path: string,
	err:  nbio.FS_Error,
}

// File_Dialog_Result is what `cmd_open_file_dialog` / `cmd_save_file_dialog`
// hand back. `cancelled` is true when the user dismissed the dialog
// without choosing (or when the OS-level picker reported an error —
// v1 folds both into the same outcome since apps typically treat them
// identically: do nothing, let the user try again). `path` is empty on
// cancel and is a persistent-heap clone the handler now owns on
// success — clone into state, copy into temp, or `delete` before it
// leaks.
File_Dialog_Result :: struct {
	path:      string,
	cancelled: bool,
}

// File_Filter describes one entry in the dialog's filter picker.
// `pattern` is a semicolon-separated list of extensions (no leading
// `.`, no glob prefix) — SDL3 translates this to each platform's
// native format. Example: `{name = "Text", pattern = "txt;md"}`.
File_Filter :: struct {
	name:    string,
	pattern: string,
}

// cmd_read_file reads a file asynchronously and delivers the result
// through `on_result` as a Msg. The returned Command does nothing on
// its own until `update` returns it — the runtime sees the Async kind
// and schedules the read with nbio.
//
//     Msg :: union { File_Loaded, File_Error_Msg, ... }
//     to_msg :: proc(r: skald.File_Read_Result) -> Msg {
//         if r.err != .None { return File_Error_Msg{err = r.err} }
//         return File_Loaded{bytes = r.bytes}
//     }
//     return state, skald.cmd_read_file("/etc/hostname", to_msg)
//
// The bytes in `File_Read_Result.bytes` are heap-allocated by nbio on
// the persistent allocator — the handler must clone into state, copy
// into temp, or `delete` before the buffer is leaked.
cmd_read_file :: proc(
	path:      string,
	on_result: proc(File_Read_Result) -> $Msg,
) -> Command(Msg) {
	// The Async_Op payload gets walked by process_command on the same
	// frame, then the path is cloned into persistent storage. Building
	// the op itself in temp keeps call sites allocation-free.
	op := new(Async_Op(Msg), context.temp_allocator)
	op^ = Async_Read_File(Msg){path = path, on_result = on_result}
	return Command(Msg){kind = .Async, async = op}
}

// cmd_write_file writes `bytes` to `path` asynchronously, creating
// or truncating the file, then closes the handle. The completion is
// delivered as a Msg via `on_result`. Unlike read, the caller does
// NOT retain ownership of `bytes` after this call — the runtime clones
// the slice into persistent storage so the source can live in the
// frame arena.
//
//     to_msg :: proc(r: skald.File_Write_Result) -> Msg {
//         if r.err != .None { return Save_Failed{err = r.err} }
//         return Saved{}
//     }
//     return state, skald.cmd_write_file(path, transmute([]u8) text, to_msg)
//
// Failure modes the handler sees: .None (ok), or any nbio.FS_Error
// from open/write/close. The file may be left in a partially-written
// state on disk if write fails mid-stream (nbio's `all=true` mode
// loops internally but doesn't roll back); apps that care about
// atomicity should write to a sibling tempfile + rename.
cmd_write_file :: proc(
	path:      string,
	bytes:     []u8,
	on_result: proc(File_Write_Result) -> $Msg,
) -> Command(Msg) {
	op := new(Async_Op(Msg), context.temp_allocator)
	op^ = Async_Write_File(Msg){path = path, bytes = bytes, on_result = on_result}
	return Command(Msg){kind = .Async, async = op}
}

// cmd_open_file_dialog shows a native OS file-open picker anchored to
// the app window and delivers the chosen path (or cancellation) as a
// Msg. The dialog is modal from the OS's perspective but does not
// block the Skald frame loop — the runtime keeps pumping while the
// picker is up, and the result lands through the same drain path as
// async I/O so the app sees it as a regular Msg.
//
//     to_msg :: proc(r: skald.File_Dialog_Result) -> Msg {
//         if r.cancelled { return Open_Cancelled{} }
//         return Open_Chosen{path = r.path}
//     }
//     return s, skald.cmd_open_file_dialog({
//         {"Text files", "txt;md"},
//         {"All files",  "*"},
//     }, to_msg)
//
// The `filters` slice may be nil or empty — the OS then shows the
// platform default (usually "All files"). Filter `pattern` uses
// SDL3's semicolon-separated extension syntax (no leading dot); `*`
// means "everything." The handler owns `result.path` on success
// and must clone or free it before the frame arena moves on.
cmd_open_file_dialog :: proc(
	filters:          []File_Filter,
	on_result:        proc(File_Dialog_Result) -> $Msg,
	default_location: string = "",
) -> Command(Msg) {
	op := new(Async_Op(Msg), context.temp_allocator)
	op^ = Async_File_Dialog(Msg){
		kind             = .Open,
		filters          = filters,
		on_result        = on_result,
		default_location = default_location,
	}
	return Command(Msg){kind = .Async, async = op}
}

// cmd_save_file_dialog mirrors `cmd_open_file_dialog` but asks the OS
// for a Save picker, which typically lets the user pick an existing
// file or type a new filename. SDL3 does not currently expose a
// "default filename" parameter to this call — apps that want to
// suggest a starting filename must pair this with a subsequent
// cmd_write_file to the returned path (the picker confirmation is
// the "Save as" step; writing happens separately). `default_location`
// is the starting directory; empty string lets the OS pick its usual
// default (typically the user's Documents).
cmd_save_file_dialog :: proc(
	filters:          []File_Filter,
	on_result:        proc(File_Dialog_Result) -> $Msg,
	default_location: string = "",
) -> Command(Msg) {
	op := new(Async_Op(Msg), context.temp_allocator)
	op^ = Async_File_Dialog(Msg){
		kind             = .Save,
		filters          = filters,
		on_result        = on_result,
		default_location = default_location,
	}
	return Command(Msg){kind = .Async, async = op}
}

// cmd_open_folder_dialog shows a native OS folder-picker anchored to
// the app window and delivers the chosen folder path (or cancellation)
// as a Msg. Unlike the file variants, folder pickers don't take file
// filters — the OS always shows directories. Result handling mirrors
// `cmd_open_file_dialog`: the handler owns `result.path` on success
// and must clone or free it before the frame arena moves on.
//
//     to_msg :: proc(r: skald.File_Dialog_Result) -> Msg {
//         if r.cancelled { return Pick_Cancelled{} }
//         return Folder_Chosen{path = r.path}
//     }
//     return s, skald.cmd_open_folder_dialog(to_msg)
cmd_open_folder_dialog :: proc(
	on_result:        proc(File_Dialog_Result) -> $Msg,
	default_location: string = "",
) -> Command(Msg) {
	op := new(Async_Op(Msg), context.temp_allocator)
	op^ = Async_File_Dialog(Msg){
		kind             = .Open_Folder,
		filters          = nil,
		on_result        = on_result,
		default_location = default_location,
	}
	return Command(Msg){kind = .Async, async = op}
}

// Async_Op is the per-Msg union of async operation descriptors. One
// variant per op kind — adding Fetch, etc. means a new struct and a
// new case in `process_command`. The parametric union keeps the
// `on_result` callbacks typed end-to-end.
Async_Op :: union($Msg: typeid) {
	Async_Read_File(Msg),
	Async_Write_File(Msg),
	Async_File_Dialog(Msg),
}

// Async_Read_File is the payload the runtime sees for a pending
// `cmd_read_file`. Apps build one through `cmd_read_file` rather than
// constructing it directly.
Async_Read_File :: struct($Msg: typeid) {
	path:      string,
	on_result: proc(File_Read_Result) -> Msg,
}

// Async_Write_File is the payload the runtime sees for a pending
// `cmd_write_file`. Apps build one through `cmd_write_file` rather
// than constructing it directly.
Async_Write_File :: struct($Msg: typeid) {
	path:      string,
	bytes:     []u8,
	on_result: proc(File_Write_Result) -> Msg,
}

// File_Dialog_Kind discriminates the native-dialog variants the runtime
// can launch on the same Async_File_Dialog payload. Open_Folder ignores
// the `filters` slice (OS folder pickers don't filter by pattern).
File_Dialog_Kind :: enum { Open, Save, Open_Folder }

// Async_File_Dialog is the payload the runtime sees for a pending
// native open/save dialog. Apps build one through `cmd_open_file_dialog`
// or `cmd_save_file_dialog` rather than constructing it directly.
Async_File_Dialog :: struct($Msg: typeid) {
	kind:             File_Dialog_Kind,
	filters:          []File_Filter,
	on_result:        proc(File_Dialog_Result) -> Msg,
	default_location: string,
}

// Read_Slot holds one outstanding read. The runtime allocates it on
// the persistent heap, hands `&slot.pending` to nbio as user_data, and
// the nbio callback writes the result fields directly into
// `slot.pending`. When `slot.pending.done` flips to true, the next
// frame's `drain_io` invokes `on_result(...)` and frees the slot.
@(private)
Read_Slot :: struct($Msg: typeid) {
	pending:   Read_Pending, // mutated by the nbio callback
	path:      string,       // persistent clone; echoed to the handler
	on_result: proc(File_Read_Result) -> Msg,
}

@(private)
Read_Pending :: struct {
	done:  bool,
	bytes: []byte,
	err:   nbio.Read_Entire_File_Error,
}

// Write_Slot tracks one outstanding write. Unlike reads, writes go
// through three chained nbio ops (open → write → close), so the
// pending struct also stores the handle between steps. `bytes` is the
// persistent-cloned payload; we free it on drain alongside the slot.
@(private)
Write_Slot :: struct($Msg: typeid) {
	pending:   Write_Pending,
	path:      string,
	bytes:     []u8,
	on_result: proc(File_Write_Result) -> Msg,
}

// Write_Pending is the untyped target that nbio callbacks mutate. The
// three-op chain (open/write/close) fills `handle` and `err` in that
// order; `done` is set after close completes. A non-nil err at any
// step short-circuits the remaining ops — write errors still close,
// but close errors obviously can't cascade further.
@(private)
Write_Pending :: struct {
	done:   bool,
	err:    nbio.FS_Error,
	handle: nbio.Handle,
}

// Dialog_Slot tracks one outstanding native file dialog. Like the
// other slot types, the first field (`pending`) is the untyped target
// the C callback writes into; the rest (`on_result`, plus persistent-
// heap bookkeeping for the SDL filter struct array) is resolved during
// drain where Msg is in scope.
@(private)
Dialog_Slot :: struct($Msg: typeid) {
	pending:      Dialog_Pending,
	on_result:    proc(File_Dialog_Result) -> Msg,

	// SDL requires the DialogFileFilter array and its cstrings to stay
	// valid until the callback fires. These live on the persistent heap
	// for the lifetime of the slot and are freed during drain.
	filter_list:  []sdl3.DialogFileFilter,
	filter_names: []cstring,
	filter_pats:  []cstring,

	// default_location is the starting directory hint SDL sees as a
	// cstring — also needs to survive until the dialog closes. nil means
	// "let the platform choose." Freed alongside the filter bookkeeping.
	default_location: cstring,
}

// Dialog_Pending is the untyped target the SDL "c" callback writes
// into. On success, `path` is a persistent-heap clone of the chosen
// filename; on cancel or error, `cancelled=true` and `path` stays "".
@(private)
Dialog_Pending :: struct {
	done:      bool,
	cancelled: bool,
	path:      string,
}

// Io_State collects every in-flight async op owned by `run`. Holding
// slot pointers (rather than the slots themselves) means the pending
// struct has a stable address for nbio to write into even as the list
// grows and shifts.
@(private)
Io_State :: struct($Msg: typeid) {
	reads:   [dynamic]^Read_Slot(Msg),
	writes:  [dynamic]^Write_Slot(Msg),
	dialogs: [dynamic]^Dialog_Slot(Msg),

	// window is needed by the file-picker path because SDL3 anchors
	// the native OS dialog to a parent window for modal behavior.
	// Stored as an opaque pointer so apps that never use pickers
	// don't pay any runtime cost for it.
	window:  ^sdl3.Window,
}

@(private)
io_state_init :: proc(s: ^Io_State($Msg), window: ^sdl3.Window) {
	s.reads   = make([dynamic]^Read_Slot(Msg))
	s.writes  = make([dynamic]^Write_Slot(Msg))
	s.dialogs = make([dynamic]^Dialog_Slot(Msg))
	s.window  = window
}

@(private)
io_state_destroy :: proc(s: ^Io_State($Msg)) {
	// Any slots still in flight at shutdown have their nbio ops
	// cancelled implicitly when the event loop is released. Freeing
	// the slots here prevents leaks in the happy case; a callback
	// firing after release would be a use-after-free, but nbio's
	// release teardown delivers no more callbacks, so we're safe.
	for slot in s.reads {
		delete(slot.path)
		free(slot)
	}
	delete(s.reads)
	for slot in s.writes {
		delete(slot.path)
		delete(slot.bytes)
		free(slot)
	}
	delete(s.writes)
	for slot in s.dialogs {
		dialog_slot_free_filters(slot)
		delete(slot.pending.path)
		free(slot)
	}
	delete(s.dialogs)
}

@(private)
dialog_slot_free_filters :: proc(slot: ^Dialog_Slot($Msg)) {
	for n in slot.filter_names { delete(n) }
	for p in slot.filter_pats  { delete(p) }
	delete(slot.filter_names)
	delete(slot.filter_pats)
	delete(slot.filter_list)
	if slot.default_location != nil { delete(slot.default_location) }
}

// process_async dispatches an Async_Op by scheduling the underlying
// nbio call and registering an in-flight slot. Called from
// `process_command` for the `.Async` command kind.
@(private)
process_async :: proc(
	op:    ^Async_Op($Msg),
	io:    ^Io_State(Msg),
) {
	switch v in op^ {
	case Async_Read_File(Msg):
		slot := new(Read_Slot(Msg))
		path_clone, _ := strings.clone(v.path)
		slot.path      = path_clone
		slot.on_result = v.on_result

		// nbio owns the bytes buffer and allocates it on the heap
		// we pass here — the runtime allocator, same as the slot.
		// The handler gets those bytes and is responsible for them.
		nbio.read_entire_file(
			path      = path_clone,
			user_data = &slot.pending,
			cb        = on_read_complete,
		)

		append(&io.reads, slot)

	case Async_Write_File(Msg):
		slot := new(Write_Slot(Msg))
		path_clone, _  := strings.clone(v.path)
		// Clone the payload into persistent storage so callers can
		// pass a frame-arena slice and forget about it — the runtime
		// owns the bytes for the lifetime of the op, then frees them
		// during drain alongside the slot.
		bytes_clone    := make([]u8, len(v.bytes))
		copy(bytes_clone, v.bytes)
		slot.path      = path_clone
		slot.bytes     = bytes_clone
		slot.on_result = v.on_result

		op := nbio.prep_open(
			path_clone,
			on_write_open,
			mode = {.Write, .Create, .Trunc},
		)
		op.user_data[0] = cast(rawptr) &slot.pending
		nbio.exec(op)

		append(&io.writes, slot)

	case Async_File_Dialog(Msg):
		slot := new(Dialog_Slot(Msg))
		slot.on_result = v.on_result

		// Translate each File_Filter into the SDL representation. Name
		// and pattern cstrings live on the persistent heap and are
		// tracked in parallel slices so drain can free them without
		// walking back into an already-freed filter_list entry.
		n := len(v.filters)
		slot.filter_list  = make([]sdl3.DialogFileFilter, n)
		slot.filter_names = make([]cstring, n)
		slot.filter_pats  = make([]cstring, n)
		for f, i in v.filters {
			slot.filter_names[i] = strings.clone_to_cstring(f.name)
			slot.filter_pats[i]  = strings.clone_to_cstring(f.pattern)
			slot.filter_list[i]  = sdl3.DialogFileFilter{
				name    = slot.filter_names[i],
				pattern = slot.filter_pats[i],
			}
		}

		append(&io.dialogs, slot)

		// `default_location` goes over to SDL as a cstring. Empty string
		// → nil so SDL picks its platform default (Documents, etc.).
		// The cstring lives on the slot until drain_io frees it after
		// the dialog closes, so SDL's C layer sees stable memory for
		// the lifetime of the picker.
		if v.default_location != "" {
			slot.default_location = strings.clone_to_cstring(v.default_location)
		}

		// Hand the untyped pending pointer to SDL as userdata. The C
		// callback writes success/cancel outcomes into it; drain_io
		// reads `done` next frame and fires the typed on_result.
		filters_ptr: [^]sdl3.DialogFileFilter
		if n > 0 { filters_ptr = raw_data(slot.filter_list) }
		switch v.kind {
		case .Open:
			sdl3.ShowOpenFileDialog(
				callback         = on_file_dialog_chosen,
				userdata         = cast(rawptr) &slot.pending,
				window           = io.window,
				filters          = filters_ptr,
				nfilters         = c.int(n),
				default_location = slot.default_location,
				allow_many       = false,
			)
		case .Save:
			sdl3.ShowSaveFileDialog(
				callback         = on_file_dialog_chosen,
				userdata         = cast(rawptr) &slot.pending,
				window           = io.window,
				filters          = filters_ptr,
				nfilters         = c.int(n),
				default_location = slot.default_location,
			)
		case .Open_Folder:
			sdl3.ShowOpenFolderDialog(
				callback         = on_file_dialog_chosen,
				userdata         = cast(rawptr) &slot.pending,
				window           = io.window,
				default_location = slot.default_location,
				allow_many       = false,
			)
		}
	}
}

// on_file_dialog_chosen is SDL3's picker completion callback. SDL
// invokes it on the main thread during event dispatch, which gives
// us a safe window to allocate on the persistent heap — but since
// the call is C-ABI there is no implicit Odin context, so we
// install the default one up front. `filelist` is NULL on error,
// `filelist[0]` is NULL on user cancellation, otherwise filelist[0]
// is the chosen path (UTF-8 cstring owned by SDL, valid only for
// the duration of this call — clone immediately).
@(private)
on_file_dialog_chosen :: proc "c" (
	userdata: rawptr,
	filelist: [^]cstring,
	filter:   c.int,
) {
	context = runtime.default_context()
	p := cast(^Dialog_Pending) userdata
	if filelist == nil || filelist[0] == nil {
		p.cancelled = true
	} else {
		cloned, _ := strings.clone(string(filelist[0]))
		p.path = cloned
	}
	p.done = true
}

// on_write_open kicks off the write step once the file is open. The
// Write_Pending pointer travels through user_data[0] across all three
// nbio ops so the completion path stays untyped (same rationale as
// on_read_complete).
@(private)
on_write_open :: proc(op: ^nbio.Operation) {
	p := cast(^Write_Pending) op.user_data[0]
	if op.open.err != nil {
		p.err  = op.open.err
		p.done = true
		return
	}
	p.handle = op.open.handle

	// An empty file is a perfectly valid save target, but nbio.write
	// asserts len(buf) > 0 (see prep_write source). Skip straight to
	// close when there's nothing to stream.
	bytes := write_bytes_from_pending(op)
	if len(bytes) == 0 {
		c := nbio.prep_close(op.open.handle, on_write_close)
		c.user_data[0] = cast(rawptr) p
		nbio.exec(c)
		return
	}

	w := nbio.prep_write(op.open.handle, 0, bytes, on_write_done, all = true)
	w.user_data[0] = cast(rawptr) p
	nbio.exec(w)
}

// Write_Slot_Header mirrors the leading fields of Write_Slot(Msg) so
// the untyped nbio callback path can reach `bytes` without knowing the
// Msg type parameter. Write_Slot's first field is `pending`, so a
// `^Write_Pending` and a `^Write_Slot_Header` pointing at the same
// allocation see the same layout up through `bytes`. `on_result`
// follows `bytes` in Write_Slot but is intentionally omitted here —
// typed dispatch happens in drain_io where Msg is in scope.
@(private)
Write_Slot_Header :: struct {
	pending: Write_Pending,
	path:    string,
	bytes:   []u8,
}

@(private)
write_bytes_from_pending :: proc(op: ^nbio.Operation) -> []u8 {
	p := cast(^Write_Pending) op.user_data[0]
	slot := cast(^Write_Slot_Header) p
	return slot.bytes
}

// on_write_done latches the write result and kicks the close step. We
// always close, even on write error, so the handle doesn't leak. Any
// write error takes precedence; a close-only failure is reported when
// the write itself succeeded.
@(private)
on_write_done :: proc(op: ^nbio.Operation) {
	p := cast(^Write_Pending) op.user_data[0]
	if op.write.err != nil {
		p.err = op.write.err
	}
	c := nbio.prep_close(p.handle, on_write_close)
	c.user_data[0] = cast(rawptr) p
	nbio.exec(c)
}

@(private)
on_write_close :: proc(op: ^nbio.Operation) {
	p := cast(^Write_Pending) op.user_data[0]
	if p.err == nil && op.close.err != nil {
		p.err = op.close.err
	}
	p.done = true
}

// on_read_complete is the nbio callback for read_entire_file. It is
// deliberately untyped — it writes into the pending slot and nothing
// else, so the per-Msg dispatch can happen later where the type
// parameter is in scope. `user_data` is the `&slot.pending` we passed
// when scheduling; casting it back is safe because the slot's address
// doesn't move (we heap-allocate it once).
@(private)
on_read_complete :: proc(
	user_data: rawptr,
	data:      []byte,
	err:       nbio.Read_Entire_File_Error,
) {
	p := cast(^Read_Pending) user_data
	p.done  = true
	p.bytes = data
	p.err   = err
}

// drain_io walks the in-flight list, dispatches any completed ops into
// `msgs`, and frees the drained slots. Called by `run` each frame
// after `nbio.tick` so completions land alongside timer- and input-
// driven msgs in the same update pass.
@(private)
drain_io :: proc(
	io:   ^Io_State($Msg),
	msgs: ^[dynamic]Msg,
) {
	i := 0
	for i < len(io.reads) {
		slot := io.reads[i]
		if !slot.pending.done {
			i += 1
			continue
		}

		result := File_Read_Result{
			path  = slot.path,
			bytes = slot.pending.bytes,
			err   = slot.pending.err.value,
		}
		append(msgs, slot.on_result(result))

		// The handler now owns `result.bytes` — we don't delete it.
		// The slot itself (and its path clone) is ours to free.
		delete(slot.path)
		free(slot)
		ordered_remove(&io.reads, i)
	}

	// Same drain pattern for writes — completion arrives via the
	// three-op chain landing `done=true` in on_write_close.
	j := 0
	for j < len(io.writes) {
		slot := io.writes[j]
		if !slot.pending.done {
			j += 1
			continue
		}

		result := File_Write_Result{
			path = slot.path,
			err  = slot.pending.err,
		}
		append(msgs, slot.on_result(result))

		delete(slot.path)
		delete(slot.bytes)
		free(slot)
		ordered_remove(&io.writes, j)
	}

	// And dialogs — `done` flips inside on_file_dialog_chosen, which
	// SDL runs on the main thread during its event pump (which
	// window_pump already called earlier this frame).
	k := 0
	for k < len(io.dialogs) {
		slot := io.dialogs[k]
		if !slot.pending.done {
			k += 1
			continue
		}

		result := File_Dialog_Result{
			path      = slot.pending.path,
			cancelled = slot.pending.cancelled,
		}
		append(msgs, slot.on_result(result))

		// The handler owns `result.path` — we don't free it here.
		// Everything else (filter bookkeeping, slot itself) is ours.
		dialog_slot_free_filters(slot)
		free(slot)
		ordered_remove(&io.dialogs, k)
	}
}
