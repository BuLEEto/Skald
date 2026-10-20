package parse

// Shared OpenType layout primitives used by GSUB and GPOS.
//
//   - Script / Language / Feature directory walk.
//   - Coverage tables (format 1: glyph array, format 2: range records).
//   - Lookup header inspection.
//
// The structural calls return small descriptor structs; per-subtable
// dispatch lives in the GSUB / GPOS modules.

// Script_Tag / Lang_Tag / Feature_Tag are all 4-byte OT tags. Aliased
// for readability — the underlying type is `Tag`.
DFLT_SCRIPT :: Tag(0x44464C54)            // 'DFLT'
DFLT_LANG   :: Tag(0x64666C74)            // 'dflt'
LATN_SCRIPT :: Tag(0x6C61746E)            // 'latn'

// Registered GSUB/GPOS feature tags the shaper names explicitly. Values
// are the 4-byte tags, big-endian (same packing as `tag`). A test pins
// each against `tag(...)` so a typo can't slip through.
FEAT_CCMP :: Tag(0x63636D70)              // 'ccmp' — mandatory
FEAT_LOCL :: Tag(0x6C6F636C)              // 'locl' — mandatory
FEAT_RLIG :: Tag(0x726C6967)              // 'rlig' — mandatory
FEAT_CASE :: Tag(0x63617365)              // 'case'
FEAT_SMCP :: Tag(0x736D6370)              // 'smcp' — small capitals
FEAT_C2SC :: Tag(0x63327363)              // 'c2sc' — capitals to small capitals
FEAT_ONUM :: Tag(0x6F6E756D)              // 'onum' — oldstyle figures
FEAT_LIGA :: Tag(0x6C696761)              // 'liga'
FEAT_CLIG :: Tag(0x636C6967)              // 'clig'
FEAT_DLIG :: Tag(0x646C6967)              // 'dlig' — discretionary ligatures
FEAT_CALT :: Tag(0x63616C74)              // 'calt'
FEAT_KERN :: Tag(0x6B65726E)              // 'kern' (GPOS)

// Lookup_Info describes one GSUB / GPOS Lookup record. `subtable_offsets`
// are absolute byte offsets into the GSUB / GPOS table.
Lookup_Info :: struct {
	type:             u16,
	flag:             u16,
	mark_filter_set:  u16,      // 0 if useMarkFilteringSet flag unset
	subtable_offsets: []u32,    // absolute offsets into the layout table
	allocator:        bool,     // true if subtable_offsets is heap-owned
}

LOOKUP_FLAG_USE_MARK_FILTERING_SET :: u16(0x0010)

// resolve_extension reads an Extension subtable (GSUB type 7 / GPOS type 9,
// format 1) at `sub_off`: a real lookup type and a 32-bit offset to the real
// subtable, measured from the extension subtable's own start. Returns the
// real lookup type and the absolute offset of the real subtable. Fonts wrap
// lookups this way once their layout tables outgrow 16-bit offsets, which is
// common — so executing these is needed for most real kerning / features.
resolve_extension :: proc(d: []u8, sub_off: u32) -> (real_type: u16, real_off: u32, ok: bool) {
	if u64(sub_off) + 8 > u64(len(d)) { return }
	format := u16(d[sub_off])<<8 | u16(d[sub_off + 1])
	if format != 1 { return }
	real_type = u16(d[sub_off + 2])<<8 | u16(d[sub_off + 3])
	ext_off := u32(d[sub_off + 4])<<24 | u32(d[sub_off + 5])<<16 | u32(d[sub_off + 6])<<8 | u32(d[sub_off + 7])
	real_off = sub_off + ext_off
	if u64(real_off) >= u64(len(d)) { return }
	ok = true
	return
}

// lookup_info_destroy frees the subtable_offsets slice if it was
// allocated (i.e., the lookup has more than zero subtables).
lookup_info_destroy :: proc(l: ^Lookup_Info, allocator := context.allocator) {
	if l.allocator { delete(l.subtable_offsets, allocator) }
	l^ = {}
}

