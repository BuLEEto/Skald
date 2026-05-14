package parse

// GSUB — Glyph Substitution Table.
//
// v0.1 implements these lookup types:
//
//   Type 1   Single substitution         — one glyph for another.
//   Type 4   Ligature substitution       — N glyphs to one.
//   Type 6   Chaining contextual subst.  — N glyphs match a context,
//                                          then trigger nested lookups
//                                          (format 3 only, the form
//                                          modern programming fonts use).
//
// These three cover the v0.1 feature set:
//
//   `liga` / `clig` / `rlig` — usually type 4.
//   `calt` (FiraCode's ligature mechanism, ditto JetBrains Mono) — type 6
//                                          with a nested type-1 or type-4.
//   `locl` — usually type 1 (per-script glyph remap).
//
// Other lookup types (2 multiple, 3 alternate, 5 contextual, 7
// extension, 8 reverse-chained) are parsed-but-not-executed at v0.1 —
// they get bodies when their scripts arrive.
//
// References: OpenType spec, "Glyph Substitution Table".

GSUB_VERSION_1_0 :: u32(0x00010000)
GSUB_VERSION_1_1 :: u32(0x00010001)

// Maximum recursion depth for nested lookup chains. The spec caps at
// 16 but most real fonts max out at 4 or so. A deeper chain is either
// malicious or a parser-state bug.
GSUB_MAX_NEST_DEPTH :: 16

Gsub :: struct {
	data:             []u8,
	script_list_off:  u16,
	feature_list_off: u16,
	lookup_list_off:  u16,
}

new_gsub :: proc(data: []u8) -> (g: Gsub, err: Error) {
	r := Reader{data = data}
	version := read_u32(&r) or_return
	if version != GSUB_VERSION_1_0 && version != GSUB_VERSION_1_1 {
		err = .Unsupported_Format
		return
	}
	g.data            = data
	g.script_list_off = read_u16(&r) or_return
	g.feature_list_off = read_u16(&r) or_return
	g.lookup_list_off = read_u16(&r) or_return
	return
}

// gsub_resolve_feature_lookups returns the lookup indices for
// (script, language, feature). Caller frees the slice with `delete`.
gsub_resolve_feature_lookups :: proc(g: ^Gsub, script_tag, lang_tag, feature_tag: Tag, allocator := context.allocator) -> ([]u16, Error) {
	return resolve_feature_lookups(g.data, g.script_list_off, g.feature_list_off, script_tag, lang_tag, feature_tag, allocator)
}

// gsub_get_lookup returns the Lookup record at `lookup_idx`. Caller
// frees with `lookup_info_destroy`.
gsub_get_lookup :: proc(g: ^Gsub, lookup_idx: u16, allocator := context.allocator) -> (Lookup_Info, Error) {
	return read_lookup_info(g.data, g.lookup_list_off, lookup_idx, allocator)
}

// gsub_apply_single_at runs the type-1 (single-substitution) lookups
// of `feature_tag` against a single buffer position. Returns true
// if any substitution fired.
//
// Used by per-position feature gating — Arabic `isol` / `init` /
// `medi` / `fina` need to fire only at glyphs whose joining state
// matches that feature; a buffer-wide `gsub_apply_feature` would
// over-substitute.
gsub_apply_single_at :: proc(g: ^Gsub, gids: []Glyph_ID, pos: int, script_tag, lang_tag, feature_tag: Tag) -> bool {
	if pos < 0 || pos >= len(gids) { return false }
	indices, _ := gsub_resolve_feature_lookups(g, script_tag, lang_tag, feature_tag, context.temp_allocator)
	for li in indices {
		info, err := gsub_get_lookup(g, li, context.temp_allocator)
		if err != .None { continue }
		if info.type != 1 { continue }
		for sub in info.subtable_offsets {
			if apply_single(g.data, sub, gids, pos) { return true }
		}
	}
	return false
}

// gsub_apply_feature walks `glyphs` left-to-right and applies every
// lookup associated with `feature_tag` under (script, language).
// Returns the total number of substitutions made (across all lookups).
//
// Lookups are applied in lookup-list-index order. Each lookup walks
// the buffer top-down again. This matches HarfBuzz's "apply each
// lookup as a separate pass" model — slower than a single fused walk
// but trivially correct for the v0.1 feature set.
gsub_apply_feature :: proc(g: ^Gsub, glyphs: ^[dynamic]Glyph_ID, script_tag, lang_tag, feature_tag: Tag) -> (subs: int) {
	indices, _ := gsub_resolve_feature_lookups(g, script_tag, lang_tag, feature_tag, context.temp_allocator)
	for li in indices {
		info, err := gsub_get_lookup(g, li, context.temp_allocator)
		if err != .None { continue }
		subs += gsub_apply_lookup_pass(g, &info, glyphs, 0)
	}
	return
}

