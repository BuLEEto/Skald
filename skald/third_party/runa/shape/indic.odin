/*
Indic (Devanagari and family) shaper — OpenType "indic2" model.

Overview
========
Indic scripts encode syllables that don't render linearly. The
codepoint stream is "logical order"; the visual order requires
reordering pieces of the cluster *before* GSUB feature application:

  - Reph: an initial RA + Halant becomes the "reph" mark and visually
    sits above the syllable's *last* consonant. Encoded as the first
    two codepoints of the cluster; reordered to the end before GSUB
    so the font's `rphf` feature has the right input shape.
  - Pre-base matra: vowel signs like ि (Devanagari I) visually
    precede the base consonant cluster but are encoded *after* it.
    Reordered to immediately before the base.
  - Half forms: a consonant followed by Halant + consonant takes the
    "half" form (without an inherent vowel). The `half` feature is
    applied only to the half-bearing consonants.
  - Conjuncts: Halant between two consonants triggers ligation via
    the `cjct` feature.

Pipeline (per syllable):
  1. Identify cluster boundary + locate base consonant.
  2. Reorder reph + pre-base matras into the right input positions.
  3. Apply Indic basic-shaping features in spec order: `locl`,
     `nukt`, `akhn`, `rphf`, `rkrf`, `pref`, `blwf`, `abvf`, `half`,
     `pstf`, `vatu`, `cjct`.
  4. Apply Indic presentation features: `init`, `pres`, `abvs`,
     `blws`, `psts`, `haln`, `calt`.

This shaper handles the dev2 (OpenType v2) feature ordering. Older
fonts that only ship dev1 tags still work because the feature
application falls through to `gsub_apply_feature` which is tag-
agnostic; the per-position guards on rphf / pref handle the rest.

Reference: OpenType "Devanagari" shaping engine docs;
HarfBuzz `hb-ot-shape-complex-indic.cc`.
*/
package shape

import "../parse"

// Indic_State is a single syllable's reordering state — exposed to
// the dispatcher in `shape.odin` so it can interleave with the rest
// of the pipeline.
@(private)
Indic_Syllable :: struct {
	lo:        int,                                     // inclusive start in the gids buffer
	hi:        int,                                     // exclusive end
	base_idx:  int,                                     // index of the base consonant within [lo, hi)
	has_reph:  bool,
}

// is_indic_script reports whether `script` should run through the
// Indic shaping pipeline. Returns true for both the OT v1 tags
// (deva / beng / etc.) and the v2 tags (dev2 / bng2 / etc.).
is_indic_script :: proc(script: parse.Tag) -> bool {
	switch script {
	case parse.tag("deva"), parse.tag("dev2"),          // Devanagari
	     parse.tag("beng"), parse.tag("bng2"),          // Bengali
	     parse.tag("gujr"), parse.tag("gjr2"),          // Gujarati
	     parse.tag("guru"), parse.tag("gur2"),          // Gurmukhi
	     parse.tag("knda"), parse.tag("knd2"),          // Kannada
	     parse.tag("mlym"), parse.tag("mlm2"),          // Malayalam
	     parse.tag("orya"), parse.tag("ory2"),          // Odia
	     parse.tag("taml"), parse.tag("tml2"),          // Tamil
	     parse.tag("telu"), parse.tag("tel2"),          // Telugu
	     parse.tag("khmr"),                              // Khmer (no v2 tag)
	     parse.tag("mymr"), parse.tag("mym2"):           // Myanmar
		return true
	}
	return false
}

// script_uses_reph reports whether the script has a reph mark —
// i.e. whether an initial RA + Halant should reorder to the end of
// the cluster for the `rphf` feature.
//
// Yes — Devanagari, Bengali, Gujarati, Kannada, Odia.
// No  — Tamil (uses pulli), Telugu / Malayalam (no reph; Malayalam
//       has chillu, a separate ZWJ-driven mechanism), Gurmukhi
//       (RA-halant subjoins rather than reph-ifies).
@(private)
script_uses_reph :: proc(script: parse.Tag) -> bool {
	switch script {
	case parse.tag("taml"), parse.tag("tml2"),
	     parse.tag("telu"), parse.tag("tel2"),
	     parse.tag("mlym"), parse.tag("mlm2"),
	     parse.tag("guru"), parse.tag("gur2"),
	     parse.tag("khmr"),
	     parse.tag("mymr"), parse.tag("mym2"):
		return false
	}
	return true
}

