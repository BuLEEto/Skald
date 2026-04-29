package skald

import "core:time"

// Widget_ID is a per-app identifier for a stateful widget. Two widgets
// with the same ID across frames are considered the same widget — their
// hover/press/focus state carries over. IDs are assigned by `widget_auto_id`
// during view construction, which means they are *positional*: the first
// button in the view tree gets id 1, the second gets 2, and so on.
//
// Positional IDs are stable as long as the view tree shape stays stable.
// When a widget's position in the tree would change (e.g. a list of
// buttons with removable rows), callers should provide an explicit id via
// builders that accept one — that's cheaper than re-stitching state on
// every edit. Explicit IDs are deferred until the first widget needs them.
Widget_ID :: distinct u64

// Widget_State is the per-widget state that must persist across frames.
// Fields used by only one widget kind (like `cursor_pos` for text_input)
// live here regardless — the extra bytes aren't worth a variant union.
//
//   last_rect  — the widget's rendered bounding box from the previous
//                frame. Builders during view construction hit-test this
//                frame's input against it. Using the previous frame's
//                rect means one-frame lag on hit testing, but it avoids
//                running layout twice per frame; under normal interaction
//                rates it's invisible.
//   pressed    — true while a mouse button is held down inside the
//                widget's bounds. Cleared on release.
//   cursor_pos — byte index into the widget's text value. Used by
//                text_input to remember where the caret sits across
//                frames; ignored by other widgets.
//   scroll_y   — current vertical scroll offset for View_Scroll. The
//                renderer clamps and writes this back after measuring
//                content against viewport so a fast wheel tick doesn't
//                leave the stored value drifting out of range.
//   content_h  — cached content height from the previous frame's render
//                pass. Scroll builders read this to reconstruct scrollbar
//                geometry for hit-testing mouse clicks and drags without
//                re-measuring the child tree.
//   drag_anchor — generic f32 scratch slot for widgets that need to
//                remember a coordinate at the start of a drag. Scrollbar
//                uses it for the grab offset within the thumb.
// Widget_Kind discriminates what sort of widget currently owns a given
// Widget_ID. Positional IDs can be reshuffled from one frame to the next
// when the tree's shape changes (a dropdown opens, a row is removed),
// which would otherwise leak a dropdown's `open=true` or a slider's
// drag offset into whatever widget inherited the slot. Comparing the
// stored kind against the caller's expected kind lets `widget_get`
// zero out state that belonged to a different widget.
Widget_Kind :: enum u8 {
	None,
	Button,
	Text_Input,
	Checkbox,
	Radio,
	Toggle,
	Slider,
	Scroll,
	Select,
	Tooltip,
	// Click_Zone is the passthrough wrapper emitted by `zone` and
	// `right_click_zone`. It carries no visual state of its own — the
	// slot exists so the renderer can stamp `last_rect` for builders
	// that need to hit-test clicks against the wrapped child's area
	// (context-menu triggers, outside-click dismissal for popovers).
	Click_Zone,
	Dialog,
	Split,
	Link,
	Toast,
	Number_Input,
	Date_Picker,
	Time_Picker,
	Menu_Bar,
	Tree,
	Color_Picker,
	Combobox,
	// Canvas is the framework escape hatch: a rectangular slot whose
	// pixels come from a user draw callback. It carries no interactive
	// state of its own, but reserves a Widget_Kind so apps can hand it
	// an ID and read `widget_last_rect` on the next frame for hit-
	// testing clicks, drags, and pen input.
	Canvas,
	// Command_Palette is the Ctrl+K-style fuzzy-match overlay that
	// lists every action a menu_bar exposes, filtered by a query.
	// State stores the query in `text_buffer`, the caret in
	// `cursor_pos`, and the highlighted-item index in `drag_donor`
	// (same convention as combobox).
	Command_Palette,
}

