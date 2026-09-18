package parse

// Type 2 charstring interpreter (Adobe Technical Note #5177).
//
// Walks one glyph's charstring bytecode (read from `Cff.charstrings_index`)
// and emits the outline as flattened line segments into an `Outline`.
// Cubic Béziers are subdivided via de Casteljau down to a 0.5-unit
// flatness tolerance — same precision the v0.5 rasterizer's
// quadratic flattener uses. We emit only on-curve points; the
// rasterizer's existing flatten path treats consecutive on-curve
// points as line segments, which is exactly what we want.
//
// Subroutine support: `callsubr` / `callgsubr` jump into a local /
// global Subr INDEX entry; `return` pops the call stack. Depth is
// capped at 10 per the Type 2 spec.

// Maximum nested subroutine call depth (Type 2 spec section 2.4).
CFF_MAX_SUBR_DEPTH :: 10

// Cubic-flatness threshold for the de-Casteljau subdivision, in
// font-design units. 0.5 is conservative but produces visually
// indistinguishable output at any rasterization size.
@(private)
CUBIC_FLATNESS :: f32(0.5)

// Cs_Context provides the subroutine pools (and, for CFF2, the
// VarStore region counts + active scalar weights) the Type 2
// interpreter needs. Same interpreter serves both CFF1 and CFF2 —
// the caller fills in the appropriate fields and dispatches.
Cs_Context :: struct {
	global_subrs:     ^Cff_Index,
	global_subr_bias: int,
	local_subrs:      ^Cff_Index,
	local_subr_bias:  int,
	// CFF2 only. For CFF1 these stay zero and the operators they
	// govern (vsindex / blend) never appear in well-formed bytecode.
	is_cff2:          bool,
	cff2:             ^Cff2,
	region_counts:    []u16,
	cur_vsindex:      int,
	cur_num_regions:  int,
	// `apply_variation` flips on when at least one axis is off its
	// default. When false (default instance), `blend` discards
	// deltas without applying them, identical to the v0.5 default-
	// only behaviour.
	apply_variation:  bool,
	axis_values:      []f32,
	// Scalars for the current vsindex's region indices, recomputed
	// whenever vsindex changes. Length matches `cur_num_regions`.
	cur_scalars:      ^[dynamic]f32,
}

// cff_glyph_outline interprets the Type 2 charstring for `gid` and
// fills `out`. Caller-owned outline; reuses backing arrays so the
// same Outline can be threaded across many glyphs.
//
// Returns `Error.Glyph_Not_Found` if `gid` is out of range. Truncated
// or malformed bytecode returns `Error.Invalid_Table`.
cff_glyph_outline :: proc(c: ^Cff, gid: Glyph_ID, out: ^Outline) -> Error {
	clear(&out.points)
	clear(&out.contour_ends)
	out.x_min, out.y_min, out.x_max, out.y_max = 0, 0, 0, 0

	if int(gid) >= c.num_glyphs { return .Glyph_Not_Found }
	bytecode, err := cff_index_get(&c.charstrings_index, int(gid))
	if err != .None { return err }
	if len(bytecode) == 0 { return .None }                // empty glyph (.notdef etc.)

	ctx := Cs_Context{
		global_subrs     = &c.global_subrs,
		global_subr_bias = c.global_subr_bias,
		local_subrs      = &c.local_subrs,
		local_subr_bias  = c.local_subr_bias,
	}
	state := Cs_State{
		x = 0, y = 0,
		out = out,
		contour_open = false,
		x_min = 0, y_min = 0, x_max = 0, y_max = 0,
		bbox_init = false,
	}
	if !run_cs(&ctx, &state, bytecode, 0) { return .Invalid_Table }

	// Closing endchar is implicit; if we opened a contour but never
	// terminated it, mark it ended on the last point.
	close_contour(&state)

	if state.bbox_init {
		out.x_min, out.y_min, out.x_max, out.y_max = state.x_min, state.y_min, state.x_max, state.y_max
	}
	return .None
}

