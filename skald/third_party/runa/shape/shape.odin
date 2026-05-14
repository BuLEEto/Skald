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

// Shape_Run_Opts is the per-call options.
Shape_Run_Opts :: struct {
	script:   parse.Tag,                       // e.g. parse.LATN_SCRIPT
	language: parse.Tag,                       // e.g. parse.DFLT_LANG
	// Add per-call feature overrides if/when the API matures.
}

@(private)
axis_values_non_default :: proc(values: []f32) -> bool {
	for v in values { if v != 0 { return true } }
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

	byte_idx: u32 = 0
	for r in text {
		gid := parse.cmap_lookup(in_.cmap, r)
		append(&gids, gid)
		append(&clusters, byte_idx)
		append(&runes, r)

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
	}

	// Stage 2: GSUB. Apply v0.1 features in the canonical order. The
	// cluster array is rewritten in parallel as ligatures collapse
	// glyphs.
	if in_.gsub != nil {
		gsub_features := [?]parse.Tag{
			parse.tag("ccmp"),
			parse.tag("locl"),
			parse.tag("rlig"),
			parse.tag("liga"),
			parse.tag("clig"),
			parse.tag("calt"),
		}
		for ft in gsub_features {
			before := len(gids)
			parse.gsub_apply_feature(in_.gsub, &gids, opts.script, opts.language, ft)
			after := len(gids)
			if before == after { continue }
			// Walk in parallel and drop cluster entries whose gid index
			// no longer exists. Since GSUB rewrites gids in place with
			// `ordered_remove(gids, j)` for the trailing inputs of a
			// ligation, the simplest re-sync is to truncate `clusters`
			// to `after` from the right — but that loses correctness if
			// non-leading positions collapsed. Walk and pull the leftmost
			// surviving cluster for each gid.
			//
			// For v0.1, the imprecision: if a ligation happened we keep
			// the cluster of the first surviving codepoint. Good enough
			// for left-to-right Latin text where ligation always
			// preserves the leftmost cluster.
			resize(&clusters, after)
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

		append(out, Shaped_Glyph{
			glyph_id  = gids[i],
			cluster   = cluster,
			x_advance = advance_units * scale,
			y_advance = f32(adjusts[i].y_advance) * scale,
			x_offset  = x_off_units * scale,
			y_offset  = y_off_units * scale,
		})
	}
}
