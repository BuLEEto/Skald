/*
Package runa is a pure-Odin modern text engine — parsing → itemization →
shaping → line-breaking → rasterization. See API.md for the public
API contract.

This file is the public facade. Internal modules live in sibling
directories (`parse/`, `shape/`, `itemize/`, `bidi/`, `linebreak/`,
`raster/`) and are not part of the supported API surface — consumers
should reach into them only at their own risk.
*/
package runa

import "core:mem"

import "parse"
import "raster"
import "shape"
import "linebreak"
import "itemize"
import "bidi"

// ---- Re-exported types from the raster package -----------------------

Atlas        :: raster.Atlas
Atlas_Page   :: raster.Atlas_Page
Atlas_Slot   :: raster.Atlas_Slot
Atlas_Format :: raster.Atlas_Format
Atlas_Dirty  :: raster.Atlas_Dirty
Atlas_Error  :: raster.Atlas_Error

atlas_make        :: raster.atlas_make
atlas_destroy     :: raster.atlas_destroy
atlas_pack_alpha  :: raster.atlas_pack_alpha
atlas_pack_rgba   :: raster.atlas_pack_rgba
atlas_flush_dirty :: raster.atlas_flush_dirty

// Error is the single public error type. Returns from every fallible
// procedure as `(T, Error)`. `Error.None` is the zero value and means
// success — callers can branch on `if err != .None`.
Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Table,         // malformed OpenType data
	Unsupported_Format,    // e.g. AAT-only font, no GSUB/GPOS
	Glyph_Not_Found,
	Axis_Out_Of_Range,
	Table_Not_Found,       // required table missing
}

// Glyph_ID is the OpenType glyph index, native size. Re-exported from
// the parse package so callers don't have to import an internal module.
Glyph_ID :: parse.Glyph_ID

// Font_ID is assigned by the Cache on first use of a Font. Distinct so
// it can't be confused with a raw integer at a call site.
Font_ID :: distinct u32

// Axis_Tag is a 4-byte OpenType axis tag (e.g. 'wght', 'wdth') packed
// big-endian.
Axis_Tag :: distinct u32

// Axis describes one variation axis a variable font exposes.
// Values are in user coordinates (the designer's chosen units —
// 100..900 for `wght`, etc.). Convert to normalised [-1, +1] space
// internally via fvar + avar.
Axis :: struct {
	tag:           Axis_Tag,
	min_value:     f32,
	default_value: f32,
	max_value:     f32,
}

// OT_Feature is a 4-byte OpenType feature tag (e.g. 'liga', 'kern')
// packed big-endian.
OT_Feature :: distinct u32

// Direction is the paragraph direction. `.Auto` runs the bidi
// algorithm to detect; `.LTR` / `.RTL` force the result.
Direction :: enum u8 { Auto, LTR, RTL }

// Align is the per-line cross-axis alignment.
Align :: enum u8 { Start, Center, End }

// Language is a BCP-47 tag held by value. 12 bytes covers every tag
// that fits in `xx-Yyyy-ZZ` shape; longer tags are rejected.
Language :: distinct [12]u8

// Outline is the parsed shape of one glyph. Re-exported from parse so
// raster / consumer code doesn't have to import an internal module.
Outline :: parse.Outline

// outline_destroy frees the dynamic arrays inside an Outline. Re-export
// so consumers don't need to reach into `parse`.
outline_destroy :: parse.outline_destroy

// Font is a parsed OpenType / TrueType font. The struct holds:
//
//   - public-readable metrics (units_per_em, num_glyphs, ascent,
//     descent, line_gap) the caller may inspect directly;
//   - private parsed-table state for cmap / hmtx / loca / glyf;
//   - the allocator used at load time, so `font_destroy` doesn't need
//     a second parameter.
//
// The caller's `data` slice is *not* copied — every parsed table view
// indexes into it. The slice must outlive the Font.
//
// Thread safety: a Font is read-only after `font_load` returns; multiple
// goroutines / threads may share one Font without synchronisation. The
// `Cache` (added later) is where mutable per-call state lives.
Font :: struct {
	// Public metrics — read-only for callers.
	units_per_em: u16,
	num_glyphs:   u16,
	ascent:       f32,
	descent:      f32,
	line_gap:     f32,
	x_min:        i16,
	y_min:        i16,
	x_max:        i16,
	y_max:        i16,

	// Private parser state.
	_data:      []u8,
	_allocator: mem.Allocator,
	_tables:    parse.Table_Index,
	_cmap:      parse.Cmap,
	_hmtx:      parse.Hmtx_Table,
	_loca:      parse.Loca,
	_glyf:      parse.Glyf,
	_cff:       parse.Cff,
	_has_cff:   bool,
	_cff2:      parse.Cff2,
	_has_cff2:  bool,
	_gsub:      parse.Gsub,
	_gpos:      parse.Gpos,
	_colr:      parse.Colr,
	_cpal:      parse.Cpal,
	_fvar:      parse.Fvar,
	_avar:      parse.Avar,
	_gvar:      parse.Gvar,
	_hvar:      parse.Hvar,
	_mvar:      parse.Mvar,
	_axis_values: []f32,                 // normalised, post-avar, per-axis. nil if no fvar.
	_has_gsub:  bool,
	_has_gpos:  bool,
	_has_colr:  bool,
	_has_fvar:  bool,
	_has_avar:  bool,
	_has_gvar:  bool,
	_has_hvar:  bool,
	_has_mvar:  bool,
	// Base (default-instance) vertical metrics; the public `ascent` /
	// `descent` / `line_gap` fields reflect MVAR deltas when the axis
	// state is off the default.
	_base_ascent:   f32,
	_base_descent:  f32,
	_base_line_gap: f32,
	_index_to_loc_format: parse.Index_To_Loc_Format,
}

// Shaped_Glyph is one positioned glyph emitted by `shape_text`. The
// shape package owns the underlying type; runa re-exports it so
// consumers don't reach into a sibling package.
//
// At the runa layer we wrap shape.Shaped_Glyph with a `font` pointer
// so the caller knows which font in the fallback stack owns the
// glyph. `Paragraph_Glyph` below carries this extra pointer.
Shaped_Glyph :: shape.Shaped_Glyph

