package skald

// Command palette — the Ctrl+K / Ctrl+Shift+P overlay that lists every
// action the app exposes via `menu_bar`, filtered by a fuzzy search.
//
// The palette deliberately *reads* from `[]Menu_Entry(Msg)` rather than
// maintaining its own command registry: the app already declares its
// actions for the menu bar, and duplicating them here would drift on
// every edit. Passing the same slice to both widgets keeps them in
// lockstep. Shortcut registration is owned by `menu_bar` — the palette
// is a passive viewer, so hotkeys don't double-fire.
//
// Filtering is subsequence-based: the query's characters must appear
// in the path in order, case-insensitive. "fisa" matches "File → Save";
// "sa" matches both "File → Save" and "File → Save As". Consecutive
// matches and word-starts score higher, so the likeliest intent floats
// to the top.

import "core:strings"
import "core:unicode/utf8"

// Palette_Command is one row in the flattened command list. `path`
// is the breadcrumb ("File → Save"), `msg` is what fires on select,
// `shortcut` is shown faintly on the right of the row as a hint. The
// `disabled` flag greys the row and skips dispatch — same convention
// as `Menu_Item.disabled`.
@(private)
Palette_Command :: struct($Msg: typeid) {
	path:     string,
	msg:      Msg,
	shortcut: Shortcut,
	disabled: bool,
}

// Palette_Match pairs a command index with its fuzzy-match score, so
// we can sort by score descending without losing the original index
// (used to dispatch the right Msg when Enter fires).
@(private)
Palette_Match :: struct {
	index: int,
	score: int,
}

