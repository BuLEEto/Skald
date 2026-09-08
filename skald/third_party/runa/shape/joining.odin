/*
Arabic / Syriac / Mandaic / N'Ko / etc. positional-shaping Joining
properties from UAX #9 Appendix B + ArabicShaping.txt.

This file ships the property lookup; the state-machine that turns
per-codepoint Joining_Type into the per-position joining form (and
selects which of `isol` / `init` / `medi` / `fina` to apply at GSUB
time) lives alongside it as `arabic_join_state`.

References: UAX §9, "Arabic Cursive Joining"; Unicode 17.0
`ArabicShaping.txt`.
*/
package shape

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// Joining_Type values from ArabicShaping.txt.
//
//   U  Non_Joining — doesn't join (e.g. ZERO WIDTH NON-JOINER).
//   R  Right_Joining — joins from the right (Arabic Alef, Reh, …).
//   L  Left_Joining — joins from the left (rare; some Mongolian).
//   D  Dual_Joining — joins on both sides (most Arabic letters).
//   T  Transparent — combining marks; pass-through for join state.
//   C  Join_Causing — ZWJ / Kashida; force a join on adjacent sides.
//   X  (our sentinel) Not Arabic / Syriac / Mandaic — no joining.
Joining_Type :: enum u8 {
	X,        // default — not a joining script
	U,
	R,
	L,
	D,
	T,
	C,
}

@(private="file")
Range :: struct {
	start, end: rune,
	jt:         Joining_Type,
}

@(private="file") g_ranges:    []Range
@(private="file") g_load_once: sync.Once

@(private="file")
JOIN_DATA :: #load("../tools/ucd/ArabicShaping.txt", string)

@(private="file") JOIN_DATA_LINES := JOIN_DATA

// joining_type returns the Joining_Type of `r`. The explicit
// ArabicShaping.txt listing wins when present — ZWJ and ZWNJ are both Cf
// but listed `C` / `U`, so they must not be derived as Transparent. On a
// miss, Mn/Me/Cf are `T` and everything else falls to `.X`, which the
// state machine treats the same as `.U`.
joining_type :: proc(r: rune) -> Joining_Type {
	sync.once_do(&g_load_once, init_table)
	lo, hi := 0, len(g_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.jt
		}
	}
	// Not explicitly listed — derive per the ArabicShaping.txt header.
	if is_transparent_by_category(r) { return .T }
	return .X
}

