package parse

import "core:math"

// gvar — Glyph Variations Table.
//
// For each glyph that varies along one or more axes, gvar carries a
// list of *tuple variations*. Each tuple defines:
//
//   - a peak in normalised axis space (e.g. wght = +1.0 corresponds
//     to the heaviest weight),
//   - optional intermediate start/end coords for asymmetric ramps,
//   - a list of affected point indices (or "all points"),
//   - per-point x and y delta values.
//
// At render time, for a caller-chosen axis tuple, we compute a scalar
// weight per tuple variation (product of per-axis 1-D weights) and
// accumulate `weight × delta` into the base outline's point
// positions.
//
// `gvar` works against the glyf-table outlines we already extract;
// `apply_glyph_variations` mutates the `Outline.points` slice
// in-place after a `glyf_outline` call.
//
// References: OpenType spec, "gvar — Glyph Variations Table".

GVAR_VERSION_1_0 :: u32(0x00010000)

GVAR_FLAG_LONG_OFFSETS :: u16(0x0001)

// Tuple variation header flags.
TUPLE_EMBEDDED_PEAK   :: u16(0x8000)
TUPLE_INTERMEDIATE    :: u16(0x4000)
TUPLE_PRIVATE_POINTS  :: u16(0x2000)
TUPLE_INDEX_MASK      :: u16(0x0FFF)

Gvar :: struct {
	data:                []u8,
	axis_count:          u16,
	shared_tuples_off:   u32,
	shared_tuple_count:  u16,
	glyph_offsets:       []u32,        // per-glyph offset into glyph_data section, length glyph_count + 1
	glyph_data_off:      u32,
}

parse_gvar :: proc(data: []u8, allocator := context.allocator) -> (g: Gvar, err: Error) {
	r := Reader{data = data}
	version := read_u32(&r) or_return
	if version != GVAR_VERSION_1_0 { err = .Unsupported_Format; return }

	axis_count          := read_u16(&r) or_return
	shared_tuple_count  := read_u16(&r) or_return
	shared_tuples_off   := read_u32(&r) or_return
	glyph_count         := read_u16(&r) or_return
	flags               := read_u16(&r) or_return
	glyph_data_off      := read_u32(&r) or_return

	long_offsets := flags & GVAR_FLAG_LONG_OFFSETS != 0

	// Per-glyph offsets follow the header. Promote 16-bit offsets
	// (×2 per spec) to u32 so the rest of the code works on one type.
	offs := make([]u32, glyph_count + 1, allocator)
	if offs == nil && glyph_count > 0 { err = .Out_Of_Memory; return }
	if long_offsets {
		for i in 0..<int(glyph_count) + 1 {
			v, e := read_u32(&r); if e != .None { delete(offs, allocator); err = e; return }
			offs[i] = v
		}
	} else {
		for i in 0..<int(glyph_count) + 1 {
			v, e := read_u16(&r); if e != .None { delete(offs, allocator); err = e; return }
			offs[i] = u32(v) * 2
		}
	}

	g = Gvar{
		data               = data,
		axis_count         = axis_count,
		shared_tuples_off  = shared_tuples_off,
		shared_tuple_count = shared_tuple_count,
		glyph_offsets      = offs,
		glyph_data_off     = glyph_data_off,
	}
	return
}

gvar_destroy :: proc(g: ^Gvar, allocator := context.allocator) {
	delete(g.glyph_offsets, allocator)
	g^ = {}
}

// apply_glyph_variations adds this glyph's gvar deltas to a SIMPLE glyph's
// outline points (all of `outline.points` belong to `gid`). Composite glyphs
// must go through glyf_outline_var, whose deltas move component offsets.
// Kept for callers that already flattened a simple glyph.
apply_glyph_variations :: proc(g: ^Gvar, gid: Glyph_ID, axis_values: []f32, outline: ^Outline) -> Error {
	dx, dy := gvar_point_deltas(g, gid, axis_values, outline.points[:], outline.contour_ends[:], len(outline.points)) or_return
	for i in 0..<len(outline.points) {
		outline.points[i].x += i32(math.round(dx[i]))
		outline.points[i].y += i32(math.round(dy[i]))
	}
	return .None
}