// command_palette renders a centered modal overlay listing every
// non-separator menu item matched against a user-typed query. Use the
// same `[]Menu_Entry` slice you pass to `menu_bar` — the palette
// flattens it to paths like "File → Save" automatically. Clicking a
// row or pressing Enter with one highlighted dispatches that item's
// Msg and then fires `on_dismiss` to close the palette.
//
// Typical wiring: the app adds a Ctrl+K `shortcut` that flips a
// boolean in its state, and passes that flag as `open`. `on_dismiss`
// flips it back. The palette auto-opens a text input and owns its
// own arrow-key / Enter / Escape handling, so the app doesn't need
// any further key wiring.
//
// `width` caps the card width (default 520 px — roomy but not
// overwhelming). `max_rows` limits how many matching rows render
// before the list stops appending; there's no scroll in v1, so
// users with very long menu lists should tune `max_rows` up.
command_palette :: proc(
	ctx:         ^Ctx($Msg),
	open:        bool,
	entries:     []Menu_Entry(Msg),
	on_dismiss:  proc() -> Msg,
	id:          Widget_ID = 0,
	width:       f32       = 520,
	max_rows:    int       = 10,
	placeholder: string    = "Type a command…",
) -> View {
	th := ctx.theme
	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Command_Palette)

	// Closed: clear the query so the next open starts empty, and emit
	// a zero-size view. Matches `dialog`'s convention.
	if !open {
		// Open→closed transition: restore focus to whatever had it
		// before the palette opened. If nothing had focus, this is a
		// no-op.
		if st.open && ctx.widgets.focus_return_id != 0 {
			widget_focus(ctx, ctx.widgets.focus_return_id)
			ctx.widgets.focus_return_id = 0
		}
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
		st.text_buffer = ""
		st.cursor_pos  = 0
		st.drag_donor  = 0
		st.open        = false
		widget_set(ctx, id, st)
		return View_Spacer{size = 0}
	}

	// Closed→open transition: snapshot the currently-focused widget so
	// we can hand focus back on close, then blur. Otherwise a
	// previously-focused text field would keep eating keystrokes while
	// the palette is up, so typing "save" would go to both the buried
	// field and the palette's query. Our own query editing is focus-
	// agnostic (we read `ctx.input.text` / `keys_pressed` directly).
	if !st.open {
		if ctx.widgets.focus_return_id == 0 {
			ctx.widgets.focus_return_id = ctx.widgets.focused_id
		}
		widget_focus(ctx, 0)
	}
	st.open = true

	// Flatten entries into a single command list. Separators are
	// dropped; paths read "Entry → Item" ("File → Save") when the
	// entry has a label, or just "Item" when the entry label is
	// empty — handy for apps with no menu_bar that want to expose
	// commands via Ctrl+K alone, without the bogus "File → " prefix
	// every row would inherit otherwise.
	commands := make([dynamic]Palette_Command(Msg), 0, 32, context.temp_allocator)
	arrow := " → "
	for entry in entries {
		for item in entry.items {
			if item.separator { continue }
			path: string
			if len(entry.label) == 0 {
				path = item.label
			} else {
				path = strings.concatenate(
					{entry.label, arrow, item.label}, context.temp_allocator)
			}
			append(&commands, Palette_Command(Msg){
				path     = path,
				msg      = item.msg,
				shortcut = item.shortcut,
				disabled = item.disabled,
			})
		}
	}

	// Current draft + caret. Always mutable locals because the editing
	// loop below works against them; we commit back into `st` near the
	// end of the proc.
	draft  := st.text_buffer
	cursor := clamp(st.cursor_pos, 0, len(draft))

	// The palette always wants text input while open. Mirrors the
	// convention every text_input follows — without this, IME state
	// doesn't engage and the soft keyboard on mobile stays hidden.
	ctx.widgets.wants_text_input = true

	// Editing. Copies combobox's inline editing pattern (no external
	// on_change Msg; mutate the draft directly in state) so the caller
	// doesn't need to plumb a Query_Changed variant.
	keys := ctx.input.keys_pressed

	if len(ctx.input.text) > 0 {
		for i := 0; i < len(ctx.input.text); i += 1 {
			ch := ctx.input.text[i]
			if ch >= 0x20 && ch != 0x7f {
				draft  = string_insert_at(draft, cursor, ctx.input.text[i:i+1])
				cursor += 1
			}
		}
	}
	if .Backspace in keys && cursor > 0 {
		draft = strings.concatenate({draft[:cursor-1], draft[cursor:]},
			context.temp_allocator)
		cursor -= 1
	}
	if .Delete in keys && cursor < len(draft) {
		draft = strings.concatenate({draft[:cursor], draft[cursor+1:]},
			context.temp_allocator)
	}
	if .Left  in keys && cursor > 0          { cursor -= 1 }
	if .Right in keys && cursor < len(draft) { cursor += 1 }
	if .Home  in keys                        { cursor = 0 }
	if .End   in keys                        { cursor = len(draft) }

	// Filter + score. Empty query → preserve declaration order so the
	// palette-on-first-open reads like the menu bar itself. Non-empty →
	// subsequence filter with word-start + consecutive-match bonuses.
	matches := make([dynamic]Palette_Match, 0, len(commands), context.temp_allocator)
	if len(draft) == 0 {
		for _, i in commands {
			append(&matches, Palette_Match{index = i, score = -i}) // stable order
		}
	} else {
		lower_q := strings.to_lower(draft, context.temp_allocator)
		for cmd, i in commands {
			lower_p := strings.to_lower(cmd.path, context.temp_allocator)
			score, ok := palette_fuzzy_score(lower_q, lower_p)
			if !ok { continue }
			append(&matches, Palette_Match{index = i, score = score})
		}
		// Insertion sort by score desc. Small N (tens of matches at
		// most), so the simple algorithm is fine.
		for i := 1; i < len(matches); i += 1 {
			j := i
			for j > 0 && matches[j].score > matches[j-1].score {
				matches[j], matches[j-1] = matches[j-1], matches[j]
				j -= 1
			}
		}
	}

	// Highlight clamping. Typing narrows the list and can leave the
	// old highlight pointing past the end; snap to 0 on any query
	// change so the user always sees "top-of-list" after a keystroke.
	hl := int(st.drag_donor)
	if len(ctx.input.text) > 0 || .Backspace in keys || .Delete in keys {
		hl = 0
	}
	if .Down in keys && len(matches) > 0 {
		hl = (hl + 1) %% len(matches)
	}
	if .Up in keys && len(matches) > 0 {
		hl = (hl - 1 + len(matches)) %% len(matches)
	}
	if hl < 0 { hl = 0 }
	if hl >= len(matches) { hl = max(0, len(matches) - 1) }

	// Enter on a non-disabled highlighted row dispatches. The dialog
	// wrapper forwards Escape to on_dismiss, so we don't handle that
	// here.
	if .Enter in keys && len(matches) > 0 {
		m := matches[hl]
		cmd := commands[m.index]
		if !cmd.disabled {
			send(ctx, cmd.msg)
			send(ctx, on_dismiss())
		}
	}

	// Prevent the inner text-input rendering from double-consuming the
	// nav keys. Enter is deliberately stripped too — otherwise a focused
	// button behind the palette could fire its own Space/Enter shortcut
	// in the same frame.
	ctx.input.keys_pressed -= {.Up, .Down, .Enter}

	// Commit draft state. Free any previous owned buffer so re-typed
	// queries don't leak.
	if draft != st.text_buffer {
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
		st.text_buffer = strings.clone(draft)
	}
	st.cursor_pos = cursor
	st.drag_donor = hl
	widget_set(ctx, id, st)

	// --- View composition ---
	// Card width; content width = card - 2*padding (dialog's default
	// padding is spacing.lg).
	pad := th.spacing.lg
	inner_w := width - 2 * pad

	// Query field. Single-line View_Text_Input, no caller-facing on_change
	// (we wrote the draft into state inline).
	fs_q := th.font.size_lg
	q_pad_y := th.spacing.sm
	q_h := fs_q + 2*q_pad_y + 6
	q_vline := []Visual_Line{
		Visual_Line{start = 0, end = len(draft), consume_space = false},
	}
	query_field := View_Text_Input{
		id                = id,              // reuse the palette's own id
		text              = draft,
		placeholder       = placeholder,
		color_bg          = th.color.surface,
		color_fg          = th.color.fg,
		color_placeholder = th.color.fg_muted,
		color_border      = th.color.primary,
		color_border_idle = th.color.border,
		color_caret       = th.color.fg,
		color_selection   = th.color.selection,
		radius            = th.radius.sm,
		padding           = {th.spacing.md, q_pad_y},
		font_size         = fs_q,
		width             = inner_w,
		height            = q_h,
		focused           = true,
		cursor_pos        = cursor,
		selection_anchor  = cursor,
		visual_lines      = q_vline,
	}

	// Rows. Cap at `max_rows`; v1 has no scroll — users with very
	// long menu sets should tune the param up.
	row_h := th.font.size_md + 2 * th.spacing.sm + 4
	show_count := min(len(matches), max_rows)

	row_views := make([dynamic]View, 0, show_count + 1, context.temp_allocator)
	for i in 0 ..< show_count {
		m := matches[i]
		cmd := commands[m.index]

		row_bg := Color{}
		if i == hl { row_bg = th.color.selection }

		fg := th.color.fg
		if cmd.disabled { fg = th.color.fg_muted }

		// Shortcut glyph on the right, dimmed. Empty shortcut renders
		// an empty spacer so the row height stays uniform.
		short_view: View
		if cmd.shortcut.key != .Backspace || cmd.shortcut.mods != {} {
			// Any registered key (even Backspace if explicitly bound)
			// will render. The {} default (all zeros) reads as unset
			// because Shortcut zero-value is {.Backspace, {}}; treat
			// "no mods AND default key" as unset.
			if cmd.shortcut.key != .Backspace || cmd.shortcut.mods != {} {
				label := shortcut_format(cmd.shortcut)
				short_view = text(label, th.color.fg_muted, th.font.size_sm)
			}
		}
		if short_view == nil { short_view = spacer(0) }

		row_view := row(
			text(cmd.path, fg, th.font.size_md),
			flex(1, spacer(0)),
			short_view,
			width       = inner_w,
			height      = row_h,
			padding     = th.spacing.md,
			cross_align = .Center,
			bg          = row_bg,
			radius      = th.radius.sm,
		)

		// Click-to-dispatch: wrap each row in a Click_Zone so mouse
		// clicks inside fire the command without making a focusable
		// button (focus stays on the query field).
		row_views = append_palette_row(ctx, row_views, row_view, cmd.msg, cmd.disabled,
			on_dismiss, id_scope = id, row_index = i)
	}

	// Empty state.
	if show_count == 0 {
		append(&row_views, col(
			text("No matches", th.color.fg_muted, th.font.size_md),
			width       = inner_w,
			padding     = th.spacing.md,
			cross_align = .Center,
		))
	}

	list := col(..row_views[:],
		width       = inner_w,
		spacing     = 2,
		cross_align = .Stretch,
	)

	// Footer hint.
	hint := text("↑↓ navigate   ⏎ select   Esc close",
		th.color.fg_muted, th.font.size_sm)

	content := col(
		query_field,
		spacer(th.spacing.sm),
		list,
		spacer(th.spacing.md),
		hint,
		spacing     = 0,
		cross_align = .Stretch,
	)

	// Wrap in a dialog for scrim + modal + Escape + shadow. No
	// initial_focus because the palette itself already engages IME
	// via wants_text_input and we handle all key events inline.
	return dialog(ctx, open, content, on_dismiss,
		width   = width,
		padding = pad,
	)
}

