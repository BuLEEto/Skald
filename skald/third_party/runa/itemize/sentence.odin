/*
UAX #29 sentence boundary detection.

Sentence boundaries are what callers want for double-paragraph
selection, screen-reader sentence-at-a-time navigation, and
sentence-level text-to-speech. Default sentence behaviour is
NO-BREAK (SB998); explicit break rules (SB1-SB4, SB11) fire after
paragraph separators or sentence-terminator chains (`. `, `? `,
`! `, etc.), and the SB6/SB7/SB8/SB8a/SB9/SB10 exceptions keep
abbreviations, decimals, and trailing punctuation in the same
sentence.

The property table embeds `SentenceBreakProperty.txt` (Unicode
17.0), parses lazily on first call, and caches a sorted range
table binary-searched per codepoint — same shape as the grapheme
and word break tables.

References: UAX #29 §5; SentenceBreakProperty.txt.
*/
package itemize

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// SB property values per UAX #29.
SB :: enum u8 {
	Other,
	CR,
	LF,
	Extend,
	Sep,
	Format,
	Sp,
	Lower,
	Upper,
	OLetter,
	Numeric,
	ATerm,
	SContinue,
	STerm,
	Close,
}

@(private="file")
SB_Range :: struct { start, end: rune, cls: SB }

@(private="file") g_sb_ranges:    []SB_Range
@(private="file") g_sb_load_once: sync.Once

@(private="file")
SB_DATA :: #load("../tools/ucd/SentenceBreakProperty.txt", string)

sb_class :: proc(r: rune) -> SB {
	sync.once_do(&g_sb_load_once, init_sb_table)
	lo, hi := 0, len(g_sb_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_sb_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .Other
}

@(private="file")
init_sb_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]SB_Range, 0, 1024)

	data := SB_DATA
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
		cls, ok := sb_from_name(name_part)
		if !ok { continue }
		append(&tmp, SB_Range{start = start, end = end, cls = cls})
	}

	sort_sb_ranges(tmp[:])
	g_sb_ranges = tmp[:]
}