// indic_shape applies the per-syllable Indic reordering + feature
// pipeline. Operates on the gids / clusters / runes buffers in
// place — same shape as the Arabic per-position pass.
indic_shape :: proc(
	gsub: ^parse.Gsub,
	gids: ^[dynamic]parse.Glyph_ID,
	clusters: ^[dynamic]u32,
	runes: []rune,
	script, language: parse.Tag,
) {
	if gsub == nil { return }

	// Indic2 (OT v2) script tags carry the modern feature set the
	// shaper expects. Convert the v1 tag to its v2 equivalent before
	// looking features up — modern fonts ship the rich `pres` /
	// `psts` / `pref` ligation rules only under the v2 script.
	script_v2 := indic_v2_tag(script)
	_ = script_v2  // used below

	// Step 1: walk the buffer, segmenting into syllables.
	syllables := make([dynamic]Indic_Syllable, 0, 16, context.temp_allocator)
	defer delete(syllables)

	n := len(runes)
	i := 0
	uses_reph_script := script_uses_reph(script)
	for i < n {
		end := find_syllable_end(runes, i)
		syl := Indic_Syllable{lo = i, hi = end, base_idx = -1, has_reph = false}
		identify_base(runes, &syl, uses_reph_script)
		append(&syllables, syl)
		i = end
	}

	// Step 2: per-syllable reordering. The gids array is rewritten
	// in place; the runes and clusters arrays follow.
	uses_reph := script_uses_reph(script)
	for &syl in syllables {
		if uses_reph { reorder_reph(gids, clusters, runes, &syl) }
		reorder_pre_base_matra(gids, clusters, runes, &syl)
	}

	// Step 3: apply Indic basic-shaping features in spec order. Each
	// feature can rewrite the gid array — but it must NOT collapse
	// gids across syllable boundaries, which the per-feature
	// substitution logic already respects (rphf / blwf only fire on
	// the gids the input mark-up positions them onto).
	indic_features := [?]parse.Tag{
		// Basic-shaping features (Microsoft Devanagari spec stage 2).
		parse.tag("locl"),
		parse.tag("nukt"),
		parse.tag("akhn"),
		parse.tag("rphf"),
		parse.tag("rkrf"),
		parse.tag("pref"),
		parse.tag("blwf"),
		parse.tag("abvf"),
		parse.tag("half"),
		parse.tag("pstf"),
		parse.tag("vatu"),
		parse.tag("cjct"),
		// Presentation features (stage 3) — compose matras into the
		// base consonant ligatures the font ships.
		parse.tag("init"),
		parse.tag("pres"),
		parse.tag("abvs"),
		parse.tag("blws"),
		parse.tag("psts"),
		parse.tag("haln"),
	}
	for ft in indic_features {
		before := len(gids)
		parse.gsub_apply_feature(gsub, gids, script_v2, language, ft)
		// If the v2 script didn't fire (font's only v1), retry with
		// the v1 tag so older fonts still benefit.
		if len(gids) == before && script_v2 != script {
			parse.gsub_apply_feature(gsub, gids, script, language, ft)
		}
		after := len(gids)
		if before != after { resize(clusters, after) }
	}
}

// indic_v2_tag maps OpenType v1 Indic script tags to their v2
// equivalents (deva → dev2 etc.). Modern fonts ship features under
// the v2 tag; the v1 tag is kept as a fallback for legacy fonts.
@(private)
indic_v2_tag :: proc(t: parse.Tag) -> parse.Tag {
	switch t {
	case parse.tag("deva"): return parse.tag("dev2")
	case parse.tag("beng"): return parse.tag("bng2")
	case parse.tag("gujr"): return parse.tag("gjr2")
	case parse.tag("guru"): return parse.tag("gur2")
	case parse.tag("knda"): return parse.tag("knd2")
	case parse.tag("mlym"): return parse.tag("mlm2")
	case parse.tag("orya"): return parse.tag("ory2")
	case parse.tag("taml"): return parse.tag("tml2")
	case parse.tag("telu"): return parse.tag("tel2")
	case parse.tag("mymr"): return parse.tag("mym2")
	}
	return t
}