// gvar_point_deltas accumulates the weighted variation deltas of every
// tuple of `gid` at `axis_values`, per point, in font units. The result has
// `n_points + 4` entries: the glyph's own points (a simple glyph's outline
// points, or a composite's component offsets) followed by the four phantom
// points. `ref` / `contour_ends` are the unvaried points and contour ends of
// a simple glyph, used to interpolate untouched points (IUP) for tuples that
// carry sparse point lists; pass nil for a composite (no interpolation).
// Slices are allocated with `allocator` (temp by default). Malformed data
// returns `.Invalid_Table`.
gvar_point_deltas :: proc(g: ^Gvar, gid: Glyph_ID, axis_values: []f32, ref: []Outline_Point, contour_ends: []u16, n_points: int, allocator := context.temp_allocator) -> (dx, dy: []f32, err: Error) {
	total := n_points + 4
	dx = make([]f32, total, allocator)
	dy = make([]f32, total, allocator)
	if int(gid) + 1 >= len(g.glyph_offsets) { return }
	if len(axis_values) != int(g.axis_count) { return dx, dy, .Invalid_Table }

	start := g.glyph_data_off + g.glyph_offsets[gid]
	end   := g.glyph_data_off + g.glyph_offsets[gid + 1]
	if end <= start { return }                       // no variation data
	if u64(end) > u64(len(g.data)) { return dx, dy, .Invalid_Table }

	glyph_data := g.data[start:end]
	r := Reader{data = glyph_data}

	tvc_raw, e1 := read_u16(&r); if e1 != .None { return dx, dy, e1 }
	data_off, e2 := read_u16(&r); if e2 != .None { return dx, dy, e2 }
	tuple_count    := tvc_raw & TUPLE_INDEX_MASK
	has_shared_pts := tvc_raw & 0x8000 != 0

	if int(data_off) > len(glyph_data) { return dx, dy, .Invalid_Table }
	serialised := glyph_data[data_off:]
	serial_cursor := 0

	shared_points: []u16
	if has_shared_pts {
		pts, consumed, ok := decode_packed_points(serialised, total)
		if !ok { return dx, dy, .Invalid_Table }
		shared_points = pts
		serial_cursor += consumed
	}

	axis_count := int(g.axis_count)
	peak   := make([]f32, axis_count, context.temp_allocator)
	istart := make([]f32, axis_count, context.temp_allocator)
	iend   := make([]f32, axis_count, context.temp_allocator)
	tdx := make([]f32, total, context.temp_allocator)
	tdy := make([]f32, total, context.temp_allocator)
	touched := make([]bool, total, context.temp_allocator)

	for _ in 0..<int(tuple_count) {
		var_data_size, e3 := read_u16(&r); if e3 != .None { return dx, dy, e3 }
		tuple_idx, e4     := read_u16(&r); if e4 != .None { return dx, dy, e4 }

		if tuple_idx & TUPLE_EMBEDDED_PEAK != 0 {
			for k in 0..<axis_count {
				v, e := read_i16(&r); if e != .None { return dx, dy, e }
				peak[k] = f32(v) / 16384.0
			}
		} else {
			si := int(tuple_idx & TUPLE_INDEX_MASK)
			if si >= int(g.shared_tuple_count) { return dx, dy, .Invalid_Table }
			base := g.shared_tuples_off + u32(si * axis_count * 2)
			if u64(base) + u64(axis_count * 2) > u64(len(g.data)) { return dx, dy, .Invalid_Table }
			for k in 0..<axis_count {
				pp := base + u32(k * 2)
				v := i16(u16(g.data[pp])<<8 | u16(g.data[pp + 1]))
				peak[k] = f32(v) / 16384.0
			}
		}

		has_intermediate := tuple_idx & TUPLE_INTERMEDIATE != 0
		if has_intermediate {
			for k in 0..<axis_count {
				v, e := read_i16(&r); if e != .None { return dx, dy, e }
				istart[k] = f32(v) / 16384.0
			}
			for k in 0..<axis_count {
				v, e := read_i16(&r); if e != .None { return dx, dy, e }
				iend[k] = f32(v) / 16384.0
			}
		}
		weight := compute_tuple_weight(peak, istart, iend, axis_values, has_intermediate)

		tuple_payload_end := serial_cursor + int(var_data_size)
		if tuple_payload_end > len(serialised) { return dx, dy, .Invalid_Table }
		payload := serialised[serial_cursor:tuple_payload_end]
		serial_cursor = tuple_payload_end

		pcursor := 0
		points: []u16
		if tuple_idx & TUPLE_PRIVATE_POINTS != 0 {
			pts, consumed, ok := decode_packed_points(payload, total)
			if !ok { return dx, dy, .Invalid_Table }
			points = pts
			pcursor = consumed
		} else {
			points = shared_points
		}
		applies_all := points == nil
		delta_count := applies_all ? total : len(points)

		dxs, dyc1, ok1 := decode_packed_deltas(payload[pcursor:], delta_count)
		if !ok1 { return dx, dy, .Invalid_Table }
		dys, _, ok2 := decode_packed_deltas(payload[pcursor + dyc1:], delta_count)
		if !ok2 { return dx, dy, .Invalid_Table }
		if weight == 0 { continue }

		if applies_all {
			n := min(len(dxs), total)
			for i in 0..<n {
				dx[i] += f32(dxs[i]) * weight
				dy[i] += f32(dys[i]) * weight
			}
			continue
		}
		// Sparse tuple: place the explicit deltas, interpolate the rest of
		// each contour (IUP), then accumulate.
		for i in 0..<total { tdx[i], tdy[i], touched[i] = 0, 0, false }
		for i in 0..<len(points) {
			pi := int(points[i])
			if pi >= total || i >= len(dxs) || i >= len(dys) { continue }
			tdx[pi], tdy[pi], touched[pi] = f32(dxs[i]), f32(dys[i]), true
		}
		if ref != nil { iup_contours(ref, contour_ends, tdx, tdy, touched) }
		for i in 0..<total {
			dx[i] += tdx[i] * weight
			dy[i] += tdy[i] * weight
		}
	}
	return
}