// cff2_glyph_outline drives the Type 2 interpreter for CFF2 glyphs.
// Resolves the per-glyph FD via FDSelect, sets the active vsindex /
// region count (so `blend` knows how many delta operands to pop),
// and otherwise reuses the same interpreter as CFF1.
//
// Default-instance only: the `blend` operator consumes its delta
// operands but does not apply them. Non-default-instance rendering
// requires Item Variation Store region-scalar evaluation, deferred
// to a follow-up.
cff2_glyph_outline :: proc(c: ^Cff2, gid: Glyph_ID, out: ^Outline, axis_values: []f32 = nil) -> Error {
	clear(&out.points)
	clear(&out.contour_ends)
	out.x_min, out.y_min, out.x_max, out.y_max = 0, 0, 0, 0

	if int(gid) >= c.num_glyphs { return .Glyph_Not_Found }
	bytecode, err := cff2_charstring_bytes_err(c, gid)
	if err != .None { return err }
	if len(bytecode) == 0 { return .None }

	fd_idx := cff2_fd_index(c, gid)
	if fd_idx < 0 || fd_idx >= len(c.fdarray) { fd_idx = 0 }

	// Set up the variation scalars for vsindex 0 if a non-default
	// axis tuple is supplied. Default-instance callers pass nil
	// (or an all-zero slice), in which case `blend` keeps the
	// default-only fast path.
	apply_var := false
	if axis_values != nil {
		for v in axis_values {
			if v != 0 { apply_var = true; break }
		}
	}
	scalars := make([dynamic]f32, 0, 16, context.temp_allocator)
	defer delete(scalars)
	if apply_var {
		cff2_compute_scalars(c, 0, axis_values, &scalars)
	}

	ctx := Cs_Context{
		global_subrs     = &c.global_subrs,
		global_subr_bias = c.global_subr_bias,
		local_subrs      = &c.fdarray[fd_idx].local_subrs,
		local_subr_bias  = c.fdarray[fd_idx].local_subr_bias,
		is_cff2          = true,
		cff2             = c,
		region_counts    = c.region_counts,
		cur_vsindex      = 0,
		cur_num_regions  = c.default_num_regions,
		apply_variation  = apply_var,
		axis_values      = axis_values,
		cur_scalars      = &scalars,
	}
	state := Cs_State{out = out}
	if !run_cs(&ctx, &state, bytecode, 0) { return .Invalid_Table }

	// CFF2 charstrings have an implicit endchar at the bytecode end.
	close_contour(&state)
	if state.bbox_init {
		out.x_min, out.y_min, out.x_max, out.y_max = state.x_min, state.y_min, state.x_max, state.y_max
	}
	return .None
}

@(private)
cff2_charstring_bytes_err :: proc(c: ^Cff2, gid: Glyph_ID) -> ([]u8, Error) {
	return cff_index_get(&c.charstrings_index, int(gid))
}

// CS_STACK_MAX is the operand stack a charstring may use. Type 2 allows 48,
// CFF2 allows 513 (OpenType CFF2 §3): one `blend` can carry a whole glyph's
// coordinates *and* their per-region deltas, so a variable font with a
// couple of regions goes well past 48 on ordinary letters. One size serves
// both — 2 KB of stack, against silently losing an "i".
CS_STACK_MAX :: 513

@(private)
Cs_State :: struct {
	x, y:           f32,                              // current pen
	stack:          [CS_STACK_MAX]f32,
	sp:             int,
	overflow:       bool,                             // a push past the end: the glyph is refused, never quietly wrong
	stem_count:     int,                              // pending hstem/vstem operands counted
	out:            ^Outline,
	contour_open:   bool,
	contour_start_idx: int,                           // index in out.points where current contour starts
	x_min, y_min:   i16,
	x_max, y_max:   i16,
	bbox_init:      bool,
	first_move:     bool,                             // strip leading width operand on the first move
	hint_mask_consumed: bool,
}

