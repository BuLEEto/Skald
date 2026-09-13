package parse

import "core:math"

// glyf — Glyph Data.
//
// Holds the outline definition for every TrueType-flavoured glyph as a
// sequence of contours; each contour is a closed loop of points where
// each point is on- or off-curve. The on/off pattern encodes quadratic
// Bézier curves:
//
//   on  -> on             : straight line
//   on  -> off -> on      : quadratic curve with one off-curve control
//   on  -> off -> off     : two off-curve points imply an implicit
//                           on-curve point at their midpoint
//
// A glyph header may also encode a "composite" — a recursive assembly
// of other glyphs with optional transforms. Composite glyphs are
// expanded lazily into the same point/contour buffer during outline
// extraction.
//
// CFF (PostScript) outlines live in a separate table; this module only
// handles TrueType-flavoured fonts.
//
// References: OpenType spec, "glyf — Glyph Data".

// Glyph_Flag — simple-glyph point flag bits.
GLYF_ON_CURVE       :: u8(0x01)
GLYF_X_SHORT        :: u8(0x02)
GLYF_Y_SHORT        :: u8(0x04)
GLYF_REPEAT         :: u8(0x08)
GLYF_X_SAME_OR_POS  :: u8(0x10)
GLYF_Y_SAME_OR_POS  :: u8(0x20)
GLYF_OVERLAP_SIMPLE :: u8(0x40)

// Component_Flag — composite-glyph flag bits.
COMP_ARG_1_AND_2_ARE_WORDS    :: u16(0x0001)
COMP_ARGS_ARE_XY_VALUES       :: u16(0x0002)
COMP_ROUND_XY_TO_GRID         :: u16(0x0004)
COMP_WE_HAVE_A_SCALE          :: u16(0x0008)
COMP_MORE_COMPONENTS          :: u16(0x0020)
COMP_WE_HAVE_AN_X_AND_Y_SCALE :: u16(0x0040)
COMP_WE_HAVE_A_TWO_BY_TWO     :: u16(0x0080)
COMP_WE_HAVE_INSTRUCTIONS     :: u16(0x0100)
COMP_USE_MY_METRICS           :: u16(0x0200)
COMP_OVERLAP_COMPOUND         :: u16(0x0400)
COMP_SCALED_COMPONENT_OFFSET  :: u16(0x0800)
COMP_UNSCALED_COMPONENT_OFFSET :: u16(0x1000)

// Maximum legal composite recursion depth — the spec mandates 16. A
// deeper chain is either malformed or maliciously crafted.
COMPOSITE_MAX_DEPTH :: 16

// Outline_Point holds one point of an outline. Coordinates are in font
// units (raw values from the file), promoted to i32 so composite
// transforms can apply without overflow.
Outline_Point :: struct {
	x, y:     i32,
	on_curve: bool,
}

// Outline is the parsed shape of one glyph. `points` holds every point
// from every contour, packed contiguously. `contour_ends` gives the
// index of the *last* point in each contour — contour i runs from
// `contour_ends[i-1]+1` (or 0 for the first) through `contour_ends[i]`,
// inclusive.
Outline :: struct {
	points:       [dynamic]Outline_Point,
	contour_ends: [dynamic]u16,
	x_min, y_min: i16,
	x_max, y_max: i16,
}

outline_destroy :: proc(o: ^Outline) {
	delete(o.points)
	delete(o.contour_ends)
	o^ = {}
}

// Glyf wraps the raw `glyf` table bytes. Outline extraction reads from
// here on demand; the table is otherwise untouched.
Glyf :: struct {
	data: []u8,
}

new_glyf :: proc(data: []u8) -> Glyf {
	return Glyf{data = data}
}

// glyf_outline materialises glyph `gid`'s outline into `out`. The caller
// owns `out` and may reuse it across calls to amortise allocations —
// existing contents are cleared but the backing arrays are kept.
//
// Empty glyphs (zero-length `loca` range, or `numberOfContours == 0`)
// return with `out.points` and `out.contour_ends` cleared and no error.
glyf_outline :: proc(g: ^Glyf, loca: ^Loca, gid: Glyph_ID, out: ^Outline) -> Error {
	clear(&out.points)
	clear(&out.contour_ends)
	out.x_min, out.y_min, out.x_max, out.y_max = 0, 0, 0, 0
	return glyf_outline_impl(g, loca, gid, out, 0)
}

@(private)
glyf_outline_impl :: proc(g: ^Glyf, loca: ^Loca, gid: Glyph_ID, out: ^Outline, depth: int) -> Error {
	if depth > COMPOSITE_MAX_DEPTH { return .Invalid_Table }

	start, length, ok := loca_glyph_range(loca, gid)
	if !ok { return .Glyph_Not_Found }
	if length == 0 { return .None }                            // empty glyph (e.g. space)

	if u64(start) + u64(length) > u64(len(g.data)) { return .Invalid_Table }
	glyph_data := g.data[start:start + length]

	r := Reader{data = glyph_data}
	num_contours := read_i16(&r) or_return
	x_min := read_i16(&r) or_return
	y_min := read_i16(&r) or_return
	x_max := read_i16(&r) or_return
	y_max := read_i16(&r) or_return
	if depth == 0 {
		out.x_min, out.y_min, out.x_max, out.y_max = x_min, y_min, x_max, y_max
	}

	if num_contours > 0 {
		return parse_simple_glyph(&r, int(num_contours), out)
	}
	if num_contours == -1 {
		return parse_composite_glyph(g, loca, &r, out, depth)
	}
	// num_contours == 0 means empty glyph header but with bounds; nothing
	// to add to the outline.
	return .None
}