// Paragraph_Glyph is one positioned glyph in a laid-out paragraph,
// tagged with the font that produced it. `font` is a non-owning
// pointer into the caller's Font_Stack — its lifetime is the caller's
// responsibility.
//
// `level` is the UAX #9 embedding level (0 LTR, odd RTL). The visual
// reorder per UAX #9 L2 is applied per-line during wrap; consumers
// drawing the glyphs walk left-to-right, level-aware.
Paragraph_Glyph :: struct {
	font:      ^Font,
	glyph_id:  Glyph_ID,
	cluster:   u32,
	x_advance: f32,
	y_advance: f32,
	x_offset:  f32,
	y_offset:  f32,
	level:     u8,
}

// Line is one laid-out line of a paragraph. At v0.1 there's no
// wrapping — every paragraph produces exactly one Line. UAX #14
// support lands in the next milestone and will turn this into a slice.
Line :: struct {
	glyphs:   []Paragraph_Glyph,
	width:    f32,
	height:   f32,
	baseline: f32,                                // y position of baseline within the line
}

// Font_Stack is a caller-owned, fallback-ordered list of fonts. The
// first font that covers each codepoint wins.
Font_Stack :: distinct []^Font

// Paragraph_Opts is the per-call configuration. See API.md.
//
// At v0.1 only `fonts` and `size` are load-bearing. `align`, `direction`,
// `max_width`, and `language` are accepted but their effects are partial
// (LTR only, no wrapping yet, no bidi).
Paragraph_Opts :: struct {
	fonts:     Font_Stack,
	size:      f32,
	direction: Direction,
	align:     Align,
	max_width: f32,                               // 0 -> no wrapping
	language:  Language,
}

// layout_paragraph lays out `text` per `opts`, producing one or more
// Lines. When `opts.max_width > 0`, runs are wrapped per UAX #14
// break opportunities (LB subset, greedy first-fit); when 0, the
// whole paragraph stays on a single line (modulo hard breaks at
// LF / CR / NL).
//
// `cache` is optional: pass `nil` for one-shot callers (e.g. a CLI
// that renders one page to a PPM and exits). For per-frame callers
// (UI redraws, scrolling viewports), pass a long-lived `^Cache` and
// the runs share their shaping cost across frames — shape on miss,
// re-use on hit. The cache stores per-run substrings; the shaper
// re-runs only when text or size changes.
//
// Each Line owns its own `glyphs` slice — caller frees with
// `line_destroy` per Line, then `delete` on the outer slice.
layout_paragraph :: proc(text: string, opts: Paragraph_Opts, cache: ^Cache = nil, allocator := context.allocator) -> (lines: []Line, err: Error) {
	if len(opts.fonts) == 0 { err = .Invalid_Table; return }
	if opts.size <= 0       { err = .Invalid_Table; return }

	// Resolve paragraph direction. `Auto` (the default) runs the
	// UAX #9 P2/P3 first-strong-character heuristic; `LTR`/`RTL`
	// force the result. The resulting `base_dir` is used to compute
	// per-codepoint bidi levels.
	base_dir := opts.direction
	if base_dir == .Auto {
		switch bidi.paragraph_direction(text) {
		case .RTL:     base_dir = .RTL
		case .LTR:     base_dir = .LTR
		case .Neutral: base_dir = .LTR
		}
	}
	// `bidi_levels` is one byte per codepoint, aligned with
	// `cp_byte_offsets`. Nil when no bidi work is needed (pure LTR
	// text + LTR base direction).
	cp_bidi_levels: []u8
	cp_byte_offsets_for_bidi: []int
	needs_bidi := base_dir == .RTL || has_any_rtl(text)
	if needs_bidi {
		bd: bidi.Direction = .LTR
		if base_dir == .RTL { bd = .RTL }
		cp_bidi_levels, cp_byte_offsets_for_bidi = bidi.resolve_levels(text, bd, context.temp_allocator)
	}

	// Walk codepoints, group into runs of same (font, script). A run
	// break happens whenever either the picked font or the resolved
	// script changes. `Common` and `Inherited` codepoints fold into
	// the preceding run per UAX #24's resolution rules; the
	// per-codepoint script comes from `itemize.script_of`.
	Run :: struct {
		font:        ^Font,
		text_start:  int,
		text_end:    int,
		script:      itemize.Script_Code,
	}
	runs := make([dynamic]Run, 0, 4, context.temp_allocator)

	cur_font:    ^Font
	cur_script:  itemize.Script_Code = itemize.COMMON
	run_start := 0
	byte_off  := 0
	for r in text {
		byte_len := utf8_byte_len(r)
		picked := pick_font_for_rune(opts.fonts, r)
		raw_script := itemize.script_of(r)
		// UAX #24 resolution: Common / Inherited fold into the
		// surrounding run. They only "set" the script if no real
		// script has appeared yet.
		next_script := cur_script
		if raw_script != itemize.COMMON && raw_script != itemize.INHERITED {
			next_script = raw_script
		} else if cur_font == nil {
			next_script = raw_script
		}
		if cur_font != nil && (picked != cur_font || next_script != cur_script) {
			append(&runs, Run{font = cur_font, text_start = run_start, text_end = byte_off, script = cur_script})
			run_start = byte_off
		}
		cur_font   = picked
		cur_script = next_script
		byte_off += byte_len
	}
	if cur_font != nil {
		append(&runs, Run{font = cur_font, text_start = run_start, text_end = byte_off, script = cur_script})
	}

	// Shape each run and concatenate. With a non-nil cache, runs hit
	// `shape_text_cached` and return the cache-owned glyph slice
	// directly. Without a cache, we shape into a temp buffer per
	// iteration.
	all_glyphs := make([dynamic]Paragraph_Glyph, 0, 32, allocator)
	tmp_shape  := make([dynamic]Shaped_Glyph, 0, 32, context.temp_allocator)

	for run in runs {
		run_text := text[run.text_start:run.text_end]
		ot_script_tag := opentype_script_tag(run.script)
		shaped: []Shaped_Glyph
		if cache != nil {
			shaped = shape_text_cached(run.font, run_text, opts.size, cache, ot_script_tag)
		} else {
			clear(&tmp_shape)
			shape_text(run.font, run_text, opts.size, &tmp_shape, ot_script_tag)
			shaped = tmp_shape[:]
		}
		for sg in shaped {
			absolute_cluster := sg.cluster + u32(run.text_start)
			level: u8 = base_dir == .RTL ? 1 : 0
			if cp_bidi_levels != nil {
				cp_idx := cluster_to_cp_idx_bidi(int(absolute_cluster), cp_byte_offsets_for_bidi)
				if cp_idx >= 0 && cp_idx < len(cp_bidi_levels) {
					level = cp_bidi_levels[cp_idx]
				}
			}
			append(&all_glyphs, Paragraph_Glyph{
				font      = run.font,
				glyph_id  = sg.glyph_id,
				cluster   = absolute_cluster,
				x_advance = sg.x_advance,
				y_advance = sg.y_advance,
				x_offset  = sg.x_offset,
				y_offset  = sg.y_offset,
				level     = level,
			})
		}
	}

	// Compute line height from the tallest font in the stack.
	scale_factor :: proc(f: ^Font, size: f32) -> f32 { return size / f32(f.units_per_em) }
	max_height: f32 = 0
	max_baseline: f32 = 0
	for f in opts.fonts {
		s := scale_factor(f, opts.size)
		h := (f.ascent - f.descent + f.line_gap) * s
		if h > max_height { max_height = h }
		if f.ascent * s > max_baseline { max_baseline = f.ascent * s }
	}

	// Hand wrap_glyphs a slice but free the dynamic-array's backing
	// via the dynamic, not the slice — the slice loses capacity info
	// and `delete(slice, ...)` only sizes-out the live length.
	lines = wrap_glyphs(text, all_glyphs[:], opts.max_width, max_height, max_baseline, allocator)
	delete(all_glyphs)
	return
}

