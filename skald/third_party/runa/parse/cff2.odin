package parse

// CFF2 — Compact Font Format 2 (variable-font extension).
//
// CFF2 replaces CFF1's header / Top DICT INDEX with a fixed header
// and a single Top DICT block, drops the Name and String INDEXes,
// and adds VariationStore + FDArray-mandatory + vsindex / blend
// charstring operators for variable fonts.
//
// v0.5 parses enough of CFF2 to produce default-instance outlines —
// the Type 2 charstring interpreter (in `cff_charstring.odin`)
// handles `vsindex` and `blend` operators by consuming their
// variation operands without applying deltas. Non-default-instance
// rendering needs the Item Variation Store regression that lands
// alongside HVAR's region resolver in a follow-up.
//
// References: OpenType CFF2 spec; Adobe Tech Note #5176.

import "core:mem"

// CFF2 Top DICT operator codes (subset).
CFF2_OP_CHARSTRINGS :: u8(17)
CFF2_OP_VSTORE      :: u8(24)
CFF2_OP_FONT_MATRIX :: u8(7)
// Two-byte operators (escape 12 + opcode).
CFF2_OP_FDARRAY     :: u8(36)
CFF2_OP_FDSELECT    :: u8(37)

// Cff_Fd is one Font DICT entry from an FDArray. Each FD has its own
// Private DICT + Local Subrs (charstrings under different FDs can use
// different subroutine pools). Shared by CFF2 and CID-keyed CFF1.
Cff_Fd :: struct {
	local_subrs:      Cff_Index,
	local_subr_bias:  int,
}

// Cff2 holds the parsed structure of a CFF2 table.
Cff2 :: struct {
	data:                []u8,
	num_glyphs:          int,

	charstrings_index:   Cff_Index,
	global_subrs:        Cff_Index,
	global_subr_bias:    int,

	fdarray:             []Cff_Fd,         // one entry per FD (FDArray INDEX)
	fdselect_off:        u32,              // offset of FDSelect within `data`
	fdselect_format:     u8,               // 0 / 3 / 4 — looked up on demand

	// vsindex 0 region count (default vsindex).
	default_num_regions: int,
	// region_counts[vsindex] = numRegions for that VarData subtable.
	region_counts:       []u16,
	// Absolute (within `data`) offset of the ItemVariationStore body
	// — needed for on-demand region/IVD lookup when applying a
	// non-default-instance blend.
	ivs_body_off:        u32,
	// Per-vsindex absolute offset of the ItemVariationData subtable
	// inside `data`. Lets the blend operator find a vsindex's
	// region-index array without re-parsing the IVS header.
	ivd_offsets:         []u32,
}