@(private)
run_cs :: proc(c: ^Cs_Context, s: ^Cs_State, code: []u8, depth: int) -> bool {
	if depth > CFF_MAX_SUBR_DEPTH { return false }
	i := 0
	for i < len(code) {
		if s.overflow { return false } // an operand went past the stack: refuse the glyph rather than draw it short
		b := code[i]
		switch {
		case b == 28:
			if i + 2 >= len(code) { return false }
			v := i16(u16(code[i + 1])<<8 | u16(code[i + 2]))
			push(s, f32(v))
			i += 3
		case b >= 32 && b <= 246:
			push(s, f32(i64(b) - 139))
			i += 1
		case b >= 247 && b <= 250:
			if i + 1 >= len(code) { return false }
			v := (i64(b) - 247) * 256 + i64(code[i + 1]) + 108
			push(s, f32(v))
			i += 2
		case b >= 251 && b <= 254:
			if i + 1 >= len(code) { return false }
			v := -(i64(b) - 251) * 256 - i64(code[i + 1]) - 108
			push(s, f32(v))
			i += 2
		case b == 255:
			// 16.16 fixed.
			if i + 4 >= len(code) { return false }
			raw := i32(u32(code[i + 1])<<24 | u32(code[i + 2])<<16 | u32(code[i + 3])<<8 | u32(code[i + 4]))
			push(s, f32(raw) / 65536.0)
			i += 5
		case b == 12:
			// Two-byte operator: the flex family draws curves, so it
			// is followed; the arithmetic ones (rare in real fonts)
			// are consumed and the stack cleared, as before.
			if i + 1 >= len(code) { return false }
			apply_escape(s, code[i + 1])
			i += 2
			s.sp = 0
		case b == 10:
			// callsubr (local).
			if s.sp < 1 { return false }
			n := int(s.stack[s.sp - 1])
			s.sp -= 1
			subr_idx := n + c.local_subr_bias
			if subr_idx < 0 || subr_idx >= c.local_subrs.count { return false }
			body, e := cff_index_get(c.local_subrs, subr_idx)
			if e != .None { return false }
			if !run_cs(c, s, body, depth + 1) { return false }
			i += 1
		case b == 29:
			// callgsubr (global).
			if s.sp < 1 { return false }
			n := int(s.stack[s.sp - 1])
			s.sp -= 1
			subr_idx := n + c.global_subr_bias
			if subr_idx < 0 || subr_idx >= c.global_subrs.count { return false }
			body, e := cff_index_get(c.global_subrs, subr_idx)
			if e != .None { return false }
			if !run_cs(c, s, body, depth + 1) { return false }
			i += 1
		case b == 11:
			// return
			return true
		case b == 14:
			// endchar — CFF1 only; CFF2 charstrings end implicitly at
			// the bytecode boundary, so this opcode shouldn't appear
			// in CFF2 bytecode but is harmless if it does.
			close_contour(s)
			s.sp = 0
			return true
		case b == 15:
			// vsindex (CFF2 only). Operand: new vsindex value (one
			// integer popped from the stack). Updates the active
			// VariationStore subtable so subsequent `blend` operators
			// know the right region count, and recomputes the
			// per-region scalar weights when a non-default instance
			// is in use.
			if !c.is_cff2 { return false }
			if s.sp < 1 { return false }
			vs := int(s.stack[s.sp - 1])
			s.sp -= 1
			c.cur_vsindex = vs
			if vs >= 0 && vs < len(c.region_counts) {
				c.cur_num_regions = int(c.region_counts[vs])
			}
			if c.apply_variation && c.cff2 != nil {
				cff2_compute_scalars(c.cff2, vs, c.axis_values, c.cur_scalars)
			}
			i += 1
		case b == 16:
			// blend (CFF2 only — op 16 is reserved in Type 2 CFF1).
			// Stack layout (bottom-to-top):
			//   def_0 ... def_{N-1}
			//   delta_{0,0} ... delta_{0,R-1}
			//   delta_{1,0} ... delta_{1,R-1}
			//   ...
			//   delta_{N-1,0} ... delta_{N-1,R-1}
			//   N (top)
			// where N = numBlends and R = the regionIndexCount of the
			// current vsindex's ItemVariationData (each delta pairs
			// with its region's scalar).
			//
			// Default instance: scalars are all zero, so deltas
			// contribute nothing — pop them and leave the N defaults.
			// Non-default: add each delta * region_scalar to its
			// corresponding default.
			if !c.is_cff2 { return false }
			if s.sp < 1 { return false }
			n := int(s.stack[s.sp - 1])
			s.sp -= 1
			if n < 0 { return false }
			deltas_per_value := c.cur_num_regions
			total_deltas := n * deltas_per_value
			if s.sp < n + total_deltas { return false }

			if c.apply_variation && c.cur_scalars != nil && len(c.cur_scalars) >= deltas_per_value {
				defaults_base := s.sp - total_deltas - n
				deltas_base   := s.sp - total_deltas
				for j in 0..<n {
					delta_off := deltas_base + j * deltas_per_value
					acc: f32 = 0
					for k in 0..<deltas_per_value {
						acc += s.stack[delta_off + k] * c.cur_scalars[k]
					}
					s.stack[defaults_base + j] += acc
				}
			}
			s.sp -= total_deltas // discard deltas, keep (possibly modified) defaults
			i += 1
		case:
			// Drawing or hinting operator.
			if !apply_op(s, b) { return false }
			i += 1
			// hintmask / cntrmask carry a bit-array after the
			// operator byte. Each bit corresponds to one stem;
			// total bytes = ceil((hstems + vstems) / 8).
			if b == 19 || b == 20 {
				skip := (s.stem_count + 7) / 8
				if i + skip > len(code) { return false }
				i += skip
			}
		}
	}
	return true
}