// wrap_glyphs splits the shaped-glyph buffer into one or more Lines
// according to break opportunities and the max_width budget.
//
// Greedy first-fit: accumulate glyphs until adding the next would
// exceed `max_width`; cut at the most recent allowed break. Mandatory
// breaks (LF / CR / NL) force a cut regardless of width.
@(private)
wrap_glyphs :: proc(text: string, all_glyphs: []Paragraph_Glyph, max_width, line_h, baseline: f32, allocator: mem.Allocator) -> []Line {
	// Build a set of break-opportunity byte offsets from the source
	// text. A break "before byte b" means: line N ends at the glyph
	// whose cluster is just before b; line N+1 starts at the glyph
	// whose cluster is b.
	runes_buf := make([dynamic]rune, 0, len(text), context.temp_allocator)
	cp_byte_offsets := make([dynamic]int, 0, len(text), context.temp_allocator)
	off := 0
	for r in text {
		append(&runes_buf, r)
		append(&cp_byte_offsets, off)
		off += utf8_byte_len(r)
	}
	runes := runes_buf[:]

	// allowed_breaks[i] = true if a line may break BEFORE codepoint i.
	// mandatory_breaks[i] = true if a line MUST break before i.
	allowed := make([dynamic]bool, len(runes), context.temp_allocator)
	mandatory := make([dynamic]bool, len(runes), context.temp_allocator)
	i := 0
	for i < len(runes) {
		next_i, must := linebreak.next_break(runes, i)
		if next_i > 0 && next_i <= len(runes) {
			if next_i < len(runes) {
				allowed[next_i] = true
				if must { mandatory[next_i] = true }
			}
		}
		if next_i <= i { i += 1 } else { i = next_i }
	}

	// Convert byte-cluster on a Paragraph_Glyph back to a codepoint
	// index for break testing.
	cluster_to_cp_idx := proc(cluster: u32, offsets: []int) -> int {
		// Binary search for the cp whose byte offset equals `cluster`.
		lo, hi := 0, len(offsets)
		for lo < hi {
			mid := (lo + hi) / 2
			switch {
			case offsets[mid] < int(cluster):  lo = mid + 1
			case offsets[mid] > int(cluster):  hi = mid
			case:                              return mid
			}
		}
		return lo
	}

	out := make([dynamic]Line, 0, 4, allocator)
	if len(all_glyphs) == 0 {
		append(&out, Line{glyphs = make([]Paragraph_Glyph, 0, allocator), width = 0, height = line_h, baseline = baseline})
		return out[:]
	}

	line_start_glyph := 0
	cur_width: f32 = 0
	last_break_glyph := -1            // glyph index *after* which a break is allowed

	emit_line := proc(out: ^[dynamic]Line, glyphs: []Paragraph_Glyph, start, end_exclusive: int, line_h, baseline: f32, allocator: mem.Allocator) -> f32 {
		span := glyphs[start:end_exclusive]
		copy_buf := make([]Paragraph_Glyph, len(span), allocator)
		copy(copy_buf, span)

		// UAX #9 L2 per-line reorder: from the highest level present
		// down to the lowest odd level, reverse contiguous spans of
		// glyphs whose level is ≥ that threshold. Skipped entirely
		// when every glyph is at level 0 (the common pure-LTR case).
		reorder_visual_in_place(copy_buf)

		w: f32 = 0
		for g in copy_buf { w += g.x_advance }
		append(out, Line{glyphs = copy_buf, width = w, height = line_h, baseline = baseline})
		return w
	}

	for gi in 0..<len(all_glyphs) {
		g := all_glyphs[gi]
		cp_idx := cluster_to_cp_idx(g.cluster, cp_byte_offsets[:])

		// Mandatory break BEFORE this glyph?
		if cp_idx > 0 && cp_idx < len(runes) && mandatory[cp_idx] {
			emit_line(&out, all_glyphs, line_start_glyph, gi, line_h, baseline, allocator)
			line_start_glyph = gi
			cur_width = 0
			last_break_glyph = -1
		}

		// Width check (only when wrapping is requested).
		if max_width > 0 && cur_width + g.x_advance > max_width && gi > line_start_glyph {
			break_at := last_break_glyph
			if break_at < line_start_glyph {
				// No break opportunity found inside the run; force a
				// break before the offending glyph rather than overflow.
				break_at = gi - 1
			}
			emit_line(&out, all_glyphs, line_start_glyph, break_at + 1, line_h, baseline, allocator)
			line_start_glyph = break_at + 1
			// Recompute cur_width for the carried-forward glyphs.
			cur_width = 0
			for k in line_start_glyph..<gi { cur_width += all_glyphs[k].x_advance }
			last_break_glyph = -1
		}

		cur_width += g.x_advance

		// Track break opportunity AFTER this glyph (so the next glyph
		// will see a candidate cut point at gi).
		next_cp := cp_idx + 1
		if next_cp < len(runes) && allowed[next_cp] {
			last_break_glyph = gi
		}
	}
	// Emit the tail.
	emit_line(&out, all_glyphs, line_start_glyph, len(all_glyphs), line_h, baseline, allocator)

	// Caller (`layout_paragraph`) owns `all_glyphs`'s backing storage
	// and frees it after we return — we hold a slice view, not the
	// dynamic, so we can't free correctly from here anyway.
	return out[:]
}

