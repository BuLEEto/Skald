package parse

// SFNT directory parsing — the entry point into an OpenType / TrueType
// font file. Every font starts with a 12-byte offset table followed by
// `numTables` 16-byte table records.
//
// References: OpenType spec, "Organization of an OpenType Font".

// SFNT magic values for the version field. The version tells the reader
// whether glyph data lives in `glyf` (TrueType outlines) or `CFF` /
// `CFF2` (PostScript outlines).
SFNT_VERSION_TT      :: u32(0x00010000)            // 'true' TrueType outlines
SFNT_VERSION_CFF     :: u32(0x4F54544F)            // 'OTTO' — CFF outlines
SFNT_VERSION_TRUE    :: u32(0x74727565)            // 'true' — Apple legacy TT
SFNT_VERSION_TYP1    :: u32(0x74797031)            // 'typ1' — Apple legacy

// TTC (TrueType Collection) header magic — multi-font containers.
// `parse_table_index` rejects them; a face is chosen with
// `ttc_face_offset` + `parse_table_index_at` (runa's `font_load_face`).
TTC_TAG              :: u32(0x74746366)            // 'ttcf'

// Table_Record points at one table inside the font buffer. Offsets are
// absolute from the start of the file; checksums are not validated by
// the parser (the OpenType spec marks them informational, and chasing
// every CVE-worthy checksum bug isn't worth the complexity at v0.1).
Table_Record :: struct {
	tag:    Tag,
	offset: u32,
	length: u32,
}

// Table_Index is the parsed SFNT directory. Records are sorted by tag
// (the on-disk form is too, so we keep that invariant for binary search
// later if profiling demands it). Linear scan is fine for the ~20–40
// tables in a real font.
Table_Index :: struct {
	sfnt_version: u32,
	records:      []Table_Record,
}

// parse_table_index reads the SFNT offset table at the start of `data`
// and returns one Table_Record per declared table. Allocates `records`
// from `allocator`; the caller frees with `delete(idx.records, allocator)`.
//
// Rejects TTC (TrueType Collection) inputs with `Unsupported_Format` —
// a collection has no single directory; callers choose a face with
// `ttc_face_offset` + `parse_table_index_at`.
parse_table_index :: proc(data: []u8, allocator := context.allocator) -> (idx: Table_Index, err: Error) {
	if is_ttc(data) {
		err = .Unsupported_Format
		return
	}
	return parse_table_index_at(data, 0, allocator)
}

// parse_table_index_at reads the offset table at byte `base` within
// `data`. For a plain font `base` is 0; for a TTC face it's the face's
// table-directory offset from `ttc_face_offset`. Table record offsets
// stay absolute from the start of `data` (the TTC spec stores them
// file-relative, and faces share tables), so `data` remains the whole
// file and the bounds checks still hold.
parse_table_index_at :: proc(data: []u8, base: u32, allocator := context.allocator) -> (idx: Table_Index, err: Error) {
	r := reader_at(data, int(base)) or_return

	version := read_u32(&r) or_return
	switch version {
	case SFNT_VERSION_TT, SFNT_VERSION_CFF, SFNT_VERSION_TRUE, SFNT_VERSION_TYP1:
		// fine
	case:
		err = .Invalid_Table
		return
	}

	num_tables := read_u16(&r) or_return
	// searchRange, entrySelector, rangeShift — derived from numTables and
	// historically used for binary search. We ignore them; modern parsers
	// don't trust them and recompute when needed.
	skip(&r, 6) or_return

	records := make([]Table_Record, num_tables, allocator)
	if records == nil && num_tables > 0 {
		err = .Out_Of_Memory
		return
	}

	for i in 0..<int(num_tables) {
		tag    := read_tag(&r) or_return
		_       = read_u32(&r) or_return        // checksum — ignored
		offset := read_u32(&r) or_return
		length := read_u32(&r) or_return

		// Each table must lie entirely inside the file. The spec doesn't
		// require this for unused tables, but a malicious offset/length
		// could later flow into a slice index and panic.
		if u64(offset) + u64(length) > u64(len(data)) {
			delete(records, allocator)
			err = .Invalid_Table
			return
		}

		records[i] = Table_Record{tag = tag, offset = offset, length = length}
	}

	idx = Table_Index{sfnt_version = version, records = records}
	return
}

// is_ttc reports whether `data` begins with a TTC (TrueType Collection)
// header.
is_ttc :: proc(data: []u8) -> bool {
	return len(data) >= 4 &&
	       (u32(data[0])<<24 | u32(data[1])<<16 | u32(data[2])<<8 | u32(data[3])) == TTC_TAG
}

// ttc_num_faces returns the number of faces in a TTC, or 1 for a plain
// single-font SFNT. 0 means the header couldn't be read.
ttc_num_faces :: proc(data: []u8) -> int {
	if !is_ttc(data) { return len(data) >= 4 ? 1 : 0 }
	r, e0 := reader_at(data, 8)                 // past 'ttcf' + majorVersion/minorVersion
	if e0 != .None { return 0 }
	n, e := read_u32(&r)
	if e != .None { return 0 }
	return int(n)
}

// ttc_face_offset returns the byte offset of face `index`'s table
// directory within a TTC. For a plain SFNT, index 0 returns offset 0.
ttc_face_offset :: proc(data: []u8, index: int) -> (off: u32, err: Error) {
	if !is_ttc(data) {
		if index == 0 { return 0, .None }       // a non-collection has one face
		err = .Invalid_Table
		return
	}
	r := reader_at(data, 0) or_return
	skip(&r, 4) or_return                        // 'ttcf' tag
	skip(&r, 4) or_return                        // majorVersion, minorVersion
	num_fonts := read_u32(&r) or_return
	if index < 0 || u32(index) >= num_fonts {
		err = .Invalid_Table
		return
	}
	skip(&r, index * 4) or_return                // offsetTable[0 ..< index]
	off = read_u32(&r) or_return
	return
}

// table_index_destroy frees the records slice allocated by
// `parse_table_index`. `allocator` must match the one passed at parse.
table_index_destroy :: proc(idx: ^Table_Index, allocator := context.allocator) {
	delete(idx.records, allocator)
	idx.records = nil
}

// find_table returns the byte range of the named table, or `Table_Not_Found`
// if the SFNT directory doesn't carry it. The returned slice aliases
// `data` — do not modify it.
find_table :: proc(idx: ^Table_Index, data: []u8, t: Tag) -> (b: []u8, err: Error) {
	for &rec in idx.records {
		if rec.tag == t {
			b = data[rec.offset:rec.offset + rec.length]
			return
		}
	}
	err = .Table_Not_Found
	return
}

// has_table reports whether the named table exists in the SFNT directory.
// Used by optional-feature probes — `head` is required, `COLR` isn't.
has_table :: proc(idx: ^Table_Index, t: Tag) -> bool {
	for &rec in idx.records {
		if rec.tag == t { return true }
	}
	return false
}

// is_truetype reports whether the SFNT carries TrueType outlines in
// `glyf` (vs. CFF / CFF2 PostScript outlines). The parser's outline
// pipeline picks the right code path based on this.
is_truetype :: proc(idx: ^Table_Index) -> bool {
	return idx.sfnt_version == SFNT_VERSION_TT ||
	       idx.sfnt_version == SFNT_VERSION_TRUE ||
	       idx.sfnt_version == SFNT_VERSION_TYP1
}

// is_cff reports whether the SFNT carries CFF / CFF2 PostScript outlines.
is_cff :: proc(idx: ^Table_Index) -> bool {
	return idx.sfnt_version == SFNT_VERSION_CFF
}