// Widget_State is the per-widget scratch record the framework stashes
// between frames. Every interactive widget owns one entry in the
// runtime's widget store keyed by `Widget_ID`; the widget re-reads its
// previous row each frame with `widget_get` and writes it back with
// `widget_set`. Fields are a grab bag because one struct covers the
// whole widget catalog — most widgets only touch a handful. Rows whose
// `last_frame` wasn't bumped this frame are reaped by the runtime, so
// widgets that carry state across frames must re-stamp it even on
// no-op frames (see: "Stateful widgets must widget_set every frame").
Widget_State :: struct {
	kind:        Widget_Kind,
	last_rect:   Rect,
	// last_frame is the frame counter value at which this state was
	// last written by a widget builder. It disambiguates positional-ID
	// reshuffles where a slot is inherited by a *different* widget of
	// the same kind: if the state wasn't written last frame, the widget
	// that owned it has moved or disappeared and we must not inherit
	// its last_rect / open / press / etc. Kind-tagging alone isn't
	// enough — two Selects reshuffling into each other's slots would
	// otherwise swap open state and hit-test rects silently.
	last_frame:  u64,
	pressed:     bool,
	cursor_pos:  int,
	// selection_anchor is the other end of a text selection range.
	// The selected range is [min(anchor, cursor_pos), max(anchor, cursor_pos));
	// when the two are equal there's no selection, just a caret.
	selection_anchor: int,
	// mouse_selecting latches when a text_input receives a press — while
	// it's true and the mouse button is still held, drags extend the
	// selection. Cleared on release. Living on Widget_State (rather than
	// recomputing from mouse_buttons[.Left]) avoids mistaking a click
	// that started *elsewhere* for a drag over this widget.
	mouse_selecting: bool,
	scroll_y:    f32,
	content_h:   f32,
	drag_anchor: f32,
	// drag_donor is the column index a table resize handle donates
	// width to/from for the active drag. Picked at latch (next fixed
	// column, else any flex column, else -1) and held here on the
	// handle's Widget_State so the donor stays consistent across the
	// whole gesture — a donor picked fresh each frame would flip away
	// once a flex donor gets locked to fixed. Only meaningful while
	// `pressed` is true; when the handle isn't latched this is just
	// the default 0 and is ignored.
	drag_donor: int,
	open:        bool, // popover-style widgets (select/combo) use this to toggle their overlay
	// anchor_pos remembers a cursor-space point for widgets whose popover
	// position is set by the triggering gesture — context_menu stores the
	// right-click coords here so the popover opens at the click, not at
	// the widget's top-left. Only meaningful when `open` is true; ignored
	// otherwise.
	anchor_pos:  [2]f32,
	// anim_t and anim_prev_ns drive per-widget open/close animations.
	// `anim_t` is the current interpolation factor in [0, 1] — 0 = fully
	// closed, 1 = fully open. `widget_anim_step` advances it toward the
	// target (derived from `open`) at a wall-clock rate and schedules
	// the next frame via `widget_request_frame_at` until the target is
	// reached. `anim_prev_ns` holds the wall-clock tick of the last
	// step so the next delta is computed correctly regardless of frame
	// rate. Widgets read `anim_t` to fade their overlay alpha.
	anim_t:        f32,
	anim_prev_ns:  i64,
	// was_focused is the previous frame's focus state for this widget.
	// Builders that seed a draft from the app's value on focus-enter (e.g.
	// number_input's text_buffer) check `focused && !was_focused` — that
	// edge fires only on the frame focus is acquired, so seeding doesn't
	// stomp on the user's in-progress edit when the draft happens to be
	// empty.
	was_focused: bool,
	// hover_start_ns is the wall-clock nanosecond value at which the
	// current hover began, or 0 when the widget is not hovered. The
	// tooltip builder uses it to wait out a show-delay before emitting
	// the popover — clearing it on mouse-exit hides the tooltip
	// immediately rather than on the next intent.
	hover_start_ns: i64,
	// visible_start_ns is the wall-clock nanosecond at which the toast
	// first rendered visible. The toast builder uses it to fire the
	// app's on_close callback once `dismiss_after` seconds elapse; 0
	// means the widget is not currently visible or has not yet been
	// seen this visibility cycle.
	visible_start_ns: i64,
	// undo is the text_input's edit history. Allocated lazily on the
	// first edit, owned by the widget; the stack and its stored strings
	// live on the persistent heap so Ctrl-Z still works after the frame
	// arena resets.
	undo:        ^Undo_Stack,
	// virtual_heights is variable-height `virtual_list`'s per-row height
	// cache. Indexed by row index, lives on the persistent heap, owned
	// by this widget slot. Allocated lazily on the first variable-height
	// pass and resized in place as rows get measured. Freed when the slot
	// is reused by another widget kind or when the store is destroyed.
	virtual_heights: ^[dynamic]f32,
	// text_buffer is a widget-owned persistent string draft. Used by
	// `number_input` to hold what the user is typing while the field is
	// focused, so partial states like "1." or "-" survive between frames
	// before they parse to a valid number. Allocated on the persistent
	// heap (context.allocator); freed when the slot is reused or the
	// store is destroyed.
	text_buffer: string,
	// nav_year / nav_month track which month grid is currently displayed
	// in a date_picker popover. Seeded from the widget's `value` (or
	// defaulted) on open; mutated directly by the builder when the user
	// clicks the prev/next header arrows. Ignored by other widget kinds.
	nav_year:    int,
	nav_month:   int,
}

// Widget_Store owns per-widget state plus single-focus bookkeeping. One
// instance lives for the lifetime of `run`.
//
//   states           — keyed by Widget_ID, preserved across frames.
//   auto_id          — reset to zero at the top of every frame so the
//                      same widget at the same tree position gets the
//                      same id each frame.
//   focused_id       — the widget currently receiving keyboard events
//                      (0 when nothing is focused). Only one widget can
//                      be focused at a time — that's enough for text
//                      inputs and is how every native toolkit models it.
//   wants_text_input — set by focused text-entry widgets during view to
//                      tell the run loop to enable SDL's IME. Reset to
//                      false at the top of each frame.
// Scroll_Rect tags a scrollable viewport with its widget id so scroll
// hand-off to the innermost hovered container can identify winners by
// rect containment + id match.
Scroll_Rect :: struct {
	id:   Widget_ID,
	rect: Rect,
}

// Focusable_Entry pairs a focusable widget's id with its caller-assigned
// tab_index. `tab_index = 0` means "natural order" — the entry keeps the
// position it was registered in, matching the pre-tab_index behaviour.
// Positive values move the entry earlier in the Tab ring in ascending
// order. Matches HTML's `tabindex` semantics minus the negative-value
// "not focusable" case (Skald uses `disabled` / `disabled` flags for
// that, not a magic index).
Focusable_Entry :: struct {
	id:        Widget_ID,
	tab_index: int,
}