// gsub_apply_lookup_pass scans `glyphs` from `start` to the end and
// applies the lookup at each position. The lookup may rewrite the
// buffer; the scan advances by the number of glyphs the lookup
// consumed at each position.
@(private)
gsub_apply_lookup_pass :: proc(g: ^Gsub, info: ^Lookup_Info, glyphs: ^[dynamic]Glyph_ID, start: int) -> (subs: int) {
	i := start
	for i < len(glyphs) {
		consumed := gsub_dispatch_lookup(g, info, glyphs, i, 0)
		if consumed > 0 {
			subs += 1
			i += consumed
		} else {
			i += 1
		}
	}
	return
}

// gsub_dispatch_lookup attempts to apply a lookup at glyph position
// `pos`. Returns the number of glyphs consumed (i.e. how far the
// caller should advance) on a successful match. Returns 0 on no
// match.
//
// `depth` is the recursion depth for nested lookups invoked by type 6.
@(private)
gsub_dispatch_lookup :: proc(g: ^Gsub, info: ^Lookup_Info, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	if depth > GSUB_MAX_NEST_DEPTH { return 0 }
	if pos < 0 || pos >= len(glyphs) { return 0 }

	switch info.type {
	case 1:
		for sub in info.subtable_offsets {
			if ok := apply_single(g.data, sub, glyphs[:], pos); ok {
				return 1
			}
		}
	case 4:
		for sub in info.subtable_offsets {
			if ok, consumed, lig := apply_ligature(g.data, sub, glyphs[:], pos); ok {
				glyphs[pos] = lig
				for _ in 1..<consumed {
					ordered_remove(glyphs, pos + 1)
				}
				return 1
			}
		}
	case 5:
		for sub in info.subtable_offsets {
			if consumed := apply_context(g, sub, glyphs, pos, depth); consumed > 0 {
				return consumed
			}
		}
	case 6:
		for sub in info.subtable_offsets {
			if consumed := apply_chained_context(g, sub, glyphs, pos, depth); consumed > 0 {
				return consumed
			}
		}
	}
	return 0
}

// apply_context — GSUB lookup type 5 "Contextual Substitution",
// formats 1 (glyph sequence), 2 (class-based), and 3 (coverage-
// based). Type 5 is the precursor of type 6 (chaining context) but
// without backtrack / lookahead — it matches a single forward
// glyph sequence and triggers nested substitution lookups at
// specific positions within that match.
@(private)
apply_context :: proc(g: ^Gsub, sub_off: u32, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	d := g.data
	if u64(sub_off) + 2 > u64(len(d)) { return 0 }
	format := u16(d[sub_off])<<8 | u16(d[sub_off + 1])

	switch format {
	case 1:
		return apply_context_format_1(g, sub_off, glyphs, pos, depth)
	case 2:
		return apply_context_format_2(g, sub_off, glyphs, pos, depth)
	case 3:
		return apply_context_format_3(g, sub_off, glyphs, pos, depth)
	}
	return 0
}

