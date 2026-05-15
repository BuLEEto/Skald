package skald

import "core:fmt"
import "core:strings"

// emoji_picker builds a 😀 trigger that opens a popover with search,
// optional recents row, 9 category tabs, paginated grid, and skin-tone
// toolbar. Clicking an emoji fires `on_pick(emoji_string)`.
//
//     Msg :: union { Pick_Emoji: string, … }
//     on_pick :: proc(e: string) -> Msg { return Pick_Emoji(strings.clone(e)) }
//
//     skald.emoji_picker(ctx, on_pick, recents = state.recent_emojis[:])
//
// The emoji string passed to `on_pick` lives in the temp arena — clone
// it before storing on State, same as any Msg-borne string.
//
// Recents are app-owned: pass a `[]string` (most-recent-first). The
// picker renders an extra row above the tabs whenever the slice is
// non-empty; the app decides how to maintain it (a fixed-size ring,
// JSON persistence, whatever fits).
//
// Skin tones: the footer carries a Fitzpatrick swatch toggle (none +
// 5 tones). Picking an emoji whose `has_skin` flag is true with a
// non-default tone selected appends the modifier codepoint to the
// returned string.
//
// Coverage: ~1150 single-codepoint emojis from Twemoji-Mozilla,
// categorised per Unicode CLDR. ZWJ-sequence variants (family
// compositions, mixed-tone people pairs) are out of scope for v1.
emoji_picker :: proc{emoji_picker_simple, emoji_picker_payload}

emoji_picker_simple :: proc(
	ctx:      ^Ctx($Msg),
	on_pick:  proc(emoji: string) -> Msg,
	id:       Widget_ID = 0,
	recents:  []string  = nil,
	disabled: bool      = false,
) -> View {
	view, picked, ok := _emoji_picker_impl(ctx, id, recents, disabled)
	if ok { send(ctx, on_pick(picked)) }
	return view
}

emoji_picker_payload :: proc(
	ctx:      ^Ctx($Msg),
	payload:  $Payload,
	on_pick:  proc(payload: Payload, emoji: string) -> Msg,
	id:       Widget_ID = 0,
	recents:  []string  = nil,
	disabled: bool      = false,
) -> View {
	view, picked, ok := _emoji_picker_impl(ctx, id, recents, disabled)
	if ok { send(ctx, on_pick(payload, picked)) }
	return view
}

@(rodata, private="file")
emoji_tab_icons := [9]string{
	"😀", "👋", "🐶", "🍎", "🚗", "⚽", "💡", "❤", "🏁",
}

// Fitzpatrick modifiers — base ("none" = no modifier) + 5 tones.
@(rodata, private="file")
emoji_skin_tones := [6]string{"", "🏻", "🏼", "🏽", "🏾", "🏿"}

// Indicator swatches used for the skin-tone toggle row. The "none"
// option renders as ✋ (default yellow); the rest render as that same
// hand with the corresponding Fitzpatrick modifier applied.
@(rodata, private="file")
emoji_skin_swatches := [6]string{"✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"}

@(private="file") EMOJI_PICKER_COLS         :: 8
// Grid rows are chosen per-view so the overall popover height stays
// roughly constant: full 6 rows when the tone strip is hidden, 5 rows
// when it's shown (the dropped row roughly balances the tone strip's
// extra height). Pagination absorbs the difference in per-page count.
@(private="file") EMOJI_PICKER_ROWS_DEFAULT :: 6
@(private="file") EMOJI_PICKER_ROWS_TONED   :: 5
@(private="file") EMOJI_CELL_SIZE     :: f32(36)
@(private="file") EMOJI_TAB_SIZE      :: f32(32)
@(private="file") EMOJI_SEARCH_H      :: f32(32)
@(private="file") EMOJI_RECENTS_H     :: f32(36)
@(private="file") EMOJI_POPOVER_W     :: f32(360)
@(private="file") EMOJI_TRIGGER_SIZE  :: f32(32)
@(private="file") EMOJI_MAX_RECENTS   :: 8     // visible across the recents row