// ---- Simple glyphs --------------------------------------------------

@(private)
parse_simple_glyph :: proc(r: ^Reader, num_contours: int, out: ^Outline) -> Error {
	// Note where this component's points start so the contour-end
	// indices we append are scoped to this component (composites later
	// concatenate multiple components into one Outline; each component's
	// endpoints must be biased by the running point count).
	base_point := len(out.points)

	end_pts_start := len(out.contour_ends)
	for i in 0..<num_contours {
		ep := read_u16(r) or_return
		append(&out.contour_ends, ep + u16(base_point))
	}
	// num_points = endPtsOfContours[last] - base_point + 1
	last_end := out.contour_ends[end_pts_start + num_contours - 1]
	num_points := int(last_end) - base_point + 1
	if num_points <= 0 || num_points > 65535 { return .Invalid_Table }

	instr_len := read_u16(r) or_return
	skip(r, int(instr_len)) or_return        // TrueType bytecode — ignored

	// ---- Flags --------------------------------------------------------
	// Pre-grow points so the on-curve flag and coordinate writes can land
	// directly. The flag pass also produces the per-point flag byte we
	// need for the coordinate passes.
	flags_scratch := make([]u8, num_points, context.temp_allocator)
	if flags_scratch == nil { return .Out_Of_Memory }

	i := 0
	for i < num_points {
		f := read_u8(r) or_return
		flags_scratch[i] = f
		i += 1
		if f & GLYF_REPEAT != 0 {
			n := read_u8(r) or_return
			if i + int(n) > num_points { return .Invalid_Table }
			for k in 0..<int(n) {
				flags_scratch[i + k] = f
			}
			i += int(n)
		}
	}

	// Pre-extend points; we'll fill x and y next.
	resize(&out.points, base_point + num_points)
	for k in 0..<num_points {
		out.points[base_point + k].on_curve = (flags_scratch[k] & GLYF_ON_CURVE) != 0
	}

	// ---- X coordinates -----------------------------------------------
	xacc: i32 = 0
	for k in 0..<num_points {
		f := flags_scratch[k]
		dx: i32 = 0
		switch {
		case f & GLYF_X_SHORT != 0:
			b := read_u8(r) or_return
			if f & GLYF_X_SAME_OR_POS != 0 {
				dx = i32(b)
			} else {
				dx = -i32(b)
			}
		case f & GLYF_X_SAME_OR_POS != 0:
			dx = 0
		case:
			v := read_i16(r) or_return
			dx = i32(v)
		}
		xacc += dx
		out.points[base_point + k].x = xacc
	}

	// ---- Y coordinates -----------------------------------------------
	yacc: i32 = 0
	for k in 0..<num_points {
		f := flags_scratch[k]
		dy: i32 = 0
		switch {
		case f & GLYF_Y_SHORT != 0:
			b := read_u8(r) or_return
			if f & GLYF_Y_SAME_OR_POS != 0 {
				dy = i32(b)
			} else {
				dy = -i32(b)
			}
		case f & GLYF_Y_SAME_OR_POS != 0:
			dy = 0
		case:
			v := read_i16(r) or_return
			dy = i32(v)
		}
		yacc += dy
		out.points[base_point + k].y = yacc
	}

	return .None
}

// ---- Composite glyphs -----------------------------------------------

// Component is one record of a composite glyph: the referenced glyph, its
// offset (font units), and its 2×2 transform.
Component :: struct {
	gid:            Glyph_ID,
	dx, dy:         i32,
	xx, xy, yx, yy: f32,
	flags:          u16,
}

// read_component parses one composite record; `more` says another follows.
@(private)
read_component :: proc(r: ^Reader) -> (c: Component, more: bool, err: Error) {
	flags := read_u16(r) or_return
	gid   := read_u16(r) or_return
	c.flags = flags
	c.gid = Glyph_ID(gid)
	args_words := (flags & COMP_ARG_1_AND_2_ARE_WORDS) != 0
	args_xy    := (flags & COMP_ARGS_ARE_XY_VALUES) != 0
	if !args_xy { return c, false, .Unsupported_Format }         // point-match attaches
	if args_words {
		a := read_i16(r) or_return
		b := read_i16(r) or_return
		c.dx, c.dy = i32(a), i32(b)
	} else {
		a := read_u8(r) or_return
		b := read_u8(r) or_return
		c.dx, c.dy = i32(i8(a)), i32(i8(b))
	}
	c.xx, c.yy = 1, 1
	if flags & COMP_WE_HAVE_A_SCALE != 0 {
		sc := read_i16(r) or_return
		c.xx = f2dot14(sc)
		c.yy = c.xx
	} else if flags & COMP_WE_HAVE_AN_X_AND_Y_SCALE != 0 {
		a := read_i16(r) or_return
		b := read_i16(r) or_return
		c.xx = f2dot14(a)
		c.yy = f2dot14(b)
	} else if flags & COMP_WE_HAVE_A_TWO_BY_TWO != 0 {
		a := read_i16(r) or_return
		b := read_i16(r) or_return
		cc := read_i16(r) or_return
		d := read_i16(r) or_return
		c.xx = f2dot14(a)
		c.xy = f2dot14(b)
		c.yx = f2dot14(cc)
		c.yy = f2dot14(d)
	}
	more = flags & COMP_MORE_COMPONENTS != 0
	return
}

