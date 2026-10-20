package parse

// CFF — Compact Font Format (Type 2 charstrings).
//
// CFF-flavoured SFNT fonts (`'OTTO'` magic) store outlines as Type 2
// charstrings rather than the `glyf` table. The CFF table itself
// contains a small directory of INDEX structures plus DICT-encoded
// metadata pointing at the charstring data and the private dict.
//
// v0.5 parses the structure to find the per-glyph charstring bytes
// + the global / local subroutine INDEXes. The Type 2 interpreter
// (`cff_charstring.odin`) walks those bytes and emits a flattened
// outline that the rasterizer consumes via the same `Outline`
// shape `glyf` produces.
//
// CFF2 (variable-CFF) is a separate revision and not parsed here —
// support arrives alongside CFF2 once a variable Adobe font lands
// in the test corpus. The CFF1 path covers every static CFF font.
//
// References: Adobe Technical Note #5176 (CFF spec) + #5177 (Type 2
// charstring format).

CFF_OP_VERSION    :: 0
CFF_OP_NOTICE     :: 1
CFF_OP_FULL_NAME  :: 2
CFF_OP_FAMILY     :: 3
CFF_OP_WEIGHT     :: 4
CFF_OP_FONT_BBOX  :: 5
CFF_OP_CHARSET    :: 15
CFF_OP_ENCODING   :: 16
CFF_OP_CHARSTRINGS :: 17
CFF_OP_PRIVATE    :: 18                                 // operand pair: size, offset
CFF_OP_CHARSTRING_TYPE :: 0x0C06                         // (12, 6) escape encoding

// Cff holds the parsed locations of the structures the rasterizer
// needs. The slice fields alias the source `data` — caller owns the
// memory, we hold lazy views.
Cff :: struct {
	data:             []u8,
	num_glyphs:       int,

	// Charstring INDEX — per-glyph Type 2 bytecode.
	charstrings_index: Cff_Index,

	// Global Subr INDEX — biased by 32768 / 1131 / 107 by length.
	global_subrs:     Cff_Index,
	global_subr_bias: int,

	// Local Subr INDEX — same bias rule.
	local_subrs:      Cff_Index,
	local_subr_bias:  int,

	// Charstring type — 1 (PostScript Type 1) or 2 (Type 2). We only
	// support 2; anything else returns Unsupported_Format at load.
	charstring_type:  int,

	// CID-keyed (Top DICT carries ROS, op 12 30). A CID font has no
	// top-level Private DICT; each glyph takes its local subrs from one
	// of many Font DICTs in `fdarray`, chosen by FDSelect. When `is_cid`
	// the single `local_subrs` above stays empty and is unused — the
	// same FD machinery CFF2 uses, wired onto the CFF1 path.
	is_cid:           bool,
	fdarray:          []Cff_Fd,                             // one Private/Subrs set per FD
	fdselect_off:     u32,                                  // FDSelect offset within `data`
}

// Cff_Index is a parsed (count, offsets, data slice) triple — view
// into the original CFF table data.
Cff_Index :: struct {
	count:   int,
	offsets: []u32,                                       // length count + 1
	data:    []u8,                                        // raw, with 1-indexed offsets
}

