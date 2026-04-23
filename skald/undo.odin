package skald

import "core:strings"

// Undo_Stack is the per-text_input edit history. Two stacks — past
// states on `undo`, reversed future states on `redo` — make the classic
// two-stack model: every mutation pushes the pre-edit state onto undo
// and clears redo; Ctrl-Z moves the current state onto redo and pops
// undo; Ctrl-Y does the reverse.
//
// Coalescing: a run of single-character typing should collapse into one
// undo step. `last_kind` records the kind of the previous frame's edit;
// when a new edit matches (both are typing, both are backspace, or both
// are delete) we don't push a new undo entry — the existing top already
// captures the pre-run state, which is what the user expects Ctrl-Z to
// land on. Pastes, cuts, selection-replacing edits, and caret-only
// moves all set `last_kind = Other`, which forbids further coalescing
// so the next typed character begins a fresh group.
//
// Memory: entry texts are cloned into `context.allocator` (the app's
// persistent heap). `undo_free` must be called when the widget dies so
// the strings don't leak. Today nothing in the framework detects widget
// death — a text_input that gets reshuffled or unmounted leaves its
// stack orphaned until process exit. For the common case (long-lived
// fields) this is a non-issue; the generalized cleanup ships alongside
// explicit-ID builders on the Later list.
Undo_Stack :: struct {
	undo:      [dynamic]Undo_Entry,
	redo:      [dynamic]Undo_Entry,
	last_kind: Edit_Kind,
}

// Undo_Entry snapshots the buffer and caret at a single historical
// point. `text` is owned by the entry (persistent-allocated clone) —
// `undo_free_entry` must be called to release it.
Undo_Entry :: struct {
	text:   string,
	cursor: int,
	anchor: int,
}

// Edit_Kind categorizes the mutation that produced an entry so the
// coalesce rule has something to compare against. Only the typing-like
// kinds (Type / Back / Del) participate in coalescing; everything else
// is treated as a hard break so the next edit starts a new group.
Edit_Kind :: enum u8 {
	None,  // no edit yet / reset
	Type,  // inserted typed characters
	Back,  // backspace
	Del,   // delete
	Other, // paste, cut, selection-replace, caret-only move
}

// undo_stack_new allocates a fresh stack on `context.allocator`. The
// caller stashes the pointer on the widget's state; the stack and its
// owned strings persist across frames.
undo_stack_new :: proc() -> ^Undo_Stack {
	s := new(Undo_Stack)
	return s
}

// undo_free releases a stack and every string in either stack. Safe on
// nil. Call when the widget is going away — not between frames, since
// the caller is still expecting to Ctrl-Z on the next frame.
undo_free :: proc(s: ^Undo_Stack) {
	if s == nil { return }
	for e in s.undo { delete(e.text) }
	for e in s.redo { delete(e.text) }
	delete(s.undo)
	delete(s.redo)
	free(s)
}

// undo_push records a pre-edit snapshot. `kind` is what the edit that's
// about to happen looks like — consecutive edits of the same typing-like
// kind coalesce by skipping the push, so the existing top of `undo`
// still captures the pre-run state.
//
// `text` is cloned internally; the caller retains ownership of the
// passed string (typically the app's persistent `value`).
undo_push :: proc(s: ^Undo_Stack, text: string, cursor, anchor: int, kind: Edit_Kind) {
	if s == nil { return }

	// New edit invalidates any redo future. Free the strings before
	// clearing so we don't leak.
	for e in s.redo { delete(e.text) }
	clear(&s.redo)

	// Coalesce with the previous entry when both sides are the same
	// typing-like kind. Other and None kinds never coalesce — they're
	// always hard breaks.
	coalesce := len(s.undo) > 0 &&
		s.last_kind == kind &&
		(kind == .Type || kind == .Back || kind == .Del)

	if !coalesce {
		cloned, _ := strings.clone(text)
		append(&s.undo, Undo_Entry{text = cloned, cursor = cursor, anchor = anchor})
	}
	s.last_kind = kind
}

// undo_mark_break sets `last_kind = Other` without pushing an entry.
// Called when the caret moves without a buffer edit (arrow key, click)
// so the next typed character starts a fresh coalesce group.
undo_mark_break :: proc(s: ^Undo_Stack) {
	if s == nil { return }
	s.last_kind = .Other
}

// undo_undo pops a state from `undo` onto `redo` and returns the
// popped entry to restore into the live buffer. The caller's "current"
// triple goes onto `redo` so Ctrl-Y can put it back. Returns ok=false
// when the undo stack is empty (nothing to revert).
//
// The returned `text` is still owned by the stack — callers should
// clone it rather than stash the pointer.
undo_undo :: proc(
	s: ^Undo_Stack,
	current_text: string, current_cursor, current_anchor: int,
) -> (text: string, cursor, anchor: int, ok: bool) {
	if s == nil || len(s.undo) == 0 { return "", 0, 0, false }

	last_i := len(s.undo) - 1
	entry  := s.undo[last_i]
	ordered_remove(&s.undo, last_i)

	current_clone, _ := strings.clone(current_text)
	append(&s.redo, Undo_Entry{
		text   = current_clone,
		cursor = current_cursor,
		anchor = current_anchor,
	})

	s.last_kind = .Other
	return entry.text, entry.cursor, entry.anchor, true
}

// undo_redo is undo_undo's mirror: pop from `redo`, push current onto
// `undo`, return the redo entry.
undo_redo :: proc(
	s: ^Undo_Stack,
	current_text: string, current_cursor, current_anchor: int,
) -> (text: string, cursor, anchor: int, ok: bool) {
	if s == nil || len(s.redo) == 0 { return "", 0, 0, false }

	last_i := len(s.redo) - 1
	entry  := s.redo[last_i]
	ordered_remove(&s.redo, last_i)

	current_clone, _ := strings.clone(current_text)
	append(&s.undo, Undo_Entry{
		text   = current_clone,
		cursor = current_cursor,
		anchor = current_anchor,
	})

	s.last_kind = .Other
	return entry.text, entry.cursor, entry.anchor, true
}
