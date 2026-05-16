/*
UAX #29 word boundary detection.

Word boundaries are coarser than grapheme clusters and finer than
sentences — they're the unit users expect from double-click word
selection, Ctrl+arrow word-by-word cursor movement, and word-by-
word iteration for spell-check, search highlighting, etc.

The algorithm walks codepoints, classifies each by its
Word_Break property (WordBreakProperty.txt; Extended_Pictographic
from emoji-data.txt for the WB3c rule), and inserts a break
between adjacent classes per the WB1..WB17 rules in UAX #29 §4.

The property table embeds `WordBreakProperty.txt` (Unicode 17.0)
+ emoji-data Extended_Pictographic, parses lazily on first call,
and caches a sorted range table binary-searched per codepoint —
same shape as `bidi/property.odin` and the grapheme tables.

References: UAX #29 §4; WordBreakProperty.txt, emoji-data.txt.
*/
package itemize

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// WB property values per UAX #29.
WB :: enum u8 {
	Other,
	CR,
	LF,
	Newline,
	Extend,
	ZWJ,
	Regional_Indicator,
	Format,
	Katakana,
	Hebrew_Letter,
	ALetter,
	Single_Quote,
	Double_Quote,
	MidNumLet,
	MidLetter,
	MidNum,
	Numeric,
	ExtendNumLet,
	WSegSpace,
	Extended_Pictographic,
}

@(private="file")
WB_Range :: struct { start, end: rune, cls: WB }

@(private="file") g_wb_ranges:    []WB_Range
@(private="file") g_wb_ext_pict:  []WB_Range                   // Extended_Pictographic fallback — consulted only when the primary table misses
@(private="file") g_wb_load_once: sync.Once

@(private="file")
WB_DATA :: #load("../tools/ucd/WordBreakProperty.txt", string)
@(private="file")
WB_EMOJI_DATA :: #load("../tools/ucd/emoji-data.txt", string)

wb_class :: proc(r: rune) -> WB {
	sync.once_do(&g_wb_load_once, init_wb_table)
	// Primary lookup: WordBreakProperty.txt classes.
	lo, hi := 0, len(g_wb_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_wb_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	// Fallback: Extended_Pictographic for codepoints without an
	// explicit Word_Break class. ALetter / Numeric / Katakana / etc.
	// listed in WordBreakProperty.txt take priority.
	lo, hi = 0, len(g_wb_ext_pict)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_wb_ext_pict[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .Other
}

@(private="file")
init_wb_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]WB_Range, 0, 1024)

	// Pass 1: WordBreakProperty.txt — the bulk of the classes.
	data := WB_DATA
	for line in strings.split_lines_iterator(&data) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		semi := strings.index_byte(t, ';')
		if semi < 0 { continue }
		cp_part   := strings.trim_space(t[:semi])
		name_part := strings.trim_space(t[semi + 1:])

		start, end: rune
		if dot := strings.index(cp_part, ".."); dot >= 0 {
			s, _ := strconv.parse_u64_of_base(cp_part[:dot], 16)
			e, _ := strconv.parse_u64_of_base(cp_part[dot + 2:], 16)
			start = rune(s); end = rune(e)
		} else {
			s, _ := strconv.parse_u64_of_base(cp_part, 16)
			start = rune(s); end = start
		}
		cls, ok := wb_from_name(name_part)
		if !ok { continue }
		append(&tmp, WB_Range{start = start, end = end, cls = cls})
	}

	sort_wb_ranges(tmp[:])
	g_wb_ranges = tmp[:]

	// Pass 2: Extended_Pictographic into a SEPARATE fallback
	// table consulted only when the primary table misses. This way
	// codepoints like U+24C2 (CIRCLED LATIN M) that are both
	// ALetter and Extended_Pictographic keep their explicit class.
	ext_tmp := make([dynamic]WB_Range, 0, 256)
	emoji_data := WB_EMOJI_DATA
	for line in strings.split_lines_iterator(&emoji_data) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		semi := strings.index_byte(t, ';')
		if semi < 0 { continue }
		cp_part   := strings.trim_space(t[:semi])
		name_part := strings.trim_space(t[semi + 1:])
		if name_part != "Extended_Pictographic" { continue }

		start, end: rune
		if dot := strings.index(cp_part, ".."); dot >= 0 {
			s, _ := strconv.parse_u64_of_base(cp_part[:dot], 16)
			e, _ := strconv.parse_u64_of_base(cp_part[dot + 2:], 16)
			start = rune(s); end = rune(e)
		} else {
			s, _ := strconv.parse_u64_of_base(cp_part, 16)
			start = rune(s); end = start
		}
		append(&ext_tmp, WB_Range{start = start, end = end, cls = .Extended_Pictographic})
	}
	sort_wb_ranges(ext_tmp[:])
	g_wb_ext_pict = ext_tmp[:]
}