// Type 5 format 1 — simple glyph-sequence context.
// Layout:
//   2  format = 1
//   2  coverageOffset
//   2  seqRuleSetCount
//   2*seqRuleSetCount  seqRuleSetOffsets
//
// Each SequenceRuleSet:
//   2  seqRuleCount
//   2*seqRuleCount     seqRuleOffsets
//
// Each SequenceRule:
//   2  glyphCount
//   2  seqLookupCount
//   2*(glyphCount - 1)  inputSequence
//   4*seqLookupCount    seqLookupRecords (seqIdx u16, lookupIdx u16)
@(private)
apply_context_format_1 :: proc(g: ^Gsub, sub_off: u32, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	d := g.data
	if u64(sub_off) + 6 > u64(len(d)) { return 0 }
	cov_off := u32(u16(d[sub_off + 2])<<8 | u16(d[sub_off + 3]))
	cov_idx := coverage_index(d, sub_off + cov_off, glyphs[pos])
	if cov_idx < 0 { return 0 }

	rule_set_count := int(u16(d[sub_off + 4])<<8 | u16(d[sub_off + 5]))
	if cov_idx >= rule_set_count { return 0 }
	rs_off_pos := sub_off + 6 + u32(cov_idx) * 2
	if u64(rs_off_pos) + 2 > u64(len(d)) { return 0 }
	rs_rel := u32(u16(d[rs_off_pos])<<8 | u16(d[rs_off_pos + 1]))
	if rs_rel == 0 { return 0 }
	rs := sub_off + rs_rel
	if u64(rs) + 2 > u64(len(d)) { return 0 }
	rule_count := int(u16(d[rs])<<8 | u16(d[rs + 1]))
	for i in 0..<rule_count {
		rp := rs + 2 + u32(i) * 2
		if u64(rp) + 2 > u64(len(d)) { break }
		rule_rel := u32(u16(d[rp])<<8 | u16(d[rp + 1]))
		rule := rs + rule_rel
		if u64(rule) + 4 > u64(len(d)) { continue }
		glyph_count := int(u16(d[rule])<<8 | u16(d[rule + 1]))
		seq_count   := int(u16(d[rule + 2])<<8 | u16(d[rule + 3]))
		if glyph_count < 1 { continue }
		if pos + glyph_count > len(glyphs) { continue }
		seq_off := rule + 4
		matched := true
		for k in 1..<glyph_count {
			gp := seq_off + u32(k - 1) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want := u16(d[gp])<<8 | u16(d[gp + 1])
			if u16(glyphs[pos + k]) != want { matched = false; break }
		}
		if !matched { continue }
		seq_recs := seq_off + u32(glyph_count - 1) * 2
		return apply_seq_lookups(g, glyphs, pos, glyph_count, seq_recs, seq_count, depth)
	}
	return 0
}

// Type 5 format 2 — class-based context.
@(private)
apply_context_format_2 :: proc(g: ^Gsub, sub_off: u32, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	d := g.data
	if u64(sub_off) + 8 > u64(len(d)) { return 0 }
	cov_off    := u32(u16(d[sub_off + 2])<<8 | u16(d[sub_off + 3]))
	class_off  := u32(u16(d[sub_off + 4])<<8 | u16(d[sub_off + 5]))
	class_set_count := int(u16(d[sub_off + 6])<<8 | u16(d[sub_off + 7]))
	if coverage_index(d, sub_off + cov_off, glyphs[pos]) < 0 { return 0 }

	cls := class_of(d, sub_off + class_off, glyphs[pos])
	if cls >= u16(class_set_count) { return 0 }
	cs_off_pos := sub_off + 8 + u32(cls) * 2
	if u64(cs_off_pos) + 2 > u64(len(d)) { return 0 }
	cs_rel := u32(u16(d[cs_off_pos])<<8 | u16(d[cs_off_pos + 1]))
	if cs_rel == 0 { return 0 }
	cs := sub_off + cs_rel
	if u64(cs) + 2 > u64(len(d)) { return 0 }
	rule_count := int(u16(d[cs])<<8 | u16(d[cs + 1]))
	for i in 0..<rule_count {
		rp := cs + 2 + u32(i) * 2
		if u64(rp) + 2 > u64(len(d)) { break }
		rule_rel := u32(u16(d[rp])<<8 | u16(d[rp + 1]))
		rule := cs + rule_rel
		if u64(rule) + 4 > u64(len(d)) { continue }
		glyph_count := int(u16(d[rule])<<8 | u16(d[rule + 1]))
		seq_count   := int(u16(d[rule + 2])<<8 | u16(d[rule + 3]))
		if glyph_count < 1 { continue }
		if pos + glyph_count > len(glyphs) { continue }
		seq_off := rule + 4
		matched := true
		for k in 1..<glyph_count {
			gp := seq_off + u32(k - 1) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want_cls := u16(d[gp])<<8 | u16(d[gp + 1])
			if class_of(d, sub_off + class_off, glyphs[pos + k]) != want_cls { matched = false; break }
		}
		if !matched { continue }
		seq_recs := seq_off + u32(glyph_count - 1) * 2
		return apply_seq_lookups(g, glyphs, pos, glyph_count, seq_recs, seq_count, depth)
	}
	return 0
}

