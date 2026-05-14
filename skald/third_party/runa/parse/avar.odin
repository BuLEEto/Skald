package parse

// avar — Axis Variations Table.
//
// Optional companion to `fvar`. Each axis can have a piecewise-linear
// curve that remaps the linearly-normalised user value (−1, 0, +1)
// into a "perceptual" coordinate the `gvar` deltas were authored
// against. Inter, for example, uses avar on `wght` so visual weight
// progression looks even across 100..900.
//
// avar is mandatory for correct variable-font rendering — without
// it, weight targets land at the wrong perceptual position on fonts
// that ship the table.
//
// References: OpenType spec, "avar — Axis Variations Table".

AVAR_VERSION_1_0 :: u32(0x00010000)

Avar :: struct {
	// `segment_maps[axis_index]` is the sorted-by-from list of
	// (from, to) F2DOT14 pairs for that axis. axis_index matches
	// the corresponding fvar axis ordering.
	segment_maps: [][]Avar_Segment,
}

Avar_Segment :: struct {
	from, to: f32,                   // both in normalised [-1, +1] space
}

parse_avar :: proc(data: []u8, allocator := context.allocator) -> (a: Avar, err: Error) {
	r := Reader{data = data}

	version := read_u32(&r) or_return
	if version != AVAR_VERSION_1_0 { err = .Unsupported_Format; return }

	skip(&r, 2) or_return                    // reserved (= 0)
	axis_count := read_u16(&r) or_return

	maps := make([][]Avar_Segment, axis_count, allocator)
	if maps == nil && axis_count > 0 { err = .Out_Of_Memory; return }

	for i in 0..<int(axis_count) {
		n, e := read_u16(&r); if e != .None {
			avar_destroy_partial(maps[:i], allocator)
			err = e
			return
		}
		segs := make([]Avar_Segment, n, allocator)
		if segs == nil && n > 0 {
			avar_destroy_partial(maps[:i], allocator)
			err = .Out_Of_Memory
			return
		}
		for j in 0..<int(n) {
			from_raw, e1 := read_i16(&r); if e1 != .None {
				delete(segs, allocator); avar_destroy_partial(maps[:i], allocator)
				err = e1; return
			}
			to_raw, e2 := read_i16(&r); if e2 != .None {
				delete(segs, allocator); avar_destroy_partial(maps[:i], allocator)
				err = e2; return
			}
			segs[j] = Avar_Segment{from = f2_14(from_raw), to = f2_14(to_raw)}
		}
		maps[i] = segs
	}
	a.segment_maps = maps
	return
}

avar_destroy :: proc(a: ^Avar, allocator := context.allocator) {
	for segs in a.segment_maps {
		delete(segs, allocator)
	}
	delete(a.segment_maps, allocator)
	a^ = {}
}

@(private)
avar_destroy_partial :: proc(maps: [][]Avar_Segment, allocator: mem.Allocator) {
	for segs in maps { delete(segs, allocator) }
}

// avar_apply remaps `normalised` (in [-1, +1]) through axis
// `axis_index`'s segment map and returns the result. If the axis
// has no segment map (or only the identity 3-point [-1, 0, +1]
// map), the value passes through unchanged.
avar_apply :: proc(a: ^Avar, axis_index: int, normalised: f32) -> f32 {
	if axis_index < 0 || axis_index >= len(a.segment_maps) { return normalised }
	segs := a.segment_maps[axis_index]
	if len(segs) < 2 { return normalised }

	// Walk to find the bracketing segment. Maps are sorted by `from`.
	if normalised <= segs[0].from { return segs[0].to }
	for i in 1..<len(segs) {
		if normalised <= segs[i].from {
			lo := segs[i - 1]
			hi := segs[i]
			span := hi.from - lo.from
			if span <= 0 { return hi.to }
			t := (normalised - lo.from) / span
			return lo.to + t * (hi.to - lo.to)
		}
	}
	return segs[len(segs) - 1].to
}

@(private)
f2_14 :: #force_inline proc(raw: i16) -> f32 {
	return f32(raw) / 16384.0
}

// mem import for the allocator parameter on the destroy helper.
import "core:mem"
