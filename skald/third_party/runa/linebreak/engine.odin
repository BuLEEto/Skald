/*
UAX #14 line-break opportunity engine.

Implements LB1 (class resolution) plus LB4..LB31 in pair form, with
SP-skip state so the "OP SP* ×", "CL SP* × NS" and similar rules
work without sprinkling lookaheads into every caller.

Rules left out at v0.1:
  - LB1's AI / SA / SG / CJ aren't tailored — they get the simple
    AL / NS / NS fallbacks. LineBreakTest expects the same default.
  - LB15a / LB15b / LB15c / LB15d / LB15e / LB15f (quotation-context):
    the LB19 simple form is used instead — × QU / QU ×.
  - LB21a (HL HY/BA × …): needs Hebrew-letter state we don't track.
  - LB30a / LB30b's regional-indicator parity counting: simplified.

References: UAX #14 §6, https://www.unicode.org/reports/tr14/
*/
package linebreak

// Opportunity classifies a break position between two codepoints.
Opportunity :: enum u8 {
	None,       // × — must NOT break here
	Allow,      // ÷ — may break here
	Mandatory,  // ÷! — MUST break here (LB4/LB5)
}

// next_break walks `text` forward from `start` and returns the
// codepoint index at the next allowed break opportunity, plus a
// flag for whether the rules made the break *mandatory* (e.g. CR
// LF in the input). When no internal break opportunity exists the
// procedure returns `(len(text), true)` per LB3 (always break at
// eot).
next_break :: proc(text: []rune, start: int) -> (idx: int, mandatory: bool) {
	if start >= len(text) { return len(text), true }

	// LB1 resolution. AI / SG / XX collapse to AL — they're "weak"
	// classes that fall back to alphabetic. SA needs more care: per
	// LB1, SA codepoints that are combining marks resolve to CM (so
	// they attach via LB9); other SA codepoints resolve to AL. CJ
	// resolves to NS (strict).
	resolve :: proc(c: Line_Break_Class, r: rune) -> Line_Break_Class {
		#partial switch c {
		case .AI, .SG, .XX:
			return .AL
		case .SA:
			return .CM if sa_resolves_to_cm(r) else .AL
		case .CJ:
			return .NS
		}
		return c
	}

	prev := resolve(line_break_class(text[start]), text[start])
	// LB8a: a ZWJ at any position (including sot) suppresses break
	// before the next char. We track that here so the LB10
	// fall-back-to-AL below doesn't erase the ZWJ × X rule.
	prev_was_zwj := prev == .ZWJ
	// LB10: a CM / ZWJ at start-of-text has no base to attach to.
	// Treat it as AL for rule-matching purposes.
	if prev == .CM || prev == .ZWJ { prev = .AL }
	// `non_sp` tracks the most recent non-SP, post-CM class — the
	// "effective predecessor" for SP-skip rules (LB14, LB16, LB17,
	// LB19, LB25 chains).
	non_sp := prev
	// LB30a regional-indicator parity counter — pairs of RI bind.
	ri_run := prev == .RI ? 1 : 0

	// LB15a tracking: non_sp_was_pi_qu_after_opener is true when
	// non_sp came from an opener-preceded Pi-QU. At sot the "before"
	// position is one of LB15a's openers, so a leading Pi-QU
	// qualifies.
	non_sp_is_pi_after_opener := prev == .QU && is_pi_punctuation(text[start])
	// "What was non_sp before the current non_sp" — needed when a
	// Pi-QU lands and we check what preceded it.
	prev_non_sp_before_cur_non_sp: Line_Break_Class = .BK  // pretend sot
	prev_rune := text[start]
	// LB25 numeric-chain state. Once a NU starts the chain, it stays
	// open through NU / SY / IS / CL / CP and lets `(CL|CP) × (PO|PR)`
	// fire. Anything outside that set breaks the chain.
	in_num_chain := prev == .NU
	// LB20a state: HH or HY immediately preceded by sot or one of
	// (BK | CR | LF | NL | OP | QU | SP | ZW). When set and the next
	// char is AL or HL, no break is allowed. At `start` the previous
	// position is `sot`, so a leading HH/HY qualifies.
	prev_is_hh_hy_after_breaker := prev == .HH || prev == .HY
	// LB28a state: prev is VI and the char before prev was an Aksara
	// base (AK / dotted-circle / AS) — primes the "(AK|◌|AS) VI ×
	// (AK|◌)" no-break.
	prev_is_vi_after_ak := false
	prev_rune_for_ak := text[start]
	prev_was_ak := is_ak_base(prev, prev_rune_for_ak)

	for i := start + 1; i < len(text); i += 1 {
		cur_raw := line_break_class(text[i])
		cur := resolve(cur_raw, text[i])

		// LB9 / LB10: CM and ZWJ attach to a base. If `prev` is one of
		// the break-causing classes (BK, CR, LF, NL, SP, ZW), the CM /
		// ZWJ has nothing to attach to — LB10 says treat it as AL and
		// apply rules normally. Otherwise (LB9) the CM / ZWJ inherits
		// `prev`'s class for rule-matching, which we approximate by
		// not advancing state.
		if cur == .CM || cur == .ZWJ {
			lb10_applies := prev == .BK || prev == .CR || prev == .LF ||
			                prev == .NL || prev == .SP || prev == .ZW
			if !lb10_applies {
				// LB8a state: a ZWJ propagates the no-break to the
				// next non-skip char; a CM (even one absorbed via
				// LB9) consumes any pending ZWJ × — once a CM has
				// been processed the break-after-cluster rules
				// resume.
				if cur == .ZWJ { prev_was_zwj = true } else { prev_was_zwj = false }
				continue
			}
			cur = .AL
		}

		op := classify(prev, non_sp, cur, ri_run, text[i], prev_rune, in_num_chain, prev_is_vi_after_ak)

		// LB8a: ZWJ × (no break after ZWJ). LB10 absorbs the ZWJ into
		// AL for rule classification, so we track the original ZWJ
		// state separately and override the result here.
		if prev_was_zwj { op = .None }

		// LB8 wins outright: a break after ZW (or after any SPs that
		// follow ZW) is mandatory by the rule's number — UAX #14
		// applies LB1–LB31 in order. The LB15 / LB20a overrides below
		// only apply when LB8 didn't trigger.
		lb8_break := prev == .ZW || (prev == .SP && non_sp == .ZW)

		// LB20a override: (sot | BK | CR | LF | NL | OP | QU | SP | ZW)
		// (HH | HY) × (AL | HL). Stops a hyphen + word from breaking
		// when used in spell-out names. (LB20a also covers the literal
		// codepoints U+002D, U+00AD, U+058A; those resolve to HY / BB
		// / similar via property lookup and reach this rule through
		// the HH/HY arm.)
		if !lb8_break && op == .Allow && prev_is_hh_hy_after_breaker && (cur == .AL || cur == .HL) {
			op = .None
		}

		// LB15a override: × (anything) when the most-recent non-SP is
		// a Pi-QU and that Pi-QU was preceded by sot or an LB15a
		// "opener" class.
		if !lb8_break && op == .Allow && non_sp_is_pi_after_opener {
			op = .None
		}

		// LB15b override: × Pf-QU when Pf-QU is followed by SP / ZW /
		// CL / CP / EX / IS / SY / BK / CR / LF / NL or eot. The
		// lookahead skips SPs that follow Pf-QU.
		if !lb8_break && op == .Allow && cur == .QU && is_pf_punctuation(text[i]) {
			next_cls := next_nonsp_class(text, i + 1)
			if lb15b_closer(next_cls) {
				op = .None
			}
		}

		// LB15c override: SP ÷ IS NU — allow a break between SP and
		// an IS that's immediately followed by a digit, so the "."
		// in "amount .5" starts a fresh line.
		if op == .None && prev == .SP && cur == .IS && i + 1 < len(text) {
			next_cls := line_break_class(text[i + 1])
			if next_cls == .NU { op = .Allow }
		}

		// LB25: (PR | PO) × (OP | HY) when the following codepoint
		// is a digit — covers the start of "$-5", "€(123)", etc.
		// Single-glyph lookahead keeps the rule from binding
		// non-numeric (PR | PO) (OP | HY) pairs.
		if op == .Allow && (prev == .PR || prev == .PO) && (cur == .OP || cur == .HY) && i + 1 < len(text) {
			next_cls := line_break_class(text[i + 1])
			if next_cls == .NU { op = .None }
		}

		switch op {
		case .Mandatory: return i, true
		case .Allow:     return i, false
		case .None:      // fall through
		}

		// State updates for the next iteration.
		prev_rune = text[i]
		// LB25 numeric chain: open on NU, extend through NU/SY/IS/CL/CP,
		// close on anything else.
		if cur == .NU {
			in_num_chain = true
		} else if in_num_chain && (cur == .SY || cur == .IS || cur == .CL || cur == .CP) {
			// still in chain
		} else {
			in_num_chain = false
		}
		if cur == .RI {
			if prev == .RI && ri_run > 0 { ri_run = 0 } else { ri_run += 1 }
		} else {
			ri_run = 0
		}
		if cur != .SP {
			// LB15a tracking: did this new non_sp become a Pi-QU that
			// was preceded by an LB15a opener?
			//   Openers: sot (handled by initialisation), BK, CR, LF,
			//            NL, OP, QU, GL, SP, ZW.
			if cur == .QU && is_pi_punctuation(text[i]) && lb15a_opener(non_sp) {
				non_sp_is_pi_after_opener = true
			} else {
				non_sp_is_pi_after_opener = false
			}
			prev_non_sp_before_cur_non_sp = non_sp
			non_sp = cur
		}
		// LB20a tracking: HH or HY positioned after a break-causing
		// class (or sot) qualifies for the no-break-before-AL/HL
		// override.
		if cur == .HH || cur == .HY {
			prev_is_hh_hy_after_breaker = lb20a_breaker(prev)
		} else {
			prev_is_hh_hy_after_breaker = false
		}
		// LB8a state — set when we just processed (or absorbed) a
		// ZWJ. Cleared once any non-CM/ZWJ char comes through and
		// claims the no-break.
		prev_was_zwj = false
		// LB28a state: prev_is_vi_after_ak primes the rule for the
		// NEXT iteration. Fires when cur is VI and the position
		// before it (prev) was an Aksara base.
		prev_is_vi_after_ak = (cur == .VI) && prev_was_ak
		prev_was_ak = is_ak_base(cur, text[i])
		prev = cur
	}
	return len(text), true
}