// push puts an operand on the stack. Past the end it sets `overflow` and the
// run is refused: dropping the value instead would draw a glyph missing
// whatever the dropped operands were.
@(private)
push :: proc(s: ^Cs_State, v: f32) {
	if s.sp < len(s.stack) {
		s.stack[s.sp] = v
		s.sp += 1
		return
	}
	s.overflow = true
}

// apply_escape runs a two-byte (12 x) operator. The flex operators are four
// spellings of the same thing: two curves that together stand in for one
// nearly-flat curve, which fonts use for shallow bows on stems. Skipping
// them, as this did before, dropped those curves and left the glyph subtly
// wrong — the same silent wrongness as an operand stack that drops values.
@(private)
apply_escape :: proc(s: ^Cs_State, op: u8) {
	x0, y0 := s.x, s.y
	switch op {
	case 35: // flex: two curves, then a flex depth we do not need
		if s.sp < 13 { return }
		a := s.stack[:]
		c1x := s.x + a[0];   c1y := s.y + a[1]
		c2x := c1x + a[2];   c2y := c1y + a[3]
		ex  := c2x + a[4];   ey  := c2y + a[5]
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
		c1x = s.x + a[6];    c1y = s.y + a[7]
		c2x = c1x + a[8];    c2y = c1y + a[9]
		ex  = c2x + a[10];   ey  = c2y + a[11]
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
	case 34: // hflex: horizontal, and it comes back to the y it started at
		if s.sp < 7 { return }
		a := s.stack[:]
		c1x := s.x + a[0];   c1y := y0
		c2x := c1x + a[1];   c2y := c1y + a[2]
		ex  := c2x + a[3];   ey  := c2y
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
		c1x = s.x + a[4];    c1y = c2y
		c2x = c1x + a[5];    c2y = y0
		ex  = c2x + a[6];    ey  = y0
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
	case 36: // hflex1: as hflex, with its own y deltas on the way out
		if s.sp < 9 { return }
		a := s.stack[:]
		c1x := s.x + a[0];   c1y := s.y + a[1]
		c2x := c1x + a[2];   c2y := c1y + a[3]
		ex  := c2x + a[4];   ey  := c2y
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
		c1x = s.x + a[5];    c1y = c2y
		c2x = c1x + a[6];    c2y = c1y + a[7]
		ex  = c2x + a[8];    ey  = y0
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
	case 37: // flex1: the last point returns to the start in whichever
		 // direction moved least, so only one delta is given for it
		if s.sp < 11 { return }
		a := s.stack[:]
		dx := a[0] + a[2] + a[4] + a[6] + a[8]
		dy := a[1] + a[3] + a[5] + a[7] + a[9]
		c1x := s.x + a[0];   c1y := s.y + a[1]
		c2x := c1x + a[2];   c2y := c1y + a[3]
		ex  := c2x + a[4];   ey  := c2y + a[5]
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
		c1x = s.x + a[6];    c1y = s.y + a[7]
		c2x = c1x + a[8];    c2y = c1y + a[9]
		if abs(dx) > abs(dy) {
			ex = c2x + a[10]; ey = y0
		} else {
			ex = x0;          ey = c2y + a[10]
		}
		emit_cubic(s, c1x, c1y, c2x, c2y, ex, ey)
		s.x, s.y = ex, ey
	}
}

