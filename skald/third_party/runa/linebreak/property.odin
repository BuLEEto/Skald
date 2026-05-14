/*
UAX #14 Line_Break property lookup.

The Unicode data ships in `tools/ucd/LineBreak.txt`; the parser builds
a sorted `[]Range` on first use and binary-searches against it. Range
count is ~3 000 — a 12-step bsearch per codepoint, which is fine for
the linebreak engine's non-hot-path.

v0.1 ships the runtime parser. The two-stage-trie codegen described in
The codegen-baked two-stage trie is the v0.2 polish — gives 5–10× lookup speedup and lets
the data ship as compile-time-baked Odin source instead of an embedded
text blob.

References: UAX #14 §6 "Line_Break Property Definitions",
`https://www.unicode.org/Public/UCD/latest/ucd/LineBreak.txt`.
*/
package linebreak

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// Line_Break property values. Aliased into a u8 for compact storage.
// Names match the UCD short identifiers.
Line_Break_Class :: enum u8 {
	// Non-tailorable
	BK,        // Mandatory Break
	CR,        // Carriage Return
	LF,        // Line Feed
	NL,        // Next Line
	SP,        // Space
	ZW,        // Zero Width Space
	ZWJ,       // Zero Width Joiner
	GL,        // Glue
	WJ,        // Word Joiner
	CM,        // Combining Mark
	// Tailorable
	AI,        // Ambiguous (Alphabetic or Ideographic)
	AK,        // Aksara
	AL,        // Alphabetic
	AP,        // Aksara Pre-Base
	AS,        // Aksara Start
	B2,        // Break Opportunity Before and After
	BA,        // Break After
	BB,        // Break Before
	CB,        // Contingent Break
	CJ,        // Conditional Japanese Starter
	CL,        // Close Punctuation
	CP,        // Close Parenthesis
	EB,        // Emoji Base
	EM,        // Emoji Modifier
	EX,        // Exclamation/Interrogation
	H2,        // Hangul LV
	H3,        // Hangul LVT
	HH,        // Hyphen-Hangul / Hyphen (Unicode 17.0 split-off from HY)
	HL,        // Hebrew Letter
	HY,        // Hyphen
	ID,        // Ideographic
	IN,        // Inseparable
	IS,        // Infix Numeric Separator
	JL,        // Hangul L Jamo
	JT,        // Hangul T Jamo
	JV,        // Hangul V Jamo
	NS,        // Nonstarter
	NU,        // Numeric
	OP,        // Open Punctuation
	PO,        // Postfix Numeric
	PR,        // Prefix Numeric
	QU,        // Quotation
	RI,        // Regional Indicator
	SA,        // Complex Context
	SG,        // Surrogate
	SY,        // Symbol
	VF,        // Virama Final
	VI,        // Virama
	XX,        // Unknown (default)
}

// Range is one row from LineBreak.txt, expanded so each row covers
// exactly one contiguous codepoint range with a single class.
Range :: struct {
	start: rune,
	end:   rune,           // inclusive
	cls:   Line_Break_Class,
}

@(private="file")
g_ranges:     []Range
@(private="file")
g_load_once:  sync.Once

// LB_DATA is the UCD source text, embedded at compile time. Updated by
// rerunning `curl -fsSL https://www.unicode.org/Public/UCD/latest/ucd/LineBreak.txt
// > tools/ucd/LineBreak.txt`.
LB_DATA :: #load("../tools/ucd/LineBreak.txt", string)

