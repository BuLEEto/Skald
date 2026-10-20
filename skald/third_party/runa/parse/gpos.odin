package parse

// GPOS — Glyph Positioning Table.
//
// v0.1 implements lookup type 2 (pair positioning) in both formats:
//
//   Format 1: per-glyph-pair value record (specific kern pairs).
//   Format 2: class-based — every pair of (first-class, second-class)
//             carries a value record. The compression every modern
//             Latin font ships kerning under.
//
// Pair positioning is the only GPOS feature the v0.1 DoD actively
// requires (programming-font letter spacing improves visibly with it).
// Mark-to-base (type 4) and cursive attachment (type 3) land when the
// Arabic shaper does.
//
// Value records carry up to four signed i16 fields (x/y placement,
// x/y advance) — the runa shaper currently uses x_advance only;
// x_placement / y_placement are read but multiplied into per-glyph
// `x_offset` / `y_offset`.
//
// References: OpenType spec, "GPOS — Glyph Positioning Table".

GPOS_VERSION_1_0 :: u32(0x00010000)
GPOS_VERSION_1_1 :: u32(0x00010001)

VALUE_FORMAT_X_PLACEMENT       :: u16(0x0001)
VALUE_FORMAT_Y_PLACEMENT       :: u16(0x0002)
VALUE_FORMAT_X_ADVANCE         :: u16(0x0004)
VALUE_FORMAT_Y_ADVANCE         :: u16(0x0008)
VALUE_FORMAT_X_PLACEMENT_DEV   :: u16(0x0010)
VALUE_FORMAT_Y_PLACEMENT_DEV   :: u16(0x0020)
VALUE_FORMAT_X_ADVANCE_DEV     :: u16(0x0040)
VALUE_FORMAT_Y_ADVANCE_DEV     :: u16(0x0080)

Gpos :: struct {
	data:             []u8,
	script_list_off:  u16,
	feature_list_off: u16,
	lookup_list_off:  u16,
}

new_gpos :: proc(data: []u8) -> (g: Gpos, err: Error) {
	r := Reader{data = data}
	version := read_u32(&r) or_return
	if version != GPOS_VERSION_1_0 && version != GPOS_VERSION_1_1 {
		err = .Unsupported_Format
		return
	}
	g.data            = data
	g.script_list_off = read_u16(&r) or_return
	g.feature_list_off = read_u16(&r) or_return
	g.lookup_list_off = read_u16(&r) or_return
	return
}

gpos_resolve_feature_lookups :: proc(g: ^Gpos, script_tag, lang_tag, feature_tag: Tag, allocator := context.allocator) -> ([]u16, Error) {
	return resolve_feature_lookups(g.data, g.script_list_off, g.feature_list_off, script_tag, lang_tag, feature_tag, allocator)
}

gpos_get_lookup :: proc(g: ^Gpos, lookup_idx: u16, allocator := context.allocator) -> (Lookup_Info, Error) {
	return read_lookup_info(g.data, g.lookup_list_off, lookup_idx, allocator)
}

// Positioned glyph delta produced by GPOS. All values are in font
// units; multiply by `size/units_per_em` to get pixels.
//
// Note this is the *delta* applied to the base advance from `hmtx`,
// not the absolute advance. The shaper sums the two when emitting the
// final placement.
Pos_Adjust :: struct {
	x_placement: i16,
	y_placement: i16,
	x_advance:   i16,
	y_advance:   i16,
}