Widget_Store :: struct {
	states:            map[Widget_ID]Widget_State,
	auto_id:           Widget_ID,
	// auto_id_scope, when non-zero, salts every positional widget id
	// produced by `widget_auto_id` so widgets built inside a nested
	// scope (typically a virtual_list/table row_builder) can't collide
	// with widgets outside the scope, even as the visible window slides.
	// Virtual_list / table push the row index (hashed with the list id)
	// before invoking row_builder and pop afterward, so auto-IDs inside
	// a row get `scope ~ counter | EXPLICIT_BIT` — stable per row, not
	// per visible-index. Zero means "no scope" and produces the old
	// plain counter behavior at the top level.
	auto_id_scope:     u64,
	focused_id:        Widget_ID,
	// focus_return_id is the widget to re-focus when an ephemeral
	// UI surface (a dialog, the command palette) closes. Set by the
	// opener (which snapshots `focused_id` before taking focus for
	// itself); cleared by the closer after it restores focus. Keeps
	// "I pressed Ctrl+K, searched, hit Esc, kept typing where I was"
	// as seamless as a native app.
	focus_return_id:   Widget_ID,
	wants_text_input:  bool,
	// frame is a monotonically increasing counter bumped by
	// widget_store_frame_reset. Widget_State carries the frame value it
	// was last written at; widget_get compares against (frame - 1) to
	// detect slots whose previous occupant moved between frames.
	frame:             u64,

	// focusables collects, in construction order, every widget that
	// advertised itself as Tab-reachable this frame. Cleared at the top
	// of the frame so the list always reflects the current view tree.
	// The run loop reads this between pump and view to translate
	// Tab / Shift-Tab presses into focus moves.
	focusables:        [dynamic]Focusable_Entry,

	// modal_rect is the card rect of the currently-rendered dialog, in
	// framebuffer pixels. Written by the dialog's renderer during
	// render_view and read at the top of the next frame by the run loop:
	//
	//   * Tab / Shift-Tab filter focusables by rect-containment so focus
	//     traps inside the dialog (focus trap has one-frame lag — fine).
	//   * The mouse preprocessor zeros `mouse_pressed[.Left]` for presses
	//     that land outside the rect so widgets underneath the scrim
	//     can't fire. Backdrop clicks are swallowed but don't dismiss —
	//     Escape + explicit buttons are the only dismissal paths.
	//
	// Cleared in widget_store_frame_reset so a closed dialog doesn't
	// leave a stale rect haunting the focus filter. `modal_rect_prev`
	// holds last frame's value (rotated at frame reset) so widgets
	// that want to gate their own hit-testing on "is there a modal
	// this frame" — like `rect_hovered` — can see it from the view
	// phase, when this-frame's `modal_rect` is still 0.
	modal_rect:        Rect,
	modal_rect_prev:   Rect,

	// overlay_rects collects the screen-space rects of currently-open
	// popovers (color_picker, select, date_picker, menu, etc) stamped
	// during builder or render. Unlike modal_rect, these do NOT trap
	// focus or swallow outside clicks — an outside click should still
	// reach the popover's builder so it can dismiss. What they DO give
	// is a way for underlying widgets (infinite canvas, drag-to-draw
	// tools) to ask "was the mouse over an overlay last frame?" before
	// reacting to a press — otherwise a color-swatch click through the
	// popover also starts a stroke on the canvas underneath.
	//
	// Two-buffer swap: `_prev` is what last frame stamped, reset at the
	// top of this frame to whatever was in `overlay_rects`. Apps read
	// the prev list via `mouse_over_overlay(ctx)` — widgets consult it
	// early in view (before the popover rebuilds) with a one-frame lag,
	// the same contract every other rect-based gate in the framework
	// uses (last_rect, modal_rect_prev, …).
	overlay_rects:      [dynamic]Rect,
	overlay_rects_prev: [dynamic]Rect,

	// scroll_rects tracks every scrollable container's viewport rect this
	// frame, in render order (outer → inner). `scroll_rects_prev` is the
	// previous frame's list. `scroll_advance` consults the prev list to
	// decide whether *it* is the innermost hovered scroller — if not, a
	// deeper widget will handle this frame's wheel delta, so it refuses
	// to consume. Nested scrolls (a virtual_list inside a page-level
	// scroll) thus route the wheel to the innermost-hovered container,
	// matching native toolkit behaviour. One-frame lag is harmless for
	// scroll UX and avoids a second render pass.
	scroll_rects:      [dynamic]Scroll_Rect,
	scroll_rects_prev: [dynamic]Scroll_Rect,

	// next_frame_deadline_ns is the wall-clock nanosecond at which some
	// widget needs the run loop to render another frame — a tooltip's
	// hover-delay expiry, a toast's auto-dismiss, an indeterminate
	// progress bar's next animation tick. Reset to 0 at the top of each
	// frame; widgets set it via `widget_request_frame_at` during view.
	// The run loop uses this to bound its idle WaitEventTimeout so lazy
	// redraw still wakes up for time-driven widgets.
	//
	// Units match `time.now()._nsec`. A value of 0 means "no deadline".
	next_frame_deadline_ns: i64,

	// Debug inspector state (F12 overlay). Only read/written by the
	// run loop and the when-ODIN_DEBUG-gated inspector renderer; in
	// release builds nothing flips the flag and the panel never draws.
	// Kept on Widget_Store because it's per-window.
	//
	// `inspector_pos` is the panel's top-left in logical pixels.
	// Initial zero is remapped to the upper-right corner on first
	// render; afterwards the user can drag the title bar to move it.
	//
	// `inspector_pinned_*` snapshots whichever widget was hovered
	// when the user pressed P so the readout stops tracking the
	// cursor while you move over to test a button. Press P again to
	// unpin.
	inspector_open:              bool,
	inspector_pos:               [2]f32,
	inspector_dragging:          bool,
	inspector_drag_offset:       [2]f32,
	inspector_pinned:            bool,
	inspector_pinned_id:         Widget_ID,
	inspector_pinned_kind:       Widget_Kind,
	inspector_pinned_rect:       Rect,
}