// is_eaw_wide_op returns true if `r` is an OP-class codepoint with
// East Asian Width W / F / H. The LB30 "(AL|HL|NU) × OP" rule has an
// EAW exception: wide OPs (like 〈) keep their default break
// opportunity instead of binding to the preceding letter. Hard-coded
// from the intersection of Unicode 17.0's `LineBreak.txt` (OP) and
// `EastAsianWidth.txt` (W|F|H).
is_eaw_wide_op :: proc(r: rune) -> bool {
	switch r {
	case 0x2329,
	     0x3008, 0x300A, 0x300C, 0x300E, 0x3010,
	     0x3014, 0x3016, 0x3018, 0x301A, 0x301D,
	     0xFE17, 0xFE35, 0xFE37, 0xFE39, 0xFE3B, 0xFE3D, 0xFE3F,
	     0xFE41, 0xFE43, 0xFE47, 0xFE59, 0xFE5B, 0xFE5D,
	     0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62:
		return true
	}
	return false
}

// is_pi_punctuation returns true if `r` has Unicode general category
// `Pi` (Initial Punctuation — opening quotation marks). The set is
// tiny enough (~11 codepoints in Unicode 17.0) to hard-code rather
// than embed a property table just for this one check.
is_pi_punctuation :: proc(r: rune) -> bool {
	switch r {
	case 0x00AB,           // LEFT-POINTING DOUBLE ANGLE QUOTATION MARK
	     0x2018,           // LEFT SINGLE QUOTATION MARK
	     0x201B, 0x201C,   // SINGLE/DOUBLE HIGH-REVERSED-9 / LEFT DOUBLE QUOTATION
	     0x201F,           // DOUBLE HIGH-REVERSED-9 QUOTATION MARK
	     0x2039,           // SINGLE LEFT-POINTING ANGLE QUOTATION MARK
	     0x2E02, 0x2E04, 0x2E09, 0x2E0C, 0x2E1C, 0x2E20:
		return true
	}
	return false
}

// sa_resolves_to_cm reports whether `r` is in Line_Break class SA *and*
// has Mn or Mc general category — i.e. it's a Thai / Lao / Myanmar /
// Khmer combining mark that LB1 says should resolve to CM rather than
// AL. The full SA range covers 757 codepoints; this subset is 191
// codepoints across 27 hard-coded ranges (generated from Unicode 17.0
// `DerivedGeneralCategory.txt` × `LineBreak.txt`).
sa_resolves_to_cm :: proc(r: rune) -> bool {
	switch r {
	case 0x0E31,
	     0x0E34..=0x0E3A,
	     0x0E47..=0x0E4E,
	     0x0EB1,
	     0x0EB4..=0x0EBC,
	     0x0EC8..=0x0ECE,
	     0x102B..=0x103E,
	     0x1056..=0x1059,
	     0x105E..=0x1060,
	     0x1062..=0x1064,
	     0x1067..=0x106D,
	     0x1071..=0x1074,
	     0x1082..=0x108D,
	     0x108F,
	     0x109A..=0x109D,
	     0x17B4..=0x17D3,
	     0x17DD,
	     0x1A55..=0x1A5E,
	     0x1A60..=0x1A7C,
	     0xA9E5,
	     0xAA7B..=0xAA7D,
	     0xAAB0,
	     0xAAB2..=0xAAB4,
	     0xAAB7..=0xAAB8,
	     0xAABE..=0xAABF,
	     0xAAC1,
	     0x1171D..=0x1172B:
		return true
	}
	return false
}

// is_pf_punctuation returns true if `r` has Unicode general category
// `Pf` (Final Punctuation — closing quotation marks). Hard-coded
// from `DerivedGeneralCategory.txt` (Unicode 17.0).
is_pf_punctuation :: proc(r: rune) -> bool {
	switch r {
	case 0x00BB,           // RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK
	     0x2019,           // RIGHT SINGLE QUOTATION MARK
	     0x201D,           // RIGHT DOUBLE QUOTATION MARK
	     0x203A,           // SINGLE RIGHT-POINTING ANGLE QUOTATION MARK
	     0x2E03, 0x2E05, 0x2E0A, 0x2E0D, 0x2E1D, 0x2E21:
		return true
	}
	return false
}