// find_syllable_end returns the (exclusive) end of the syllable
// starting at `lo`. A Devanagari syllable per spec:
//
//   (Repha)? (C[N]? (H[J]? C[N]?)*) [M[N]? H?]* (B|V)?
//
// where C = consonant, M = matra, H = halant, N = nukta, J = ZWJ,
// B = bindu, V = visarga. Simpler approximation in v0.9: consume
// the maximal sequence of Indic codepoints that don't cross another
// syllable's base consonant — when we hit a consonant after seeing
// a halant we keep going (conjunct); without halant we stop.
@(private)
find_syllable_end :: proc(runes: []rune, lo: int) -> int {
	n := len(runes)
	if lo >= n { return lo }

	i := lo
	seen_consonant := false
	prev_halant    := false

	for i < n {
		r  := runes[i]
		cl := isc_class(r)

		#partial switch cl {
		case .Consonant, .Consonant_Dead, .Consonant_Placeholder, .Consonant_With_Stacker,
		     .Consonant_Preceding_Repha, .Consonant_Succeeding_Repha,
		     .Consonant_Head_Letter:
			if seen_consonant && !prev_halant {
				// New base — start a fresh syllable here.
				return i
			}
			seen_consonant = true
			prev_halant    = false
		case .Consonant_Medial, .Consonant_Subjoined, .Consonant_Final:
			// Medial / subjoined / final consonants always attach to
			// the current syllable — they're parts of the base, not
			// new bases.
			prev_halant = false
		case .Vowel_Independent, .Vowel, .Vowel_Dependent:
			// Vowel anchors a syllable just like a consonant for
			// boundary purposes, but doesn't permit a following bare
			// consonant to join.
			if seen_consonant && cl == .Vowel_Independent && !prev_halant {
				return i
			}
			seen_consonant = true
			prev_halant    = false
		case .Virama, .Pure_Killer, .Invisible_Stacker:
			prev_halant = true
		case .Nukta, .Bindu, .Visarga, .Avagraha, .Gemination_Mark, .Tone_Mark,
		     .Cantillation_Mark, .Syllable_Modifier, .Consonant_Killer,
		     .Non_Joiner, .Joiner, .Modifying_Letter:
			// Attach to the running syllable.
			prev_halant = false
		case .Other:
			if seen_consonant {
				return i
			}
			// Pre-syllable junk — just walk past it.
		case:
			prev_halant = false
		} // #partial switch cl

		i += 1
	}
	return n
}

// identify_base picks the base consonant of the syllable. The base
// is the LAST consonant in the cluster that is not preceded by a
// halant (i.e. that would carry the inherent vowel / vowel sign).
// Also detects whether the syllable starts with a Repha (RA + Halant
// at the front).
@(private)
identify_base :: proc(runes: []rune, syl: ^Indic_Syllable, uses_reph: bool) {
	// Reph detection: RA + Halant at positions [lo, lo+1) — but
	// only when the active script actually uses reph. Tamil treats
	// RA+Halant as a regular pulli'd consonant; flagging it as reph
	// would cause the wrong reorder.
	if uses_reph && syl.hi - syl.lo >= 2 {
		r0 := runes[syl.lo]
		r1 := runes[syl.lo + 1]
		if is_ra_for_reph(r0) && isc_class(r1) == .Virama {
			syl.has_reph = true
		}
	}

	// Base = last consonant that is not followed by halant (= the
	// one that gets the matra). We scan from the end backwards.
	// Skip the reph if present so it doesn't get picked as base.
	scan_from := syl.lo
	if syl.has_reph { scan_from += 2 }

	for j := syl.hi - 1; j >= scan_from; j -= 1 {
		c := isc_class(runes[j])
		if !is_consonant_class(c) { continue }
		// If this consonant is followed by Halant, it's a half-form,
		// not the base. Keep scanning.
		if j + 1 < syl.hi && isc_class(runes[j + 1]) == .Virama { continue }
		syl.base_idx = j
		return
	}
	// No base consonant found — independent vowel cluster, etc. Leave
	// base_idx at -1 and let reordering skip this syllable.
	if syl.base_idx < 0 && syl.hi > syl.lo {
		// Fall back to the first consonant or first codepoint.
		for j in scan_from..<syl.hi {
			if is_consonant_class(isc_class(runes[j])) {
				syl.base_idx = j
				return
			}
		}
		syl.base_idx = scan_from
	}
}

// is_pre_base_position reports whether an IPC value indicates a
// codepoint visually positioned (at least partly) to the LEFT of
// the consonant cluster — i.e. it needs to be reordered to the
// front of the cluster in the input buffer for the GSUB
// presentation rules to fire correctly.
@(private)
is_pre_base_position :: proc(ipc: IPC) -> bool {
	#partial switch ipc {
	case .Left, .Visual_Order_Left,
	     .Top_And_Left, .Top_And_Left_And_Right,
	     .Bottom_And_Left, .Top_And_Bottom_And_Left,
	     .Left_And_Right:
		return true
	}
	return false
}