@(private="file")
sort_wb_ranges :: proc(rs: []WB_Range) {
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
wb_from_name :: proc(s: string) -> (WB, bool) {
	switch s {
	case "CR":                 return .CR, true
	case "LF":                 return .LF, true
	case "Newline":            return .Newline, true
	case "Extend":             return .Extend, true
	case "ZWJ":                return .ZWJ, true
	case "Regional_Indicator": return .Regional_Indicator, true
	case "Format":             return .Format, true
	case "Katakana":           return .Katakana, true
	case "Hebrew_Letter":      return .Hebrew_Letter, true
	case "ALetter":            return .ALetter, true
	case "Single_Quote":       return .Single_Quote, true
	case "Double_Quote":       return .Double_Quote, true
	case "MidNumLet":          return .MidNumLet, true
	case "MidLetter":          return .MidLetter, true
	case "MidNum":             return .MidNum, true
	case "Numeric":            return .Numeric, true
	case "ExtendNumLet":       return .ExtendNumLet, true
	case "WSegSpace":          return .WSegSpace, true
	}
	return .Other, false
}

// Word iterator — same shape as the grapheme iterator. Yields
// `(byte_lo, byte_hi)` per word; iteration ends when ok = false.
Word_Iter :: struct {
	text:     string,
	byte_pos: int,
}

word_iter_make :: proc(text: string) -> Word_Iter {
	return Word_Iter{text = text, byte_pos = 0}
}

// word_iter_next returns the next word's byte range. Per UAX #29
// the boundaries form a partition of the input; every codepoint
// belongs to exactly one "word", though many of those words are
// degenerate runs of a single non-word character (whitespace,
// punctuation, etc.).
word_iter_next :: proc(it: ^Word_Iter) -> (lo, hi: int, ok: bool) {
	if it.byte_pos >= len(it.text) { return }

	lo = it.byte_pos
	s := it.text[lo:]
	cur_r, cur_sz := utf8_decode(s)
	pos := lo + cur_sz

	cur_eff := effective_wb(cur_r)
	prev_eff := cur_eff
	// `prev_literal_wb` is the WB class of the IMMEDIATELY preceding
	// codepoint (no WB4 absorption). WB3c (ZWJ × Extended_Pictographic)
	// fires only when the ZWJ is directly adjacent — an intervening
	// Extend means the rule doesn't apply.
	prev_literal_wb := cur_eff
	// Track WB7-family two-back state: ALetter/HL × (MidLetter|
	// MidNumLet|SQ) × ALetter/HL — the boundary between the mid
	// punctuation and the second word-letter must not break, and
	// neither must the one between the first word-letter and the
	// mid-punctuation.
	pre_mid: WB = .Other                                 // class before a buffered Mid* candidate, if any
	saw_mid_after_aletter := false
	saw_mid_after_numeric := false
	// WB7c "Hebrew_Letter Double_Quote × Hebrew_Letter" — remembers
	// whether the codepoint before the most recent Double_Quote was HL.
	pre_dq_was_hl := false
	ri_run := cur_eff == .Regional_Indicator ? 1 : 0
	had_extend_since_base := false                       // see WB3d comment below

	for pos < len(it.text) {
		next_r, next_sz := utf8_decode(it.text[pos:])
		next_cls_raw := wb_class(next_r)

		// WB4: ignore Extend / Format / ZWJ for boundary purposes,
		// EXCEPT after CR / LF / Newline. Those classes always
		// produce a break (WB3a/b), regardless of what follows.
		if next_cls_raw == .Extend || next_cls_raw == .Format || next_cls_raw == .ZWJ {
			// If prev was CR / LF / Newline, fall through to the
			// boundary check (WB3a will break). Otherwise the
			// boundary cluster extends and we skip the test.
			if prev_eff != .CR && prev_eff != .LF && prev_eff != .Newline {
				// Track that an Extend cluster intervened so the
				// literal-pair rule WB3d (WSegSpace × WSegSpace) can
				// fall through to WB999 once we hit the next base.
				had_extend_since_base = true
				prev_literal_wb = next_cls_raw
				pos += next_sz
				continue
			}
		}
		next_eff := next_cls_raw

		// One-codepoint WB4-aware lookahead for WB6 / WB11: the
		// "(ALetter|HL) × (Mid*|SQ) × (ALetter|HL)" rule needs to
		// know what comes AFTER the candidate Mid. Pre-skip
		// Extend / Format / ZWJ to find the effective next-next.
		next_next_eff: WB = .Other
		{
			look := pos + next_sz
			for look < len(it.text) {
				lr, ls := utf8_decode(it.text[look:])
				lc := wb_class(lr)
				if lc == .Extend || lc == .Format || lc == .ZWJ {
					look += ls
					continue
				}
				next_next_eff = lc
				break
			}
		}
		cur_is_ext_pict := is_ext_pict_rune(next_r)
		boundary := word_boundary(prev_eff, next_eff, next_next_eff, pre_mid, saw_mid_after_aletter, saw_mid_after_numeric, ri_run, had_extend_since_base, prev_literal_wb == .ZWJ, cur_is_ext_pict, pre_dq_was_hl)
		if boundary {
			hi = pos
			it.byte_pos = pos
			ok = true
			return
		}

		// Update state for next iteration.
		// WB7-family buffering: if cur was ALetter/HL and we now see
		// a MidLetter/MidNumLet/SQ, remember that. If WE leave that
		// state without seeing another ALetter/HL, we'll break — but
		// the boundary check above already used the lookahead.
		if (next_eff == .MidLetter || next_eff == .MidNumLet || next_eff == .Single_Quote) &&
		   (prev_eff == .ALetter || prev_eff == .Hebrew_Letter) {
			pre_mid = prev_eff
			saw_mid_after_aletter = true
		} else if (next_eff == .MidNum || next_eff == .MidNumLet || next_eff == .Single_Quote) &&
		          prev_eff == .Numeric {
			pre_mid = prev_eff
			saw_mid_after_numeric = true
		} else {
			pre_mid = .Other
			saw_mid_after_aletter = false
			saw_mid_after_numeric = false
		}
		// RI parity for WB15/16.
		if next_eff == .Regional_Indicator {
			ri_run = ri_run % 2 == 0 ? ri_run + 1 : 0
		} else {
			ri_run = 0
		}

		// WB7c tracking: remember whether the codepoint just before a
		// Double_Quote was Hebrew_Letter. Used at the next iteration
		// to decide HL DQ × HL (no break).
		if next_eff == .Double_Quote {
			pre_dq_was_hl = is_aletter(prev_eff) && prev_eff == .Hebrew_Letter
		} else {
			pre_dq_was_hl = false
		}

		// Clear the Extend-since-base flag now that a base lands.
		had_extend_since_base = false

		prev_eff = next_eff
		prev_literal_wb = next_cls_raw
		pos += next_sz
	}

	// End of text — emit the last word.
	hi = pos
	it.byte_pos = pos
	ok = true
	return
}

// word_boundary returns true when there's a break between
// `prev` and `cur`. Implementation walks the WB1..WB17 rules in
// the order the spec lists them; the first matching rule decides
// the boundary.
@(private)
word_boundary :: proc(prev, cur, next: WB, pre_mid: WB, saw_mid_after_aletter, saw_mid_after_numeric: bool, ri_run: int, had_extend_since_base, prev_literal_was_zwj, cur_is_ext_pict, pre_dq_was_hl: bool) -> bool {
	// WB3: CR × LF.
	if prev == .CR && cur == .LF { return false }
	// WB3a / WB3b: always break around Control / CR / LF / Newline.
	if prev == .CR || prev == .LF || prev == .Newline { return true }
	if cur == .CR  || cur == .LF  || cur == .Newline  { return true }
	// WB3c: ZWJ × Extended_Pictographic. Uses the LITERAL prev
	// codepoint class — an intervening Extend means the rule doesn't
	// apply. cur is Ext_Pict either by primary class or via the
	// fallback table (U+24C2 etc. are ALetter+Ext_Pict).
	if prev_literal_was_zwj && (cur == .Extended_Pictographic || cur_is_ext_pict) { return false }
	// WB3d: WSegSpace × WSegSpace. Pair-table-literal — if an
	// Extend / Format / ZWJ cluster intervened, the run is no
	// longer pure whitespace and the rule doesn't fire.
	if prev == .WSegSpace && cur == .WSegSpace && !had_extend_since_base { return false }

	// WB5: (ALetter|HL) × (ALetter|HL).
	if is_aletter(prev) && is_aletter(cur) { return false }
	// WB6/7: (ALetter|HL) × (MidLetter|MidNumLet|SQ) (ALetter|HL).
	// Uses the caller-supplied `next` lookahead to require that the
	// Mid* be followed by another letter; otherwise WB999 fires
	// and we break at the position between the letter and the Mid*.
	if is_aletter(prev) && is_mid_letter_or_quote(cur) && is_aletter(next) {
		return false
	}
	if is_mid_letter_or_quote(prev) && is_aletter(cur) && saw_mid_after_aletter {
		return false
	}
	// WB7a: HL × Single_Quote (Hebrew letter + apostrophe stays).
	if prev == .Hebrew_Letter && cur == .Single_Quote { return false }
	// WB7b: HL × DQ HL — only when the DQ is followed by another HL.
	if prev == .Hebrew_Letter && cur == .Double_Quote && next == .Hebrew_Letter { return false }
	// WB7c: HL DQ × HL — the codepoint before the DQ must have been HL.
	if prev == .Double_Quote && cur == .Hebrew_Letter && pre_dq_was_hl { return false }

	// WB8: Numeric × Numeric.
	if prev == .Numeric && cur == .Numeric { return false }
	// WB9: (ALetter|HL) × Numeric.
	if is_aletter(prev) && cur == .Numeric { return false }
	// WB10: Numeric × (ALetter|HL).
	if prev == .Numeric && is_aletter(cur) { return false }
	// WB11/12: Numeric × (MidNum|MidNumLet|SQ) × Numeric (with
	// one-codepoint lookahead).
	if prev == .Numeric && is_mid_num(cur) && next == .Numeric { return false }
	if is_mid_num(prev) && cur == .Numeric && saw_mid_after_numeric { return false }

	// WB13: Katakana × Katakana.
	if prev == .Katakana && cur == .Katakana { return false }
	// WB13a: (ALetter|HL|Numeric|Katakana|ExtendNumLet) × ExtendNumLet.
	if (is_aletter(prev) || prev == .Numeric || prev == .Katakana || prev == .ExtendNumLet) &&
	   cur == .ExtendNumLet {
		return false
	}
	// WB13b: ExtendNumLet × (ALetter|HL|Numeric|Katakana).
	if prev == .ExtendNumLet && (is_aletter(cur) || cur == .Numeric || cur == .Katakana) {
		return false
	}
	// WB15/16: paired Regional_Indicator (RI RI ×).
	if prev == .Regional_Indicator && cur == .Regional_Indicator && ri_run % 2 == 1 {
		return false
	}

	// WB999: default ÷ — break.
	return true
}

@(private)
is_aletter :: proc(c: WB) -> bool {
	return c == .ALetter || c == .Hebrew_Letter
}

@(private)
is_mid_letter_or_quote :: proc(c: WB) -> bool {
	return c == .MidLetter || c == .MidNumLet || c == .Single_Quote
}

@(private)
is_mid_num :: proc(c: WB) -> bool {
	return c == .MidNum || c == .MidNumLet || c == .Single_Quote
}

// effective_wb resolves the WB class of `r`, ignoring the WB4
// extending-class collapse (callers handle that separately).
@(private)
effective_wb :: proc(r: rune) -> WB {
	return wb_class(r)
}

// is_ext_pict_rune reports whether `r` is in Extended_Pictographic,
// regardless of whether some other Word_Break class shadows it (so
// WB3c — ZWJ × Extended_Pictographic — fires for code points like
// U+24C2 CIRCLED M that are both ALetter and Extended_Pictographic).
@(private)
is_ext_pict_rune :: proc(r: rune) -> bool {
	sync.once_do(&g_wb_load_once, init_wb_table)
	lo, hi := 0, len(g_wb_ext_pict)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_wb_ext_pict[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return true
		}
	}
	return false
}