// gpos_apply_feature walks `gids` and applies positioning lookups for
// the named feature under (script, language). Each glyph's
// `adjusts[i]` receives the cumulative shift.
//
// Supported lookup types:
//
//   Type 2 — Pair positioning (kerning).
//   Type 4 — Mark-to-base attachment (`mark` feature).
//   Type 5 — Mark-to-ligature.   Type 6 — Mark-to-mark.
//   Type 9 — Extension: resolved to the wrapped type, then dispatched.
//
// Returns the number of adjustments applied.
gpos_apply_feature :: proc(g: ^Gpos, gids: []Glyph_ID, adjusts: []Pos_Adjust, script_tag, lang_tag, feature_tag: Tag) -> (n: int) {
	if len(gids) != len(adjusts) { return 0 }

	indices, _ := gpos_resolve_feature_lookups(g, script_tag, lang_tag, feature_tag, context.temp_allocator)
	for li in indices {
		info, err := gpos_get_lookup(g, li, context.temp_allocator)
		if err != .None { continue }

		// Extension (type 9): rewrite to the real lookup type + the real
		// subtable offsets, then dispatch as usual. All subtables of a
		// lookup share one type, so the last resolved type stands.
		if info.type == 9 {
			offs := make([dynamic]u32, 0, len(info.subtable_offsets), context.temp_allocator)
			rt: u16 = 0
			for sub in info.subtable_offsets {
				real_type, real_off, ok := resolve_extension(g.data, sub)
				if !ok || real_type == 9 { continue }
				rt = real_type
				append(&offs, real_off)
			}
			info.type = rt
			info.subtable_offsets = offs[:]
			info.allocator = false
		}

		switch info.type {
		case 2:
			for i in 0..<len(gids) - 1 {
				for sub in info.subtable_offsets {
					v1, v2, ok := pair_pos_lookup(g.data, sub, gids[i], gids[i + 1])
					if !ok { continue }
					adjusts[i].x_placement += v1.x_placement
					adjusts[i].y_placement += v1.y_placement
					adjusts[i].x_advance   += v1.x_advance
					adjusts[i].y_advance   += v1.y_advance
					adjusts[i + 1].x_placement += v2.x_placement
					adjusts[i + 1].y_placement += v2.y_placement
					adjusts[i + 1].x_advance   += v2.x_advance
					adjusts[i + 1].y_advance   += v2.y_advance
					n += 1
					break
				}
			}
		case 4:
			// Walk marks. For each glyph that lives in `markCoverage`,
			// scan backward to find the most recent base in
			// `baseCoverage`, ignoring intervening marks.
			for i in 1..<len(gids) {
				for sub in info.subtable_offsets {
					adj, base_idx, ok := mark_to_base_lookup(g.data, sub, gids[:], adjusts, i)
					if !ok { continue }
					_ = base_idx
					adjusts[i].x_placement += adj.x_placement
					adjusts[i].y_placement += adj.y_placement
					n += 1
					break
				}
			}
		case 5:
			// Mark-to-ligature: like type 4 but the base is a
			// ligature glyph composed of multiple components, and the
			// mark attaches to one specific component's anchor. v0.9
			// attaches every mark to the *last* component; full
			// component-index tracking arrives alongside the ligature-
			// component bookkeeping in the GSUB shaper for v1.0.
			for i in 1..<len(gids) {
				for sub in info.subtable_offsets {
					adj, base_idx, ok := mark_to_ligature_lookup(g.data, sub, gids[:], adjusts, i)
					if !ok { continue }
					_ = base_idx
					adjusts[i].x_placement += adj.x_placement
					adjusts[i].y_placement += adj.y_placement
					n += 1
					break
				}
			}
		case 6:
			// Mark-to-mark: identical to type 4 but the "base" must
			// itself be a mark. Stops scanning at the first
			// non-mark glyph rather than crossing into letters.
			for i in 1..<len(gids) {
				for sub in info.subtable_offsets {
					adj, base_idx, ok := mark_to_mark_lookup(g.data, sub, gids[:], adjusts, i)
					if !ok { continue }
					_ = base_idx
					adjusts[i].x_placement += adj.x_placement
					adjusts[i].y_placement += adj.y_placement
					n += 1
					break
				}
			}
		}
	}
	return
}