// is_transparent_by_category reports General_Category Mn / Me / Cf —
// the set ArabicShaping.txt omits and defines as Joining_Type=T. Without
// it every harakat breaks the cursive chain.
//
// 376 ranges / 2242 codepoints from Unicode 17.0
// `tools/ucd/DerivedGeneralCategory.txt`, hard-coded rather than
// `#load`ed to keep the 277 KB source out of the binary.
//
// To regenerate: filter for Mn/Me/Cf, **sort by codepoint**, merge
// contiguous ranges. The sort is mandatory — the file is grouped by
// category, so merging in file order silently drops 183 codepoints
// (ZWJ and ZWNJ among them) and still emits a valid switch.
// `tests/shape/joining_table_test.odin` catches a bad regeneration.
@(private="file")
is_transparent_by_category :: proc(r: rune) -> bool {
	switch r {
	case 0x00AD, 0x0300..=0x036F, 0x0483..=0x0489, 0x0591..=0x05BD,
	     0x05BF, 0x05C1..=0x05C2, 0x05C4..=0x05C5, 0x05C7,
	     0x0600..=0x0605, 0x0610..=0x061A, 0x061C, 0x064B..=0x065F,
	     0x0670, 0x06D6..=0x06DD, 0x06DF..=0x06E4, 0x06E7..=0x06E8,
	     0x06EA..=0x06ED, 0x070F, 0x0711, 0x0730..=0x074A,
	     0x07A6..=0x07B0, 0x07EB..=0x07F3, 0x07FD, 0x0816..=0x0819,
	     0x081B..=0x0823, 0x0825..=0x0827, 0x0829..=0x082D, 0x0859..=0x085B,
	     0x0890..=0x0891, 0x0897..=0x089F, 0x08CA..=0x0902, 0x093A,
	     0x093C, 0x0941..=0x0948, 0x094D, 0x0951..=0x0957,
	     0x0962..=0x0963, 0x0981, 0x09BC, 0x09C1..=0x09C4,
	     0x09CD, 0x09E2..=0x09E3, 0x09FE, 0x0A01..=0x0A02,
	     0x0A3C, 0x0A41..=0x0A42, 0x0A47..=0x0A48, 0x0A4B..=0x0A4D,
	     0x0A51, 0x0A70..=0x0A71, 0x0A75, 0x0A81..=0x0A82,
	     0x0ABC, 0x0AC1..=0x0AC5, 0x0AC7..=0x0AC8, 0x0ACD,
	     0x0AE2..=0x0AE3, 0x0AFA..=0x0AFF, 0x0B01, 0x0B3C,
	     0x0B3F, 0x0B41..=0x0B44, 0x0B4D, 0x0B55..=0x0B56,
	     0x0B62..=0x0B63, 0x0B82, 0x0BC0, 0x0BCD,
	     0x0C00, 0x0C04, 0x0C3C, 0x0C3E..=0x0C40,
	     0x0C46..=0x0C48, 0x0C4A..=0x0C4D, 0x0C55..=0x0C56, 0x0C62..=0x0C63,
	     0x0C81, 0x0CBC, 0x0CBF, 0x0CC6,
	     0x0CCC..=0x0CCD, 0x0CE2..=0x0CE3, 0x0D00..=0x0D01, 0x0D3B..=0x0D3C,
	     0x0D41..=0x0D44, 0x0D4D, 0x0D62..=0x0D63, 0x0D81,
	     0x0DCA, 0x0DD2..=0x0DD4, 0x0DD6, 0x0E31,
	     0x0E34..=0x0E3A, 0x0E47..=0x0E4E, 0x0EB1, 0x0EB4..=0x0EBC,
	     0x0EC8..=0x0ECE, 0x0F18..=0x0F19, 0x0F35, 0x0F37,
	     0x0F39, 0x0F71..=0x0F7E, 0x0F80..=0x0F84, 0x0F86..=0x0F87,
	     0x0F8D..=0x0F97, 0x0F99..=0x0FBC, 0x0FC6, 0x102D..=0x1030,
	     0x1032..=0x1037, 0x1039..=0x103A, 0x103D..=0x103E, 0x1058..=0x1059,
	     0x105E..=0x1060, 0x1071..=0x1074, 0x1082, 0x1085..=0x1086,
	     0x108D, 0x109D, 0x135D..=0x135F, 0x1712..=0x1714,
	     0x1732..=0x1733, 0x1752..=0x1753, 0x1772..=0x1773, 0x17B4..=0x17B5,
	     0x17B7..=0x17BD, 0x17C6, 0x17C9..=0x17D3, 0x17DD,
	     0x180B..=0x180F, 0x1885..=0x1886, 0x18A9, 0x1920..=0x1922,
	     0x1927..=0x1928, 0x1932, 0x1939..=0x193B, 0x1A17..=0x1A18,
	     0x1A1B, 0x1A56, 0x1A58..=0x1A5E, 0x1A60,
	     0x1A62, 0x1A65..=0x1A6C, 0x1A73..=0x1A7C, 0x1A7F,
	     0x1AB0..=0x1ADD, 0x1AE0..=0x1AEB, 0x1B00..=0x1B03, 0x1B34,
	     0x1B36..=0x1B3A, 0x1B3C, 0x1B42, 0x1B6B..=0x1B73,
	     0x1B80..=0x1B81, 0x1BA2..=0x1BA5, 0x1BA8..=0x1BA9, 0x1BAB..=0x1BAD,
	     0x1BE6, 0x1BE8..=0x1BE9, 0x1BED, 0x1BEF..=0x1BF1,
	     0x1C2C..=0x1C33, 0x1C36..=0x1C37, 0x1CD0..=0x1CD2, 0x1CD4..=0x1CE0,
	     0x1CE2..=0x1CE8, 0x1CED, 0x1CF4, 0x1CF8..=0x1CF9,
	     0x1DC0..=0x1DFF, 0x200B..=0x200F, 0x202A..=0x202E, 0x2060..=0x2064,
	     0x2066..=0x206F, 0x20D0..=0x20F0, 0x2CEF..=0x2CF1, 0x2D7F,
	     0x2DE0..=0x2DFF, 0x302A..=0x302D, 0x3099..=0x309A, 0xA66F..=0xA672,
	     0xA674..=0xA67D, 0xA69E..=0xA69F, 0xA6F0..=0xA6F1, 0xA802,
	     0xA806, 0xA80B, 0xA825..=0xA826, 0xA82C,
	     0xA8C4..=0xA8C5, 0xA8E0..=0xA8F1, 0xA8FF, 0xA926..=0xA92D,
	     0xA947..=0xA951, 0xA980..=0xA982, 0xA9B3, 0xA9B6..=0xA9B9,
	     0xA9BC..=0xA9BD, 0xA9E5, 0xAA29..=0xAA2E, 0xAA31..=0xAA32,
	     0xAA35..=0xAA36, 0xAA43, 0xAA4C, 0xAA7C,
	     0xAAB0, 0xAAB2..=0xAAB4, 0xAAB7..=0xAAB8, 0xAABE..=0xAABF,
	     0xAAC1, 0xAAEC..=0xAAED, 0xAAF6, 0xABE5,
	     0xABE8, 0xABED, 0xFB1E, 0xFE00..=0xFE0F,
	     0xFE20..=0xFE2F, 0xFEFF, 0xFFF9..=0xFFFB, 0x101FD,
	     0x102E0, 0x10376..=0x1037A, 0x10A01..=0x10A03, 0x10A05..=0x10A06,
	     0x10A0C..=0x10A0F, 0x10A38..=0x10A3A, 0x10A3F, 0x10AE5..=0x10AE6,
	     0x10D24..=0x10D27, 0x10D69..=0x10D6D, 0x10EAB..=0x10EAC, 0x10EFA..=0x10EFF,
	     0x10F46..=0x10F50, 0x10F82..=0x10F85, 0x11001, 0x11038..=0x11046,
	     0x11070, 0x11073..=0x11074, 0x1107F..=0x11081, 0x110B3..=0x110B6,
	     0x110B9..=0x110BA, 0x110BD, 0x110C2, 0x110CD,
	     0x11100..=0x11102, 0x11127..=0x1112B, 0x1112D..=0x11134, 0x11173,
	     0x11180..=0x11181, 0x111B6..=0x111BE, 0x111C9..=0x111CC, 0x111CF,
	     0x1122F..=0x11231, 0x11234, 0x11236..=0x11237, 0x1123E,
	     0x11241, 0x112DF, 0x112E3..=0x112EA, 0x11300..=0x11301,
	     0x1133B..=0x1133C, 0x11340, 0x11366..=0x1136C, 0x11370..=0x11374,
	     0x113BB..=0x113C0, 0x113CE, 0x113D0, 0x113D2,
	     0x113E1..=0x113E2, 0x11438..=0x1143F, 0x11442..=0x11444, 0x11446,
	     0x1145E, 0x114B3..=0x114B8, 0x114BA, 0x114BF..=0x114C0,
	     0x114C2..=0x114C3, 0x115B2..=0x115B5, 0x115BC..=0x115BD, 0x115BF..=0x115C0,
	     0x115DC..=0x115DD, 0x11633..=0x1163A, 0x1163D, 0x1163F..=0x11640,
	     0x116AB, 0x116AD, 0x116B0..=0x116B5, 0x116B7,
	     0x1171D, 0x1171F, 0x11722..=0x11725, 0x11727..=0x1172B,
	     0x1182F..=0x11837, 0x11839..=0x1183A, 0x1193B..=0x1193C, 0x1193E,
	     0x11943, 0x119D4..=0x119D7, 0x119DA..=0x119DB, 0x119E0,
	     0x11A01..=0x11A0A, 0x11A33..=0x11A38, 0x11A3B..=0x11A3E, 0x11A47,
	     0x11A51..=0x11A56, 0x11A59..=0x11A5B, 0x11A8A..=0x11A96, 0x11A98..=0x11A99,
	     0x11B60, 0x11B62..=0x11B64, 0x11B66, 0x11C30..=0x11C36,
	     0x11C38..=0x11C3D, 0x11C3F, 0x11C92..=0x11CA7, 0x11CAA..=0x11CB0,
	     0x11CB2..=0x11CB3, 0x11CB5..=0x11CB6, 0x11D31..=0x11D36, 0x11D3A,
	     0x11D3C..=0x11D3D, 0x11D3F..=0x11D45, 0x11D47, 0x11D90..=0x11D91,
	     0x11D95, 0x11D97, 0x11EF3..=0x11EF4, 0x11F00..=0x11F01,
	     0x11F36..=0x11F3A, 0x11F40, 0x11F42, 0x11F5A,
	     0x13430..=0x13440, 0x13447..=0x13455, 0x1611E..=0x16129, 0x1612D..=0x1612F,
	     0x16AF0..=0x16AF4, 0x16B30..=0x16B36, 0x16F4F, 0x16F8F..=0x16F92,
	     0x16FE4, 0x1BC9D..=0x1BC9E, 0x1BCA0..=0x1BCA3, 0x1CF00..=0x1CF2D,
	     0x1CF30..=0x1CF46, 0x1D167..=0x1D169, 0x1D173..=0x1D182, 0x1D185..=0x1D18B,
	     0x1D1AA..=0x1D1AD, 0x1D242..=0x1D244, 0x1DA00..=0x1DA36, 0x1DA3B..=0x1DA6C,
	     0x1DA75, 0x1DA84, 0x1DA9B..=0x1DA9F, 0x1DAA1..=0x1DAAF,
	     0x1E000..=0x1E006, 0x1E008..=0x1E018, 0x1E01B..=0x1E021, 0x1E023..=0x1E024,
	     0x1E026..=0x1E02A, 0x1E08F, 0x1E130..=0x1E136, 0x1E2AE,
	     0x1E2EC..=0x1E2EF, 0x1E4EC..=0x1E4EF, 0x1E5EE..=0x1E5EF, 0x1E6E3,
	     0x1E6E6, 0x1E6EE..=0x1E6EF, 0x1E6F5, 0x1E8D0..=0x1E8D6,
	     0x1E944..=0x1E94A, 0xE0001, 0xE0020..=0xE007F, 0xE0100..=0xE01EF:
		return true
	}
	return false
}