// resolve_feature_lookups returns the lookup indices for the
// (script, language, feature) tuple by walking the script and feature
// lists. Falls back to (script, DFLT_LANG) and then (DFLT_SCRIPT,
// DFLT_LANG) if the requested combination isn't present.
//
// Layout-table-agnostic: works on a GSUB or GPOS table byte slice with
// the same script/feature-list shape. `script_list_off` and
// `feature_list_off` are the offsets read from the table header.
//
// Returns a freshly allocated slice; caller frees with `delete`.
resolve_feature_lookups :: proc(
	data: []u8,
	script_list_off, feature_list_off: u16,
	script_tag, lang_tag, feature_tag: Tag,
	allocator := context.allocator,
) -> (lookup_indices: []u16, err: Error) {
	// Try (script, lang) → (script, DFLT_LANG) → (DFLT_SCRIPT, DFLT_LANG).
	feature_indices := find_lang_feature_indices(data, script_list_off, script_tag, lang_tag) or_return
	if len(feature_indices) == 0 {
		feature_indices = find_lang_feature_indices(data, script_list_off, script_tag, DFLT_LANG) or_return
	}
	if len(feature_indices) == 0 && script_tag != DFLT_SCRIPT {
		feature_indices = find_lang_feature_indices(data, script_list_off, DFLT_SCRIPT, DFLT_LANG) or_return
	}
	defer delete(feature_indices, context.temp_allocator)

	// Walk the feature list, collect lookup indices for any feature
	// record matching `feature_tag`.
	lookups_dyn := make([dynamic]u16, 0, 8, allocator)
	for fi in feature_indices {
		fr_off, ftag, ferr := feature_record_at(data, feature_list_off, fi)
		if ferr != .None { continue }
		if ftag != feature_tag { continue }
		idx_list, idxerr := feature_lookup_indices(data, feature_list_off, fr_off)
		if idxerr != .None { continue }
		for li in idx_list { append(&lookups_dyn, li) }
		delete(idx_list, context.temp_allocator)
	}
	lookup_indices = lookups_dyn[:]
	return
}

// find_lang_feature_indices walks the ScriptList, finds `script_tag`'s
// Script, then `lang_tag`'s LangSys, and returns the LangSys's
// `featureIndices` array. Returns an empty (temp-allocated) slice if
// any step misses.
@(private)
find_lang_feature_indices :: proc(data: []u8, script_list_off: u16, script_tag, lang_tag: Tag) -> (indices: []u16, err: Error) {
	r := reader_at(data, int(script_list_off)) or_return

	count := read_u16(&r) or_return
	for i in 0..<int(count) {
		stag := read_tag(&r) or_return
		soff := read_u16(&r) or_return
		if stag != script_tag { continue }

		script_off := int(script_list_off) + int(soff)
		sr := reader_at(data, script_off) or_return

		default_langsys_off := read_u16(&sr) or_return
		lang_count          := read_u16(&sr) or_return

		// Caller may want DFLT_LANG, which the spec encodes as the
		// "defaultLangSys" subtable. Distinguish:
		if lang_tag == DFLT_LANG && default_langsys_off != 0 {
			return read_langsys_features(data, script_off + int(default_langsys_off))
		}
		for j in 0..<int(lang_count) {
			ltag := read_tag(&sr) or_return
			loff := read_u16(&sr) or_return
			if ltag == lang_tag {
				return read_langsys_features(data, script_off + int(loff))
			}
		}
		// Fall through to the default if the language wasn't listed
		// explicitly — common when the asked-for lang isn't supported
		// but the script does have a default.
		if default_langsys_off != 0 {
			return read_langsys_features(data, script_off + int(default_langsys_off))
		}
		return
	}
	return
}

@(private)
read_langsys_features :: proc(data: []u8, off: int) -> (indices: []u16, err: Error) {
	r := reader_at(data, off) or_return
	skip(&r, 2) or_return                    // lookupOrderOffset (reserved, == 0)
	required_idx := read_u16(&r) or_return
	_ = required_idx                         // not used at v0.1
	count := read_u16(&r) or_return
	out := make([]u16, count, context.temp_allocator)
	for i in 0..<int(count) {
		out[i] = read_u16(&r) or_return
	}
	indices = out
	return
}

