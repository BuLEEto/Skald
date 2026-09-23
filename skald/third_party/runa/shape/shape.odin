/*
Package shape turns a UTF-8 run into a sequence of positioned glyph
IDs by applying the font's GSUB (substitution) and GPOS (positioning)
tables.

v0.1 scope:
  - LTR Latin / Cyrillic / Greek.
  - GSUB: liga, clig, calt, rlig, locl, ccmp.
  - GPOS: kern (pair positioning).
  - No script/language fallback at this layer — the caller passes a
    pre-resolved (script, language) pair. The itemizer's job to pick
    them.

Cluster tracking is approximate at v0.1 — every glyph carries
`cluster = byte_offset_of_first_codepoint_at_input`. Ligatures retain
the cluster of the *first* input glyph; the trailing inputs disappear.
*/
package shape

import "../parse"

// Shaped_Glyph is one output glyph from `shape_run`. Coordinates are in
// pixel space: caller-friendly, no per-call font-unit conversion.
//
// `cluster` is the byte index of the source codepoint within the input
// string. Multiple glyphs may share a cluster (when one codepoint
// produces several glyphs); a single glyph may span multiple clusters
// (ligation).
Shaped_Glyph :: struct {
	glyph_id:  parse.Glyph_ID,
	cluster:   u32,
	x_advance: f32,
	y_advance: f32,
	x_offset:  f32,
	y_offset:  f32,
}

// Shape_Inputs is the set of parsed tables `shape_run` consumes. Pass
// `gsub = nil` / `gpos = nil` for fonts that lack those tables — the
// shaper degrades gracefully (advances from `hmtx` only, no
// substitution, no kerning).
//
// `hvar` + `axis_values` are optional variable-font state. When
// supplied, the shaper applies HVAR advance-width deltas so the
// emitted `x_advance` tracks the selected instance.
Shape_Inputs :: struct {
	cmap:         ^parse.Cmap,
	hmtx:         ^parse.Hmtx_Table,
	gsub:         ^parse.Gsub,                // may be nil
	gpos:         ^parse.Gpos,                // may be nil
	hvar:         ^parse.Hvar,                // may be nil (static font or no HVAR)
	axis_values:  []f32,                       // nil or all-zero → default instance
	units_per_em: u16,
}

// Feature is a discretionary GSUB feature a caller may switch off per call.
// The mandatory features (ccmp, locl, rlig) are always applied and are not
// representable here — they are correctness, not preference.
Feature :: enum u8 {
	Ligatures,             // liga
	Contextual_Ligatures,  // clig
	Contextual_Alternates, // calt (code-font -> == != … ligatures fire here)
}

// Shape_Run_Opts is the per-call options.
Shape_Run_Opts :: struct {
	script:   parse.Tag,                       // e.g. parse.LATN_SCRIPT
	language: parse.Tag,                       // e.g. parse.DFLT_LANG
	// Discretionary features to switch off this call; {} = all applied.
	// Changes glyph advances, so shape and measure with the same set.
	disable_features: bit_set[Feature],
}

@(private)
axis_values_non_default :: proc(values: []f32) -> bool {
	for v in values { if v != 0 { return true } }
	return false
}

// is_default_ignorable reports Unicode Default_Ignorable_Code_Point —
// LRM / RLM / ALM, ZWJ / ZWNJ, variation selectors, and friends. These
// carry meaning for bidi and joining but must not paint: HarfBuzz emits
// them as a zero-advance space, and without that U+061C ARABIC LETTER
// MARK rendered as a visible 0.6 em glyph in the middle of Arabic text.
//
// 17 ranges from Unicode 17.0 `tools/ucd/DerivedCoreProperties.txt`
// (property `Default_Ignorable_Code_Point`).
@(private)
is_default_ignorable :: proc(r: rune) -> bool {
	switch r {
	case 0x00AD, 0x034F, 0x061C, 0x115F..=0x1160,
	     0x17B4..=0x17B5, 0x180B..=0x180F, 0x200B..=0x200F, 0x202A..=0x202E,
	     0x2060..=0x206F, 0x3164, 0xFE00..=0xFE0F, 0xFEFF,
	     0xFFA0, 0xFFF0..=0xFFF8, 0x1BCA0..=0x1BCA3, 0x1D173..=0x1D17A,
	     0xE0000..=0xE0FFF:
		return true
	}
	return false
}