// line_destroy frees the `glyphs` slice inside one Line.
line_destroy :: proc(l: ^Line, allocator := context.allocator) {
	delete(l.glyphs, allocator)
	l^ = {}
}

// measure_text is the cheap-path measurement procedure — shapes the
// text with the first covering font in the stack and returns the
// pixel-space width + height. No line-wrapping, no allocations beyond
// `context.temp_allocator`.
measure_text :: proc(text: string, opts: Paragraph_Opts) -> (width, height: f32) {
	if len(opts.fonts) == 0 || opts.size <= 0 { return 0, 0 }

	tmp := make([dynamic]Shaped_Glyph, 0, 32, context.temp_allocator)

	// Same run-splitting as layout_paragraph, but we don't materialise
	// glyphs into the caller's allocator.
	byte_off := 0
	cur_font: ^Font
	run_start := 0
	for r in text {
		picked := pick_font_for_rune(opts.fonts, r)
		if picked != cur_font && cur_font != nil {
			clear(&tmp)
			shape_text(cur_font, text[run_start:byte_off], opts.size, &tmp)
			for sg in tmp { width += sg.x_advance }
			run_start = byte_off
		}
		cur_font = picked
		byte_off += utf8_byte_len(r)
	}
	if cur_font != nil {
		clear(&tmp)
		shape_text(cur_font, text[run_start:byte_off], opts.size, &tmp)
		for sg in tmp { width += sg.x_advance }
	}

	for f in opts.fonts {
		s := opts.size / f32(f.units_per_em)
		h := (f.ascent - f.descent + f.line_gap) * s
		if h > height { height = h }
	}
	return
}

// pick_font_for_rune returns the first font in `stack` whose cmap
// covers `r`, or stack[0] as the last-resort fallback (so the caller
// gets *something* — the .notdef glyph, but never a crash).
// opentype_script_tag converts a UAX #24 / ISO 15924 Script_Code
// (title-case, e.g. 'Latn') into the OpenType layout script tag
// (lowercase, 'latn'). The bytes are the same letters; the case
// differs.
//
// Special cases: Common / Inherited / Unknown all map to 'latn' as
// a safe fallback — these scripts have no shaper-feature data of
// their own, and 'latn' is the closest thing to "default rules" in
// modern OpenType fonts.
// reorder_visual_in_place applies UAX #9 L2 to a single line's glyph
// span. Walks levels from highest down to lowest odd, reversing each
// maximal contiguous span at level ≥ threshold. Pure-LTR lines
// (every glyph at level 0) short-circuit.
@(private)
reorder_visual_in_place :: proc(glyphs: []Paragraph_Glyph) {
	if len(glyphs) <= 1 { return }
	highest: u8 = 0
	lowest_odd: u8 = 255
	for g in glyphs {
		if g.level > highest    { highest = g.level }
		if g.level & 1 == 1 && g.level < lowest_odd { lowest_odd = g.level }
	}
	if lowest_odd == 255 { return }                  // no RTL levels — nothing to reorder
	for L := highest; L >= lowest_odd; L -= 1 {
		i := 0
		for i < len(glyphs) {
			if glyphs[i].level < L { i += 1; continue }
			j := i
			for j < len(glyphs) && glyphs[j].level >= L { j += 1 }
			// Reverse glyphs[i:j].
			for k in 0..<(j - i) / 2 {
				glyphs[i + k], glyphs[j - 1 - k] = glyphs[j - 1 - k], glyphs[i + k]
			}
			i = j
		}
		if L == 0 { break }
	}
}

@(private)
has_any_rtl :: proc(text: string) -> bool {
	for r in text {
		#partial switch bidi.bidi_class(r) {
		case .R, .AL: return true
		}
	}
	return false
}

@(private)
cluster_to_cp_idx_bidi :: proc(cluster: int, offsets: []int) -> int {
	lo, hi := 0, len(offsets)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case offsets[mid] < cluster: lo = mid + 1
		case offsets[mid] > cluster: hi = mid
		case:                        return mid
		}
	}
	return lo
}

@(private)
opentype_script_tag :: proc(s: itemize.Script_Code) -> parse.Tag {
	switch s {
	case itemize.COMMON, itemize.INHERITED, itemize.UNKNOWN:
		return parse.LATN_SCRIPT
	}
	v := u32(s)
	// Lowercase each of the four ASCII bytes (set bit 5 if uppercase).
	out: u32 = 0
	for i in 0..<4 {
		b := u8(v >> uint((3 - i) * 8))
		if b >= 'A' && b <= 'Z' { b |= 0x20 }
		out = (out << 8) | u32(b)
	}
	return parse.Tag(out)
}

@(private)
pick_font_for_rune :: proc(stack: Font_Stack, r: rune) -> ^Font {
	for f in stack {
		if font_lookup_glyph(f, r) != 0 { return f }
	}
	return stack[0]
}

@(private)
utf8_byte_len :: proc(r: rune) -> int {
	switch {
	case r < 0x80:    return 1
	case r < 0x800:   return 2
	case r < 0x10000: return 3
	}
	return 4
}