// iup_contours fills deltas for untouched points from their nearest touched
// neighbours along each contour, per the spec's "inferred deltas" rule.
@(private)
iup_contours :: proc(ref: []Outline_Point, contour_ends: []u16, tdx, tdy: []f32, touched: []bool) {
	start := 0
	for ce in contour_ends {
		end := min(int(ce), len(ref) - 1)
		if end < start { break }
		n_touched := 0
		first := -1
		for i in start..=end {
			if touched[i] {
				n_touched += 1
				if first < 0 { first = i }
			}
		}
		if n_touched == 0 || n_touched == end - start + 1 {
			start = end + 1
			continue
		}
		if n_touched == 1 {
			for i in start..=end { tdx[i], tdy[i] = tdx[first], tdy[first] }
			start = end + 1
			continue
		}
		for i in start..=end {
			if touched[i] { continue }
			p := i
			for {
				p -= 1
				if p < start { p = end }
				if touched[p] { break }
			}
			q := i
			for {
				q += 1
				if q > end { q = start }
				if touched[q] { break }
			}
			tdx[i] = iup_axis(f32(ref[p].x), f32(ref[q].x), f32(ref[i].x), tdx[p], tdx[q])
			tdy[i] = iup_axis(f32(ref[p].y), f32(ref[q].y), f32(ref[i].y), tdy[p], tdy[q])
		}
		start = end + 1
	}
}

@(private)
iup_axis :: proc(ra, rb, r, da, db: f32) -> f32 {
	if ra == rb { return da if da == db else 0 }
	lo_r, hi_r, lo_d, hi_d := ra, rb, da, db
	if lo_r > hi_r { lo_r, hi_r, lo_d, hi_d = rb, ra, db, da }
	if r <= lo_r { return lo_d }
	if r >= hi_r { return hi_d }
	return lo_d + (r - lo_r) * (hi_d - lo_d) / (hi_r - lo_r)
}