new_cff :: proc(data: []u8, allocator := context.allocator) -> (c: Cff, err: Error) {
	if len(data) < 4 { err = .Invalid_Table; return }
	major     := data[0]
	hdr_size  := int(data[2])
	top_off_size := int(data[3])
	_ = top_off_size
	if major != 1 { err = .Unsupported_Format; return }   // CFF2 = major 2
	if hdr_size < 4 || hdr_size > len(data) { err = .Invalid_Table; return }

	c.data = data

	// Name INDEX — typically one entry, the PostScript name. Skipped.
	pos := hdr_size
	name_idx, p1, e1 := read_cff_index(data, pos, allocator)
	if e1 != .None { err = e1; return }
	pos = p1
	_ = name_idx

	// Top DICT INDEX — one DICT per font. CFF1 single-font: one entry.
	top_idx, p2, e2 := read_cff_index(data, pos, allocator)
	if e2 != .None { cff_index_destroy(&name_idx, allocator); err = e2; return }
	pos = p2
	if top_idx.count < 1 {
		cff_index_destroy(&name_idx, allocator); cff_index_destroy(&top_idx, allocator)
		err = .Invalid_Table
		return
	}

	// String INDEX — referenced by SIDs in Top DICT. Not needed for
	// outline extraction.
	string_idx, p3, e3 := read_cff_index(data, pos, allocator)
	if e3 != .None {
		cff_index_destroy(&name_idx, allocator); cff_index_destroy(&top_idx, allocator)
		err = e3
		return
	}
	pos = p3
	_ = string_idx
	defer cff_index_destroy(&string_idx, allocator)

	// Global Subr INDEX — used by callgsubr, indexed with bias.
	gsubrs, p4, e4 := read_cff_index(data, pos, allocator)
	if e4 != .None {
		cff_index_destroy(&name_idx, allocator); cff_index_destroy(&top_idx, allocator)
		err = e4
		return
	}
	_ = p4
	c.global_subrs = gsubrs
	c.global_subr_bias = subr_bias(gsubrs.count)

	cff_index_destroy(&name_idx, allocator)
	defer cff_index_destroy(&top_idx, allocator)

	// Parse Top DICT to find CharStrings / Private / Charstring Type.
	top_entry, terr := cff_index_get(&top_idx, 0)
	if terr != .None { err = terr; return }

	charstrings_off: u32 = 0
	private_size: u32 = 0
	private_off: u32 = 0
	fdarray_off: u32 = 0
	fdselect_off: u32 = 0
	c.charstring_type = 2
	if !parse_top_dict(top_entry, &charstrings_off, &private_size, &private_off, &c.charstring_type, &c.is_cid, &fdarray_off, &fdselect_off) {
		err = .Invalid_Table
		return
	}
	if charstrings_off == 0 { err = .Invalid_Table; return }
	if c.charstring_type != 2 { err = .Unsupported_Format; return }

	// CharStrings INDEX.
	cs_idx, _, ce := read_cff_index(data, int(charstrings_off), allocator)
	if ce != .None { err = ce; return }
	c.charstrings_index = cs_idx
	c.num_glyphs = cs_idx.count

	// Private DICT → Local Subrs offset (relative to Private DICT start).
	if private_size > 0 && private_off > 0 {
		end := u64(private_off) + u64(private_size)
		if end > u64(len(data)) { err = .Invalid_Table; return }
		local_subr_rel: u32 = 0
		if parse_private_dict(data[private_off:end], &local_subr_rel) && local_subr_rel != 0 {
			abs_off := int(private_off) + int(local_subr_rel)
			lsubrs, _, le := read_cff_index(data, abs_off, allocator)
			if le == .None {
				c.local_subrs = lsubrs
				c.local_subr_bias = subr_bias(lsubrs.count)
			}
		}
	}

	// CID-keyed font: read the FDArray (an INDEX of Font DICTs) and each
	// FD's Private DICT → Local Subrs, so a glyph can take its subrs from
	// the FD that FDSelect maps it to. Same shape as the CFF2 path, but
	// the FDArray / Local Subr INDEXes use the CFF1 (narrow-count) reader.
	if c.is_cid && fdarray_off != 0 {
		c.fdselect_off = fdselect_off
		fd_index, _, fe := read_cff_index(data, int(fdarray_off), allocator)
		if fe == .None {
			defer cff_index_destroy(&fd_index, allocator)
			c.fdarray = make([]Cff_Fd, fd_index.count, allocator)
			for i in 0..<fd_index.count {
				fd_bytes, ferr := cff_index_get(&fd_index, i)
				if ferr != .None { continue }
				fd_priv_size, fd_priv_off: u32 = 0, 0
				if !parse_font_dict_private(fd_bytes, &fd_priv_size, &fd_priv_off) { continue }
				if fd_priv_size == 0 || fd_priv_off == 0 { continue }
				fd_end := u64(fd_priv_off) + u64(fd_priv_size)
				if fd_end > u64(len(data)) { continue }
				fd_subr_rel: u32 = 0
				if parse_private_dict(data[fd_priv_off:fd_end], &fd_subr_rel) && fd_subr_rel != 0 {
					abs_off := int(fd_priv_off) + int(fd_subr_rel)
					lsubrs, _, le := read_cff_index(data, abs_off, allocator)
					if le == .None {
						c.fdarray[i].local_subrs     = lsubrs
						c.fdarray[i].local_subr_bias = subr_bias(lsubrs.count)
					}
				}
			}
		}
	}

	return
}

cff_destroy :: proc(c: ^Cff, allocator := context.allocator) {
	cff_index_destroy(&c.charstrings_index, allocator)
	cff_index_destroy(&c.global_subrs, allocator)
	cff_index_destroy(&c.local_subrs, allocator)
	for i in 0..<len(c.fdarray) {
		cff_index_destroy(&c.fdarray[i].local_subrs, allocator)
	}
	delete(c.fdarray, allocator)
	c^ = {}
}

// cff_fd_index resolves the Font DICT index for `gid` via FDSelect in a
// CID-keyed font. Non-CID (or single-FD) fonts always return 0.
cff_fd_index :: proc(c: ^Cff, gid: Glyph_ID) -> int {
	if !c.is_cid || c.fdselect_off == 0 || len(c.fdarray) <= 1 { return 0 }
	return fdselect_lookup(c.data, c.fdselect_off, gid)
}

// cff_charstring_bytes returns the Type 2 charstring bytes for `gid`,
// aliasing the source data. Empty for unmapped glyphs.
cff_charstring_bytes :: proc(c: ^Cff, gid: Glyph_ID) -> []u8 {
	b, _ := cff_index_get(&c.charstrings_index, int(gid))
	return b
}

// ---- INDEX reader -----------------------------------------------