// font_load parses the SFNT directory and every required table out of
// `data`. The caller retains ownership of `data` — it must outlive the
// returned Font. On error, no allocations are leaked.
//
// Required tables at v0.1: `head`, `maxp`, `cmap`, `hhea`, `hmtx`,
// `loca`, `glyf`. A font missing any of these returns
// `Error.Table_Not_Found`. Fonts shipping only CFF (`OTTO` SFNT) are
// rejected with `Error.Unsupported_Format` for now — CFF outlines land
// in a follow-up commit.
font_load :: proc(data: []u8, allocator := context.allocator) -> (f: Font, err: Error) {
	f._data = data
	f._allocator = allocator

	tables, terr := parse.parse_table_index(data, allocator)
	if terr != .None {
		err = map_parse_err(terr)
		return
	}
	f._tables = tables

	// Outline flavour. `is_truetype` selects the `glyf`-table path;
	// `is_cff` selects the CFF charstring path. Anything else
	// (Type 1, AAT-only, …) is rejected.
	if !parse.is_truetype(&f._tables) && !parse.is_cff(&f._tables) {
		parse.table_index_destroy(&f._tables, allocator)
		err = .Unsupported_Format
		return
	}

	// head + maxp first — every subsequent parse depends on them.
	head, herr := load_head_table(&f)
	if herr != .None { font_destroy(&f); err = herr; return }
	mx, mxerr := load_maxp_table(&f)
	if mxerr != .None { font_destroy(&f); err = mxerr; return }

	f.units_per_em = head.units_per_em
	f.num_glyphs   = mx.num_glyphs
	f.x_min, f.y_min, f.x_max, f.y_max = head.x_min, head.y_min, head.x_max, head.y_max
	f._index_to_loc_format = head.index_to_loc_format

	// hhea — ascent / descent / line gap, plus number_of_h_metrics.
	hhea, hherr := load_hhea_table(&f)
	if hherr != .None { font_destroy(&f); err = hherr; return }
	f.ascent   = f32(hhea.ascender)
	f.descent  = f32(hhea.descender)
	f.line_gap = f32(hhea.line_gap)

	// cmap, hmtx, loca, glyf.
	cmap_bytes, ferr := parse.find_table(&f._tables, data, parse.tag("cmap"))
	if ferr != .None { font_destroy(&f); err = map_parse_err(ferr); return }
	cm, cerr := parse.parse_cmap(cmap_bytes, allocator)
	if cerr != .None { font_destroy(&f); err = map_parse_err(cerr); return }
	f._cmap = cm

	hmtx_bytes, herr2 := parse.find_table(&f._tables, data, parse.tag("hmtx"))
	if herr2 != .None { font_destroy(&f); err = map_parse_err(herr2); return }
	hmtx, hmerr := parse.new_hmtx(hmtx_bytes, hhea.number_of_h_metrics, mx.num_glyphs)
	if hmerr != .None { font_destroy(&f); err = map_parse_err(hmerr); return }
	f._hmtx = hmtx

	// Outline path: TrueType uses loca + glyf; CFF uses a single
	// 'CFF ' table that contains its own per-glyph offsets.
	if parse.is_truetype(&f._tables) {
		loca_bytes, lerr := parse.find_table(&f._tables, data, parse.tag("loca"))
		if lerr != .None { font_destroy(&f); err = map_parse_err(lerr); return }
		loca, lerr2 := parse.parse_loca(loca_bytes, head.index_to_loc_format, mx.num_glyphs, allocator)
		if lerr2 != .None { font_destroy(&f); err = map_parse_err(lerr2); return }
		f._loca = loca

		glyf_bytes, gerr := parse.find_table(&f._tables, data, parse.tag("glyf"))
		if gerr != .None { font_destroy(&f); err = map_parse_err(gerr); return }
		f._glyf = parse.new_glyf(glyf_bytes)
	} else {
		// CFF or CFF2. CFF2 fonts ship a `CFF2` table; CFF1 fonts
		// ship `CFF `. Some hybrid Adobe fonts (rare) ship both — we
		// prefer CFF2 when present since its variation support
		// supersedes the static CFF1 outlines.
		if parse.has_table(&f._tables, parse.tag("CFF2")) {
			cff2_bytes, cerr := parse.find_table(&f._tables, data, parse.tag("CFF2"))
			if cerr != .None { font_destroy(&f); err = map_parse_err(cerr); return }
			cff2, ccerr := parse.new_cff2(cff2_bytes, allocator)
			if ccerr != .None { font_destroy(&f); err = map_parse_err(ccerr); return }
			f._cff2 = cff2
			f._has_cff2 = true
		} else {
			cff_bytes, cerr_cff := parse.find_table(&f._tables, data, parse.tag("CFF "))
			if cerr_cff != .None { font_destroy(&f); err = map_parse_err(cerr_cff); return }
			cff, ccerr := parse.new_cff(cff_bytes, allocator)
			if ccerr != .None { font_destroy(&f); err = map_parse_err(ccerr); return }
			f._cff = cff
			f._has_cff = true
		}
	}

	// GSUB / GPOS are optional. Pure-display fonts (logos, fallback
	// scripts) ship without them; the shaper degrades to a glyph-walk
	// when missing.
	if parse.has_table(&f._tables, parse.tag("GSUB")) {
		gsub_bytes, _ := parse.find_table(&f._tables, data, parse.tag("GSUB"))
		gs, gsuberr := parse.new_gsub(gsub_bytes)
		if gsuberr == .None {
			f._gsub = gs
			f._has_gsub = true
		}
	}
	if parse.has_table(&f._tables, parse.tag("GPOS")) {
		gpos_bytes, _ := parse.find_table(&f._tables, data, parse.tag("GPOS"))
		gp, gposerr := parse.new_gpos(gpos_bytes)
		if gposerr == .None {
			f._gpos = gp
			f._has_gpos = true
		}
	}

	// COLR + CPAL together — they're a pair. Either both present and
	// the font carries colour layers, or neither and we treat it as
	// monochrome.
	if parse.has_table(&f._tables, parse.tag("COLR")) && parse.has_table(&f._tables, parse.tag("CPAL")) {
		colr_bytes, _ := parse.find_table(&f._tables, data, parse.tag("COLR"))
		cpal_bytes, _ := parse.find_table(&f._tables, data, parse.tag("CPAL"))
		cr, ce := parse.new_colr(colr_bytes)
		cp, pe := parse.new_cpal(cpal_bytes)
		if ce == .None && pe == .None {
			f._colr = cr
			f._cpal = cp
			f._has_colr = true
		}
	}

	// Variable-font tables. fvar describes the axes; avar (optional)
	// reshapes user → normalised; gvar holds per-glyph deltas applied
	// during outline extraction. All three load opportunistically —
	// missing any means the font renders at its default instance.
	if parse.has_table(&f._tables, parse.tag("fvar")) {
		fvar_bytes, _ := parse.find_table(&f._tables, data, parse.tag("fvar"))
		fv, ferr_fv := parse.parse_fvar(fvar_bytes, allocator)
		if ferr_fv == .None {
			f._fvar = fv
			f._has_fvar = true
			// Initialise normalised axis state to all zeros (default
			// instance per axis).
			f._axis_values = make([]f32, len(fv.axes), allocator)
		}
	}
	if f._has_fvar && parse.has_table(&f._tables, parse.tag("avar")) {
		avar_bytes, _ := parse.find_table(&f._tables, data, parse.tag("avar"))
		av, aerr := parse.parse_avar(avar_bytes, allocator)
		if aerr == .None {
			f._avar = av
			f._has_avar = true
		}
	}
	if f._has_fvar && parse.has_table(&f._tables, parse.tag("gvar")) {
		gvar_bytes, _ := parse.find_table(&f._tables, data, parse.tag("gvar"))
		gv, gerr_gv := parse.parse_gvar(gvar_bytes, allocator)
		if gerr_gv == .None {
			f._gvar = gv
			f._has_gvar = true
		}
	}
	if f._has_fvar && parse.has_table(&f._tables, parse.tag("HVAR")) {
		hvar_bytes, _ := parse.find_table(&f._tables, data, parse.tag("HVAR"))
		hv, herr := parse.parse_hvar(hvar_bytes)
		if herr == .None {
			f._hvar = hv
			f._has_hvar = true
		}
	}
	if f._has_fvar && parse.has_table(&f._tables, parse.tag("MVAR")) {
		mvar_bytes, _ := parse.find_table(&f._tables, data, parse.tag("MVAR"))
		mv, merr2 := parse.parse_mvar(mvar_bytes)
		if merr2 == .None {
			f._mvar = mv
			f._has_mvar = true
		}
	}

	// Stash the default-instance vertical metrics so `font_set_variation`
	// can rebuild them at the new axis values without re-reading the
	// font.
	f._base_ascent   = f.ascent
	f._base_descent  = f.descent
	f._base_line_gap = f.line_gap

	return
}