@(private="file")
sort_sb_ranges :: proc(rs: []SB_Range) {
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
sb_from_name :: proc(s: string) -> (SB, bool) {
	switch s {
	case "CR":        return .CR, true
	case "LF":        return .LF, true
	case "Extend":    return .Extend, true
	case "Sep":       return .Sep, true
	case "Format":    return .Format, true
	case "Sp":        return .Sp, true
	case "Lower":     return .Lower, true
	case "Upper":     return .Upper, true
	case "OLetter":   return .OLetter, true
	case "Numeric":   return .Numeric, true
	case "ATerm":     return .ATerm, true
	case "SContinue": return .SContinue, true
	case "STerm":     return .STerm, true
	case "Close":     return .Close, true
	}
	return .Other, false
}

// Sentence iterator — yields `(byte_lo, byte_hi)` per sentence.
Sentence_Iter :: struct {
	text:     string,
	byte_pos: int,
}

sentence_iter_make :: proc(text: string) -> Sentence_Iter {
	return Sentence_Iter{text = text, byte_pos = 0}
}

// sentence_iter_next returns the next sentence's byte range.
// Default rule is NO-BREAK (SB998); explicit breaks come from
// SB4 (after ParaSep) and SB11 (after SATerm Close* Sp* ParaSep?).
sentence_iter_next :: proc(it: ^Sentence_Iter) -> (lo, hi: int, ok: bool) {
	if it.byte_pos >= len(it.text) { return }

	lo = it.byte_pos
	pos := lo

	// State.
	prev_eff:           SB   = .Other        // effective class of the previous (non-absorbed) codepoint
	prev_pre_eff:       SB   = .Other        // effective class two codepoints back — used for SB7 lookback
	first_codepoint    := true
	in_tail            := false              // we're inside a SATerm Close* Sp* (ParaSep)? sequence
	tail_is_aterm      := false
	close_seen         := false              // Close has been seen in the current tail
	sp_seen            := false              // Sp has been seen in the current tail
	parasep_seen       := false              // ParaSep has been seen in the current tail (next codepoint will SB4-break)
	pre_aterm_class:    SB = .Other          // class of the codepoint IMMEDIATELY before the most recent ATerm — used by SB7

	for pos < len(it.text) {
		cur_r, cur_sz := utf8_decode(it.text[pos:])
		cls := sb_class(cur_r)

		// SB5: Extend / Format absorb into the previous cluster,
		// EXCEPT immediately after sot / Sep / CR / LF. After a
		// ParaSep we want the Format / Extend to be its own codepoint
		// so SB4 fires at the boundary BEFORE it.
		if (cls == .Extend || cls == .Format) && !first_codepoint &&
		   prev_eff != .Sep && prev_eff != .CR && prev_eff != .LF {
			pos += cur_sz
			continue
		}

		if first_codepoint {
			// SB1: sot ÷ Any — the boundary at lo is implicit (we
			// just yield the upcoming codepoint as the sentence start).
			prev_eff = cls
			if cls == .ATerm || cls == .STerm {
				in_tail = true
				tail_is_aterm = cls == .ATerm
				sp_seen = false
				parasep_seen = false
				pre_aterm_class = .Other
			}
			first_codepoint = false
			pos += cur_sz
			continue
		}

		// Decide whether the boundary between prev and cur is a break.
		boundary := false

		switch {
		// SB3: CR × LF — never break inside CRLF.
		case prev_eff == .CR && cls == .LF:
			boundary = false
		// SB4: ParaSep ÷ — break after Sep / CR / LF (with SB3 already excluded).
		case prev_eff == .Sep || prev_eff == .CR || prev_eff == .LF:
			boundary = true
		// SB6/7/8/8a/9/10/11 — the tail rules.
		case in_tail:
			boundary = sb_tail_boundary(cls, tail_is_aterm, close_seen, sp_seen, parasep_seen, pre_aterm_class, it.text, pos + cur_sz)
		// SB998: default no break.
		case:
			boundary = false
		}

		if boundary {
			hi = pos
			it.byte_pos = pos
			ok = true
			return
		}

		// Update the rolling 2-back state.
		prev_pre_eff = prev_eff
		prev_eff = cls

		// Tail-state transitions on the codepoint we just consumed.
		if in_tail {
			switch {
			case cls == .Close && !sp_seen && !parasep_seen:
				// SB9: still in Close* phase.
				close_seen = true
			case cls == .Sp && !parasep_seen:
				sp_seen = true
			case cls == .Sep || cls == .CR || cls == .LF:
				parasep_seen = true
				if cls == .CR {
					// CR may be followed by LF (still inside the
					// same ParaSep cluster per SB3). We stay in the
					// tail until the next non-LF.
				}
			case cls == .ATerm || cls == .STerm:
				// SB8a restarted the tail.
				tail_is_aterm = cls == .ATerm
				close_seen = false
				sp_seen = false
				parasep_seen = false
				pre_aterm_class = prev_pre_eff
			case cls == .SContinue:
				// SB8a continues the tail without resetting.
			case:
				// Anything else (Numeric for SB6, Upper for SB7,
				// Lower for SB8, or SB8-lookahead Lower) exits the
				// tail because the no-break has already been
				// committed for this position.
				in_tail = false
			}
		}

		// If the current codepoint starts a new tail.
		if !in_tail && (cls == .ATerm || cls == .STerm) {
			in_tail = true
			tail_is_aterm = cls == .ATerm
			close_seen = false
			sp_seen = false
			parasep_seen = false
			pre_aterm_class = prev_pre_eff
		}

		pos += cur_sz
	}

	hi = pos
	it.byte_pos = pos
	ok = true
	return
}

// sb_tail_boundary returns true iff there's a break between the
// preceding SATerm Close* Sp* (ParaSep?) tail and `cls`. It
// encodes SB6, SB7, SB8, SB8a, SB9, SB10, SB11 in priority order.
//
// `text_ahead_off` is the byte position immediately after `cls` —
// used for the SB8 lookahead scan (which walks ¬letter codepoints
// until it finds Lower or one of the terminating classes).
@(private)
sb_tail_boundary :: proc(cls: SB, tail_is_aterm, close_seen, sp_seen, parasep_seen: bool, pre_aterm_class: SB, text: string, text_ahead_off: int) -> bool {
	// SB6: ATerm × Numeric — literal pair, no Close / Sp / ParaSep allowed in between.
	if !close_seen && !sp_seen && !parasep_seen && cls == .Numeric && tail_is_aterm { return false }
	// SB7: (Upper|Lower) ATerm × Upper — likewise a literal triple, the
	// Upper must immediately follow the ATerm (after Extend / Format absorption).
	if !close_seen && !sp_seen && !parasep_seen && cls == .Upper && tail_is_aterm &&
	   (pre_aterm_class == .Upper || pre_aterm_class == .Lower) { return false }
	// SB8a: SATerm Close* Sp* × (SContinue | SATerm) — comma/colon
	// after a terminator keeps the sentence open.
	if !parasep_seen && (cls == .SContinue || cls == .ATerm || cls == .STerm) { return false }
	// SB9: SATerm Close* × Close — only valid before any Sp.
	if !sp_seen && !parasep_seen && cls == .Close { return false }
	// SB10: SATerm Close* Sp* × Sp — Sp absorbs into the tail.
	if !parasep_seen && cls == .Sp { return false }
	// SB9/SB10: ParaSep folds into the tail.
	if !parasep_seen && (cls == .Sep || cls == .CR || cls == .LF) { return false }
	// SB8: ATerm Close* Sp* × ¬(OLetter|Upper|Lower|ParaSep|SATerm)* Lower.
	// Only for ATerm (not STerm) per the spec.
	if tail_is_aterm && !parasep_seen {
		if cls == .Lower { return false }
		// Lookahead through neutral codepoints (anything that is NOT
		// one of OLetter/Upper/Lower/Sep/CR/LF/ATerm/STerm) until we
		// hit a Lower (no break) or one of the terminating classes
		// (break). Extend / Format are absorbed (skipped).
		if cls != .OLetter && cls != .Upper && cls != .Sep && cls != .CR && cls != .LF {
			pos := text_ahead_off
			for pos < len(text) {
				lr, ls := utf8_decode(text[pos:])
				lc := sb_class(lr)
				if lc == .Extend || lc == .Format { pos += ls; continue }
				if lc == .Lower { return false }
				if lc == .OLetter || lc == .Upper || lc == .Sep || lc == .CR || lc == .LF ||
				   lc == .ATerm || lc == .STerm { break }
				pos += ls
			}
		}
	}
	// SB11: SATerm Close* Sp* ParaSep? ÷ — default break out of the tail.
	return true
}