// compute_tuple_weight is the per-axis product from the OpenType spec
// section "Algorithm for interpolation of instances".
@(private)
compute_tuple_weight :: proc(peak, istart, iend, axis_values: []f32, has_intermediate: bool) -> f32 {
	weight: f32 = 1.0
	for k in 0..<len(axis_values) {
		v := axis_values[k]
		p := peak[k]
		if p == 0 { continue }                          // axis doesn't affect this tuple
		if v == 0 || (v < 0) != (p < 0) { return 0 }    // sign mismatch / default → no contribution
		axis_w: f32
		if !has_intermediate {
			if v == p { axis_w = 1 } else {
				if (p > 0 && v > p) || (p < 0 && v < p) {
					return 0
				}
				axis_w = v / p
			}
		} else {
			s := istart[k]
			e := iend[k]
			if v <= s || v >= e { return 0 }
			if v == p           { axis_w = 1 }
			else if v < p       { axis_w = (v - s) / (p - s) }
			else                { axis_w = (e - v) / (e - p) }
		}
		weight *= axis_w
	}
	return weight
}

// decode_packed_points returns the indexed point list. Returns
// (nil, 1, true) for the "all points" sentinel (first byte == 0).
// Allocates from `context.temp_allocator`.
@(private)
decode_packed_points :: proc(data: []u8, num_points: int) -> (pts: []u16, consumed: int, ok: bool) {
	if len(data) == 0 { return nil, 0, false }
	first := data[0]
	if first == 0 {
		// All points implied.
		return nil, 1, true
	}
	cursor := 1
	count: int
	if first & 0x80 != 0 {
		if cursor >= len(data) { return nil, 0, false }
		count = (int(first & 0x7F) << 8) | int(data[cursor])
		cursor += 1
	} else {
		count = int(first)
	}

	out := make([dynamic]u16, 0, count, context.temp_allocator)
	prev: u16 = 0
	for len(out) < count {
		if cursor >= len(data) { return nil, 0, false }
		control := data[cursor]
		cursor += 1
		run := int(control & 0x7F) + 1
		short := control & 0x80 == 0
		for i in 0..<run {
			if len(out) >= count { break }
			delta: u16
			if short {
				if cursor >= len(data) { return nil, 0, false }
				delta = u16(data[cursor])
				cursor += 1
			} else {
				if cursor + 1 >= len(data) { return nil, 0, false }
				delta = u16(data[cursor])<<8 | u16(data[cursor + 1])
				cursor += 2
			}
			prev += delta
			append(&out, prev)
		}
	}
	return out[:], cursor, true
}

// decode_packed_deltas reads `count` packed signed-integer deltas.
// Format: control byte (high 2 bits encode value format, low 6 bits
// encode run length − 1) followed by zero or more value bytes.
@(private)
decode_packed_deltas :: proc(data: []u8, count: int) -> (out: []i16, consumed: int, ok: bool) {
	values := make([dynamic]i16, 0, count, context.temp_allocator)
	cursor := 0
	for len(values) < count {
		if cursor >= len(data) { return nil, 0, false }
		control := data[cursor]
		cursor += 1
		run := int(control & 0x3F) + 1
		switch control & 0xC0 {
		case 0x80:                                   // zero run
			for i in 0..<run {
				if len(values) >= count { break }
				append(&values, i16(0))
			}
		case 0x40:                                   // 16-bit signed values
			for i in 0..<run {
				if len(values) >= count { break }
				if cursor + 1 >= len(data) { return nil, 0, false }
				v := i16(u16(data[cursor])<<8 | u16(data[cursor + 1]))
				cursor += 2
				append(&values, v)
			}
		case 0x00:                                   // 8-bit signed values
			for i in 0..<run {
				if len(values) >= count { break }
				if cursor >= len(data) { return nil, 0, false }
				v := i16(i8(data[cursor]))
				cursor += 1
				append(&values, v)
			}
		case:                                        // 0xC0 reserved
			return nil, 0, false
		}
	}
	return values[:], cursor, true
}