@(private)
apply_op :: proc(s: ^Cs_State, op: u8) -> bool {
	// Strip the leading width operand on the first stack-clearing
	// operator. Type 2 puts an optional width as the first value.
	switch op {
	case 21:                                          // rmoveto
		strip_width(s, 2)
		if s.sp < 2 { return false }
		dx := s.stack[s.sp - 2]; dy := s.stack[s.sp - 1]
		close_contour(s)
		s.x += dx; s.y += dy
		open_contour(s)
		s.sp = 0
	case 22:                                          // hmoveto
		strip_width(s, 1)
		if s.sp < 1 { return false }
		close_contour(s)
		s.x += s.stack[s.sp - 1]
		open_contour(s)
		s.sp = 0
	case 4:                                           // vmoveto
		strip_width(s, 1)
		if s.sp < 1 { return false }
		close_contour(s)
		s.y += s.stack[s.sp - 1]
		open_contour(s)
		s.sp = 0
	case 5:                                           // rlineto — pairs
		k := 0
		for k + 2 <= s.sp {
			s.x += s.stack[k]; s.y += s.stack[k + 1]
			emit_point(s, s.x, s.y)
			k += 2
		}
		s.sp = 0
	case 6:                                           // hlineto — alternating h/v
		k := 0
		for k < s.sp {
			s.x += s.stack[k]; k += 1
			emit_point(s, s.x, s.y)
			if k >= s.sp { break }
			s.y += s.stack[k]; k += 1
			emit_point(s, s.x, s.y)
		}
		s.sp = 0
	case 7:                                           // vlineto — alternating v/h
		k := 0
		for k < s.sp {
			s.y += s.stack[k]; k += 1
			emit_point(s, s.x, s.y)
			if k >= s.sp { break }
			s.x += s.stack[k]; k += 1
			emit_point(s, s.x, s.y)
		}
		s.sp = 0
	case 8:                                           // rrcurveto — triples of 2-tuples
		k := 0
		for k + 6 <= s.sp {
			cx1 := s.x + s.stack[k];   cy1 := s.y + s.stack[k + 1]
			cx2 := cx1 + s.stack[k + 2]; cy2 := cy1 + s.stack[k + 3]
			ex  := cx2 + s.stack[k + 4]; ey  := cy2 + s.stack[k + 5]
			emit_cubic(s, cx1, cy1, cx2, cy2, ex, ey)
			s.x = ex; s.y = ey
			k += 6
		}
		s.sp = 0
	case 24:                                          // rcurveline: N rrcurves then one rline
		k := 0
		for k + 6 <= s.sp - 2 {
			cx1 := s.x + s.stack[k];     cy1 := s.y + s.stack[k + 1]
			cx2 := cx1 + s.stack[k + 2]; cy2 := cy1 + s.stack[k + 3]
			ex  := cx2 + s.stack[k + 4]; ey  := cy2 + s.stack[k + 5]
			emit_cubic(s, cx1, cy1, cx2, cy2, ex, ey)
			s.x = ex; s.y = ey
			k += 6
		}
		if k + 2 == s.sp {
			s.x += s.stack[k]; s.y += s.stack[k + 1]
			emit_point(s, s.x, s.y)
		}
		s.sp = 0
	case 25:                                          // rlinecurve: N rlines then one rrcurve
		k := 0
		for k + 2 <= s.sp - 6 {
			s.x += s.stack[k]; s.y += s.stack[k + 1]
			emit_point(s, s.x, s.y)
			k += 2
		}
		if k + 6 == s.sp {
			cx1 := s.x + s.stack[k];     cy1 := s.y + s.stack[k + 1]
			cx2 := cx1 + s.stack[k + 2]; cy2 := cy1 + s.stack[k + 3]
			ex  := cx2 + s.stack[k + 4]; ey  := cy2 + s.stack[k + 5]
			emit_cubic(s, cx1, cy1, cx2, cy2, ex, ey)
			s.x = ex; s.y = ey
		}
		s.sp = 0
	case 26:                                          // vvcurveto
		k := 0
		dx1: f32 = 0
		if s.sp & 1 == 1 { dx1 = s.stack[0]; k = 1 }
		for k + 4 <= s.sp {
			cx1 := s.x + dx1;          cy1 := s.y + s.stack[k]
			cx2 := cx1 + s.stack[k + 1]; cy2 := cy1 + s.stack[k + 2]
			ex  := cx2;                  ey  := cy2 + s.stack[k + 3]
			emit_cubic(s, cx1, cy1, cx2, cy2, ex, ey)
			s.x = ex; s.y = ey
			dx1 = 0
			k += 4
		}
		s.sp = 0
	case 27:                                          // hhcurveto
		k := 0
		dy1: f32 = 0
		if s.sp & 1 == 1 { dy1 = s.stack[0]; k = 1 }
		for k + 4 <= s.sp {
			cx1 := s.x + s.stack[k];   cy1 := s.y + dy1
			cx2 := cx1 + s.stack[k + 1]; cy2 := cy1 + s.stack[k + 2]
			ex  := cx2 + s.stack[k + 3]; ey  := cy2
			emit_cubic(s, cx1, cy1, cx2, cy2, ex, ey)
			s.x = ex; s.y = ey
			dy1 = 0
			k += 4
		}
		s.sp = 0
	case 30:                                          // vhcurveto — alternating v/h
		k := 0
		for k + 4 <= s.sp {
			cx1 := s.x;                cy1 := s.y + s.stack[k]
			cx2 := cx1 + s.stack[k + 1]; cy2 := cy1 + s.stack[k + 2]
			ex  := cx2 + s.stack[k + 3]
			ey  := cy2
			if k + 5 == s.sp { ey += s.stack[k + 4] }
			emit_cubic(s, cx1, cy1, cx2, cy2, ex, ey)
			s.x = ex; s.y = ey
			k += 4
			if k + 4 > s.sp { break }
			cx1b := s.x + s.stack[k];     cy1b := s.y
			cx2b := cx1b + s.stack[k + 1]; cy2b := cy1b + s.stack[k + 2]
			exb  := cx2b
			eyb  := cy2b + s.stack[k + 3]
			if k + 5 == s.sp { exb += s.stack[k + 4] }
			emit_cubic(s, cx1b, cy1b, cx2b, cy2b, exb, eyb)
			s.x = exb; s.y = eyb
			k += 4
		}
		s.sp = 0
	case 31:                                          // hvcurveto — alternating h/v
		k := 0
		for k + 4 <= s.sp {
			cx1 := s.x + s.stack[k];   cy1 := s.y
			cx2 := cx1 + s.stack[k + 1]; cy2 := cy1 + s.stack[k + 2]
			ex  := cx2
			ey  := cy2 + s.stack[k + 3]
			if k + 5 == s.sp { ex += s.stack[k + 4] }
			emit_cubic(s, cx1, cy1, cx2, cy2, ex, ey)
			s.x = ex; s.y = ey
			k += 4
			if k + 4 > s.sp { break }
			cx1b := s.x;                cy1b := s.y + s.stack[k]
			cx2b := cx1b + s.stack[k + 1]; cy2b := cy1b + s.stack[k + 2]
			exb  := cx2b + s.stack[k + 3]
			eyb  := cy2b
			if k + 5 == s.sp { eyb += s.stack[k + 4] }
			emit_cubic(s, cx1b, cy1b, cx2b, cy2b, exb, eyb)
			s.x = exb; s.y = eyb
			k += 4
		}
		s.sp = 0
	case 1, 3, 18, 23:                                // hstem / vstem / hstemhm / vstemhm
		// Hinting — count pairs and discard.
		strip_width(s, 0)                              // even-count operand → no width
		s.stem_count += s.sp / 2
		s.sp = 0
	case 19, 20:                                      // hintmask / cntrmask
		// Implicit vstem before mask if values remain on stack.
		strip_width(s, 0)
		s.stem_count += s.sp / 2
		s.sp = 0
	}
	return true
}