// shape_run shapes `text` for one font at `size` pixels, appending to
// `out`. Existing entries in `out` are kept — the caller can reuse the
// dynamic array across calls. Allocations made during shaping land in
// `context.temp_allocator` and are not held past the call.
shape_run :: proc(in_: ^Shape_Inputs, opts: Shape_Run_Opts, text: string, size: f32, out: ^[dynamic]Shaped_Glyph) {
	scale := size / f32(in_.units_per_em)

	// Stage 1: map codepoints to glyph IDs, recording the source byte
	// offset for cluster tracking + the raw rune for downstream
	// Arabic / joining state computation.
	gids     := make([dynamic]parse.Glyph_ID, 0, len(text), context.temp_allocator)
	clusters := make([dynamic]u32,            0, len(text), context.temp_allocator)
	runes    := make([dynamic]rune,           0, len(text), context.temp_allocator)

	// Parallel to `gids`: marks the positions that came from a
	// Default_Ignorable codepoint, so stage 5 can blank them. Tracked
	// here because this is the only point where the rune → glyph mapping
	// is exactly 1:1; it follows `clusters` through the GSUB resizes.
	ignorable := make([dynamic]bool, 0, len(text), context.temp_allocator)

	byte_idx: u32 = 0
	for r in text {
		gid := parse.cmap_lookup(in_.cmap, r)
		append(&gids, gid)
		append(&clusters, byte_idx)
		append(&runes, r)
		append(&ignorable, is_default_ignorable(r))

		// Advance byte index by the UTF-8 length of the codepoint we
		// just consumed.
		if r < 0x80 { byte_idx += 1 }
		else if r < 0x800 { byte_idx += 2 }
		else if r < 0x10000 { byte_idx += 3 }
		else { byte_idx += 4 }
	}

	// Stage 1b: Arabic / cursive-joining per-position substitution.
	// For runs whose script is `arab` (or another joining script),
	// compute each glyph's joining form and apply the matching
	// `isol` / `init` / `medi` / `fina` GSUB feature *only at that
	// position*. Buffer-wide `gsub_apply_feature` over-substitutes;
	// per-position gating is what HarfBuzz and friends do.
	if in_.gsub != nil && opts.script == parse.tag("arab") {
		forms := make([]Joining_Form, len(runes), context.temp_allocator)
		arabic_join_state(runes[:], forms)
		for i in 0..<len(forms) {
			ft: parse.Tag
			switch forms[i] {
			case .Isolated: ft = parse.tag("isol")
			case .Initial:  ft = parse.tag("init")
			case .Medial:   ft = parse.tag("medi")
			case .Final:    ft = parse.tag("fina")
			}
			parse.gsub_apply_single_at(in_.gsub, gids[:], i, opts.script, opts.language, ft)
		}
	}

	// Stage 1c: Indic shaping. For Devanagari + sibling scripts run
	// the syllable-aware reordering + Indic feature sequence BEFORE
	// the script-agnostic GSUB stage so its rphf / blwf / half / etc.
	// see the right glyph input order. The generic `liga` / `calt`
	// stage below then composes any remaining ligatures on top.
	if in_.gsub != nil && is_indic_script(opts.script) {
		indic_shape(in_.gsub, &gids, &clusters, runes[:], opts.script, opts.language)
		resize(&ignorable, len(gids))
	}

	// Stage 2: GSUB. Apply v0.1 features in the canonical order. The
	// cluster array is rewritten in parallel as ligatures collapse
	// glyphs.
	if in_.gsub != nil {
		// ccmp / locl / rlig are mandatory (correctness); liga / clig /
		// calt are discretionary and honour `opts.disable_features`.
		Stage :: struct { tag: parse.Tag, opt: Maybe(Feature) }
		gsub_features := [?]Stage{
			{parse.tag("ccmp"), nil},
			{parse.tag("locl"), nil},
			{parse.tag("rlig"), nil},
			{parse.tag("liga"), .Ligatures},
			{parse.tag("clig"), .Contextual_Ligatures},
			{parse.tag("calt"), .Contextual_Alternates},
		}
		removed := make([dynamic]int, 0, 8, context.temp_allocator)
		for st in gsub_features {
			if f, ok := st.opt.?; ok && f in opts.disable_features { continue }
			clear(&removed)
			parse.gsub_apply_feature(in_.gsub, &gids, opts.script, opts.language, st.tag, &removed)
			// Replay the exact glyph deletions gsub made onto the parallel
			// arrays, in the same order, so a ligature keeps every later
			// glyph's cluster correct. (Truncating from the right instead
			// slid every cluster past the ligature by one.)
			for idx in removed {
				if idx < len(clusters)  { ordered_remove(&clusters, idx) }
				if idx < len(ignorable) { ordered_remove(&ignorable, idx) }
			}
		}
	}

	// Stage 3: per-glyph horizontal advance from hmtx.
	adjusts := make([]parse.Pos_Adjust, len(gids), context.temp_allocator)

	// Stage 4: GPOS — apply pair-positioning + mark-attachment
	// features in font units. `kern` adjusts advance/letter spacing;
	// `mark` snaps mark glyphs to base-glyph anchor points; `mkmk`
	// stacks marks on previously-placed marks.
	if in_.gpos != nil {
		parse.gpos_apply_feature(in_.gpos, gids[:], adjusts, opts.script, opts.language, parse.tag("kern"))
		parse.gpos_apply_feature(in_.gpos, gids[:], adjusts, opts.script, opts.language, parse.tag("mark"))
		parse.gpos_apply_feature(in_.gpos, gids[:], adjusts, opts.script, opts.language, parse.tag("mkmk"))
	}

	// Stage 5: emit Shaped_Glyph slice in pixel space.
	apply_hvar := in_.hvar != nil && axis_values_non_default(in_.axis_values)
	for i in 0..<len(gids) {
		m := parse.hmtx_glyph_metric(in_.hmtx, gids[i])
		advance_units := f32(m.advance_width) + f32(adjusts[i].x_advance)
		if apply_hvar {
			advance_units += f32(parse.hvar_advance_delta(in_.hvar, gids[i], in_.axis_values))
		}
		x_off_units   := f32(adjusts[i].x_placement)
		y_off_units   := f32(adjusts[i].y_placement)

		cluster: u32 = 0
		if i < len(clusters) { cluster = clusters[i] }

		// Default-ignorables (LRM / RLM / ALM, ZWJ / ZWNJ, variation
		// selectors) have already done their job in the joining and bidi
		// passes. They must not paint: emit the space glyph at zero
		// advance, which is what HarfBuzz does.
		gid := gids[i]
		if i < len(ignorable) && ignorable[i] {
			gid = parse.cmap_lookup(in_.cmap, ' ')
			advance_units = 0
			x_off_units   = 0
			y_off_units   = 0
		}

		append(out, Shaped_Glyph{
			glyph_id  = gid,
			cluster   = cluster,
			x_advance = advance_units * scale,
			y_advance = f32(adjusts[i].y_advance) * scale,
			x_offset  = x_off_units * scale,
			y_offset  = y_off_units * scale,
		})
	}
}