// widget_request_frame_at tells the run loop to render another frame no
// later than `wake_ns` wall-clock time (in the same units as
// `time.now()._nsec`). Called by time-driven widgets — tooltips, toast
// dismissals, indeterminate progress bars — so lazy redraw doesn't
// starve their timers.
widget_request_frame_at :: proc(ctx: ^Ctx($Msg), wake_ns: i64) {
	cur := ctx.widgets.next_frame_deadline_ns
	if cur == 0 || wake_ns < cur {
		ctx.widgets.next_frame_deadline_ns = wake_ns
	}
}

// widget_anim_step advances `st.anim_t` toward `target` (expected 0 or 1)
// over `duration_s` seconds, using wall-clock deltas so animation speed
// is framerate-independent. Returns an eased value in [0, 1] suitable
// for fade alpha. While the animation is mid-tween it schedules the
// next frame (~16 ms out) via `widget_request_frame_at`, so lazy redraw
// keeps ticking until the target is reached.
//
// Callers: popover builders that want their overlay to fade in on open
// and fade out on close. Typical use:
//
//     target: f32 = st.open ? 1 : 0
//     anim := widget_anim_step(ctx, &st, target, 0.15)
//     overlay(..., opacity = anim, ...)
//
// The caller still owns `widget_set(ctx, id, st)` — this proc mutates
// `st.anim_t` and `st.anim_prev_ns` in place but does not write back
// to the store.
widget_anim_step :: proc(ctx: ^Ctx($Msg), st: ^Widget_State, target: f32, duration_s: f32) -> f32 {
	now_ns := time.now()._nsec
	prev := st.anim_prev_ns
	st.anim_prev_ns = now_ns

	// First frame after a long idle: snap anim_prev_ns but don't jump the
	// value — just start ticking from here. Also protects against huge
	// dt if the app was backgrounded.
	dt: f32 = 0
	if prev != 0 {
		delta_ns := now_ns - prev
		if delta_ns > 0 && delta_ns < 200_000_000 { // clamp at 200 ms
			dt = f32(f64(delta_ns) / 1_000_000_000.0)
		}
	}

	t := st.anim_t
	if duration_s <= 0 {
		t = target
	} else {
		step := dt / duration_s
		if t < target {
			t += step
			if t > target { t = target }
		} else if t > target {
			t -= step
			if t < target { t = target }
		}
	}
	st.anim_t = t

	if t != target {
		widget_request_frame_at(ctx, now_ns + 16_000_000)
	}

	// Cubic ease-out: 1 - (1 - t)^3. Snappy open, gentle settle.
	inv := 1 - t
	return 1 - inv * inv * inv
}

// widget_store_init allocates the backing maps and lists a Widget_Store
// needs. `run` calls this once at startup; apps rarely touch it directly.
widget_store_init :: proc(ws: ^Widget_Store) {
	ws.states             = make(map[Widget_ID]Widget_State)
	ws.auto_id            = 0
	ws.auto_id_scope      = 0
	ws.focused_id         = 0
	ws.frame              = 1 // so first-frame writes stamp a non-zero value
	ws.focusables         = make([dynamic]Focusable_Entry)
	ws.overlay_rects      = make([dynamic]Rect)
	ws.overlay_rects_prev = make([dynamic]Rect)
	ws.scroll_rects       = make([dynamic]Scroll_Rect)
	ws.scroll_rects_prev  = make([dynamic]Scroll_Rect)
}

// widget_store_destroy frees per-widget heap resources (undo stacks,
// height caches) and tears down the backing map. `run` calls this on
// shutdown; apps rarely touch it directly.
widget_store_destroy :: proc(ws: ^Widget_Store) {
	// Free per-slot heap resources before tearing down the map. Match
	// the allocation sites: undo stacks for text inputs, height caches
	// for variable-height virtual lists.
	for _, st in ws.states {
		if st.undo != nil { undo_free(st.undo) }
		if st.virtual_heights != nil {
			delete(st.virtual_heights^)
			free(st.virtual_heights)
		}
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
	}
	delete(ws.states)
	delete(ws.focusables)
	delete(ws.overlay_rects)
	delete(ws.overlay_rects_prev)
	delete(ws.scroll_rects)
	delete(ws.scroll_rects_prev)
	ws.states = nil
}