@(private)
pair_pos_lookup :: proc(data: []u8, sub_off: u32, first, second: Glyph_ID) -> (v1: Pos_Adjust, v2: Pos_Adjust, ok: bool) {
	if u64(sub_off) + 8 > u64(len(data)) { return }
	format := u16(data[sub_off])<<8 | u16(data[sub_off + 1])

	coverage_off := u32(u16(data[sub_off + 2])<<8 | u16(data[sub_off + 3]))
	value_format_1 := u16(data[sub_off + 4])<<8 | u16(data[sub_off + 5])
	value_format_2 := u16(data[sub_off + 6])<<8 | u16(data[sub_off + 7])

	cov_idx := coverage_index(data, sub_off + coverage_off, first)
	if cov_idx < 0 { return }

	v1_size := value_record_size(value_format_1)
	v2_size := value_record_size(value_format_2)

	switch format {
	case 1:
		return pair_pos_format_1(data, sub_off, u32(cov_idx), value_format_1, value_format_2, v1_size, v2_size, second)
	case 2:
		return pair_pos_format_2(data, sub_off, value_format_1, value_format_2, v1_size, v2_size, first, second)
	}
	return
}

@(private)
pair_pos_format_1 :: proc(data: []u8, sub_off: u32, cov_idx: u32, fmt1, fmt2: u16, v1_size, v2_size: int, second: Glyph_ID) -> (v1, v2: Pos_Adjust, ok: bool) {
	if u64(sub_off) + 10 > u64(len(data)) { return }
	set_count := u16(data[sub_off + 8])<<8 | u16(data[sub_off + 9])
	if cov_idx >= u32(set_count) { return }

	set_off_pos := sub_off + 10 + cov_idx * 2
	if u64(set_off_pos) + 2 > u64(len(data)) { return }
	set_off_rel := u32(u16(data[set_off_pos])<<8 | u16(data[set_off_pos + 1]))
	set_off := sub_off + set_off_rel

	if u64(set_off) + 2 > u64(len(data)) { return }
	pair_count := u16(data[set_off])<<8 | u16(data[set_off + 1])

	pair_size := 2 + v1_size + v2_size
	for i in 0..<int(pair_count) {
		p := set_off + 2 + u32(i) * u32(pair_size)
		if u64(p) + 2 > u64(len(data)) { break }
		second_gid := u16(data[p])<<8 | u16(data[p + 1])
		if second_gid != u16(second) { continue }
		// Read value records.
		v1 = read_value_record(data, p + 2, fmt1)
		v2 = read_value_record(data, p + 2 + u32(v1_size), fmt2)
		ok = true
		return
	}
	return
}

@(private)
pair_pos_format_2 :: proc(data: []u8, sub_off: u32, fmt1, fmt2: u16, v1_size, v2_size: int, first, second: Glyph_ID) -> (v1, v2: Pos_Adjust, ok: bool) {
	if u64(sub_off) + 16 > u64(len(data)) { return }
	class_def_1_off := u32(u16(data[sub_off + 8])<<8  | u16(data[sub_off +  9]))
	class_def_2_off := u32(u16(data[sub_off + 10])<<8 | u16(data[sub_off + 11]))
	class_1_count   :=     u16(data[sub_off + 12])<<8 | u16(data[sub_off + 13])
	class_2_count   :=     u16(data[sub_off + 14])<<8 | u16(data[sub_off + 15])

	c1 := class_def_lookup(data, sub_off + class_def_1_off, first)
	c2 := class_def_lookup(data, sub_off + class_def_2_off, second)
	if c1 < 0 || c2 < 0 { return }
	if c1 >= int(class_1_count) || c2 >= int(class_2_count) { return }

	row_size := u32(v1_size + v2_size) * u32(class_2_count)
	cell := sub_off + 16 + u32(c1) * row_size + u32(c2) * u32(v1_size + v2_size)
	if u64(cell) + u64(v1_size + v2_size) > u64(len(data)) { return }
	v1 = read_value_record(data, cell, fmt1)
	v2 = read_value_record(data, cell + u32(v1_size), fmt2)
	ok = true
	return
}