// line_break_class returns the Line_Break property of `r`. Codepoints
// outside the assigned range fall through to `XX`.
line_break_class :: proc(r: rune) -> Line_Break_Class {
	sync.once_do(&g_load_once, init_lb_table)

	lo, hi := 0, len(g_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .XX
}

@(private="file")
init_lb_table :: proc() {
	// Allocate from the runtime heap, NOT from `context.allocator`.
	// The data lives for the process lifetime; using context.allocator
	// would let test-scoped tracking allocators flag it as a leak.
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]Range, 0, 4096)
	for line in strings.split_lines_iterator(&LB_DATA_LINES) {
		// Skip blanks and comments.
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		// Strip trailing comment, then split on ';'.
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = strings.trim_space(trimmed[:hash])
		}
		semi := strings.index_byte(trimmed, ';')
		if semi < 0 { continue }
		cp_part  := strings.trim_space(trimmed[:semi])
		cls_part := strings.trim_space(trimmed[semi + 1:])

		// Codepoint range: either "XXXX" or "XXXX..YYYY".
		start, end: rune
		if dot := strings.index(cp_part, ".."); dot >= 0 {
			s_u, _ := strconv.parse_u64_of_base(cp_part[:dot], 16)
			e_u, _ := strconv.parse_u64_of_base(cp_part[dot + 2:], 16)
			start = rune(s_u); end = rune(e_u)
		} else {
			s_u, _ := strconv.parse_u64_of_base(cp_part, 16)
			start = rune(s_u); end = start
		}
		cls, ok := class_from_short(cls_part)
		if !ok { continue }
		append(&tmp, Range{start = start, end = end, cls = cls})
	}
	g_ranges = tmp[:]
	// Ranges in LineBreak.txt are already ascending, no need to sort.
}

// LB_DATA_LINES is the iterable view of LB_DATA. The
// `split_lines_iterator` mutates its string view as it walks; keep
// the original LB_DATA pristine so re-runs (in tests, say) see the
// full text.
@(private="file")
LB_DATA_LINES := LB_DATA

@(private="file")
class_from_short :: proc(s: string) -> (Line_Break_Class, bool) {
	switch s {
	case "BK":  return .BK,  true
	case "CR":  return .CR,  true
	case "LF":  return .LF,  true
	case "NL":  return .NL,  true
	case "SP":  return .SP,  true
	case "ZW":  return .ZW,  true
	case "ZWJ": return .ZWJ, true
	case "GL":  return .GL,  true
	case "WJ":  return .WJ,  true
	case "CM":  return .CM,  true
	case "AI":  return .AI,  true
	case "AK":  return .AK,  true
	case "AL":  return .AL,  true
	case "AP":  return .AP,  true
	case "AS":  return .AS,  true
	case "B2":  return .B2,  true
	case "BA":  return .BA,  true
	case "BB":  return .BB,  true
	case "CB":  return .CB,  true
	case "CJ":  return .CJ,  true
	case "CL":  return .CL,  true
	case "CP":  return .CP,  true
	case "EB":  return .EB,  true
	case "EM":  return .EM,  true
	case "EX":  return .EX,  true
	case "H2":  return .H2,  true
	case "H3":  return .H3,  true
	case "HH":  return .HH,  true
	case "HL":  return .HL,  true
	case "HY":  return .HY,  true
	case "ID":  return .ID,  true
	case "IN":  return .IN,  true
	case "IS":  return .IS,  true
	case "JL":  return .JL,  true
	case "JT":  return .JT,  true
	case "JV":  return .JV,  true
	case "NS":  return .NS,  true
	case "NU":  return .NU,  true
	case "OP":  return .OP,  true
	case "PO":  return .PO,  true
	case "PR":  return .PR,  true
	case "QU":  return .QU,  true
	case "RI":  return .RI,  true
	case "SA":  return .SA,  true
	case "SG":  return .SG,  true
	case "SY":  return .SY,  true
	case "VF":  return .VF,  true
	case "VI":  return .VI,  true
	case "XX":  return .XX,  true
	}
	return .XX, false
}