// widget_store_frame_reset is called by `run` at the top of each frame so
// auto-IDs start from zero again and per-frame flags (like wants_text_input)
// clear. The persistent fields — state map, focused_id — are untouched.
@(private)
widget_store_frame_reset :: proc(ws: ^Widget_Store) {
	ws.auto_id                = 0
	ws.auto_id_scope          = 0
	ws.wants_text_input       = false
	ws.next_frame_deadline_ns = 0
	ws.frame                 += 1
	clear(&ws.focusables)
	// Swap the overlay buffers so this frame's builders/renderers can
	// push into a fresh `overlay_rects`, while `overlay_rects_prev`
	// (what they published last frame) is what mouse_over_overlay reads
	// this frame.
	ws.overlay_rects, ws.overlay_rects_prev = ws.overlay_rects_prev, ws.overlay_rects
	clear(&ws.overlay_rects)
	// Same swap-and-clear for scroll_rects so scroll_advance can consult
	// last frame's list while stamping this frame's.
	ws.scroll_rects, ws.scroll_rects_prev = ws.scroll_rects_prev, ws.scroll_rects
	clear(&ws.scroll_rects)
	// modal_rect rotates: last frame's value moves into `_prev` (so
	// widgets can gate their hit-testing on it during view), then this
	// frame's is cleared and re-stamped by the dialog renderer if still
	// open.
	ws.modal_rect_prev = ws.modal_rect
	ws.modal_rect      = {}
	if ws.frame % WIDGET_EVICT_INTERVAL == 0 {
		widget_store_evict_stale(ws)
	}
}

// Eviction cadence for the states map. Without a sweep, a virtualized list
// of 100 000 rows with per-row hash_ids accumulates 100 000 persistent
// entries the moment the user scrolls through them once — even if none of
// that state is ever read again. Sweep periodically (not every frame, to
// amortize the O(n) scan) and drop entries whose `last_frame` is well in
// the past. The max-age is long enough that a collapsed panel or a
// scrolled-away row can return within a minute or two without losing any
// hover/press/selection/undo state; shorter would make eviction user-
// visible, longer would let the map grow without bound in practice.
WIDGET_EVICT_INTERVAL :: 600    // frames between sweeps (≈10 s @60 fps)
WIDGET_EVICT_MAX_AGE  :: 7200   // frames of inactivity before eviction (≈2 min)

@(private)
widget_store_evict_stale :: proc(ws: ^Widget_Store) {
	// Collect victims first; deleting while iterating a map is asking
	// for iteration-order weirdness.
	victims := make([dynamic]Widget_ID, 0, 16, context.temp_allocator)
	for id, st in ws.states {
		if id == ws.focused_id { continue }
		if st.last_frame + WIDGET_EVICT_MAX_AGE < ws.frame {
			append(&victims, id)
		}
	}
	for id in victims {
		st := ws.states[id]
		if st.undo != nil { undo_free(st.undo) }
		if st.virtual_heights != nil {
			delete(st.virtual_heights^)
			free(st.virtual_heights)
		}
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
		delete_key(&ws.states, id)
	}
}

// widget_auto_id returns the next positional widget id. Builders call this
// once per stateful widget they construct. When `auto_id_scope` is set
// (virtual_list / table pushes it before calling row_builder), the
// returned id is salted with the scope so positional IDs inside the row
// can't collide with IDs outside it — and stay stable per row even when
// the visible window slides. Marks scoped IDs explicit so kind-mismatch
// cleanup treats them as deliberate.
widget_auto_id :: proc(ctx: ^Ctx($Msg)) -> Widget_ID {
	ctx.widgets.auto_id += 1
	if ctx.widgets.auto_id_scope != 0 {
		// Mix the per-row scope with the per-call counter through a
		// golden-ratio multiply so two small inputs (scope=1 counter=2 vs
		// scope=2 counter=1) don't XOR-collide into the same id. Plain
		// XOR was fine when both inputs were already hashes, but apps
		// passing small ints as scope keys (`row.id`) plus the
		// inherently-small counter caused widgets to alias across rows
		// — selects opening then immediately re-closing, number_inputs
		// stealing each other's draft buffers, etc.
		mixed := ctx.widgets.auto_id_scope ~ (u64(ctx.widgets.auto_id) * 0x9e3779b97f4a7c15)
		return Widget_ID(mixed) | WIDGET_ID_EXPLICIT_BIT
	}
	return ctx.widgets.auto_id
}

// widget_make_sub_id derives a stable child id from a parent id and a
// numeric sub-key. Use this for the sub-ids inside a widget that has
// per-option, per-row, or per-cell internals — each star of a `rating`,
// each section header of an `accordion`, each option button of a
// `select`. The result has the explicit bit set so kind-mismatch
// cleanup treats it as deliberate.
//
// Mixing math: each input goes through its own multiplicative constant
// then the two are added (mod 2^64). No XOR. This breaks the *whole
// class* of cancellation bugs we hit twice during development:
//
//   1. Raw `parent ~ (i+1)` aliased small ints across rows.
//   2. `parent ~ (i+1) * GR` (the leaf-only fix) was safe at one
//      level but composed unsafely with the framework's
//      `widget_auto_id`, which XORs the same `counter * GR` term
//      again — row N at counter N collapsed to `parent` because the
//      GR terms cancel.
//
// Multiplication-then-addition with two distinct constants has no
// algebraic shortcut to cancel, regardless of whether the result is
// later passed through `widget_scope_push` (which multiplies by
// `SCOPE_MULTIPLIER`) or composed with itself.
widget_make_sub_id :: proc(parent: Widget_ID, key: u64) -> Widget_ID {
	mixed := u64(parent) * 0x9e3779b97f4a7c15 + key * 0xbf58476d1ce4e5b9
	return Widget_ID(mixed) | WIDGET_ID_EXPLICIT_BIT
}