new_cff2 :: proc(data: []u8, allocator := context.allocator) -> (c: Cff2, err: Error) {
	if len(data) < 5 { err = .Invalid_Table; return }
	major := data[0]
	if major != 2 { err = .Unsupported_Format; return }
	hdr_size := int(data[2])
	top_dict_len := int(u16(data[3])<<8 | u16(data[4]))
	if hdr_size < 5 || hdr_size + top_dict_len > len(data) {
		err = .Invalid_Table
		return
	}
	c.data = data

	top_dict := data[hdr_size:hdr_size + top_dict_len]

	charstrings_off, fdarray_off, fdselect_off, vstore_off: u32
	if !parse_cff2_top_dict(top_dict, &charstrings_off, &fdarray_off, &fdselect_off, &vstore_off) {
		err = .Invalid_Table
		return
	}
	c.fdselect_off = fdselect_off

	// Global Subr INDEX — immediately after the Top DICT.
	gsubrs, _, ge := read_cff_index(data, hdr_size + top_dict_len, allocator, true)
	if ge != .None { err = ge; return }
	c.global_subrs = gsubrs
	c.global_subr_bias = subr_bias(gsubrs.count)

	if charstrings_off == 0 { err = .Invalid_Table; return }
	cs_idx, _, ce := read_cff_index(data, int(charstrings_off), allocator, true)
	if ce != .None {
		cff_index_destroy(&c.global_subrs, allocator)
		err = ce
		return
	}
	c.charstrings_index = cs_idx
	c.num_glyphs = cs_idx.count

	// VarStore — needed for blend region counts AND for the
	// non-default-instance region scalar computation in CFF2 `blend`.
	// CFF2 spec: VarStore data starts with a u16 length, then the
	// ItemVariationStore body.
	if vstore_off != 0 {
		ok := parse_cff2_varstore(data, int(vstore_off),
			&c.default_num_regions, &c.region_counts, &c.ivs_body_off, &c.ivd_offsets, allocator)
		_ = ok
	}
	if c.default_num_regions == 0 { c.default_num_regions = 1 }

	// FDArray INDEX — each entry is a Font DICT in DICT format. Per
	// CFF2 spec a CFF2 font *must* have an FDArray (even with a
	// single FD).
	if fdarray_off == 0 {
		cff2_destroy(&c, allocator)
		err = .Invalid_Table
		return
	}
	fd_idx, _, fe := read_cff_index(data, int(fdarray_off), allocator, true)
	if fe != .None {
		cff2_destroy(&c, allocator)
		err = fe
		return
	}
	defer cff_index_destroy(&fd_idx, allocator)

	c.fdarray = make([]Cff_Fd, fd_idx.count, allocator)
	for i in 0..<fd_idx.count {
		fd_bytes, ferr := cff_index_get(&fd_idx, i)
		if ferr != .None { continue }
		priv_size, priv_off: u32 = 0, 0
		if !parse_font_dict_private(fd_bytes, &priv_size, &priv_off) { continue }
		if priv_size == 0 || priv_off == 0 { continue }
		end := u64(priv_off) + u64(priv_size)
		if end > u64(len(data)) { continue }

		local_subr_rel: u32 = 0
		// CFF2 Private DICT shares format with CFF1; reuse parser.
		if parse_private_dict(data[priv_off:end], &local_subr_rel) && local_subr_rel != 0 {
			abs_off := int(priv_off) + int(local_subr_rel)
			lsubrs, _, le := read_cff_index(data, abs_off, allocator, true)
			if le == .None {
				c.fdarray[i].local_subrs     = lsubrs
				c.fdarray[i].local_subr_bias = subr_bias(lsubrs.count)
			}
		}
	}
	return
}

cff2_destroy :: proc(c: ^Cff2, allocator := context.allocator) {
	cff_index_destroy(&c.charstrings_index, allocator)
	cff_index_destroy(&c.global_subrs, allocator)
	for i in 0..<len(c.fdarray) {
		cff_index_destroy(&c.fdarray[i].local_subrs, allocator)
	}
	delete(c.fdarray,       allocator)
	delete(c.region_counts, allocator)
	delete(c.ivd_offsets,   allocator)
	c^ = {}
}

// cff2_charstring_bytes returns the charstring data for `gid`.
cff2_charstring_bytes :: proc(c: ^Cff2, gid: Glyph_ID) -> []u8 {
	b, _ := cff_index_get(&c.charstrings_index, int(gid))
	return b
}

// cff2_fd_index resolves the FD index for a glyph via FDSelect.
// Single-FD fonts may omit FDSelect; we return 0 in that case.
cff2_fd_index :: proc(c: ^Cff2, gid: Glyph_ID) -> int {
	if c.fdselect_off == 0 || len(c.fdarray) <= 1 { return 0 }
	return fdselect_lookup(c.data, c.fdselect_off, gid)
}