// CFF / CFF2 INDEX reader. CFF1 uses a u16 count + u8 offSize header
// (3-byte prefix); CFF2 uses a u32 count + u8 offSize (5-byte prefix).
// Both call into this proc with `wide_count` set accordingly.
@(private)
read_cff_index :: proc(data: []u8, pos: int, allocator: mem.Allocator, wide_count := false) -> (idx: Cff_Index, end: int, err: Error) {
	header_size := wide_count ? 5 : 3
	if pos + header_size - 1 > len(data) { err = .Invalid_Table; return }
	count: int
	if wide_count {
		count = int(u32(data[pos])<<24 | u32(data[pos + 1])<<16 |
		            u32(data[pos + 2])<<8  | u32(data[pos + 3]))
	} else {
		count = int(u16(data[pos])<<8 | u16(data[pos + 1]))
	}
	if count == 0 {
		end = pos + (wide_count ? 4 : 2)
		return
	}
	if pos + header_size > len(data) { err = .Invalid_Table; return }
	off_size := int(data[pos + header_size - 1])
	if off_size < 1 || off_size > 4 { err = .Invalid_Table; return }

	off_array_start := pos + header_size
	off_array_end := off_array_start + (count + 1) * off_size
	if off_array_end > len(data) { err = .Invalid_Table; return }

	offsets := make([]u32, count + 1, allocator)
	for i in 0..<count + 1 {
		raw: u32 = 0
		base := off_array_start + i * off_size
		for k in 0..<off_size {
			raw = (raw << 8) | u32(data[base + k])
		}
		offsets[i] = raw
	}

	// Object data starts immediately after the offsets array. CFF
	// offsets are 1-indexed (offset value 1 = first byte of object
	// data); the 1-based-to-0-based conversion happens in
	// `cff_index_get`.
	data_base := off_array_end
	last_off := int(offsets[count])
	end = data_base + last_off - 1
	if end > len(data) { delete(offsets, allocator); err = .Invalid_Table; return }

	idx.count = count
	idx.offsets = offsets
	idx.data = data[data_base:end]
	return
}

@(private)
cff_index_destroy :: proc(idx: ^Cff_Index, allocator: mem.Allocator) {
	delete(idx.offsets, allocator)
	idx^ = {}
}

// cff_index_get returns the bytes for entry `i` in the INDEX.
cff_index_get :: proc(idx: ^Cff_Index, i: int) -> (b: []u8, err: Error) {
	if i < 0 || i >= idx.count { err = .Invalid_Table; return }
	start := int(idx.offsets[i])     - 1
	end   := int(idx.offsets[i + 1]) - 1
	if start < 0 || end > len(idx.data) || end < start {
		err = .Invalid_Table
		return
	}
	b = idx.data[start:end]
	return
}

@(private)
subr_bias :: proc(count: int) -> int {
	switch {
	case count < 1240:  return 107
	case count < 33900: return 1131
	}
	return 32768
}

// ---- DICT parser -----------------------------------------------

// parse_top_dict pulls just the operators we care about. Returns
// false on malformed input.
@(private)
parse_top_dict :: proc(d: []u8, charstrings_off: ^u32, private_size, private_off: ^u32, charstring_type: ^int, is_cid: ^bool, fdarray_off, fdselect_off: ^u32) -> bool {
	stack: [48]i64
	sp := 0

	i := 0
	for i < len(d) {
		b := d[i]
		switch {
		case b == 30:                                  // real number
			// Skip BCD-encoded real. Read pairs of nibbles until 0xf
			// nibble.
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
			// Two-byte operator.
			if i + 1 >= len(d) { return false }
			b2 := d[i + 1]
			i += 2
			switch b2 {
			case 6:  if sp >= 1 { charstring_type^ = int(stack[sp - 1]) } // CharstringType
			case 30: is_cid^ = true                                       // ROS — CID-keyed
			case 36: if sp >= 1 { fdarray_off^  = u32(stack[sp - 1]) }    // FDArray
			case 37: if sp >= 1 { fdselect_off^ = u32(stack[sp - 1]) }    // FDSelect
			}
			sp = 0
		case:
			// One-byte operator.
			switch b {
			case CFF_OP_CHARSTRINGS:
				if sp >= 1 { charstrings_off^ = u32(stack[sp - 1]) }
			case CFF_OP_PRIVATE:
				if sp >= 2 {
					private_size^ = u32(stack[sp - 2])
					private_off^  = u32(stack[sp - 1])
				}
			}
			sp = 0
			i += 1
		}
	}
	return true
}

@(private)
parse_private_dict :: proc(d: []u8, local_subr_rel: ^u32) -> bool {
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
			i += 2
			sp = 0
		case:
			// 19 = Subrs (offset, relative to Private DICT start)
			if b == 19 && sp >= 1 { local_subr_rel^ = u32(stack[sp - 1]) }
			sp = 0
			i += 1
		}
	}
	return true
}

// Type-2 charstring interpreter lives in cff_charstring.odin so this
// file stays focused on the table layout. Both files share `Cff` and
// the INDEX helpers.

import "core:mem"