// mark_to_base_lookup applies GPOS lookup type 4 (mark-to-base) at
// position `mark_idx`. Returns the placement delta to add to the mark
// glyph, plus the resolved base glyph index (for caller diagnostics).
//
// Subtable layout (format 1 only — the spec defines no others):
//
//   format             u16  = 1
//   mark_coverage_off  Offset16  (relative to subtable)
//   base_coverage_off  Offset16
//   mark_class_count   u16
//   mark_array_off     Offset16
//   base_array_off     Offset16
//
// MarkArray:   count u16, mark_records[count] = { class u16, anchor_off Offset16 (from MarkArray start) }
// BaseArray:   count u16, base_records[count] each carrying `mark_class_count` anchor offsets
// Anchor (fmt 1): format u16 = 1, x i16, y i16. Formats 2/3 add an
//                 attachment point / device tables; we read just the x/y
//                 for any format and ignore the rest.
@(private)
mark_to_base_lookup :: proc(data: []u8, sub_off: u32, gids: []Glyph_ID, adjusts: []Pos_Adjust, mark_idx: int) -> (adj: Pos_Adjust, base_idx: int, ok: bool) {
	if u64(sub_off) + 12 > u64(len(data)) { return }
	format := u16(data[sub_off])<<8 | u16(data[sub_off + 1])
	if format != 1 { return }
	mark_cov_off := u32(u16(data[sub_off + 2])<<8 | u16(data[sub_off + 3]))
	base_cov_off := u32(u16(data[sub_off + 4])<<8 | u16(data[sub_off + 5]))
	mark_class_count := u16(data[sub_off + 6])<<8 | u16(data[sub_off + 7])
	mark_array_off := u32(u16(data[sub_off + 8])<<8 | u16(data[sub_off + 9]))
	base_array_off := u32(u16(data[sub_off + 10])<<8 | u16(data[sub_off + 11]))

	mark_cov_idx := coverage_index(data, sub_off + mark_cov_off, gids[mark_idx])
	if mark_cov_idx < 0 { return }

	// Scan back for the most recent glyph in base coverage. Glyphs
	// that are themselves in mark coverage skip — they're attachable
	// children of an earlier base. Anything else (un-classified
	// glyph) also acts as a base "barrier" for safety: don't reach
	// across word boundaries.
	bi := -1
	for j := mark_idx - 1; j >= 0; j -= 1 {
		idx := coverage_index(data, sub_off + base_cov_off, gids[j])
		if idx >= 0 { bi = j; break }
		// If this glyph is a mark too, keep scanning; otherwise stop
		// (e.g. a space glyph isn't a base, but it shouldn't anchor
		// either).
		if coverage_index(data, sub_off + mark_cov_off, gids[j]) >= 0 { continue }
		return
	}
	if bi < 0 { return }
	base_cov_idx := coverage_index(data, sub_off + base_cov_off, gids[bi])

	// Read the mark record: { mark_class u16, anchor_off Offset16 }
	mark_array_base := sub_off + mark_array_off
	if u64(mark_array_base) + 2 > u64(len(data)) { return }
	mark_count := u16(data[mark_array_base])<<8 | u16(data[mark_array_base + 1])
	if u32(mark_cov_idx) >= u32(mark_count) { return }
	rec_off := mark_array_base + 2 + u32(mark_cov_idx) * 4
	if u64(rec_off) + 4 > u64(len(data)) { return }
	mark_class  := u16(data[rec_off])<<8 | u16(data[rec_off + 1])
	mark_anchor_off := u32(u16(data[rec_off + 2])<<8 | u16(data[rec_off + 3]))
	if mark_class >= mark_class_count { return }
	mx, my, mok := read_anchor(data, mark_array_base + mark_anchor_off)
	if !mok { return }

	// Read the base record: an array of `mark_class_count` anchor
	// offsets (relative to BaseArray start).
	base_array_base := sub_off + base_array_off
	if u64(base_array_base) + 2 > u64(len(data)) { return }
	base_count := u16(data[base_array_base])<<8 | u16(data[base_array_base + 1])
	if u32(base_cov_idx) >= u32(base_count) { return }
	base_rec_off := base_array_base + 2 + u32(base_cov_idx) * u32(mark_class_count) * 2
	if u64(base_rec_off) + u64(mark_class_count) * 2 > u64(len(data)) { return }
	anchor_off_pos := base_rec_off + u32(mark_class) * 2
	base_anchor_off := u32(u16(data[anchor_off_pos])<<8 | u16(data[anchor_off_pos + 1]))
	if base_anchor_off == 0 { return }                  // null offset — this class doesn't attach here
	bx, by, bok := read_anchor(data, base_array_base + base_anchor_off)
	if !bok { return }

	// Mark placement: base.anchor - mark.anchor, then subtract the
	// running advance of every glyph between the base and the mark
	// so the mark lands ON the base anchor rather than at the mark's
	// pen position.
	dx: i32 = i32(bx) - i32(mx)
	dy: i32 = i32(by) - i32(my)
	for j := bi; j < mark_idx; j += 1 {
		dx -= i32(adjusts[j].x_advance)
	}
	adj.x_placement = i32_to_i16_sat(dx)
	adj.y_placement = i32_to_i16_sat(dy)
	base_idx = bi
	ok = true
	return
}