// fdselect_lookup reads the FDSelect table at `fdselect_off` within
// `data` and returns the Font DICT index for `gid`. Shared by CFF2 and
// CID-keyed CFF1. Formats: 0 (one byte per glyph), 3 (u16 ranges), 4
// (u32 ranges — CFF2 only). Returns 0 on malformed data.
fdselect_lookup :: proc(data: []u8, fdselect_off: u32, gid: Glyph_ID) -> int {
	d := data
	off := int(fdselect_off)
	if off + 1 > len(d) { return 0 }
	format := d[off]
	g := u16(gid)
	switch format {
	case 0:
		// 1 byte per glyph.
		p := off + 1 + int(g)
		if p >= len(d) { return 0 }
		return int(d[p])
	case 3:
		// nRanges u16, then ranges of [first u16, fd u8], then sentinel u16.
		if off + 3 > len(d) { return 0 }
		n_ranges := int(u16(d[off + 1])<<8 | u16(d[off + 2]))
		base := off + 3
		// Binary search the ranges.
		lo, hi := 0, n_ranges
		for lo < hi {
			mid := (lo + hi) / 2
			p := base + mid * 3
			if p + 3 > len(d) { return 0 }
			first := u16(d[p])<<8 | u16(d[p + 1])
			next_first: u16
			if mid + 1 < n_ranges {
				np := base + (mid + 1) * 3
				next_first = u16(d[np])<<8 | u16(d[np + 1])
			} else {
				sp := base + n_ranges * 3
				next_first = u16(d[sp])<<8 | u16(d[sp + 1])
			}
			switch {
			case g < first:           hi = mid
			case g >= next_first:     lo = mid + 1
			case:                     return int(d[p + 2])
			}
		}
		return 0
	case 4:
		// nRanges u32, then ranges of [first u32, fd u16], then sentinel u32.
		if off + 5 > len(d) { return 0 }
		n_ranges := int(u32(d[off + 1])<<24 | u32(d[off + 2])<<16 |
		                u32(d[off + 3])<<8 | u32(d[off + 4]))
		base := off + 5
		lo, hi := 0, n_ranges
		for lo < hi {
			mid := (lo + hi) / 2
			p := base + mid * 6
			if p + 6 > len(d) { return 0 }
			first := u32(d[p])<<24 | u32(d[p + 1])<<16 | u32(d[p + 2])<<8 | u32(d[p + 3])
			next_first: u32
			if mid + 1 < n_ranges {
				np := base + (mid + 1) * 6
				next_first = u32(d[np])<<24 | u32(d[np + 1])<<16 | u32(d[np + 2])<<8 | u32(d[np + 3])
			} else {
				sp := base + n_ranges * 6
				next_first = u32(d[sp])<<24 | u32(d[sp + 1])<<16 | u32(d[sp + 2])<<8 | u32(d[sp + 3])
			}
			switch {
			case u32(g) < first:           hi = mid
			case u32(g) >= next_first:     lo = mid + 1
			case:                          return int(u16(d[p + 4])<<8 | u16(d[p + 5]))
			}
		}
		return 0
	}
	return 0
}