// strip_width consumes the leading width operand (if present) on the
// stack before the first move/stem op of a glyph. Width on stack iff
// odd-count remaining for stem ops, or one-more-than-needed for moves.
@(private)
strip_width :: proc(s: ^Cs_State, expected: int) {
	if s.first_move { return }
	if s.sp == expected + 1 {
		// Skip the leading width by shifting down.
		for i in 0..<expected {
			s.stack[i] = s.stack[i + 1]
		}
		s.sp = expected
	}
	s.first_move = true
}

@(private)
open_contour :: proc(s: ^Cs_State) {
	s.contour_open = true
	s.contour_start_idx = len(s.out.points)
	emit_point(s, s.x, s.y)
}

@(private)
close_contour :: proc(s: ^Cs_State) {
	if !s.contour_open { return }
	if len(s.out.points) > s.contour_start_idx {
		append(&s.out.contour_ends, u16(len(s.out.points) - 1))
	}
	s.contour_open = false
}

@(private)
emit_point :: proc(s: ^Cs_State, x, y: f32) {
	append(&s.out.points, Outline_Point{x = i32(x), y = i32(y), on_curve = true})
	xi := i16_sat(x)
	yi := i16_sat(y)
	if !s.bbox_init {
		s.x_min = xi; s.y_min = yi; s.x_max = xi; s.y_max = yi
		s.bbox_init = true
	} else {
		if xi < s.x_min { s.x_min = xi }
		if yi < s.y_min { s.y_min = yi }
		if xi > s.x_max { s.x_max = xi }
		if yi > s.y_max { s.y_max = yi }
	}
}