// mark_to_ligature_lookup applies GPOS lookup type 5 at `mark_idx`.
//
// Subtable layout (format 1 only):
//   format               u16 = 1
//   mark_coverage_off    Offset16
//   ligature_coverage_off Offset16
//   mark_class_count     u16
//   mark_array_off       Offset16
//   ligature_array_off   Offset16
//
// LigatureArray:
//   ligature_count       u16
//   ligature_attach_offs[ligature_count]  u16 (relative to LigatureArray)
//
// LigatureAttach:
//   component_count      u16
//   component_records[component_count] each carrying `mark_class_count`
//   anchor offsets (relative to LigatureAttach start).
//
// The mark attaches to one *component* of the ligature. v0.9 binds
// to the LAST component when no component-index tracking is
// available; the typical Indic / Arabic shaping pipeline overrides
// this once GSUB ligature substitution records component spans.
@(private)
mark_to_ligature_lookup :: proc(data: []u8, sub_off: u32, gids: []Glyph_ID, adjusts: []Pos_Adjust, mark_idx: int) -> (adj: Pos_Adjust, base_idx: int, ok: bool) {
	if u64(sub_off) + 12 > u64(len(data)) { return }
	format := u16(data[sub_off])<<8 | u16(data[sub_off + 1])
	if format != 1 { return }
	mark_cov_off := u32(u16(data[sub_off + 2])<<8 | u16(data[sub_off + 3]))
	lig_cov_off  := u32(u16(data[sub_off + 4])<<8 | u16(data[sub_off + 5]))
	mark_class_count := u16(data[sub_off + 6])<<8 | u16(data[sub_off + 7])
	mark_array_off   := u32(u16(data[sub_off + 8])<<8 | u16(data[sub_off + 9]))
	lig_array_off    := u32(u16(data[sub_off + 10])<<8 | u16(data[sub_off + 11]))

	mark_cov_idx := coverage_index(data, sub_off + mark_cov_off, gids[mark_idx])
	if mark_cov_idx < 0 { return }

	// Scan back to find the ligature.
	bi := -1
	for j := mark_idx - 1; j >= 0; j -= 1 {
		idx := coverage_index(data, sub_off + lig_cov_off, gids[j])
		if idx >= 0 { bi = j; break }
		if coverage_index(data, sub_off + mark_cov_off, gids[j]) >= 0 { continue }
		return
	}
	if bi < 0 { return }
	lig_cov_idx := coverage_index(data, sub_off + lig_cov_off, gids[bi])

	// Read mark record.
	mark_array_base := sub_off + mark_array_off
	if u64(mark_array_base) + 2 > u64(len(data)) { return }
	mark_count := u16(data[mark_array_base])<<8 | u16(data[mark_array_base + 1])
	if u32(mark_cov_idx) >= u32(mark_count) { return }
	rec_off := mark_array_base + 2 + u32(mark_cov_idx) * 4
	if u64(rec_off) + 4 > u64(len(data)) { return }
	mark_class := u16(data[rec_off])<<8 | u16(data[rec_off + 1])
	mark_anchor_off := u32(u16(data[rec_off + 2])<<8 | u16(data[rec_off + 3]))
	if mark_class >= mark_class_count { return }
	mx, my, mok := read_anchor(data, mark_array_base + mark_anchor_off)
	if !mok { return }

	// Walk LigatureArray → LigatureAttach for the matched ligature
	// glyph.
	lig_array_base := sub_off + lig_array_off
	if u64(lig_array_base) + 2 > u64(len(data)) { return }
	lig_count := u16(data[lig_array_base])<<8 | u16(data[lig_array_base + 1])
	if u32(lig_cov_idx) >= u32(lig_count) { return }
	attach_off_pos := lig_array_base + 2 + u32(lig_cov_idx) * 2
	if u64(attach_off_pos) + 2 > u64(len(data)) { return }
	attach_rel := u32(u16(data[attach_off_pos])<<8 | u16(data[attach_off_pos + 1]))
	attach_base := lig_array_base + attach_rel
	if u64(attach_base) + 2 > u64(len(data)) { return }
	component_count := u16(data[attach_base])<<8 | u16(data[attach_base + 1])
	if component_count == 0 { return }

	// Default to the last component until ligature-component tracking
	// lands. Each component record holds `mark_class_count` Offset16
	// anchor offsets (relative to LigatureAttach start).
	component_idx := u32(component_count) - 1
	comp_rec_off := attach_base + 2 + component_idx * u32(mark_class_count) * 2
	if u64(comp_rec_off) + u64(mark_class_count) * 2 > u64(len(data)) { return }
	anchor_off_pos := comp_rec_off + u32(mark_class) * 2
	lig_anchor_off := u32(u16(data[anchor_off_pos])<<8 | u16(data[anchor_off_pos + 1]))
	if lig_anchor_off == 0 { return }
	bx, by, bok := read_anchor(data, attach_base + lig_anchor_off)
	if !bok { return }

	dx: i32 = i32(bx) - i32(mx)
	dy: i32 = i32(by) - i32(my)
	for j := bi; j < mark_idx; j += 1 {
		dx -= i32(adjusts[j].x_advance)
	}
	adj.x_placement = i32_to_i16_sat(dx)
	adj.y_placement = i32_to_i16_sat(dy)
	base_idx = bi
	ok = true
	return
}