@(private)
is_consonant_class :: proc(c: ISC) -> bool {
	#partial switch c {
	case .Consonant, .Consonant_Dead, .Consonant_Placeholder,
	     .Consonant_With_Stacker, .Consonant_Preceding_Repha,
	     .Consonant_Succeeding_Repha, .Consonant_Head_Letter,
	     .Consonant_Subjoined, .Consonant_Medial, .Consonant_Final:
		return true
	}
	return false
}

// is_ra_for_reph reports whether `r` is a script's "RA" (the
// consonant that becomes reph at cluster start). Devanagari + the
// closely-related scripts use specific codepoints:
@(private)
is_ra_for_reph :: proc(r: rune) -> bool {
	switch r {
	case 0x0930, 0x0931:       return true              // Devanagari RA, RRA
	case 0x09B0, 0x09F0:       return true              // Bengali RA, BENGALI LETTER RA WITH MIDDLE DIAGONAL
	case 0x0A30:               return true              // Gurmukhi RA
	case 0x0AB0:               return true              // Gujarati RA
	case 0x0B30:               return true              // Odia RA
	case 0x0BB0:               return true              // Tamil RA
	case 0x0C30:               return true              // Telugu RA
	case 0x0CB0:               return true              // Kannada RA
	case 0x0D30:               return true              // Malayalam RA
	}
	return false
}

// reorder_reph: if the syllable starts with RA + Halant, move that
// pair to AFTER the base consonant. The visual position of reph is
// at the top-right of the syllable; the GSUB `rphf` feature
// rewrites the (RA, Halant) pair to the reph glyph regardless of
// where it sits, so the move is mostly bookkeeping for downstream
// features that key off "everything between base and reph".
@(private)
reorder_reph :: proc(gids: ^[dynamic]parse.Glyph_ID, clusters: ^[dynamic]u32, runes: []rune, syl: ^Indic_Syllable) {
	if !syl.has_reph || syl.base_idx < 0 { return }
	// Reph is at [lo, lo+1] (the RA and the Halant). Move to
	// [base_idx, base_idx+1] (just after the base, before any matras).
	lo := syl.lo
	base := syl.base_idx
	if base <= lo + 1 { return }                        // base is the reph itself somehow

	ra_g  := gids[lo]
	hal_g := gids[lo + 1]
	ra_c  := clusters[lo]
	hal_c := clusters[lo + 1]

	// Shift [lo+2, base+1) left by 2 to fill the gap.
	for k in lo + 2..=base {
		gids[k - 2]     = gids[k]
		clusters[k - 2] = clusters[k]
	}
	// Place the moved reph immediately after the (now shifted) base.
	gids[base - 1]     = ra_g
	gids[base]         = hal_g
	clusters[base - 1] = ra_c
	clusters[base]     = hal_c

	// Update base_idx — it moved left by 2 inside the syllable.
	syl.base_idx = base - 2
	_ = runes
}

// reorder_pre_base_matra moves vowel signs visually positioned to
// the LEFT of the base consonant into the right slot in the input
// buffer. UCD encodes left-side matras under two IPC values:
//
//   - `Left` — Devanagari / Gujarati / Telugu I-matras.
//   - `Visual_Order_Left` — Bengali / Tamil / Malayalam / Odia
//     I-matras (the name is a UCD historical artefact; these
//     codepoints are still encoded *after* the consonant in source
//     and need the same reorder as `Left` for runa's pipeline).
//
// Both cases shift the matra to immediately before the base consonant.
@(private)
reorder_pre_base_matra :: proc(gids: ^[dynamic]parse.Glyph_ID, clusters: ^[dynamic]u32, runes: []rune, syl: ^Indic_Syllable) {
	if syl.base_idx < 0 { return }
	// Pre-base matras move to the START of the cluster (position
	// `lo`), not just before the base consonant. For a single-
	// consonant cluster the two are the same; for multi-consonant
	// clusters (e.g. Devanagari "क्ति" — KA + VIRAMA + TA + I-MATRA)
	// the matra needs to land before the half-form, which is
	// position `lo`.
	lo := syl.lo
	for j := lo + 1; j < syl.hi; j += 1 {
		if !is_pre_base_position(ipc_class(runes[j])) { continue }
		matra_g := gids[j]
		matra_c := clusters[j]
		for k := j; k > lo; k -= 1 {
			gids[k]     = gids[k - 1]
			clusters[k] = clusters[k - 1]
		}
		gids[lo]     = matra_g
		clusters[lo] = matra_c
		// The base just shifted right by one; reflect that so other
		// passes still see the right index. The matra's new position
		// is `lo`; everything after slides right.
		if syl.base_idx >= lo { syl.base_idx += 1 }
		lo += 1
	}
}