@(private)
emit_cubic :: proc(s: ^Cs_State, c1x, c1y, c2x, c2y, ex, ey: f32) {
	flatten_cubic(s, s.x, s.y, c1x, c1y, c2x, c2y, ex, ey, 0)
}

@(private)
flatten_cubic :: proc(s: ^Cs_State, p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y: f32, depth: int) {
	// Recursive de Casteljau subdivision until the chord deviation
	// drops below the flatness tolerance. Depth cap to avoid
	// pathological inputs.
	if depth > 16 {
		emit_point(s, p3x, p3y)
		return
	}
	mid_chord_x := (p0x + p3x) * 0.5
	mid_chord_y := (p0y + p3y) * 0.5
	// Check both control-point deviations from the chord midpoint.
	d1x := p1x - mid_chord_x; d1y := p1y - mid_chord_y
	d2x := p2x - mid_chord_x; d2y := p2y - mid_chord_y
	if d1x * d1x + d1y * d1y <= CUBIC_FLATNESS * CUBIC_FLATNESS &&
	   d2x * d2x + d2y * d2y <= CUBIC_FLATNESS * CUBIC_FLATNESS {
		emit_point(s, p3x, p3y)
		return
	}
	q0x := (p0x + p1x) * 0.5;   q0y := (p0y + p1y) * 0.5
	q1x := (p1x + p2x) * 0.5;   q1y := (p1y + p2y) * 0.5
	q2x := (p2x + p3x) * 0.5;   q2y := (p2y + p3y) * 0.5
	r0x := (q0x + q1x) * 0.5;   r0y := (q0y + q1y) * 0.5
	r1x := (q1x + q2x) * 0.5;   r1y := (q1y + q2y) * 0.5
	mx  := (r0x + r1x) * 0.5;   my  := (r0y + r1y) * 0.5

	flatten_cubic(s, p0x, p0y, q0x, q0y, r0x, r0y, mx,  my,  depth + 1)
	flatten_cubic(s, mx,  my,  r1x, r1y, q2x, q2y, p3x, p3y, depth + 1)
}

@(private)
i16_sat :: #force_inline proc(v: f32) -> i16 {
	if v >  32767 { return  32767 }
	if v < -32768 { return -32768 }
	return i16(v)
}