// apply_mvar_metrics recomputes the public ascent / descent /
// line_gap fields from `_base_*` plus the MVAR deltas at the
// current axis state.
@(private)
apply_mvar_metrics :: proc(f: ^Font) {
	if !f._has_mvar || !any_axis_non_default(f._axis_values) {
		f.ascent   = f._base_ascent
		f.descent  = f._base_descent
		f.line_gap = f._base_line_gap
		return
	}
	hasc :: parse.Tag(0x68617363)         // 'hasc'
	hdsc :: parse.Tag(0x68647363)         // 'hdsc'
	hlgp :: parse.Tag(0x686C6770)         // 'hlgp'
	f.ascent   = f._base_ascent   + f32(parse.mvar_lookup_delta(&f._mvar, hasc, f._axis_values))
	f.descent  = f._base_descent  + f32(parse.mvar_lookup_delta(&f._mvar, hdsc, f._axis_values))
	f.line_gap = f._base_line_gap + f32(parse.mvar_lookup_delta(&f._mvar, hlgp, f._axis_values))
}

// font_has_color_layers reports whether `gid` has a COLR layered
// rendering. Use this to branch your rasterizer between the alpha and
// RGBA pipelines.
font_has_color_layers :: proc(f: ^Font, gid: Glyph_ID) -> bool {
	if !f._has_colr { return false }
	return parse.colr_is_base(&f._colr, gid)
}

// font_color_layers returns the COLR layer list for `gid`. Caller frees
// with `delete`. Returns an empty slice if the glyph has no layered
// rendering or the font lacks COLR.
font_color_layers :: proc(f: ^Font, gid: Glyph_ID, allocator := context.allocator) -> ([]parse.Colr_Layer, Error) {
	if !f._has_colr { return nil, .None }
	layers, err := parse.colr_layers(&f._colr, gid, allocator)
	return layers, map_parse_err(err)
}