// Widget_Scope_Saved captures the caller's auto-id counter + scope at
// `widget_scope_push` time so `widget_scope_pop` can restore exactly
// what the outer builder was seeing — nesting scopes (a list row
// containing another list) just works.
Widget_Scope_Saved :: struct {
	scope:   u64,
	counter: Widget_ID,
}

// SCOPE_MULTIPLIER salts user-supplied scope keys before they meet the
// auto-id counter. Using a distinct constant from the counter's
// `0x9e3779b97f4a7c15` (golden ratio) prevents XOR self-cancellation
// when callers pass keys that already encode the same multiplier.
SCOPE_MULTIPLIER :: u64(0x94d049bb133111eb)

// widget_scope_push opens a per-row (or other stable-key) id scope. All
// `widget_auto_id` calls between push and pop produce IDs salted with
// `key`, so widgets built inside the scope can't collide with widgets
// outside it. Pair with `widget_scope_pop`, passing the returned value
// (or wrap the call site in a defer).
//
//     saved := skald.widget_scope_push(ctx, hash_id(row_key))
//     defer skald.widget_scope_pop(ctx, saved)
//     // …build widgets that should be scoped to `row_key`…
//
// Implementation note: the user's `key` is multiplied through
// `SCOPE_MULTIPLIER` before being stored. `widget_auto_id` later
// combines that scope with `counter * 0x9e3779b97f4a7c15`. Distinct
// multipliers stop XOR self-cancellation when callers pass keys that
// already encode `parent ~ (idx * 0x9e37…)` — that pattern would
// otherwise alias row N's auto-id at counter N to row 0's auto-id at
// counter 0 (= the parent), silently sharing widget state across
// rows. Surfaced by an order-table whose row-N checkbox at counter 1
// collided with row-2's number_input at counter 2.
widget_scope_push :: proc(ctx: ^Ctx($Msg), key: u64) -> Widget_Scope_Saved {
	saved := Widget_Scope_Saved{
		scope   = ctx.widgets.auto_id_scope,
		counter = ctx.widgets.auto_id,
	}
	mixed: u64
	if key != 0 { mixed = key * SCOPE_MULTIPLIER }
	ctx.widgets.auto_id_scope = mixed
	ctx.widgets.auto_id       = 0
	return saved
}

// widget_scope_pop restores the outer scope captured by the matching
// push. Must be called on every path out of the scope (defer is the
// common pattern).
widget_scope_pop :: proc(ctx: ^Ctx($Msg), saved: Widget_Scope_Saved) {
	ctx.widgets.auto_id_scope = saved.scope
	ctx.widgets.auto_id       = saved.counter
}

// WIDGET_ID_EXPLICIT_BIT marks IDs produced by `hash_id` (or any caller
// passing an explicit key) so they can't collide with positional
// auto-IDs. widget_auto_id increments from 1 and in practice never
// reaches values with the high bit set, so flipping the top bit on
// explicit IDs partitions the namespace cleanly.
WIDGET_ID_EXPLICIT_BIT :: Widget_ID(1) << 63

// hash_id turns a stable string key into a Widget_ID. The returned ID
// keeps its identity across frames even when the widget's position in
// the view tree changes — the critical property for list rows that can
// be reordered, filtered, or removed without having their state
// (pressed, focused, scroll offset, undo stack) bleed into a neighbor.
//
//     for item, i in items {
//         id := skald.hash_id(item.key)
//         skald.row(
//             skald.button(ctx, item.label, Msg.Click,
//                 id = id, ...),
//             ...,
//         )
//     }
//
// FNV-1a 64-bit — fast, no dependencies, more than enough collision
// resistance for typical key counts in a GUI.
hash_id :: proc(key: string) -> Widget_ID {
	h := u64(0xcbf29ce484222325)
	for b in transmute([]u8)key {
		h ~= u64(b)
		h *= 0x100000001b3
	}
	return Widget_ID(h) | WIDGET_ID_EXPLICIT_BIT
}

// widget_resolve_id picks between an explicitly-passed id and the next
// positional auto-id. Builders call it once via `id := widget_resolve_id(ctx, id)`
// so existing `id` references in the body stay unchanged — the local
// shadow of the param turns into a real Widget_ID in one step.
@(private)
widget_resolve_id :: proc(ctx: ^Ctx($Msg), explicit: Widget_ID) -> Widget_ID {
	if explicit != 0 { return explicit }
	return widget_auto_id(ctx)
}

// widget_get returns the stored state for `id`, or the zero value if the
// widget wasn't seen last frame (e.g. first frame after it appeared).
// `kind` is the caller's widget type; if the slot currently stores state
// for a different kind (because positional IDs reshuffled), the returned
// state is reset so stale flags like `open` / `pressed` don't bleed into
// the new occupant. The kind is stamped on the returned state so a
// subsequent `widget_set` preserves it.
widget_get :: proc(ctx: ^Ctx($Msg), id: Widget_ID, kind: Widget_Kind) -> Widget_State {
	st := ctx.widgets.states[id]
	// Two tests catch slot reuse between widgets:
	//   1. kind mismatch — the slot now holds a different widget kind.
	//   2. stale generation — the slot wasn't written this frame or
	//      last frame, so whoever owned it has moved/disappeared and
	//      we must not inherit their last_rect / open / press flags.
	//      (Same-frame re-reads are fine — widgets like virtual_list
	//      may widget_get, widget_set, then call into scroll_advance
	//      which does its own widget_get on the same id.)
	if st.kind != kind || st.last_frame + 1 < ctx.widgets.frame {
		// Release any heap resources the prior occupant owned so we
		// don't leak when positional-ID reshuffle hands the slot to a
		// different widget kind. undo_free is safe on nil.
		if st.undo != nil { undo_free(st.undo); st.undo = nil }
		if st.virtual_heights != nil {
			delete(st.virtual_heights^)
			free(st.virtual_heights)
		}
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
		st = Widget_State{kind = kind}
	}
	return st
}