@(private)
parse_cff2_top_dict :: proc(d: []u8, charstrings_off, fdarray_off, fdselect_off, vstore_off: ^u32) -> bool {
	stack: [48]i64
	sp := 0
	i := 0
	for i < len(d) {
		b := d[i]
		switch {
		case b == 30:
			j := i + 1
			for j < len(d) {
				v := d[j]
				j += 1
				if v & 0x0F == 0x0F || v & 0xF0 == 0xF0 { break }
			}
			i = j
			if sp < len(stack) { stack[sp] = 0; sp += 1 }
		case b == 28:
			if i + 2 >= len(d) { return false }
			v := i16(u16(d[i + 1])<<8 | u16(d[i + 2]))
			if sp < len(stack) { stack[sp] = i64(v); sp += 1 }
			i += 3
		case b == 29:
			if i + 4 >= len(d) { return false }
			v := i32(u32(d[i + 1])<<24 | u32(d[i + 2])<<16 | u32(d[i + 3])<<8 | u32(d[i + 4]))
			if sp < len(stack) { stack[sp] = i64(v); sp += 1 }
			i += 5
		case b >= 32 && b <= 246:
			if sp < len(stack) { stack[sp] = i64(b) - 139; sp += 1 }
			i += 1
		case b >= 247 && b <= 250:
			if i + 1 >= len(d) { return false }
			v := (i64(b) - 247) * 256 + i64(d[i + 1]) + 108
			if sp < len(stack) { stack[sp] = v; sp += 1 }
			i += 2
		case b >= 251 && b <= 254:
			if i + 1 >= len(d) { return false }
			v := -(i64(b) - 251) * 256 - i64(d[i + 1]) - 108
			if sp < len(stack) { stack[sp] = v; sp += 1 }
			i += 2
		case b == 12:
			if i + 1 >= len(d) { return false }
			b2 := d[i + 1]
			i += 2
			switch b2 {
			case CFF2_OP_FDARRAY:  if sp >= 1 { fdarray_off^  = u32(stack[sp - 1]) }
			case CFF2_OP_FDSELECT: if sp >= 1 { fdselect_off^ = u32(stack[sp - 1]) }
			}
			sp = 0
		case:
			switch b {
			case CFF2_OP_CHARSTRINGS: if sp >= 1 { charstrings_off^ = u32(stack[sp - 1]) }
			case CFF2_OP_VSTORE:      if sp >= 1 { vstore_off^      = u32(stack[sp - 1]) }
			}
			sp = 0
			i += 1
		}
	}
	return true
}

// parse_font_dict_private extracts the Private DICT location operands
// (size + offset) from a Font DICT entry. Shared by CFF2 and CID-keyed
// CFF1 FDArray entries — both use the same DICT encoding.
@(private)
parse_font_dict_private :: proc(d: []u8, priv_size, priv_off: ^u32) -> bool {
	stack: [48]i64
	sp := 0
	i := 0
	for i < len(d) {
		b := d[i]
		switch {
		case b == 30:
			j := i + 1
			for j < len(d) {
				v := d[j]
				j += 1
				if v & 0x0F == 0x0F || v & 0xF0 == 0xF0 { break }
			}
			i = j
			if sp < len(stack) { stack[sp] = 0; sp += 1 }
		case b == 28:
			if i + 2 >= len(d) { return false }
			v := i16(u16(d[i + 1])<<8 | u16(d[i + 2]))
			if sp < len(stack) { stack[sp] = i64(v); sp += 1 }
			i += 3
		case b == 29:
			if i + 4 >= len(d) { return false }
			v := i32(u32(d[i + 1])<<24 | u32(d[i + 2])<<16 | u32(d[i + 3])<<8 | u32(d[i + 4]))
			if sp < len(stack) { stack[sp] = i64(v); sp += 1 }
			i += 5
		case b >= 32 && b <= 246:
			if sp < len(stack) { stack[sp] = i64(b) - 139; sp += 1 }
			i += 1
		case b >= 247 && b <= 250:
			if i + 1 >= len(d) { return false }
			v := (i64(b) - 247) * 256 + i64(d[i + 1]) + 108
			if sp < len(stack) { stack[sp] = v; sp += 1 }
			i += 2
		case b >= 251 && b <= 254:
			if i + 1 >= len(d) { return false }
			v := -(i64(b) - 251) * 256 - i64(d[i + 1]) - 108
			if sp < len(stack) { stack[sp] = v; sp += 1 }
			i += 2
		case b == 12:
			// Two-byte operators — none we care about for the Font DICT.
			i += 2
			sp = 0
		case:
			// One-byte operators. CFF1's Private operator (18) is the
			// same here: pair of (size, offset).
			if b == CFF_OP_PRIVATE && sp >= 2 {
				priv_size^ = u32(stack[sp - 2])
				priv_off^  = u32(stack[sp - 1])
			}
			sp = 0
			i += 1
		}
	}
	return true
}