// Type 5 format 3 — coverage-array-based context. Same shape as type
// 6 format 3 without the backtrack / lookahead arrays.
@(private)
apply_context_format_3 :: proc(g: ^Gsub, sub_off: u32, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	d := g.data
	if u64(sub_off) + 6 > u64(len(d)) { return 0 }
	in_count := int(u16(d[sub_off + 2])<<8 | u16(d[sub_off + 3]))
	seq_count := int(u16(d[sub_off + 4])<<8 | u16(d[sub_off + 5]))
	if in_count == 0 { return 0 }
	if pos + in_count > len(glyphs) { return 0 }

	in_offs_base := sub_off + 6
	if u64(in_offs_base) + u64(in_count) * 2 > u64(len(d)) { return 0 }

	// Wait — the seq_count is actually positioned AFTER the input
	// coverage offsets, not before. Reparse layout per spec:
	//   2  format
	//   2  glyphCount     (== in_count)
	//   2  seqLookupCount (== seq_count)
	//   2*glyphCount  coverageOffsets
	//   4*seqLookupCount  seqLookupRecords
	in_offs_base = sub_off + 6
	if u64(in_offs_base) + u64(in_count) * 2 > u64(len(d)) { return 0 }
	for i in 0..<in_count {
		p := in_offs_base + u32(i) * 2
		off := u32(u16(d[p])<<8 | u16(d[p + 1]))
		if coverage_index(d, sub_off + off, glyphs[pos + i]) < 0 { return 0 }
	}
	seq_recs := in_offs_base + u32(in_count) * 2
	return apply_seq_lookups(g, glyphs, pos, in_count, seq_recs, seq_count, depth)
}

// apply_seq_lookups runs the SubstLookupRecord array shared by type
// 5 and type 6 contextual subtables.
@(private)
apply_seq_lookups :: proc(g: ^Gsub, glyphs: ^[dynamic]Glyph_ID, pos, window_size: int, seq_recs_base: u32, seq_count, depth: int) -> int {
	d := g.data
	consumed := window_size
	for s in 0..<seq_count {
		p := seq_recs_base + u32(s) * 4
		if u64(p) + 4 > u64(len(d)) { break }
		seq_idx := int(u16(d[p])<<8 | u16(d[p + 1]))
		lookup_idx := u16(d[p + 2])<<8 | u16(d[p + 3])
		if seq_idx >= consumed { continue }

		nested, err := gsub_get_lookup(g, lookup_idx, context.temp_allocator)
		if err != .None { continue }

		before := len(glyphs)
		_ = gsub_dispatch_lookup(g, &nested, glyphs, pos + seq_idx, depth + 1)
		after := len(glyphs)
		if before > after {
			consumed -= (before - after)
			if consumed < 1 { consumed = 1 }
		}
	}
	return consumed
}

// class_of looks up the ClassDef class for `g` in a ClassDef table at
// `off`. Format 1 = range start + class array; format 2 = sorted range
// records.
@(private)
class_of :: proc(data: []u8, off: u32, g: Glyph_ID) -> u16 {
	if u64(off) + 2 > u64(len(data)) { return 0 }
	format := u16(data[off])<<8 | u16(data[off + 1])
	switch format {
	case 1:
		if u64(off) + 6 > u64(len(data)) { return 0 }
		start := u16(data[off + 2])<<8 | u16(data[off + 3])
		count := u16(data[off + 4])<<8 | u16(data[off + 5])
		if u16(g) < start || u16(g) >= start + count { return 0 }
		p := off + 6 + u32(u16(g) - start) * 2
		if u64(p) + 2 > u64(len(data)) { return 0 }
		return u16(data[p])<<8 | u16(data[p + 1])
	case 2:
		if u64(off) + 4 > u64(len(data)) { return 0 }
		nr := int(u16(data[off + 2])<<8 | u16(data[off + 3]))
		lo, hi := 0, nr
		for lo < hi {
			mid := (lo + hi) / 2
			rp := off + 4 + u32(mid) * 6
			if u64(rp) + 6 > u64(len(data)) { return 0 }
			r_start := u16(data[rp])<<8     | u16(data[rp + 1])
			r_end   := u16(data[rp + 2])<<8 | u16(data[rp + 3])
			switch {
			case u16(g) < r_start: hi = mid
			case u16(g) > r_end:   lo = mid + 1
			case:                  return u16(data[rp + 4])<<8 | u16(data[rp + 5])
			}
		}
	}
	return 0
}

// ---- Lookup type 1: Single substitution -----------------------------