// transform_points applies a component's 2×2 matrix and offset to the points
// appended since `first`.
@(private)
transform_points :: proc(out: ^Outline, first: int, c: Component) {
	for idx in first..<len(out.points) {
		pt := out.points[idx]
		tx := c.xx*f32(pt.x) + c.yx*f32(pt.y)
		ty := c.xy*f32(pt.x) + c.yy*f32(pt.y)
		out.points[idx].x = i32(tx) + c.dx
		out.points[idx].y = i32(ty) + c.dy
	}
}

@(private)
parse_composite_glyph :: proc(g: ^Glyf, loca: ^Loca, r: ^Reader, out: ^Outline, depth: int) -> Error {
	for {
		c, more := read_component(r) or_return
		first_added := len(out.points)
		glyf_outline_impl(g, loca, c.gid, out, depth + 1) or_return
		transform_points(out, first_added, c)
		if !more { break }
	}
	return .None
}

// ---- Variable glyphs --------------------------------------------------

// glyf_outline_var is glyf_outline with gvar deltas applied at
// `axis_values` (normalised, one per axis). Simple glyphs get their own
// point deltas (with interpolation of untouched points); a composite glyph's
// deltas move its component offsets, and each component is varied on its
// own before being placed — the spec's model, and the reason a flattened
// composite cannot be varied after the fact.
glyf_outline_var :: proc(g: ^Glyf, loca: ^Loca, gv: ^Gvar, axis_values: []f32, gid: Glyph_ID, out: ^Outline) -> Error {
	clear(&out.points)
	clear(&out.contour_ends)
	out.x_min, out.y_min, out.x_max, out.y_max = 0, 0, 0, 0
	return glyf_outline_var_impl(g, loca, gv, axis_values, gid, out, 0)
}

@(private)
glyf_outline_var_impl :: proc(g: ^Glyf, loca: ^Loca, gv: ^Gvar, axis_values: []f32, gid: Glyph_ID, out: ^Outline, depth: int) -> Error {
	if depth > COMPOSITE_MAX_DEPTH { return .Invalid_Table }
	start, length, ok := loca_glyph_range(loca, gid)
	if !ok { return .Glyph_Not_Found }
	if length == 0 { return .None }
	if u64(start) + u64(length) > u64(len(g.data)) { return .Invalid_Table }
	r := Reader{data = g.data[start:start + length]}
	num_contours := read_i16(&r) or_return
	x_min := read_i16(&r) or_return
	y_min := read_i16(&r) or_return
	x_max := read_i16(&r) or_return
	y_max := read_i16(&r) or_return
	if depth == 0 {
		out.x_min, out.y_min, out.x_max, out.y_max = x_min, y_min, x_max, y_max
	}

	if num_contours > 0 {
		base  := len(out.points)
		cbase := len(out.contour_ends)
		parse_simple_glyph(&r, int(num_contours), out) or_return
		pts := out.points[base:]
		ends := make([]u16, len(out.contour_ends) - cbase, context.temp_allocator)
		for i in 0..<len(ends) { ends[i] = out.contour_ends[cbase + i] - u16(base) }
		dx, dy := gvar_point_deltas(gv, gid, axis_values, pts, ends, len(pts)) or_return
		for i in 0..<len(pts) {
			pts[i].x += i32(math.round(dx[i]))
			pts[i].y += i32(math.round(dy[i]))
		}
		return .None
	}
	if num_contours == -1 {
		comps := make([dynamic]Component, 0, 4, context.temp_allocator)
		for {
			c, more := read_component(&r) or_return
			append(&comps, c)
			if !more { break }
		}
		dx, dy := gvar_point_deltas(gv, gid, axis_values, nil, nil, len(comps)) or_return
		for &c, i in comps {
			c.dx += i32(math.round(dx[i]))
			c.dy += i32(math.round(dy[i]))
		}
		for c in comps {
			first_added := len(out.points)
			glyf_outline_var_impl(g, loca, gv, axis_values, c.gid, out, depth + 1) or_return
			transform_points(out, first_added, c)
		}
	}
	return .None
}

@(private)
f2dot14 :: #force_inline proc(v: i16) -> f32 {
	return f32(v) / 16384.0
}