// raster_glyph rasterizes `gid` at `size` pixels with subpixel x-offset
// bucket `subpx_x` (0..3, quarter-pixel steps) and packs the result
// into `atlas`. Returns the slot so the caller can sample from
// `atlas.pages_alpha[slot.page_index].pixels` or `pages_color`
// depending on `slot.is_color`.
//
// Mono glyphs go into the atlas's alpha pages; colour-base glyphs
// (per `font_has_color_layers`) are composited via COLR layers and
// packed into the RGBA pages.
raster_glyph :: proc(font: ^Font, gid: Glyph_ID, size: f32, subpx_x: u8, atlas: ^Atlas, allocator := context.allocator) -> (slot: Atlas_Slot, err: Error) {
	if size <= 0 { err = .Invalid_Table; return }

	// Scratch for the rasterizer's edge buffer.
	edges := make([dynamic]raster.Edge, 0, 256, context.temp_allocator)

	if font_has_color_layers(font, gid) {
		// Prefer the COLRv1 brush-aware path when the font carries a v1
		// BaseGlyphList — it gives true linear gradients instead of
		// the flat first-stop approximation the v0 path emits.
		if font._has_colr && font._colr.version >= 1 && font._colr.base_glyph_list_off != 0 {
			brush_layers := make([dynamic]parse.Colr_Brush_Layer, 0, 8, context.temp_allocator)
			defer parse.colr_brush_layers_destroy(&brush_layers, context.temp_allocator)
			if parse.colr_v1_brush_layers(&font._colr, gid, &brush_layers, context.temp_allocator) && len(brush_layers) > 0 {
				bm, xo, yo, rerr := raster.rasterize_colr_brush_layers(
					brush_layers[:], &font._cpal, 0, [4]u8{0, 0, 0, 255},
					&font._glyf, &font._loca, font.units_per_em, size, &edges,
					context.temp_allocator,
				)
				if rerr != .None { err = .Invalid_Table; return }
				defer raster.color_bitmap_destroy(&bm, context.temp_allocator)
				if bm.width == 0 || bm.height == 0 { return }
				s, aerr := raster.atlas_pack_rgba(atlas, bm.pixels, u16(bm.width), u16(bm.height), [2]f32{f32(xo), f32(yo)})
				if aerr != .None { err = .Invalid_Table; return }
				slot = s
				return
			}
		}

		layers, lerr := font_color_layers(font, gid, context.temp_allocator)
		if lerr != .None { err = lerr; return }

		bm, xo, yo, rerr := raster.rasterize_colr_layers(
			layers, &font._cpal, 0, [4]u8{0, 0, 0, 255},
			&font._glyf, &font._loca, font.units_per_em, size, &edges,
			context.temp_allocator,
		)
		if rerr != .None { err = .Invalid_Table; return }
		defer raster.color_bitmap_destroy(&bm, context.temp_allocator)
		if bm.width == 0 || bm.height == 0 { return }

		s, aerr := raster.atlas_pack_rgba(atlas, bm.pixels, u16(bm.width), u16(bm.height), [2]f32{f32(xo), f32(yo)})
		if aerr != .None { err = .Invalid_Table; return }
		slot = s
		return
	}

	// Mono path.
	outline := Outline{}
	defer outline_destroy(&outline)
	oerr := font_glyph_outline(font, gid, &outline)
	if oerr != .None { err = oerr; return }
	if len(outline.contour_ends) == 0 { return }

	bm, xo, yo, rerr := raster.rasterize(&outline, font.units_per_em, size, &edges, subpx_x, context.temp_allocator)
	if rerr != .None { err = .Invalid_Table; return }
	defer raster.bitmap_destroy(&bm, context.temp_allocator)
	if bm.width == 0 || bm.height == 0 { return }

	s, aerr := raster.atlas_pack_alpha(atlas, bm.pixels, u16(bm.width), u16(bm.height), [2]f32{f32(xo), f32(yo)})
	if aerr != .None { err = .Invalid_Table; return }
	slot = s
	return
}

// font_palette_color returns the colour of palette entry `entry_idx`
// in palette 0. For multi-palette fonts (light/dark theme variants),
// callers can reach into `font._cpal` directly via `parse.cpal_lookup`.
// At v0.1 the runa surface exposes only palette 0.
font_palette_color :: proc(f: ^Font, entry_idx: u16) -> [4]u8 {
	if !f._has_colr { return {} }
	c := parse.cpal_lookup(&f._cpal, 0, entry_idx)
	return [4]u8{c.r, c.g, c.b, c.a}
}

// font_destroy releases parser state. The allocator captured at load is
// reused — the caller never passes it again. `f._data` is *not* freed;
// caller still owns the source bytes.
font_destroy :: proc(f: ^Font) {
	parse.cmap_destroy(&f._cmap, f._allocator)
	parse.loca_destroy(&f._loca, f._allocator)
	if f._has_cff  { parse.cff_destroy(&f._cff,  f._allocator) }
	if f._has_cff2 { parse.cff2_destroy(&f._cff2, f._allocator) }
	parse.table_index_destroy(&f._tables, f._allocator)
	if f._has_fvar { parse.fvar_destroy(&f._fvar, f._allocator) }
	if f._has_avar { parse.avar_destroy(&f._avar, f._allocator) }
	if f._has_gvar { parse.gvar_destroy(&f._gvar, f._allocator) }
	if f._axis_values != nil { delete(f._axis_values, f._allocator) }
	f^ = {}
}

// font_axes returns the variable-font axes the font exposes, in fvar
// order. Returns nil for non-variable fonts. The slice is owned by
// the Font; do not modify or free.
font_axes :: proc(f: ^Font) -> []Axis {
	if !f._has_fvar { return nil }
	// Build a public-facing slice on first call. For v0.5 we lazy-alloc
	// once per Font and stash; for simplicity at v0.1 sense we just
	// re-export Variation_Axis as Axis structurally.
	out := make([]Axis, len(f._fvar.axes), context.temp_allocator)
	for ax, i in f._fvar.axes {
		out[i] = Axis{
			tag           = Axis_Tag(ax.tag),
			min_value     = ax.min_value,
			default_value = ax.default_value,
			max_value     = ax.max_value,
		}
	}
	return out
}

// font_set_variation sets axis `axis` to user-coordinate `value` on
// `f`. Subsequent calls to `font_glyph_outline` apply gvar deltas
// scaled to the current axis tuple. Returns `Axis_Out_Of_Range` if
// `value` falls outside the axis's `[min, max]` interval, or
// `Unsupported_Format` if the font has no fvar table.
//
// Threading: not safe to call concurrently with shaping / outline
// calls on the same Font — the axis state is read by
// `font_glyph_outline`.
font_set_variation :: proc(f: ^Font, axis: Axis_Tag, value: f32) -> Error {
	if !f._has_fvar { return .Unsupported_Format }

	axis_def: parse.Variation_Axis
	axis_idx := -1
	for a, i in f._fvar.axes {
		if a.tag == parse.Tag(axis) {
			axis_def = a
			axis_idx = i
			break
		}
	}
	if axis_idx < 0 { return .Glyph_Not_Found }         // tag not on this font
	if value < axis_def.min_value || value > axis_def.max_value {
		return .Axis_Out_Of_Range
	}

	norm := parse.normalize_axis_value(axis_def, value)
	if f._has_avar { norm = parse.avar_apply(&f._avar, axis_idx, norm) }
	f._axis_values[axis_idx] = norm
	apply_mvar_metrics(f)
	return .None
}