@(private)
apply_single :: proc(data: []u8, sub_off: u32, glyphs: []Glyph_ID, pos: int) -> bool {
	if u64(sub_off) + 6 > u64(len(data)) { return false }
	format := u16(data[sub_off])<<8 | u16(data[sub_off + 1])
	coverage_off := u32(u16(data[sub_off + 2])<<8 | u16(data[sub_off + 3]))

	cov_idx := coverage_index(data, sub_off + coverage_off, glyphs[pos])
	if cov_idx < 0 { return false }

	switch format {
	case 1:
		// deltaGlyphID is signed.
		delta_raw := u16(data[sub_off + 4])<<8 | u16(data[sub_off + 5])
		delta := i16(delta_raw)
		glyphs[pos] = Glyph_ID(u16(i32(u16(glyphs[pos])) + i32(delta)))
		return true
	case 2:
		count := u16(data[sub_off + 4])<<8 | u16(data[sub_off + 5])
		if cov_idx >= int(count) { return false }
		p := sub_off + 6 + u32(cov_idx) * 2
		if u64(p) + 2 > u64(len(data)) { return false }
		new_gid := u16(data[p])<<8 | u16(data[p + 1])
		glyphs[pos] = Glyph_ID(new_gid)
		return true
	}
	return false
}

// ---- Lookup type 4: Ligature substitution ---------------------------

@(private)
apply_ligature :: proc(data: []u8, sub_off: u32, glyphs: []Glyph_ID, cursor: int) -> (ok: bool, consumed: int, lig_glyph: Glyph_ID) {
	if u64(sub_off) + 6 > u64(len(data)) { return }
	format := u16(data[sub_off])<<8 | u16(data[sub_off + 1])
	if format != 1 { return }
	coverage_off := u32(u16(data[sub_off + 2])<<8 | u16(data[sub_off + 3]))
	set_count    := u16(data[sub_off + 4])<<8 | u16(data[sub_off + 5])

	abs_coverage := sub_off + coverage_off
	cov_idx := coverage_index(data, abs_coverage, glyphs[cursor])
	if cov_idx < 0 || cov_idx >= int(set_count) { return }

	set_off_pos := sub_off + 6 + u32(cov_idx) * 2
	if u64(set_off_pos) + 2 > u64(len(data)) { return }
	set_off_rel := u32(u16(data[set_off_pos])<<8 | u16(data[set_off_pos + 1]))
	set_off := sub_off + set_off_rel

	if u64(set_off) + 2 > u64(len(data)) { return }
	lig_count := u16(data[set_off])<<8 | u16(data[set_off + 1])

	best_consumed := 0
	best_glyph: Glyph_ID = 0
	for li in 0..<int(lig_count) {
		lig_off_pos := set_off + 2 + u32(li) * 2
		if u64(lig_off_pos) + 2 > u64(len(data)) { continue }
		lig_off_rel := u32(u16(data[lig_off_pos])<<8 | u16(data[lig_off_pos + 1]))
		lig_off := set_off + lig_off_rel

		if u64(lig_off) + 4 > u64(len(data)) { continue }
		out_glyph := u16(data[lig_off])<<8 | u16(data[lig_off + 1])
		comp_count := u16(data[lig_off + 2])<<8 | u16(data[lig_off + 3])
		if comp_count == 0 { continue }
		if cursor + int(comp_count) > len(glyphs) { continue }

		match := true
		base := lig_off + 4
		if u64(base) + u64(comp_count - 1) * 2 > u64(len(data)) { continue }
		for ci in 1..<int(comp_count) {
			p := base + u32(ci - 1) * 2
			want := u16(data[p])<<8 | u16(data[p + 1])
			if u16(glyphs[cursor + ci]) != want { match = false; break }
		}
		if match && int(comp_count) > best_consumed {
			best_consumed = int(comp_count)
			best_glyph = Glyph_ID(out_glyph)
		}
	}
	if best_consumed > 0 {
		return true, best_consumed, best_glyph
	}
	return
}

// ---- Lookup type 6 format 3: Chaining contextual substitution -------