@(private)
lb15a_opener :: proc(c: Line_Break_Class) -> bool {
	#partial switch c {
	case .BK, .CR, .LF, .NL, .OP, .QU, .GL, .SP, .ZW: return true
	}
	return false
}

// lb20a_breaker classifies whether `c` is the kind of "break-causing"
// context that primes LB20a's HH/HY-stick rule. The sot position is
// handled by initialisation; this proc covers BK/CR/LF/NL/OP/QU/SP/ZW.
@(private)
lb20a_breaker :: proc(c: Line_Break_Class) -> bool {
	#partial switch c {
	case .BK, .CR, .LF, .NL, .OP, .QU, .SP, .ZW: return true
	}
	return false
}

// is_reserved_pictographic returns true for codepoints that are both
// Extended_Pictographic and General_Category=Cn (reserved/unassigned).
// LB30b's second arm — [Ext_Pictographic & Cn] × EM — needs this so
// future-emoji codepoints stay bound to a trailing skin-tone modifier
// even before they're formally assigned. Ranges are Unicode 17.0;
// refresh when bumping the targeted Unicode version.
@(private)
is_reserved_pictographic :: proc(r: rune) -> bool {
	switch {
	case r >= 0x1F80C && r <= 0x1F80F: return true
	case r >= 0x1F848 && r <= 0x1F84F: return true
	case r >= 0x1F85A && r <= 0x1F85F: return true
	case r >= 0x1F888 && r <= 0x1F88F: return true
	case r >= 0x1F8AE && r <= 0x1F8AF: return true
	case r >= 0x1F8BC && r <= 0x1F8BF: return true
	case r >= 0x1F8C2 && r <= 0x1F8CF: return true
	case r >= 0x1F8D9 && r <= 0x1F8FF: return true
	case r >= 0x1FC00 && r <= 0x1FFFD: return true
	}
	return false
}