// mark_to_mark_lookup applies GPOS lookup type 6 (mark-to-mark) at
// position `mark_idx`. Subtable layout mirrors type 4 but the
// "base" array is a `Mark2Array` of mark glyphs:
//
//   format               u16  = 1
//   mark1_coverage_off   Offset16   (the attaching mark)
//   mark2_coverage_off   Offset16   (the previously-placed mark)
//   mark_class_count     u16
//   mark1_array_off      Offset16
//   mark2_array_off      Offset16
//
// The scan stops at the first non-mark2 glyph: stacked marks land on
// their immediate mark-predecessor, not across word boundaries.
@(private)
mark_to_mark_lookup :: proc(data: []u8, sub_off: u32, gids: []Glyph_ID, adjusts: []Pos_Adjust, mark_idx: int) -> (adj: Pos_Adjust, base_idx: int, ok: bool) {
	if u64(sub_off) + 12 > u64(len(data)) { return }
	format := u16(data[sub_off])<<8 | u16(data[sub_off + 1])
	if format != 1 { return }
	m1_cov_off := u32(u16(data[sub_off + 2])<<8 | u16(data[sub_off + 3]))
	m2_cov_off := u32(u16(data[sub_off + 4])<<8 | u16(data[sub_off + 5]))
	mark_class_count := u16(data[sub_off + 6])<<8 | u16(data[sub_off + 7])
	m1_array_off := u32(u16(data[sub_off + 8])<<8 | u16(data[sub_off + 9]))
	m2_array_off := u32(u16(data[sub_off + 10])<<8 | u16(data[sub_off + 11]))

	m1_cov_idx := coverage_index(data, sub_off + m1_cov_off, gids[mark_idx])
	if m1_cov_idx < 0 { return }

	// Look for the immediate mark2 predecessor.
	bi := -1
	for j := mark_idx - 1; j >= 0; j -= 1 {
		idx := coverage_index(data, sub_off + m2_cov_off, gids[j])
		if idx >= 0 { bi = j; break }
		break                                       // not a mark2 — stop
	}
	if bi < 0 { return }
	m2_cov_idx := coverage_index(data, sub_off + m2_cov_off, gids[bi])

	// Mark1 anchor.
	m1_array_base := sub_off + m1_array_off
	if u64(m1_array_base) + 2 > u64(len(data)) { return }
	m1_count := u16(data[m1_array_base])<<8 | u16(data[m1_array_base + 1])
	if u32(m1_cov_idx) >= u32(m1_count) { return }
	rec_off := m1_array_base + 2 + u32(m1_cov_idx) * 4
	if u64(rec_off) + 4 > u64(len(data)) { return }
	mark_class := u16(data[rec_off])<<8 | u16(data[rec_off + 1])
	m1_anchor_off := u32(u16(data[rec_off + 2])<<8 | u16(data[rec_off + 3]))
	if mark_class >= mark_class_count { return }
	mx, my, mok := read_anchor(data, m1_array_base + m1_anchor_off)
	if !mok { return }

	// Mark2 anchor.
	m2_array_base := sub_off + m2_array_off
	if u64(m2_array_base) + 2 > u64(len(data)) { return }
	m2_count := u16(data[m2_array_base])<<8 | u16(data[m2_array_base + 1])
	if u32(m2_cov_idx) >= u32(m2_count) { return }
	m2_rec_off := m2_array_base + 2 + u32(m2_cov_idx) * u32(mark_class_count) * 2
	if u64(m2_rec_off) + u64(mark_class_count) * 2 > u64(len(data)) { return }
	anchor_off_pos := m2_rec_off + u32(mark_class) * 2
	m2_anchor_off := u32(u16(data[anchor_off_pos])<<8 | u16(data[anchor_off_pos + 1]))
	if m2_anchor_off == 0 { return }
	bx, by, bok := read_anchor(data, m2_array_base + m2_anchor_off)
	if !bok { return }

	dx: i32 = i32(bx) - i32(mx)
	dy: i32 = i32(by) - i32(my)
	for j := bi; j < mark_idx; j += 1 {
		dx -= i32(adjusts[j].x_advance)
	}
	adj.x_placement = i32_to_i16_sat(dx)
	adj.y_placement = i32_to_i16_sat(dy)
	base_idx = bi
	ok = true
	return
}