// apply_chained_context — type 6 format 3 (chaining contextual
// substitution). Most call sites are no-ops: the cursor glyph doesn't
// sit in the subtable's first input coverage. We fast-reject before
// allocating any scratch by reading just the first input coverage
// offset from the on-disk layout.
@(private)
apply_chained_context :: proc(g: ^Gsub, sub_off: u32, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	d := g.data
	if u64(sub_off) + 2 > u64(len(d)) { return 0 }
	format := u16(d[sub_off])<<8 | u16(d[sub_off + 1])
	if format == 2 {
		return apply_chained_context_format_2(g, sub_off, glyphs, pos, depth)
	}
	if format == 1 {
		return apply_chained_context_format_1(g, sub_off, glyphs, pos, depth)
	}
	if format != 3 { return 0 }

	// Layout (relative to sub_off):
	//   2  format
	//   2  bt_count        |
	//   2*bt_count          bt_offsets
	//   2  in_count
	//   2*in_count          in_offsets
	//   2  la_count
	//   2*la_count          la_offsets
	//   2  seq_count
	//   4*seq_count         seq_lookup_records
	cursor := u32(sub_off) + 2
	if u64(cursor) + 2 > u64(len(d)) { return 0 }
	bt_count := u32(u16(d[cursor])<<8 | u16(d[cursor + 1]))
	cursor += 2 + bt_count * 2

	if u64(cursor) + 2 > u64(len(d)) { return 0 }
	in_count := u32(u16(d[cursor])<<8 | u16(d[cursor + 1]))
	cursor += 2

	// Fast-reject path. Read the first input coverage offset and check
	// whether glyphs[pos] is in it. The vast majority of positions
	// miss; this saves the rest of the subtable parse.
	if in_count == 0 { return 0 }
	if u64(cursor) + u64(in_count) * 2 > u64(len(d)) { return 0 }
	if pos + int(in_count) > len(glyphs) { return 0 }
	first_in_off := u32(u16(d[cursor])<<8 | u16(d[cursor + 1]))
	if coverage_index(d, sub_off + first_in_off, glyphs[pos]) < 0 { return 0 }

	in_offs_base := cursor
	cursor += in_count * 2

	if u64(cursor) + 2 > u64(len(d)) { return 0 }
	la_count := u32(u16(d[cursor])<<8 | u16(d[cursor + 1]))
	cursor += 2
	la_offs_base := cursor
	if u64(cursor) + u64(la_count) * 2 > u64(len(d)) { return 0 }
	cursor += la_count * 2

	if u64(cursor) + 2 > u64(len(d)) { return 0 }
	seq_count := u32(u16(d[cursor])<<8 | u16(d[cursor + 1]))
	seq_recs_base := cursor + 2

	// Re-walk backtrack offsets to validate predecessor matches.
	bt_offs_base := u32(sub_off) + 4
	for i in 0..<int(bt_count) {
		bp := pos - 1 - i
		if bp < 0 { return 0 }
		p := bt_offs_base + u32(i) * 2
		off := u32(u16(d[p])<<8 | u16(d[p + 1]))
		if coverage_index(d, sub_off + off, glyphs[bp]) < 0 { return 0 }
	}
	// Match remaining input glyphs (skip index 0; already matched).
	for i := 1; i < int(in_count); i += 1 {
		p := in_offs_base + u32(i) * 2
		off := u32(u16(d[p])<<8 | u16(d[p + 1]))
		if coverage_index(d, sub_off + off, glyphs[pos + i]) < 0 { return 0 }
	}
	// Match lookahead.
	la_start := pos + int(in_count)
	for i in 0..<int(la_count) {
		lp := la_start + i
		if lp >= len(glyphs) { return 0 }
		p := la_offs_base + u32(i) * 2
		off := u32(u16(d[p])<<8 | u16(d[p + 1]))
		if coverage_index(d, sub_off + off, glyphs[lp]) < 0 { return 0 }
	}

	// Apply nested lookups.
	consumed_window := int(in_count)
	for s in 0..<int(seq_count) {
		p := seq_recs_base + u32(s) * 4
		if u64(p) + 4 > u64(len(d)) { break }
		seq_idx := u32(u16(d[p])<<8 | u16(d[p + 1]))
		lookup_idx := u32(u16(d[p + 2])<<8 | u16(d[p + 3]))
		if int(seq_idx) >= consumed_window { continue }

		nested, err := gsub_get_lookup(g, u16(lookup_idx), context.temp_allocator)
		if err != .None { continue }

		before := len(glyphs)
		_ = gsub_dispatch_lookup(g, &nested, glyphs, pos + int(seq_idx), depth + 1)
		after := len(glyphs)
		if before > after {
			consumed_window -= (before - after)
			if consumed_window < 1 { consumed_window = 1 }
		}
	}
	return consumed_window
}