// widget_set writes the widget's state back into the store. Builders
// typically call this after recomputing hover/press state for the frame.
// Stamps the current frame counter so `widget_get` can tell next frame
// whether this slot was actually written this frame.
widget_set :: proc(ctx: ^Ctx($Msg), id: Widget_ID, st: Widget_State) {
	st := st
	st.last_frame = ctx.widgets.frame
	ctx.widgets.states[id] = st
}

// widget_has_focus reports whether `id` currently owns keyboard focus.
widget_has_focus :: proc(ctx: ^Ctx($Msg), id: Widget_ID) -> bool {
	return ctx.widgets.focused_id == id
}

// widget_focus gives keyboard focus to `id`. Pass 0 to clear focus
// entirely. Widgets typically call this from a mouse-down handler once
// they've confirmed the click landed inside their bounds.
widget_focus :: proc(ctx: ^Ctx($Msg), id: Widget_ID) {
	ctx.widgets.focused_id = id
}

// is_typing reports whether a text-input widget currently owns keyboard
// focus. Apps use it to gate unmodified letter/digit shortcuts so e.g.
// typing "G" into a rename field doesn't also fire a global Grid_Toggle
// binding. Reads the focused widget's stored kind, which persists across
// frame_reset — unlike `wants_text_input`, which gets cleared each frame
// and only becomes true later in view when the text_input mounts.
is_typing :: proc(ctx: ^Ctx($Msg)) -> bool {
	fid := ctx.widgets.focused_id
	if fid == 0 { return false }
	return ctx.widgets.states[fid].kind == .Text_Input
}

// mouse_over_overlay reports whether the pointer is currently over any
// open popover (color_picker, select, date_picker, menu, …). Canvas-like
// widgets that react to presses (paint strokes, spatial drags) should
// gate on `!mouse_over_overlay(ctx)` so a click that selected a colour
// in a popover floating above the canvas doesn't also start a stroke.
// Reads the previous frame's stamped overlay_rects — one-frame lag, the
// same contract every other rect-based gate uses.
mouse_over_overlay :: proc(ctx: ^Ctx($Msg)) -> bool {
	p := ctx.input.mouse_pos
	for rr in ctx.widgets.overlay_rects_prev {
		if rect_contains_point(rr, p) { return true }
	}
	return false
}

// widget_stamp_overlay_rect is called from a popover widget's renderer
// (color_picker, select, date_picker, …) to publish the card's screen-
// space rect for this frame. Reset at the top of every frame, so a
// closed popover naturally stops appearing in the list. Pushing an empty
// or negative-sized rect is a no-op.
widget_stamp_overlay_rect :: proc(ws: ^Widget_Store, r: Rect) {
	if r.w <= 0 || r.h <= 0 { return }
	append(&ws.overlay_rects, r)
}

// widget_record_rect is called by the renderer once the widget has been
// placed in window coordinates. The rect is what hit-testing next frame
// will check against.
@(private)
widget_record_rect :: proc(ws: ^Widget_Store, id: Widget_ID, rect: Rect) {
	st := ws.states[id]
	st.last_rect = rect
	ws.states[id] = st
}