@(private)
read_anchor :: proc(data: []u8, off: u32) -> (x, y: i16, ok: bool) {
	if u64(off) + 6 > u64(len(data)) { return }
	// All anchor formats start with `format u16, x i16, y i16`. Higher
	// formats append optional attachment / device data we ignore.
	x = i16(u16(data[off + 2])<<8 | u16(data[off + 3]))
	y = i16(u16(data[off + 4])<<8 | u16(data[off + 5]))
	ok = true
	return
}

@(private)
i32_to_i16_sat :: #force_inline proc(v: i32) -> i16 {
	if v >  32767 { return  32767 }
	if v < -32768 { return -32768 }
	return i16(v)
}

@(private)
value_record_size :: proc(fmt: u16) -> int {
	size := 0
	for bit: u16 = 1; bit != 0; bit <<= 1 {
		if fmt & bit != 0 { size += 2 }
	}
	return size
}

@(private)
read_value_record :: proc(data: []u8, off: u32, fmt: u16) -> Pos_Adjust {
	r := Pos_Adjust{}
	p := off
	read_field :: proc(data: []u8, p: ^u32) -> i16 {
		if u64(p^) + 2 > u64(len(data)) { return 0 }
		v := i16(u16(data[p^])<<8 | u16(data[p^ + 1]))
		p^ += 2
		return v
	}
	if fmt & VALUE_FORMAT_X_PLACEMENT       != 0 { r.x_placement = read_field(data, &p) }
	if fmt & VALUE_FORMAT_Y_PLACEMENT       != 0 { r.y_placement = read_field(data, &p) }
	if fmt & VALUE_FORMAT_X_ADVANCE         != 0 { r.x_advance   = read_field(data, &p) }
	if fmt & VALUE_FORMAT_Y_ADVANCE         != 0 { r.y_advance   = read_field(data, &p) }
	// Device-table offsets occupy 2 bytes each but don't carry positional
	// data we use at v0.1 — skip them.
	if fmt & VALUE_FORMAT_X_PLACEMENT_DEV   != 0 { _ = read_field(data, &p) }
	if fmt & VALUE_FORMAT_Y_PLACEMENT_DEV   != 0 { _ = read_field(data, &p) }
	if fmt & VALUE_FORMAT_X_ADVANCE_DEV     != 0 { _ = read_field(data, &p) }
	if fmt & VALUE_FORMAT_Y_ADVANCE_DEV     != 0 { _ = read_field(data, &p) }
	return r
}