// One-shot warning when the picker is built under fontstash. Twemoji-
// Mozilla ships COLR layers only — its `glyf` outlines are empty — so
// fontstash renders every emoji cell as a blank rect, which is
// effectively unusable. Remove this whole gate once runa becomes the
// default backend (1.x) — there's no longer a path that hits it.
@(private="file") emoji_picker_warned_no_runa: bool

@(private)
_emoji_picker_impl :: proc(
	ctx:      ^Ctx($Msg),
	id:       Widget_ID,
	recents:  []string,
	disabled: bool,
) -> (view: View, picked: string, ok: bool) {
	th := ctx.theme

	if !emoji_picker_warned_no_runa && ctx.renderer != nil && ctx.renderer.text.runa_state == nil {
		fmt.eprintln("[skald] emoji_picker: running under fontstash — emoji cells will render blank. Build with SKALD_RUNA=1 for colour emoji.")
		emoji_picker_warned_no_runa = true
	}

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Emoji_Picker)
	focused := !disabled && widget_has_focus(ctx, id)

	if disabled { st.open = false }
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, st.last_rect) {
		st.open = false
	}

	trigger_rect    := st.last_rect
	trigger_hovered := !disabled && rect_hovered(ctx, trigger_rect)

	// Clear search draft on close so each open starts fresh.
	if !st.open && len(st.text_buffer) > 0 {
		delete(st.text_buffer)
		st.text_buffer = ""
		st.cursor_pos  = 0
	}

	cat  := clamp(st.cursor_pos, 0, len(Emoji_Group) - 1)
	page := max(0, st.drag_donor)
	tone := clamp(st.selection_anchor, 0, len(emoji_skin_tones) - 1)
	query := st.text_buffer

	// Truncate recents to what we can show in one row.
	recent_count := min(len(recents), EMOJI_MAX_RECENTS)
	recents_visible := recent_count > 0

	// Build the active emoji index list — either filtered (search) or a
	// flat indices array into the category window. Stored in temp arena.
	searching := len(query) > 0
	results := make([dynamic]int, 0, 64, context.temp_allocator)
	if searching {
		lower_q := strings.to_lower(query, context.temp_allocator)
		for entry, i in emoji_table {
			if strings.contains(entry.name, lower_q) {
				append(&results, i)
			}
		}
	} else {
		lo := emoji_group_offsets[cat]
		hi := emoji_group_offsets[cat + 1]
		for i in lo..<hi { append(&results, i) }
	}
	// Tones only apply to People & Body (and any future skin-tone-base
	// emojis). Suppress the tone strip on categories / searches where
	// none of the visible entries respond, so the swatches don't look
	// broken when the user clicks one and the grid doesn't change.
	tones_apply := false
	for idx in results {
		if emoji_table[idx].has_skin { tones_apply = true; break }
	}

	// Trade one grid row for the tone strip so the popover height stays
	// constant when switching between People (tones visible) and other
	// categories (tones hidden). Pagination absorbs the smaller per-page
	// count automatically.
	rows := EMOJI_PICKER_ROWS_DEFAULT
	if tones_apply { rows = EMOJI_PICKER_ROWS_TONED }
	per_page := EMOJI_PICKER_COLS * rows

	total    := len(results)
	max_page := max(0, (total - 1) / per_page)
	if page > max_page { page = max_page; st.drag_donor = page }

	// Popover geometry.
	overlay_pad := th.spacing.md
	border_w    := f32(1)
	gap         := th.spacing.sm
	tabs_h      := EMOJI_TAB_SIZE
	grid_h      := f32(rows) * EMOJI_CELL_SIZE
	tone_h      := f32(28)
	page_text_h := f32(18)
	// 8px (not 2) so the with-tones footer is exactly 6 px taller, which
	// matches the row removed from the grid — keeping overall popover
	// height identical across categories.
	tone_page_gap := f32(8)
	footer_h    := page_text_h
	if tones_apply { footer_h = tone_h + tone_page_gap + page_text_h }
	header_h := EMOJI_SEARCH_H + gap
	if recents_visible { header_h += EMOJI_RECENTS_H + gap }
	if !searching     { header_h += tabs_h + gap }
	overlay_h := 2*(overlay_pad + border_w) + header_h + grid_h + gap + footer_h

	overlay_rect := overlay_placement_rect(ctx, trigger_rect,
		{EMOJI_POPOVER_W, overlay_h}, .Below, {0, 4})
	mouse_over_overlay := rect_contains_point(overlay_rect, ctx.input.mouse_pos)
	if st.open { widget_stamp_overlay_rect(ctx.widgets, overlay_rect) }

	content_x := overlay_rect.x + overlay_pad + border_w
	content_y := overlay_rect.y + overlay_pad + border_w
	inner_w   := EMOJI_POPOVER_W - 2*(overlay_pad + border_w)

	search_rect := Rect{content_x, content_y, inner_w, EMOJI_SEARCH_H}
	cursor_y := content_y + EMOJI_SEARCH_H + gap
	recents_rect: Rect
	if recents_visible {
		recents_rect = Rect{content_x, cursor_y, inner_w, EMOJI_RECENTS_H}
		cursor_y += EMOJI_RECENTS_H + gap
	}
	tabs_rect: Rect
	if !searching {
		tabs_rect = Rect{content_x, cursor_y, inner_w, tabs_h}
		cursor_y += tabs_h + gap
	}
	grid_rect_w := f32(EMOJI_PICKER_COLS) * EMOJI_CELL_SIZE
	grid_origin_x := content_x + (inner_w - grid_rect_w) / 2
	grid_rect   := Rect{grid_origin_x, cursor_y, grid_rect_w, grid_h}
	footer_rect := Rect{content_x, cursor_y + grid_h + gap, inner_w, footer_h}

	// Trigger toggle + outside-click dismiss.
	if !disabled && ctx.input.mouse_pressed[.Left] {
		if trigger_hovered {
			st.open = !st.open
			widget_focus(ctx, id)
			focused = true
		} else if st.open && !mouse_over_overlay {
			st.open = false
		}
	}
	if focused && !disabled {
		keys := ctx.input.keys_pressed
		if !st.open && (.Space in keys || .Enter in keys) { st.open = true }
		if .Escape in keys { st.open = false }
	}

	// Inline search editing — mirrors command_palette's pattern. While
	// the popover is open we always want text input; keystrokes flow
	// into the draft regardless of widget focus.
	if st.open && !disabled {
		ctx.widgets.wants_text_input = true
		draft  := query
		cursor := clamp(st.cursor_pos, 0, len(draft))
		changed := false
		keys := ctx.input.keys_pressed
		if len(ctx.input.text) > 0 {
			for i := 0; i < len(ctx.input.text); i += 1 {
				ch := ctx.input.text[i]
				if ch >= 0x20 && ch != 0x7f {
					draft   = string_insert_at(draft, cursor, ctx.input.text[i:i+1])
					cursor += 1
					changed = true
				}
			}
		}
		if .Backspace in keys && cursor > 0 {
			draft   = strings.concatenate({draft[:cursor-1], draft[cursor:]},
				context.temp_allocator)
			cursor -= 1
			changed = true
		}
		if changed {
			if len(st.text_buffer) > 0 { delete(st.text_buffer) }
			st.text_buffer = strings.clone(draft)
			st.cursor_pos  = cursor
			query = st.text_buffer
			st.drag_donor = 0
			page          = 0
		}
	}

	// Tabs hit-test (only when not searching).
	if st.open && !searching && ctx.input.mouse_pressed[.Left] && rect_contains_point(tabs_rect, ctx.input.mouse_pos) {
		slot_w := tabs_rect.w / f32(len(Emoji_Group))
		col_idx := int((ctx.input.mouse_pos.x - tabs_rect.x) / slot_w)
		if col_idx < 0 { col_idx = 0 }
		if col_idx >= len(Emoji_Group) { col_idx = len(Emoji_Group) - 1 }
		if col_idx != cat {
			cat = col_idx
			st.cursor_pos = cat
			st.drag_donor = 0
			page          = 0
			// rebuild results for the new category
			clear(&results)
			lo := emoji_group_offsets[cat]
			hi := emoji_group_offsets[cat + 1]
			for i in lo..<hi { append(&results, i) }
			total    = len(results)
			max_page = max(0, (total - 1) / per_page)
		}
	}

	// Recents hit-test.
	if st.open && recents_visible && ctx.input.mouse_released[.Left] && rect_contains_point(recents_rect, ctx.input.mouse_pos) {
		slot_w := EMOJI_CELL_SIZE
		col_idx := int((ctx.input.mouse_pos.x - recents_rect.x) / slot_w)
		if col_idx >= 0 && col_idx < recent_count {
			picked  = recents[col_idx]
			ok      = true
			st.open = false
		}
	}

	// Grid hit-test → resolve to emoji + apply skin tone if applicable.
	if st.open && ctx.input.mouse_released[.Left] && rect_contains_point(grid_rect, ctx.input.mouse_pos) {
		col_idx := int((ctx.input.mouse_pos.x - grid_rect.x) / EMOJI_CELL_SIZE)
		row_idx := int((ctx.input.mouse_pos.y - grid_rect.y) / EMOJI_CELL_SIZE)
		if col_idx >= 0 && col_idx < EMOJI_PICKER_COLS && row_idx >= 0 && row_idx < rows {
			cell_idx := page * per_page + row_idx * EMOJI_PICKER_COLS + col_idx
			if cell_idx < total {
				entry := emoji_table[results[cell_idx]]
				glyph := entry.glyph
				if entry.has_skin && tone > 0 {
					glyph = strings.concatenate({glyph, emoji_skin_tones[tone]}, context.temp_allocator)
				}
				picked  = glyph
				ok      = true
				st.open = false
			}
		}
	}

	// Pagination + skin tone hit-tests in the footer.
	arrow_w := f32(28)
	arrow_hit_h := tone_h if tones_apply else footer_h
	prev_rect := Rect{footer_rect.x, footer_rect.y, arrow_w, arrow_hit_h}
	next_rect := Rect{footer_rect.x + footer_rect.w - arrow_w, footer_rect.y, arrow_w, arrow_hit_h}
	tone_w    := f32(26)
	tone_strip_w := tone_w * f32(len(emoji_skin_tones))
	tone_origin_x := footer_rect.x + (footer_rect.w - tone_strip_w) / 2
	tone_rect := Rect{tone_origin_x, footer_rect.y, tone_strip_w, tone_h}
	if st.open && ctx.input.mouse_pressed[.Left] {
		if rect_contains_point(prev_rect, ctx.input.mouse_pos) && page > 0 {
			page         -= 1
			st.drag_donor = page
		} else if rect_contains_point(next_rect, ctx.input.mouse_pos) && page < max_page {
			page         += 1
			st.drag_donor = page
		} else if tones_apply && rect_contains_point(tone_rect, ctx.input.mouse_pos) {
			col_idx := int((ctx.input.mouse_pos.x - tone_rect.x) / tone_w)
			if col_idx >= 0 && col_idx < len(emoji_skin_tones) {
				tone = col_idx
				st.selection_anchor = tone
			}
		}
	}

	// Swallow overlay clicks so widgets after this don't see them.
	if st.open {
		if ctx.input.mouse_pressed[.Left]  && mouse_over_overlay { ctx.input.mouse_pressed[.Left]  = false }
		if ctx.input.mouse_released[.Left] && mouse_over_overlay { ctx.input.mouse_released[.Left] = false }
	}

	anim_op: f32 = 0
	if st.open {
		anim_op = widget_anim_step(ctx, &st, 1, 0.12)
	} else {
		st.anim_t       = 0
		st.anim_prev_ns = 0
	}
	widget_set(ctx, id, st)

	// Build trigger.
	border_c := th.color.border
	if focused { border_c = th.color.primary }
	trigger_label := text("😀", th.color.fg, th.font.size_lg)
	trigger_inner := col(
		trigger_label,
		width  = EMOJI_TRIGGER_SIZE, height = EMOJI_TRIGGER_SIZE,
		bg     = th.color.surface,
		radius = th.radius.sm,
		main_align = .Center, cross_align = .Center,
	)
	bordered_trigger := col(
		trigger_inner,
		padding = border_w,
		width   = EMOJI_TRIGGER_SIZE + 2*border_w,
		bg      = border_c,
		radius  = th.radius.sm,
	)
	c := new(View, context.temp_allocator)
	c^ = bordered_trigger
	zone_trigger := View(View_Zone{id = id, child = c})

	if !st.open {
		view = zone_trigger
		return
	}

	// ---- Build popover content ----

	// Search input — labels with placeholder when empty.
	search_text := query
	search_color := th.color.fg
	if len(search_text) == 0 {
		search_text  = "Search emoji…"
		search_color = th.color.fg_muted
	}
	search_view := col(
		text(search_text, search_color, th.font.size_md),
		width  = search_rect.w,
		height = EMOJI_SEARCH_H,
		padding = th.spacing.sm,
		bg     = th.color.surface,
		radius = th.radius.sm,
		main_align = .Center, cross_align = .Start,
	)

	// Recents row (when visible).
	recents_view: View
	if recents_visible {
		recents_cells := make([]View, recent_count, context.temp_allocator)
		for i in 0..<recent_count {
			recents_cells[i] = col(
				text(recents[i], th.color.fg, th.font.size_lg),
				width  = EMOJI_CELL_SIZE, height = EMOJI_CELL_SIZE,
				radius = th.radius.sm,
				main_align = .Center, cross_align = .Center,
			)
		}
		recents_view = row(
			..recents_cells,
			spacing = 0,
			width   = recents_rect.w,
			height  = EMOJI_RECENTS_H,
		)
	}

	// Tabs row (hidden during search).
	tabs_view: View
	if !searching {
		tab_cells := make([]View, len(Emoji_Group), context.temp_allocator)
		for i in 0..<len(Emoji_Group) {
			bg: Color = {}
			if i == cat { bg = th.color.selection }
			tab_cells[i] = col(
				text(emoji_tab_icons[i], th.color.fg, th.font.size_md),
				width  = tabs_rect.w / f32(len(Emoji_Group)),
				height = tabs_h,
				bg     = bg,
				radius = th.radius.sm,
				main_align = .Center, cross_align = .Center,
			)
		}
		tabs_view = row(..tab_cells, spacing = 0, width = tabs_rect.w, height = tabs_h)
	}

	// Grid — `per_page` cells per page (48 without tones, 40 with),
	// optionally short on the last page.
	row_views := make([]View, rows, context.temp_allocator)
	for r in 0..<rows {
		cell_views := make([]View, EMOJI_PICKER_COLS, context.temp_allocator)
		for cc in 0..<EMOJI_PICKER_COLS {
			cell_idx := page * per_page + r * EMOJI_PICKER_COLS + cc
			if cell_idx < total {
				cell_x := grid_rect.x + f32(cc) * EMOJI_CELL_SIZE
				cell_y := grid_rect.y + f32(r)  * EMOJI_CELL_SIZE
				hovered := mouse_over_overlay && rect_contains_point(
					Rect{cell_x, cell_y, EMOJI_CELL_SIZE, EMOJI_CELL_SIZE},
					ctx.input.mouse_pos)
				bg: Color = {}
				if hovered { bg = th.color.surface }
				glyph := emoji_table[results[cell_idx]].glyph
				if emoji_table[results[cell_idx]].has_skin && tone > 0 {
					glyph = strings.concatenate({glyph, emoji_skin_tones[tone]}, context.temp_allocator)
				}
				cell_views[cc] = col(
					text(glyph, th.color.fg, th.font.size_lg),
					width  = EMOJI_CELL_SIZE, height = EMOJI_CELL_SIZE,
					bg     = bg,
					radius = th.radius.sm,
					main_align = .Center, cross_align = .Center,
				)
			} else {
				cell_views[cc] = col(width = EMOJI_CELL_SIZE, height = EMOJI_CELL_SIZE)
			}
		}
		row_views[r] = row(..cell_views, spacing = 0, height = EMOJI_CELL_SIZE)
	}
	grid_inner := col(..row_views, spacing = 0, width = grid_rect.w, height = grid_h)
	grid_view := col(
		grid_inner,
		width  = inner_w, height = grid_h,
		main_align = .Center, cross_align = .Center,
	)

	// Footer — < arrow, skin-tone strip, page label, > arrow.
	prev_color := th.color.fg
	if page == 0 { prev_color = th.color.fg_muted }
	next_color := th.color.fg
	if page >= max_page { next_color = th.color.fg_muted }
	arrow_h := footer_h if !tones_apply else tone_h
	prev_arrow := col(text("◀", prev_color, th.font.size_md),
		width = arrow_w, height = arrow_h, main_align = .Center, cross_align = .Center)
	next_arrow := col(text("▶", next_color, th.font.size_md),
		width = arrow_w, height = arrow_h, main_align = .Center, cross_align = .Center)

	tone_cells := make([]View, len(emoji_skin_tones), context.temp_allocator)
	for i in 0..<len(emoji_skin_tones) {
		bg: Color = {}
		if i == tone { bg = th.color.selection }
		tone_cells[i] = col(
			text(emoji_skin_swatches[i], th.color.fg, th.font.size_md),
			width  = tone_w, height = tone_h,
			bg     = bg,
			radius = th.radius.sm,
			main_align = .Center, cross_align = .Center,
		)
	}
	tone_view := row(..tone_cells, spacing = 0, width = tone_strip_w, height = tone_h)

	page_label: string
	if searching {
		page_label = fmt.tprintf("%d results — %d / %d", total, page + 1, max_page + 1)
	} else {
		page_label = fmt.tprintf("%s — %d / %d", emoji_group_names[cat], page + 1, max_page + 1)
	}
	page_text := col(text(page_label, th.color.fg_muted, th.font.size_xs),
		height = page_text_h, main_align = .Center, cross_align = .Center)
	footer: View
	if tones_apply {
		tone_row := row(
			prev_arrow,
			flex(1, col(tone_view, height = tone_h, main_align = .Center, cross_align = .Center)),
			next_arrow,
			spacing = 0, width = footer_rect.w, height = tone_h, cross_align = .Center,
		)
		footer = col(
			tone_row,
			page_text,
			spacing = tone_page_gap,
			width  = footer_rect.w,
			height = footer_h,
			cross_align = .Stretch,
		)
	} else {
		// No skin-tone-capable emojis in view — arrows flank the page label.
		page_row := row(
			prev_arrow,
			flex(1, page_text),
			next_arrow,
			spacing = 0, width = footer_rect.w, height = footer_h, cross_align = .Center,
		)
		footer = page_row
	}

	// Stack the popover content.
	stack: [dynamic]View
	stack.allocator = context.temp_allocator
	append(&stack, search_view)
	append(&stack, spacer(gap))
	if recents_visible {
		append(&stack, recents_view)
		append(&stack, spacer(gap))
	}
	if !searching {
		append(&stack, tabs_view)
		append(&stack, spacer(gap))
	}
	append(&stack, grid_view)
	append(&stack, spacer(gap))
	append(&stack, footer)

	inner := col(
		..stack[:],
		spacing = 0,
		padding = overlay_pad,
		width   = EMOJI_POPOVER_W - 2*border_w,
		height  = overlay_h - 2*border_w,
		bg      = th.color.elevated,
		radius  = th.radius.sm,
		cross_align = .Start,
	)
	card := col(
		inner,
		padding = border_w,
		width   = EMOJI_POPOVER_W,
		bg      = th.color.border,
		radius  = th.radius.sm,
		cross_align = .Start,
	)

	view = col(
		zone_trigger,
		overlay(trigger_rect, card, .Below, {0, 4}, anim_op),
		cross_align = .Start,
	)
	return
}