@(private="file")
init_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]Range, 0, 1024)
	for line in strings.split_lines_iterator(&JOIN_DATA_LINES) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = strings.trim_space(trimmed[:hash])
		}
		// Format: CODE; NAME ; JOINING_TYPE ; JOINING_GROUP
		parts := strings.split(trimmed, ";", context.temp_allocator)
		if len(parts) < 3 { continue }
		cp_str := strings.trim_space(parts[0])
		jt_str := strings.trim_space(parts[2])
		jt: Joining_Type
		ok: bool
		switch jt_str {
		case "U": jt = .U; ok = true
		case "R": jt = .R; ok = true
		case "L": jt = .L; ok = true
		case "D": jt = .D; ok = true
		case "T": jt = .T; ok = true
		case "C": jt = .C; ok = true
		}
		if !ok { continue }
		// Single codepoint per line; ArabicShaping.txt doesn't use
		// ranges.
		s, _ := strconv.parse_u64_of_base(cp_str, 16)
		append(&tmp, Range{start = rune(s), end = rune(s), jt = jt})
	}
	sort_ranges(tmp[:])
	g_ranges = tmp[:]
}

@(private="file")
sort_ranges :: proc(rs: []Range) {
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

// Joining_Form — what shape the glyph takes given its neighbours.
// Maps directly to the OpenType GSUB feature tag that should fire
// for that character: `isol`, `init`, `medi`, `fina`.
Joining_Form :: enum u8 {
	Isolated,        // 'isol' — no join on either side
	Initial,         // 'init' — joins on the left (next char accepts)
	Medial,          // 'medi' — joins on both sides
	Final,           // 'fina' — joins on the right (previous char accepts)
}

// arabic_join_state walks `runes` and assigns each codepoint its
// Joining_Form. The state machine is the one from Unicode TR9
// Appendix B — informally:
//
//   right-joining (R) follows D / R / C → its joining form gains a
//   right-side link (becomes final or medial);
//   left-joining (L) precedes D / L / C → gains a left link
//   (becomes initial or medial);
//   transparent (T) passes through for state purposes;
//   non-joining (U / X) interrupts the chain.
//
// `forms` must be sized to `len(runes)`. Caller-owned slice.
arabic_join_state :: proc(runes: []rune, forms: []Joining_Form) {
	if len(runes) == 0 || len(forms) != len(runes) { return }

	// First pass: every character starts as Isolated. We'll add
	// init/medi/fina bits as we walk.
	for i in 0..<len(runes) { forms[i] = .Isolated }

	// `last_d_or_l_idx` tracks the most recent non-transparent
	// joining character that can attach to the *next* codepoint
	// (i.e., something that has a left-attaching tail).
	prev_join_idx := -1
	for i in 0..<len(runes) {
		jt := joining_type(runes[i])
		if jt == .T {
			continue                              // transparent; carry prev state forward
		}

		// Resolve THIS character's joining state by looking at
		// `prev_join_idx`'s joining type.
		links_right := false                       // this char's right side joins
		if prev_join_idx >= 0 {
			pjt := joining_type(runes[prev_join_idx])
			// Right-side join of THIS char requires the previous
			// non-transparent char to be D, L, or C.
			if pjt == .D || pjt == .L || pjt == .C {
				if jt == .R || jt == .D || jt == .C {
					links_right = true
				}
			}
		}

		// If this char attaches on its right side, AND the previous
		// joining character is currently Initial or Medial-eligible,
		// upgrade them.
		if links_right && prev_join_idx >= 0 {
			// THIS char becomes Final (or Medial if it can also link
			// left — that's resolved in the next iteration).
			forms[i] = .Final
			// Previous char's right side joined to us — bump it from
			// Isolated→Initial or Final→Medial.
			pform := forms[prev_join_idx]
			#partial switch pform {
			case .Isolated: forms[prev_join_idx] = .Initial
			case .Final:    forms[prev_join_idx] = .Medial
			}
		}

		// Only D/L/C/R/U advance the chain. U breaks it.
		if jt == .U || jt == .X {
			prev_join_idx = -1
		} else {
			prev_join_idx = i
		}
	}
}