// class_def_lookup returns the class index of `gid` per a ClassDef table
// at `data[off:]`, or -1 if the glyph isn't covered. Class 0 is the
// "default" class for any glyph not explicitly listed.
//
// Format 1: format=1, startGlyphID, glyphCount, classes[glyphCount].
// Format 2: format=2, classRangeCount, ClassRangeRecord[count].
@(private)
class_def_lookup :: proc(data: []u8, off: u32, gid: Glyph_ID) -> int {
	if u64(off) + 4 > u64(len(data)) { return -1 }
	format := u16(data[off])<<8 | u16(data[off + 1])
	switch format {
	case 1:
		start := u16(data[off + 2])<<8 | u16(data[off + 3])
		if u64(off) + 6 > u64(len(data)) { return -1 }
		count := u16(data[off + 4])<<8 | u16(data[off + 5])
		if u16(gid) < start { return 0 }                 // class 0 = default
		idx := int(u16(gid) - start)
		if idx >= int(count) { return 0 }
		p := off + 6 + u32(idx) * 2
		if u64(p) + 2 > u64(len(data)) { return -1 }
		return int(u16(data[p])<<8 | u16(data[p + 1]))
	case 2:
		count := u16(data[off + 2])<<8 | u16(data[off + 3])
		base := off + 4
		if u64(base) + u64(count) * 6 > u64(len(data)) { return -1 }
		// Linear scan — class-def ranges are short in practice (~16-128).
		for i in 0..<int(count) {
			p := base + u32(i) * 6
			s := u16(data[p])<<8     | u16(data[p + 1])
			e := u16(data[p + 2])<<8 | u16(data[p + 3])
			c := u16(data[p + 4])<<8 | u16(data[p + 5])
			if u16(gid) >= s && u16(gid) <= e { return int(c) }
		}
		return 0
	}
	return -1
}