@(private)
lb15b_closer :: proc(c: Line_Break_Class) -> bool {
	#partial switch c {
	case .BK, .CR, .LF, .NL, .SP, .ZW, .CL, .CP, .EX, .IS, .SY: return true
	}
	return false
}

// next_nonsp_class scans `text` from `start` forward, skipping SP
// codepoints, and returns the resolved Line_Break_Class of the next
// non-SP codepoint, or `.BK` as a sentinel for end-of-text (which
// behaves like an LB15b closer per the rule).
@(private)
next_nonsp_class :: proc(text: []rune, start: int) -> Line_Break_Class {
	for i := start; i < len(text); i += 1 {
		c := line_break_class(text[i])
		if c != .SP { return c }
	}
	return .BK
}

// is_ak_base reports whether the (class, rune) pair acts as an
// Aksara base for LB28a. U+25CC DOTTED CIRCLE is class AL but the
// LB28a rules treat it as a base equivalently to AK / AS.
@(private)
is_ak_base :: proc(c: Line_Break_Class, r: rune) -> bool {
	return c == .AK || c == .AS || r == 0x25CC
}

@(private)
classify :: proc(prev, non_sp_prev, cur: Line_Break_Class, ri_run: int, cur_rune, prev_rune: rune, in_num_chain: bool, prev_is_vi_after_ak := false) -> Opportunity {
	// ---- LB4 / LB5: hard breaks --------------------------------------
	if prev == .BK { return .Mandatory }
	if prev == .CR && cur != .LF { return .Mandatory }
	if prev == .LF || prev == .NL { return .Mandatory }

	// ---- LB6: never break before mandatory-break characters ----------
	if cur == .BK || cur == .CR || cur == .LF || cur == .NL { return .None }

	// ---- LB7: never break before SP / ZW -----------------------------
	if cur == .SP || cur == .ZW { return .None }

	// ---- LB8: break after ZW (and any SPs that follow ZW) -----------
	// "ZW SP* ÷" — the engine's `non_sp` tracks the most recent
	// non-space class, so a SP whose last-non-SP was ZW still
	// allows the break.
	// (LB8a: × ZWJ — handled by the CM/ZWJ shortcut in the walker.)
	if prev == .ZW { return .Allow }
	if prev == .SP && non_sp_prev == .ZW { return .Allow }

	// ---- LB11: WJ × and × WJ ----------------------------------------
	if cur == .WJ || prev == .WJ { return .None }

	// ---- LB12 / LB12a: GL --------------------------------------------
	if prev == .GL { return .None }
	if cur == .GL {
		// LB12a: × GL except when prev is SP / BA / HY / HH. (CB is
		// *not* an exception — LB12a fires first, before LB20 can
		// break.) HH was added in Unicode 16: a Hebrew hyphen acts
		// like an ordinary hyphen for the purpose of allowing a
		// break before a following non-breaking space.
		#partial switch prev {
		case .SP, .BA, .HY, .HH: // natural break — let later rules decide
		case:                    return .None
		}
	}

	// ---- LB13: × CL / CP / EX / IS / SY ------------------------------
	if cur == .CL || cur == .CP || cur == .EX || cur == .IS || cur == .SY {
		return .None
	}

	// ---- LB14: OP SP* × ---------------------------------------------
	if non_sp_prev == .OP { return .None }

	// ---- LB15a / 15b / 15c / 15d / 15e / 15f: QU context-quotation ---
	// v0.1 falls back to LB19's simple × QU / QU ×.

	// ---- LB16: CL/CP SP* × NS ---------------------------------------
	if cur == .NS && (non_sp_prev == .CL || non_sp_prev == .CP) {
		return .None
	}

	// ---- LB17: B2 SP* × B2 ------------------------------------------
	if cur == .B2 && non_sp_prev == .B2 { return .None }

	// ---- LB18: SP ÷ --------------------------------------------------
	if prev == .SP { return .Allow }

	// ---- LB19: × QU and QU × -----------------------------------------
	if cur == .QU || prev == .QU { return .None }

	// ---- LB20: ÷ CB and CB ÷ -----------------------------------------
	if cur == .CB || prev == .CB { return .Allow }

	// ---- LB21: × BA / HY / HH / NS; BB × ------------------------------
	if cur == .BA || cur == .HY || cur == .HH || cur == .NS { return .None }
	if prev == .BB { return .None }
	// (`× BB` and `× HH` are NOT rules — break opportunities are
	// allowed AFTER HH except in specific contexts.)

	// ---- LB22: × IN --------------------------------------------------
	if cur == .IN { return .None }

	// ---- LB23: (AL|HL) × NU; NU × (AL|HL) ----------------------------
	if (prev == .AL || prev == .HL) && cur == .NU { return .None }
	if prev == .NU && (cur == .AL || cur == .HL) { return .None }

	// ---- LB23a: PR × (ID|EB|EM); (ID|EB|EM) × PO ----------------------
	if prev == .PR && (cur == .ID || cur == .EB || cur == .EM) { return .None }
	if (prev == .ID || prev == .EB || prev == .EM) && cur == .PO { return .None }

	// ---- LB24: (PR|PO) × (AL|HL); (AL|HL) × (PR|PO) -------------------
	if (prev == .PR || prev == .PO) && (cur == .AL || cur == .HL) { return .None }
	if (prev == .AL || prev == .HL) && (cur == .PR || cur == .PO) { return .None }

	// ---- LB25: numeric expressions (per-pair simplification of the
	// LB25 regex "PR? (OP|HY)? NU (NU|SY|IS)* (CL|CP)? (PR|PO)?") ----
	if prev == .NU && (cur == .NU || cur == .SY || cur == .IS) { return .None }
	if (prev == .PR || prev == .PO) && cur == .NU { return .None }
	if prev == .NU && (cur == .CL || cur == .CP) { return .None }
	// (CL|CP) × (PO|PR) — only inside an open numeric chain.
	if in_num_chain && (prev == .CL || prev == .CP) && (cur == .PO || cur == .PR) {
		return .None
	}
	if prev == .NU && cur == .NU { return .None }
	// LB25: IS × NU is unconditional (the "decimal separator"
	// interpretation — "1,000" / ",5"); SY × NU only holds inside
	// an already-open numeric chain (the "5/3" case stays together
	// but a sot "/3" still gets a break).
	if prev == .IS && cur == .NU { return .None }
	if in_num_chain && prev == .SY && cur == .NU { return .None }
	// LB21b: SY × HL — solidus followed by a Hebrew letter stays
	// together (used in Hebrew abbreviations like "ר' אבק").
	if prev == .SY && cur == .HL { return .None }
	// LB25: HY × NU — hyphen feeding a number (e.g. "-5"). OP × NU
	// is already covered by LB14 (OP SP* ×).
	if prev == .HY && cur == .NU { return .None }
	// LB25: NU × PO and NU × PR — number followed by post/prefix
	// like "5%" or "100€".
	if prev == .NU && (cur == .PO || cur == .PR) { return .None }
	// LB25: (PR | PO) × (OP | HY) — prefix that begins a numeric
	// chain ("$-5", "$(123)"). Only fires when the position after
	// the OP/HY is going to be a digit, otherwise unrelated PR + OP
	// (like a non-numeric "% (note)") would bind. We approximate
	// that via a single-glyph lookahead at the walker level — see
	// `pr_op_lookahead` override below.

	// ---- LB26 / LB27: Hangul -----------------------------------------
	if prev == .JL && (cur == .JL || cur == .JV || cur == .H2 || cur == .H3) {
		return .None
	}
	if (prev == .JV || prev == .H2) && (cur == .JV || cur == .JT) { return .None }
	if (prev == .JT || prev == .H3) && cur == .JT { return .None }
	if (prev == .JL || prev == .JV || prev == .JT || prev == .H2 || prev == .H3) && cur == .PO {
		return .None
	}
	if prev == .PR && (cur == .JL || cur == .JV || cur == .JT || cur == .H2 || cur == .H3) {
		return .None
	}

	// ---- LB28: (AL|HL) × (AL|HL) -------------------------------------
	if (prev == .AL || prev == .HL) && (cur == .AL || cur == .HL) { return .None }

	// ---- LB28a: Aksara cluster (Brahmic-script bind) -----------------
	// (AK | 25CC | AS) × (VF | VI)
	// AP × (AK | 25CC | AS)
	// (AK | 25CC | AS) VI × (AK | 25CC) — handled via the
	// `prev_is_vi_after_ak` flag the walker maintains.
	// The "× (AK|…) VF" lookahead variant still needs lookahead
	// state we don't track.
	if is_ak_base(prev, prev_rune) && (cur == .VF || cur == .VI) { return .None }
	if prev == .AP && is_ak_base(cur, cur_rune) { return .None }
	if prev_is_vi_after_ak && is_ak_base(cur, cur_rune) { return .None }

	// ---- LB29: IS × (AL|HL) ------------------------------------------
	if prev == .IS && (cur == .AL || cur == .HL) { return .None }

	// ---- LB30: (AL|HL|NU) × OP; CP × (AL|HL|NU) ----------------------
	// Spec-defined EAW exception: wide-form OPs (e.g. U+2329, CJK
	// brackets, fullwidth parens) keep the default break — they're
	// visually their own column rather than glued to the preceding
	// letter. `is_eaw_wide_op` is a 29-entry hard-coded table from
	// EastAsianWidth.txt.
	if (prev == .AL || prev == .HL || prev == .NU) && cur == .OP && !is_eaw_wide_op(cur_rune) {
		return .None
	}
	if prev == .CP && (cur == .AL || cur == .HL || cur == .NU) { return .None }

	// ---- LB30a: RI × RI but only for odd-count runs -------------------
	if prev == .RI && cur == .RI && ri_run % 2 == 1 { return .None }

	// ---- LB30b: EB × EM ----------------------------------------------
	// Plus the second arm — [Extended_Pictographic & Cn] × EM —
	// which covers reserved emoji codepoints (future-emoji slots).
	// `is_reserved_pictographic` enumerates the Unicode-17.0 ranges
	// that satisfy both properties.
	if prev == .EB && cur == .EM { return .None }
	if cur == .EM && is_reserved_pictographic(prev_rune) { return .None }

	// ---- LB31: default ÷ ALL -----------------------------------------
	return .Allow
}