// rect_contains_point returns true if `p` lies inside `r` (inclusive on
// top/left, exclusive on bottom/right). Used for mouse hit testing.
rect_contains_point :: proc(r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

// rect_contains_rect returns true if `outer` fully covers `inner`. Used
// by rect_hovered to decide whether a widget is inside (= still hoverable)
// or underneath (= should suppress hover) an open popover.
rect_contains_rect :: proc(outer, inner: Rect) -> bool {
	return inner.x >= outer.x && inner.x + inner.w <= outer.x + outer.w &&
	       inner.y >= outer.y && inner.y + inner.h <= outer.y + outer.h
}

// rect_hovered is the hover-aware variant of rect_contains_point: returns
// true when the mouse is inside `rect` AND is not over an open popover
// that sits on top of this widget. Widgets beneath an open dropdown /
// date picker / combobox etc. still compute hovered = true if they only
// check `rect_contains_point`, producing a subtle bleed-through glow.
// `rect_hovered` consults the previous frame's `overlay_rects_prev` and
// suppresses the hover when one of those overlays contains the mouse
// *without* fully containing the widget's rect (so a widget that IS an
// overlay child stays hoverable).
//
// Use this in every widget builder's hover check:
//
//     hovered := rect_hovered(ctx, st.last_rect)
//
// instead of the old `rect_contains_point(st.last_rect, ctx.input.mouse_pos)`.
rect_hovered :: proc(ctx: ^Ctx($Msg), rect: Rect) -> bool {
	mp := ctx.input.mouse_pos
	if !rect_contains_point(rect, mp) { return false }
	// Modal dialog: widgets whose rect isn't fully inside the modal card
	// shouldn't hover, even if the mouse happens to land over them. The
	// scrim blocks pointer events conceptually — this is the
	// implementation. Exception: a widget inside a registered overlay
	// (a popover spawned from the dialog content — select dropdown,
	// date picker, etc.) is reachable even when its rect spills past
	// the modal card, because the user can see it and the overlay is
	// drawn over the scrim. Without this exception, a select inside a
	// dialog whose dropdown extends below the card has its lower
	// options dead-clickable.
	mr := ctx.widgets.modal_rect_prev
	if mr.w > 0 && mr.h > 0 && !rect_contains_rect(mr, rect) {
		inside_overlay := false
		for rr in ctx.widgets.overlay_rects_prev {
			if rect_contains_rect(rr, rect) {
				inside_overlay = true
				break
			}
		}
		if !inside_overlay { return false }
	}
	for rr in ctx.widgets.overlay_rects_prev {
		if rect_contains_point(rr, mp) && !rect_contains_rect(rr, rect) {
			return false
		}
	}
	return true
}

// widget_make_focusable adds `id` to this frame's focusables list, so
// Tab traversal knows to stop on it. Stateful widgets that can meaningfully
// accept keyboard focus (text_input, button, checkbox, slider) call this
// once per frame during their builder.
// widget_make_focusable adds `id` to this frame's focusables list with
// the default natural-order tab_index of 0.
widget_make_focusable :: proc(ctx: ^Ctx($Msg), id: Widget_ID, tab_index: int = 0) {
	append(&ctx.widgets.focusables, Focusable_Entry{
		id = id, tab_index = tab_index,
	})
}

// widget_tab_index overrides `id`'s tab_index for the current frame.
// Apps call this *after* the widget builder returns, when they want
// to steer the Tab ring — e.g. a form laid out "phone above email"
// visually but meant to Tab email → phone. Updates the most-recent
// matching entry in this frame's focusables; a no-op if the widget
// never registered (disabled) or the id isn't present.
//
//     email_id := skald.hash_id("email")
//     name_id  := skald.hash_id("name")
//     skald.text_input(ctx, s.name,  on_name,  id = name_id)
//     skald.text_input(ctx, s.email, on_email, id = email_id)
//     skald.widget_tab_index(ctx, email_id, 1)   // email first
//     skald.widget_tab_index(ctx, name_id,  2)   // then name
//
// Positive values sort first, ascending. 0 means "natural order after
// all positives" — the default for every widget.
widget_tab_index :: proc(ctx: ^Ctx($Msg), id: Widget_ID, tab_index: int) {
	for &entry, i in ctx.widgets.focusables {
		_ = i
		if entry.id == id {
			entry.tab_index = tab_index
			return
		}
	}
}

// widget_advance_focus moves `focused_id` one step along the focusables
// list collected in the previous frame. Called from the run loop when
// Tab (`backward=false`) or Shift+Tab (`backward=true`) was pressed.
// Wraps around at both ends; if nothing is currently focused, the first
// (or last) focusable becomes focused.
//
// When a modal dialog is active (ws.modal_rect non-zero), the cycle is
// restricted to focusables whose recorded rect sits inside the modal
// rect — classic focus trap. One-frame lag: a focusable whose rect
// hasn't been recorded yet (e.g. a newly-opened dialog on frame 0) is
// skipped; focus lands on it via rect-containment on the following frame.
@(private)
widget_advance_focus :: proc(ws: ^Widget_Store, backward: bool) {
	n := len(ws.focusables)
	if n == 0 { return }

	modal_on := ws.modal_rect.w > 0 && ws.modal_rect.h > 0

	// Build the cycle set. Without a modal, it's every focusable in
	// registration order. With a modal, keep only focusables whose
	// last_rect centers lie inside modal_rect.
	//
	// Tab-order rule (matches HTML): entries with a positive
	// `tab_index` come first, in ascending order; entries with 0
	// follow in registration order. A stable sort preserves build
	// order inside each tab_index group.
	picked := make([dynamic]Focusable_Entry, 0, n, context.temp_allocator)
	for entry in ws.focusables {
		if modal_on {
			st, ok := ws.states[entry.id]
			if !ok { continue }
			r := st.last_rect
			if r.w <= 0 || r.h <= 0 { continue }
			cx := r.x + r.w / 2
			cy := r.y + r.h / 2
			if !rect_contains_point(ws.modal_rect, {cx, cy}) { continue }
		}
		append(&picked, entry)
	}
	m := len(picked)
	if m == 0 { return }

	// Stable insertion sort: positives (asc) first, zeroes keep order.
	// Tiny N in practice (< ~30 focusables per view) so O(n²) is fine.
	for i := 1; i < m; i += 1 {
		j := i
		for j > 0 {
			a := picked[j-1].tab_index
			b := picked[j].tab_index
			// Move j earlier if b outranks a. Positive ranks less than
			// zero, and smaller positives rank less than larger positives.
			outranks := false
			if a == 0 && b > 0 { outranks = true }
			else if a > 0 && b > 0 && b < a { outranks = true }
			if !outranks { break }
			picked[j-1], picked[j] = picked[j], picked[j-1]
			j -= 1
		}
	}

	pool := make([dynamic]Widget_ID, 0, m, context.temp_allocator)
	for entry in picked { append(&pool, entry.id) }

	idx := -1
	for id, i in pool {
		if id == ws.focused_id { idx = i; break }
	}
	if idx < 0 {
		ws.focused_id = pool[m - 1 if backward else 0]
		return
	}

	step := -1 if backward else 1
	ws.focused_id = pool[(idx + step + m) %% m]
}