// palette_fuzzy_score scores a subsequence match of `q` inside `text`.
// Both arguments must be lowercase. Returns `ok = false` if any query
// character can't be found in order. Higher scores mean a closer
// match: +10 per matched char, +consecutive bonus for runs, +5 for
// word-start matches. Small integers so everything fits in an int.
@(private)
palette_fuzzy_score :: proc(q, text: string) -> (score: int, ok: bool) {
	if len(q) == 0 { return 0, true }
	qi := 0
	last_match_at := -2
	run := 0
	for i := 0; i < len(text); i += 1 {
		if qi >= len(q) { break }
		if q[qi] == text[i] {
			score += 10
			if last_match_at == i - 1 {
				run += 1
				score += run * 3
			} else {
				run = 0
			}
			// Word-start bonus — first char, after space, or after the
			// decorative arrow glyph used in the path.
			if i == 0 || text[i-1] == ' ' || text[i-1] == 0xe2 { // UTF-8 leading byte of →
				score += 5
			}
			last_match_at = i
			qi += 1
		}
	}
	if qi < len(q) { return 0, false }
	return score, true
}

// append_palette_row wraps a row view in a Click_Zone that dispatches
// `msg` (and `on_dismiss`) on a left click inside the row's rect.
// Kept as a helper so the main builder stays readable. The zone id is
// derived from the palette id + row index so state is stable across
// frames without auto-id collisions.
@(private)
append_palette_row :: proc(
	ctx:         ^Ctx($Msg),
	rows:        [dynamic]View,
	row_view:    View,
	msg:         Msg,
	disabled:    bool,
	on_dismiss:  proc() -> Msg,
	id_scope:    Widget_ID,
	row_index:   int,
) -> [dynamic]View {
	rows := rows
	if !disabled {
		zone_id := id_scope ~ Widget_ID((row_index + 1) * 7919) | WIDGET_ID_EXPLICIT_BIT
		zst := widget_get(ctx, zone_id, .Click_Zone)
		if rect_hovered(ctx, zst.last_rect) && ctx.input.mouse_pressed[.Left] {
			send(ctx, msg)
			send(ctx, on_dismiss())
		}
		widget_set(ctx, zone_id, zst)
		c := new(View, context.temp_allocator)
		c^ = row_view
		append(&rows, View_Zone{id = zone_id, child = c})
	} else {
		append(&rows, row_view)
	}
	return rows
}