@(private)
feature_record_at :: proc(data: []u8, feature_list_off: u16, idx: u16) -> (record_off: int, tag: Tag, err: Error) {
	r, eerr := reader_at(data, int(feature_list_off))
	if eerr != .None { err = eerr; return }
	count := read_u16(&r) or_return
	if u32(idx) >= u32(count) { err = .Invalid_Table; return }
	// Each FeatureRecord is 6 bytes (Tag + Offset16).
	skip(&r, int(idx) * 6) or_return
	tag = read_tag(&r) or_return
	off := read_u16(&r) or_return
	record_off = int(feature_list_off) + int(off)
	return
}

@(private)
feature_lookup_indices :: proc(data: []u8, feature_list_off: u16, feature_record_off: int) -> (indices: []u16, err: Error) {
	r := reader_at(data, feature_record_off) or_return
	skip(&r, 2) or_return                    // featureParamsOffset
	count := read_u16(&r) or_return
	out := make([]u16, count, context.temp_allocator)
	for i in 0..<int(count) {
		out[i] = read_u16(&r) or_return
	}
	indices = out
	return
}

// read_lookup_info parses one Lookup record from a LookupList. The
// returned Lookup_Info's `subtable_offsets` is allocated; free via
// `lookup_info_destroy`.
read_lookup_info :: proc(data: []u8, lookup_list_off: u16, lookup_idx: u16, allocator := context.allocator) -> (l: Lookup_Info, err: Error) {
	r, rerr := reader_at(data, int(lookup_list_off))
	if rerr != .None { err = rerr; return }

	count := read_u16(&r) or_return
	if u32(lookup_idx) >= u32(count) { err = .Invalid_Table; return }
	skip(&r, int(lookup_idx) * 2) or_return
	rel_off := read_u16(&r) or_return

	lookup_off := int(lookup_list_off) + int(rel_off)
	lr, lerr := reader_at(data, lookup_off)
	if lerr != .None { err = lerr; return }

	l.type = read_u16(&lr) or_return
	l.flag = read_u16(&lr) or_return
	sub_count := read_u16(&lr) or_return

	if sub_count > 0 {
		l.subtable_offsets = make([]u32, sub_count, allocator)
		if l.subtable_offsets == nil { err = .Out_Of_Memory; return }
		l.allocator = true
		for i in 0..<int(sub_count) {
			off := read_u16(&lr) or_return
			l.subtable_offsets[i] = u32(lookup_off) + u32(off)
		}
	}
	if l.flag & LOOKUP_FLAG_USE_MARK_FILTERING_SET != 0 {
		l.mark_filter_set = read_u16(&lr) or_return
	}
	return
}

// ---- Coverage tables ------------------------------------------------

// coverage_index returns the coverage index for `gid` in the coverage
// table starting at `data[off:]`, or -1 if the glyph isn't covered.
//
// Format 1: format=1, glyphCount, glyphArray[glyphCount].
// Format 2: format=2, rangeCount, RangeRecord[rangeCount] = {start, end, startCoverageIndex}.
coverage_index :: proc(data: []u8, off: u32, gid: Glyph_ID) -> int {
	if u64(off) + 4 > u64(len(data)) { return -1 }
	format := u16(data[off])<<8 | u16(data[off + 1])
	count  := u16(data[off + 2])<<8 | u16(data[off + 3])

	switch format {
	case 1:
		// Binary search over a sorted u16 array.
		base := off + 4
		if u64(base) + u64(count) * 2 > u64(len(data)) { return -1 }
		lo, hi := 0, int(count)
		for lo < hi {
			mid := (lo + hi) / 2
			p := base + u32(mid) * 2
			v := u16(data[p])<<8 | u16(data[p + 1])
			if v == u16(gid) { return mid }
			if v < u16(gid) { lo = mid + 1 } else { hi = mid }
		}
		return -1
	case 2:
		base := off + 4
		if u64(base) + u64(count) * 6 > u64(len(data)) { return -1 }
		lo, hi := 0, int(count)
		for lo < hi {
			mid := (lo + hi) / 2
			p := base + u32(mid) * 6
			start := u16(data[p])<<8 | u16(data[p + 1])
			end   := u16(data[p + 2])<<8 | u16(data[p + 3])
			start_coverage_idx := u16(data[p + 4])<<8 | u16(data[p + 5])
			if u16(gid) < start { hi = mid; continue }
			if u16(gid) > end   { lo = mid + 1; continue }
			return int(start_coverage_idx) + int(u16(gid) - start)
		}
		return -1
	}
	return -1
}