// font_reset_variations restores every axis to its default
// instance — same as calling `font_set_variation(f, ax.tag,
// ax.default_value)` for each axis.
font_reset_variations :: proc(f: ^Font) {
	if !f._has_fvar { return }
	for i in 0..<len(f._axis_values) { f._axis_values[i] = 0 }
	apply_mvar_metrics(f)
}

// font_lookup_glyph returns the glyph ID for `codepoint`, or 0
// (`.notdef`) if the font doesn't cover it. Always present for any
// loaded font.
font_lookup_glyph :: proc(f: ^Font, codepoint: rune) -> Glyph_ID {
	return parse.cmap_lookup(&f._cmap, codepoint)
}

// font_glyph_advance returns the horizontal advance width of `gid` in
// font units. Multiply by `pixel_size / units_per_em` to get pixels.
//
// On variable fonts with HVAR, the advance reflects the axis state
// set via `font_set_variation` — bold-weight glyphs report a larger
// advance than the default-weight, so letter spacing tracks the
// chosen instance. Variable fonts without HVAR fall back to the
// default-instance advance from `hmtx` (correct only at the default
// instance; visibly drifts elsewhere).
font_glyph_advance :: proc(f: ^Font, gid: Glyph_ID) -> u16 {
	base := parse.hmtx_glyph_metric(&f._hmtx, gid).advance_width
	if f._has_hvar && any_axis_non_default(f._axis_values) {
		delta := parse.hvar_advance_delta(&f._hvar, gid, f._axis_values)
		v := i32(base) + delta
		if v < 0 { v = 0 }
		return u16(v)
	}
	return base
}

// font_glyph_outline materialises `gid`'s outline into `out`. Reuses
// `out`'s backing arrays — call once, draw many times, recycle the
// outline across glyphs to amortise allocation.
//
// On variable fonts, the outline reflects the axis state set via
// `font_set_variation` — gvar deltas are applied to the base
// glyf outline before this proc returns. The default instance
// produces deltas-of-zero, identical to the static outline.
//
// Returns `Error.Glyph_Not_Found` if `gid` is out of range,
// `Error.Invalid_Table` if the glyph data is malformed.
font_glyph_outline :: proc(f: ^Font, gid: Glyph_ID, out: ^Outline) -> Error {
	if f._has_cff2 {
		return map_parse_err(parse.cff2_glyph_outline(&f._cff2, gid, out, f._axis_values))
	}
	if f._has_cff {
		return map_parse_err(parse.cff_glyph_outline(&f._cff, gid, out))
	}
	gerr := parse.glyf_outline(&f._glyf, &f._loca, gid, out)
	if gerr != .None { return map_parse_err(gerr) }

	// Apply gvar deltas if the font is variable AND any axis is off
	// its default. The default-instance fast-reject saves the gvar
	// table walk for the common case of static-instance use.
	if f._has_gvar && any_axis_non_default(f._axis_values) {
		verr := parse.apply_glyph_variations(&f._gvar, gid, f._axis_values, out)
		if verr != .None { return map_parse_err(verr) }
	}
	return .None
}

@(private)
any_axis_non_default :: proc(values: []f32) -> bool {
	for v in values { if v != 0 { return true } }
	return false
}

// shape_text shapes one UTF-8 run for `font` at `size` pixels and
// appends the result to `out`. Existing `out` entries are kept — the
// caller may reuse the buffer across calls.
//
// At v0.1 the shaper is LTR Latin / Cyrillic / Greek (the script tag
// passed in defaults to `latn` if zero). Bidi reordering and Arabic
// shaping land in v0.5.
shape_text :: proc(font: ^Font, text: string, size: f32, out: ^[dynamic]Shaped_Glyph, script_tag: parse.Tag = parse.LATN_SCRIPT, language_tag: parse.Tag = parse.DFLT_LANG) {
	inputs := shape.Shape_Inputs{
		cmap         = &font._cmap,
		hmtx         = &font._hmtx,
		gsub         = &font._gsub if font._has_gsub else nil,
		gpos         = &font._gpos if font._has_gpos else nil,
		hvar         = &font._hvar if font._has_hvar else nil,
		axis_values  = font._axis_values,
		units_per_em = font.units_per_em,
	}
	opts := shape.Shape_Run_Opts{script = script_tag, language = language_tag}
	shape.shape_run(&inputs, opts, text, size, out)
}

@(private)
load_head_table :: proc(f: ^Font) -> (parse.Head_Table, Error) {
	bytes, terr := parse.find_table(&f._tables, f._data, parse.tag("head"))
	if terr != .None { return {}, map_parse_err(terr) }
	h, herr := parse.parse_head(bytes)
	return h, map_parse_err(herr)
}

@(private)
load_maxp_table :: proc(f: ^Font) -> (parse.Maxp_Table, Error) {
	bytes, terr := parse.find_table(&f._tables, f._data, parse.tag("maxp"))
	if terr != .None { return {}, map_parse_err(terr) }
	m, merr := parse.parse_maxp(bytes)
	return m, map_parse_err(merr)
}

@(private)
load_hhea_table :: proc(f: ^Font) -> (parse.Hhea_Table, Error) {
	bytes, terr := parse.find_table(&f._tables, f._data, parse.tag("hhea"))
	if terr != .None { return {}, map_parse_err(terr) }
	h, herr := parse.parse_hhea(bytes)
	return h, map_parse_err(herr)
}

// map_parse_err converts a parse.Error to a runa.Error. The two enums
// stay separate so the parse package never has to import its own
// public surface, but the variants line up one-for-one.
@(private)
map_parse_err :: proc(e: parse.Error) -> Error {
	switch e {
	case .None:               return .None
	case .Out_Of_Memory:      return .Out_Of_Memory
	case .Invalid_Table:      return .Invalid_Table
	case .Unsupported_Format: return .Unsupported_Format
	case .Table_Not_Found:    return .Table_Not_Found
	case .Glyph_Not_Found:    return .Glyph_Not_Found
	}
	return .Invalid_Table
}