// gsub_apply_ligature is the v0 entry point retained for backwards
// compatibility with the gsub_probe tool. It applies one ligature
// lookup (type 4) and returns the substitution count.
gsub_apply_ligature :: proc(g: ^Gsub, lookup: ^Lookup_Info, glyphs: ^[dynamic]Glyph_ID) -> (substitutions: int) {
	if lookup.type != 4 { return 0 }
	return gsub_apply_lookup_pass(g, lookup, glyphs, 0)
}

// apply_chained_context_format_1 — type 6 format 1 (glyph-sequence
// chaining context).
//
// Layout:
//   2  format = 1
//   2  coverageOffset
//   2  chainSubRuleSetCount
//   2*chainSubRuleSetCount  chainSubRuleSetOffsets
//
// Each ChainSubRuleSet:
//   2  chainSubRuleCount
//   2*chainSubRuleCount     chainSubRuleOffsets
//
// Each ChainSubRule:
//   2  backtrackGlyphCount
//   2*backtrackGlyphCount   backtrackSequence (glyph ids)
//   2  inputGlyphCount
//   2*(inputGlyphCount - 1) inputSequence
//   2  lookaheadGlyphCount
//   2*lookaheadGlyphCount   lookaheadSequence
//   2  substLookupCount
//   4*substLookupCount      substLookupRecords
@(private)
apply_chained_context_format_1 :: proc(g: ^Gsub, sub_off: u32, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	d := g.data
	if u64(sub_off) + 6 > u64(len(d)) { return 0 }
	cov_off := u32(u16(d[sub_off + 2])<<8 | u16(d[sub_off + 3]))
	cov_idx := coverage_index(d, sub_off + cov_off, glyphs[pos])
	if cov_idx < 0 { return 0 }
	rs_count := int(u16(d[sub_off + 4])<<8 | u16(d[sub_off + 5]))
	if cov_idx >= rs_count { return 0 }

	rs_off_pos := sub_off + 6 + u32(cov_idx) * 2
	if u64(rs_off_pos) + 2 > u64(len(d)) { return 0 }
	rs_rel := u32(u16(d[rs_off_pos])<<8 | u16(d[rs_off_pos + 1]))
	if rs_rel == 0 { return 0 }
	rs := sub_off + rs_rel
	if u64(rs) + 2 > u64(len(d)) { return 0 }
	rule_count := int(u16(d[rs])<<8 | u16(d[rs + 1]))
	for i in 0..<rule_count {
		rp := rs + 2 + u32(i) * 2
		if u64(rp) + 2 > u64(len(d)) { break }
		rule_rel := u32(u16(d[rp])<<8 | u16(d[rp + 1]))
		rule := rs + rule_rel
		if u64(rule) + 2 > u64(len(d)) { continue }
		bt_count := int(u16(d[rule])<<8 | u16(d[rule + 1]))
		cur := rule + 2
		// Match backtrack (in reverse order — backtrack[0] is the
		// glyph immediately before pos).
		matched := true
		if pos < bt_count { continue }
		for k in 0..<bt_count {
			gp := cur + u32(k) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want := u16(d[gp])<<8 | u16(d[gp + 1])
			if u16(glyphs[pos - 1 - k]) != want { matched = false; break }
		}
		if !matched { continue }
		cur += u32(bt_count) * 2
		if u64(cur) + 2 > u64(len(d)) { continue }
		in_count := int(u16(d[cur])<<8 | u16(d[cur + 1]))
		cur += 2
		if pos + in_count > len(glyphs) { continue }
		for k in 1..<in_count {
			gp := cur + u32(k - 1) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want := u16(d[gp])<<8 | u16(d[gp + 1])
			if u16(glyphs[pos + k]) != want { matched = false; break }
		}
		if !matched { continue }
		cur += u32(in_count - 1) * 2
		if u64(cur) + 2 > u64(len(d)) { continue }
		la_count := int(u16(d[cur])<<8 | u16(d[cur + 1]))
		cur += 2
		la_start := pos + in_count
		if la_start + la_count > len(glyphs) { continue }
		for k in 0..<la_count {
			gp := cur + u32(k) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want := u16(d[gp])<<8 | u16(d[gp + 1])
			if u16(glyphs[la_start + k]) != want { matched = false; break }
		}
		if !matched { continue }
		cur += u32(la_count) * 2
		if u64(cur) + 2 > u64(len(d)) { continue }
		seq_count := int(u16(d[cur])<<8 | u16(d[cur + 1]))
		return apply_seq_lookups(g, glyphs, pos, in_count, cur + 2, seq_count, depth)
	}
	return 0
}