// parse_cff2_varstore extracts region counts per ItemVariationData
// subtable. For default-instance rendering we only need the counts
// (used by the `blend` operator to know how many delta operands to
// pop). The actual delta values are unused since the default
// instance applies zero-scaled deltas.
@(private)
parse_cff2_varstore :: proc(data: []u8, abs_off: int, default_num_regions: ^int, region_counts: ^[]u16, ivs_body_off: ^u32, ivd_offsets: ^[]u32, allocator: mem.Allocator) -> bool {
	if abs_off + 2 > len(data) { return false }
	// VarStore is prefixed by a u16 length (the body length in bytes).
	body_len := int(u16(data[abs_off])<<8 | u16(data[abs_off + 1]))
	body_off := abs_off + 2
	if body_off + body_len > len(data) { return false }
	body := data[body_off:body_off + body_len]
	// ItemVariationStore: format u16, variationRegionListOffset u32,
	// itemVariationDataCount u16, itemVariationDataOffsets u32[count].
	if len(body) < 8 { return false }
	ivd_count := int(u16(body[6])<<8 | u16(body[7]))
	if 8 + ivd_count * 4 > len(body) { return false }

	counts  := make([]u16, ivd_count, allocator)
	offsets := make([]u32, ivd_count, allocator)
	for i in 0..<ivd_count {
		p := 8 + i * 4
		ivd_rel := u32(body[p])<<24 | u32(body[p + 1])<<16 | u32(body[p + 2])<<8 | u32(body[p + 3])
		ivd_abs := int(ivd_rel)
		if ivd_abs + 6 > len(body) {
			delete(counts, allocator); delete(offsets, allocator); return false
		}
		// ItemVariationData: itemCount u16, shortDeltaCount u16, regionIndexCount u16, ...
		region_index_count := u16(body[ivd_abs + 4])<<8 | u16(body[ivd_abs + 5])
		counts[i]  = region_index_count
		offsets[i] = u32(body_off) + ivd_rel
	}
	region_counts^ = counts
	ivd_offsets^   = offsets
	ivs_body_off^  = u32(body_off)
	if ivd_count > 0 { default_num_regions^ = int(counts[0]) }
	return true
}

// cff2_compute_scalars fills `out` with the per-region scalar weights
// for the given `vsindex` evaluated at `axis_values`. The number of
// scalars equals the IVD's regionIndexCount; entry i is the scalar
// for the region referenced by regionIndexes[i].
//
// Caller is responsible for `out` capacity / clearing — this proc
// resizes `out` to match the region count. Returns false if the
// vsindex is out of range or the IVS data is malformed.
cff2_compute_scalars :: proc(c: ^Cff2, vsindex: int, axis_values: []f32, out: ^[dynamic]f32) -> bool {
	if vsindex < 0 || vsindex >= len(c.ivd_offsets) { return false }
	if c.ivs_body_off == 0 { return false }
	d := c.data
	ivs_body := c.ivs_body_off
	if u64(ivs_body) + 8 > u64(len(d)) { return false }
	regions_rel := u32(d[ivs_body + 2])<<24 | u32(d[ivs_body + 3])<<16 |
	               u32(d[ivs_body + 4])<<8  | u32(d[ivs_body + 5])
	regions_abs := ivs_body + regions_rel

	ivd_abs := c.ivd_offsets[vsindex]
	if u64(ivd_abs) + 6 > u64(len(d)) { return false }
	region_index_count := int(u16(d[ivd_abs + 4])<<8 | u16(d[ivd_abs + 5]))
	region_indices_off := ivd_abs + 6
	if u64(region_indices_off) + u64(region_index_count) * 2 > u64(len(d)) { return false }

	resize(out, region_index_count)
	for i in 0..<region_index_count {
		rip := region_indices_off + u32(i) * 2
		region_idx := u16(d[rip])<<8 | u16(d[rip + 1])
		out[i] = ivs_region_scalar(d, regions_abs, region_idx, axis_values)
	}
	return true
}