// apply_chained_context_format_2 — type 6 format 2 (class-based
// chaining context).
//
// Layout:
//   2  format = 2
//   2  coverageOffset
//   2  backtrackClassDefOffset
//   2  inputClassDefOffset
//   2  lookaheadClassDefOffset
//   2  chainSubClassSetCount
//   2*chainSubClassSetCount  chainSubClassSetOffsets (may be 0)
//
// Each ChainSubClassSet / Rule shape is the same as format 1 but the
// backtrack / input / lookahead arrays hold *class values* instead of
// glyph IDs.
@(private)
apply_chained_context_format_2 :: proc(g: ^Gsub, sub_off: u32, glyphs: ^[dynamic]Glyph_ID, pos, depth: int) -> int {
	d := g.data
	if u64(sub_off) + 12 > u64(len(d)) { return 0 }
	cov_off    := u32(u16(d[sub_off + 2])<<8 | u16(d[sub_off + 3]))
	if coverage_index(d, sub_off + cov_off, glyphs[pos]) < 0 { return 0 }
	bt_class   := u32(u16(d[sub_off + 4])<<8 | u16(d[sub_off + 5]))
	in_class   := u32(u16(d[sub_off + 6])<<8 | u16(d[sub_off + 7]))
	la_class   := u32(u16(d[sub_off + 8])<<8 | u16(d[sub_off + 9]))
	cs_count   := int(u16(d[sub_off + 10])<<8 | u16(d[sub_off + 11]))

	cls0 := class_of(d, sub_off + in_class, glyphs[pos])
	if cls0 >= u16(cs_count) { return 0 }
	cs_off_pos := sub_off + 12 + u32(cls0) * 2
	if u64(cs_off_pos) + 2 > u64(len(d)) { return 0 }
	cs_rel := u32(u16(d[cs_off_pos])<<8 | u16(d[cs_off_pos + 1]))
	if cs_rel == 0 { return 0 }
	cs := sub_off + cs_rel
	if u64(cs) + 2 > u64(len(d)) { return 0 }
	rule_count := int(u16(d[cs])<<8 | u16(d[cs + 1]))
	for i in 0..<rule_count {
		rp := cs + 2 + u32(i) * 2
		if u64(rp) + 2 > u64(len(d)) { break }
		rule_rel := u32(u16(d[rp])<<8 | u16(d[rp + 1]))
		rule := cs + rule_rel
		if u64(rule) + 2 > u64(len(d)) { continue }
		bt_count := int(u16(d[rule])<<8 | u16(d[rule + 1]))
		cur := rule + 2
		matched := true
		if pos < bt_count { continue }
		for k in 0..<bt_count {
			gp := cur + u32(k) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want := u16(d[gp])<<8 | u16(d[gp + 1])
			if class_of(d, sub_off + bt_class, glyphs[pos - 1 - k]) != want { matched = false; break }
		}
		if !matched { continue }
		cur += u32(bt_count) * 2
		if u64(cur) + 2 > u64(len(d)) { continue }
		in_count := int(u16(d[cur])<<8 | u16(d[cur + 1]))
		cur += 2
		if pos + in_count > len(glyphs) { continue }
		for k in 1..<in_count {
			gp := cur + u32(k - 1) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want := u16(d[gp])<<8 | u16(d[gp + 1])
			if class_of(d, sub_off + in_class, glyphs[pos + k]) != want { matched = false; break }
		}
		if !matched { continue }
		cur += u32(in_count - 1) * 2
		if u64(cur) + 2 > u64(len(d)) { continue }
		la_count := int(u16(d[cur])<<8 | u16(d[cur + 1]))
		cur += 2
		la_start := pos + in_count
		if la_start + la_count > len(glyphs) { continue }
		for k in 0..<la_count {
			gp := cur + u32(k) * 2
			if u64(gp) + 2 > u64(len(d)) { matched = false; break }
			want := u16(d[gp])<<8 | u16(d[gp + 1])
			if class_of(d, sub_off + la_class, glyphs[la_start + k]) != want { matched = false; break }
		}
		if !matched { continue }
		cur += u32(la_count) * 2
		if u64(cur) + 2 > u64(len(d)) { continue }
		seq_count := int(u16(d[cur])<<8 | u16(d[cur + 1]))
		return apply_seq_lookups(g, glyphs, pos, in_count, cur + 2, seq_count, depth)
	}
	return 0
}
