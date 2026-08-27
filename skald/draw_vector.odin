package skald

import "core:math"

// Higher-level vector primitives layered on the batch's triangle path
// (draw_triangles / draw_tris_vc / draw_stroke). Everything here is
// convenience geometry — a canvas author could tessellate these by hand,
// but they're the shapes every custom widget ends up wanting (lines,
// circles, arcs, wires, filled polygons) so we ship them once.
//
// Coordinates are logical pixels, origin top-left, y down — the same space
// as every other draw_* proc and as `Canvas_Painter.bounds`.
//
// `aa`: the open/stroked procs forward it to draw_stroke's feathered-edge
// path; the filled/closed procs add their own 1px alpha-0 fringe via
// draw_tris_vc. Opt-in, off by default, matching draw_stroke — a solid
// fill without AA stays a plain triangle list.

// ---- small vector helpers -------------------------------------------------

@(private = "file")
v2norm :: proc(v: [2]f32) -> [2]f32 {
	m := math.sqrt(v.x * v.x + v.y * v.y)
	if m < 1e-6 { return {0, 0} }
	return {v.x / m, v.y / m}
}

@(private = "file")
cross2 :: proc(a, b: [2]f32) -> f32 { return a.x * b.y - a.y * b.x }

@(private = "file")
v2dist :: proc(a, b: [2]f32) -> f32 {
	d := b - a
	return math.sqrt(d.x * d.x + d.y * d.y)
}

// arc_segments picks a segment count so an arc of the given radius/sweep
// stays visually smooth without over-tessellating tiny circles: roughly one
// segment per 6px of arc length, clamped to a sane range.
@(private = "file")
arc_segments :: proc(radius, sweep: f32) -> int {
	length := abs(sweep) * max(radius, 0.5)
	n := int(math.ceil(length / 6))
	return clamp(n, 2, 512)
}

// ---- open / stroked primitives (reuse draw_stroke) ------------------------

// draw_line strokes a straight segment from `a` to `b`, `width` px thick,
// centred on the line. A zero-length line draws nothing meaningful.
draw_line :: proc(r: ^Renderer, a, b: [2]f32, width: f32, color: Color, aa := false) {
	if width <= 0 { return }
	s := [2]Stroke_Sample{{pos = a, pressure = 1}, {pos = b, pressure = 1}}
	draw_stroke(r, s[:], width, color, aa)
}

// draw_polyline strokes a connected, constant-width path through `points`
// (joins handled by draw_stroke). It's the plain-line counterpart to
// draw_stroke, which takes per-point pressure. Needs at least two points.
draw_polyline :: proc(r: ^Renderer, points: [][2]f32, width: f32, color: Color, aa := false) {
	if len(points) < 2 || width <= 0 { return }
	s := make([]Stroke_Sample, len(points), context.temp_allocator)
	for p, i in points { s[i] = {pos = p, pressure = 1} }
	draw_stroke(r, s[:], width, color, aa)
}

// draw_arc strokes a circular arc of `radius` about `center`, from angle
// `a0` to `a1` (radians). Angle 0 is +x; increasing angle sweeps clockwise
// on screen (y is down). A full ring is `draw_ring`; this is the open form
// for gauges, knobs, and progress arcs.
draw_arc :: proc(
	r: ^Renderer, center: [2]f32, radius, a0, a1, width: f32, color: Color, aa := false,
) {
	if radius <= 0 || width <= 0 { return }
	sweep := a1 - a0
	n := arc_segments(radius, sweep)
	s := make([]Stroke_Sample, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		a := a0 + sweep * f32(i) / f32(n)
		s[i] = {pos = center + {math.cos(a) * radius, math.sin(a) * radius}, pressure = 1}
	}
	draw_stroke(r, s[:], width, color, aa)
}

// draw_bezier strokes a cubic Bézier through control points p0..p3, flattened
// to a polyline. The classic node-editor wire is a cubic with horizontal
// tangents at the two endpoints.
draw_bezier :: proc(
	r: ^Renderer, p0, p1, p2, p3: [2]f32, width: f32, color: Color, aa := false,
) {
	if width <= 0 { return }
	// Segment count from the control-polygon length — longer/curvier curves
	// get more segments.
	spread := v2dist(p0, p1) + v2dist(p1, p2) + v2dist(p2, p3)
	n := clamp(int(math.ceil(spread / 6)), 4, 256)
	pts := make([][2]f32, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		pts[i] = u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
	}
	draw_polyline(r, pts, width, color, aa)
}

// draw_bezier_quad strokes a quadratic Bézier (single control point p1).
draw_bezier_quad :: proc(
	r: ^Renderer, p0, p1, p2: [2]f32, width: f32, color: Color, aa := false,
) {
	if width <= 0 { return }
	spread := v2dist(p0, p1) + v2dist(p1, p2)
	n := clamp(int(math.ceil(spread / 6)), 4, 256)
	pts := make([][2]f32, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		pts[i] = u * u * p0 + 2 * u * t * p1 + t * t * p2
	}
	draw_polyline(r, pts, width, color, aa)
}

// ---- filled disc ----------------------------------------------------------

// draw_circle fills a disc of `radius` about `center` (triangle fan). With
// `aa` it adds a 1px feathered rim so the edge isn't stair-stepped.
draw_circle :: proc(r: ^Renderer, center: [2]f32, radius: f32, color: Color, aa := false) {
	if radius <= 0 { return }
	n := arc_segments(radius, 2 * math.PI)
	rim := make([][2]f32, n, context.temp_allocator)
	for i in 0 ..< n {
		a := 2 * math.PI * f32(i) / f32(n)
		rim[i] = center + {math.cos(a) * radius, math.sin(a) * radius}
	}
	if !aa {
		verts := make([dynamic][2]f32, 0, n * 3, context.temp_allocator)
		for i in 0 ..< n {
			j := (i + 1) % n
			append(&verts, center, rim[i], rim[j])
		}
		draw_triangles(r, verts[:], color)
		return
	}
	core := [4]f32{color.r, color.g, color.b, color.a}
	edge := [4]f32{color.r, color.g, color.b, 0}
	// Feathered rim one pixel past the fill radius.
	out := make([][2]f32, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = center + v2norm(rim[i] - center) * (radius + 1)
	}
	vp := make([dynamic][2]f32, 0, n * 9, context.temp_allocator)
	vc := make([dynamic][4]f32, 0, n * 9, context.temp_allocator)
	for i in 0 ..< n {
		j := (i + 1) % n
		append(&vp, center, rim[i], rim[j]);   append(&vc, core, core, core)
		append(&vp, rim[i], rim[j], out[j]);   append(&vc, core, core, edge)
		append(&vp, rim[i], out[j], out[i]);   append(&vc, core, edge, edge)
	}
	draw_tris_vc(r, vp[:], vc[:])
}

// ---- closed ribbons: ring + rect outline ----------------------------------

// fill_ribbon_loop strokes a *closed* centreline `path` into a ribbon of
// half-width `half`, mitring each vertex so the loop joins cleanly at the
// seam (unlike an open draw_stroke, whose endpoints are flat caps). Used by
// draw_ring and draw_rect_outline.
@(private = "file")
fill_ribbon_loop :: proc(r: ^Renderer, path: [][2]f32, half: f32, color: Color, aa: bool) {
	n := len(path)
	if n < 3 || half <= 0 { return }
	inner := make([][2]f32, n, context.temp_allocator)
	outer := make([][2]f32, n, context.temp_allocator)
	mdir  := make([][2]f32, n, context.temp_allocator) // unit outward miter dir
	for i in 0 ..< n {
		prev := path[(i - 1 + n) % n]
		cur  := path[i]
		nxt  := path[(i + 1) % n]
		d0 := v2norm(cur - prev)
		d1 := v2norm(nxt - cur)
		n0 := [2]f32{-d0.y, d0.x}
		n1 := [2]f32{-d1.y, d1.x}
		m := v2norm(n0 + n1)
		// Miter length = half / cos(theta/2); clamp so sharp corners don't spike.
		denom := m.x * n1.x + m.y * n1.y
		scale: f32 = denom > 0.2 ? 1 / denom : 1
		if scale > 4 { scale = 4 }
		mm := m * (half * scale)
		outer[i] = cur + mm
		inner[i] = cur - mm
		mdir[i]  = m
	}
	if !aa {
		verts := make([dynamic][2]f32, 0, n * 6, context.temp_allocator)
		for i in 0 ..< n {
			j := (i + 1) % n
			append(&verts, outer[i], outer[j], inner[j])
			append(&verts, outer[i], inner[j], inner[i])
		}
		draw_triangles(r, verts[:], color)
		return
	}
	core := [4]f32{color.r, color.g, color.b, color.a}
	edge := [4]f32{color.r, color.g, color.b, 0}
	vp := make([dynamic][2]f32, 0, n * 18, context.temp_allocator)
	vc := make([dynamic][4]f32, 0, n * 18, context.temp_allocator)
	for i in 0 ..< n {
		j := (i + 1) % n
		append(&vp, outer[i], outer[j], inner[j]); append(&vc, core, core, core)
		append(&vp, outer[i], inner[j], inner[i]); append(&vc, core, core, core)
		ofi := outer[i] + mdir[i]; ofj := outer[j] + mdir[j]
		append(&vp, outer[i], outer[j], ofj); append(&vc, core, core, edge)
		append(&vp, outer[i], ofj, ofi);      append(&vc, core, edge, edge)
		ifi := inner[i] - mdir[i]; ifj := inner[j] - mdir[j]
		append(&vp, inner[i], inner[j], ifj); append(&vc, core, core, edge)
		append(&vp, inner[i], ifj, ifi);      append(&vc, core, edge, edge)
	}
	draw_tris_vc(r, vp[:], vc[:])
}

// draw_ring strokes a circle outline of `radius`, `width` px thick, centred
// on the perimeter.
draw_ring :: proc(
	r: ^Renderer, center: [2]f32, radius, width: f32, color: Color, aa := false,
) {
	if radius <= 0 || width <= 0 { return }
	n := arc_segments(radius, 2 * math.PI)
	path := make([][2]f32, n, context.temp_allocator)
	for i in 0 ..< n {
		a := 2 * math.PI * f32(i) / f32(n)
		path[i] = center + {math.cos(a) * radius, math.sin(a) * radius}
	}
	fill_ribbon_loop(r, path, width * 0.5, color, aa)
}

@(private = "file")
rr_corner :: proc(out: ^[dynamic][2]f32, cx, cy, a0, a1, rr: f32, k: int) {
	for i in 0 ..= k {
		a := a0 + (a1 - a0) * f32(i) / f32(k)
		append(out, [2]f32{cx + math.cos(a) * rr, cy + math.sin(a) * rr})
	}
}

// rounded_rect_path returns the closed centreline of a (optionally rounded)
// rectangle, wound clockwise. radius 0 gives the four corners.
@(private = "file")
rounded_rect_path :: proc(rect: Rect, radius: f32) -> [][2]f32 {
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	rr := min(radius, min(w, h) * 0.5)
	if rr <= 0 {
		p := make([][2]f32, 4, context.temp_allocator)
		p[0] = {x, y}; p[1] = {x + w, y}; p[2] = {x + w, y + h}; p[3] = {x, y + h}
		return p
	}
	k := clamp(int(math.ceil(rr / 3)), 2, 32)
	out := make([dynamic][2]f32, 0, (k + 1) * 4, context.temp_allocator)
	rr_corner(&out, x + w - rr, y + rr,     -math.PI * 0.5, 0,             rr, k) // top → right
	rr_corner(&out, x + w - rr, y + h - rr, 0,              math.PI * 0.5, rr, k) // right → bottom
	rr_corner(&out, x + rr,     y + h - rr, math.PI * 0.5,  math.PI,       rr, k) // bottom → left
	rr_corner(&out, x + rr,     y + rr,     math.PI,        math.PI * 1.5, rr, k) // left → top
	return out[:]
}

// draw_rect_outline strokes a rectangle outline (optionally rounded), `width`
// px thick, centred on the edge. The go-to for node/selection borders.
draw_rect_outline :: proc(
	r: ^Renderer, rect: Rect, width: f32, color: Color, radius: f32 = 0, aa := false,
) {
	if width <= 0 { return }
	path := rounded_rect_path(rect, radius)
	fill_ribbon_loop(r, path, width * 0.5, color, aa)
}

// ---- filled polygon (ear clipping) ----------------------------------------

@(private = "file")
point_in_tri :: proc(p, a, b, c: [2]f32) -> bool {
	d1 := cross2(b - a, p - a)
	d2 := cross2(c - b, p - b)
	d3 := cross2(a - c, p - c)
	neg := d1 < 0 || d2 < 0 || d3 < 0
	pos := d1 > 0 || d2 > 0 || d3 > 0
	return !(neg && pos)
}

// draw_polygon fills any simple (non-self-intersecting) polygon by ear
// clipping — convex or concave, either winding. With `aa` it feathers the
// boundary edges. Self-intersecting outlines are not supported.
draw_polygon :: proc(r: ^Renderer, points: [][2]f32, color: Color, aa := false) {
	n := len(points)
	if n < 3 { return }

	// Signed area fixes the winding: work on a positively-wound index list so
	// the convex test (cross > 0) is unambiguous.
	area2: f32 = 0
	for i in 0 ..< n {
		j := (i + 1) % n
		area2 += points[i].x * points[j].y - points[j].x * points[i].y
	}
	idx := make([dynamic]int, 0, n, context.temp_allocator)
	if area2 >= 0 {
		for i in 0 ..< n { append(&idx, i) }
	} else {
		for i := n - 1; i >= 0; i -= 1 { append(&idx, i) }
	}

	tri := make([dynamic][2]f32, 0, (n - 2) * 3, context.temp_allocator)
	guard := 0
	for len(idx) > 3 {
		guard += 1
		if guard > n * n { break } // degenerate / self-intersecting: bail
		m := len(idx)
		ear := false
		for k in 0 ..< m {
			i0 := idx[(k - 1 + m) % m]
			i1 := idx[k]
			i2 := idx[(k + 1) % m]
			a := points[i0]; b := points[i1]; c := points[i2]
			if cross2(b - a, c - b) <= 0 { continue } // reflex vertex
			inside := false
			for kk in 0 ..< m {
				vi := idx[kk]
				if vi == i0 || vi == i1 || vi == i2 { continue }
				if point_in_tri(points[vi], a, b, c) { inside = true; break }
			}
			if inside { continue }
			append(&tri, a, b, c)
			ordered_remove(&idx, k)
			ear = true
			break
		}
		if !ear { break }
	}
	if len(idx) == 3 {
		append(&tri, points[idx[0]], points[idx[1]], points[idx[2]])
	}

	if !aa {
		draw_triangles(r, tri[:], color)
		return
	}
	core := [4]f32{color.r, color.g, color.b, color.a}
	edge := [4]f32{color.r, color.g, color.b, 0}
	vp := make([dynamic][2]f32, 0, len(tri) + n * 6, context.temp_allocator)
	vc := make([dynamic][4]f32, 0, len(tri) + n * 6, context.temp_allocator)
	for p in tri { append(&vp, p); append(&vc, core) }
	// Outward-normal feather along each boundary edge; sign follows the
	// original winding so it always pushes away from the interior.
	s: f32 = area2 >= 0 ? 1 : -1
	for i in 0 ..< n {
		j := (i + 1) % n
		a := points[i]; b := points[j]
		d := v2norm(b - a)
		nrm := s * [2]f32{d.y, -d.x}
		ao := a + nrm; bo := b + nrm
		append(&vp, a, b, bo); append(&vc, core, core, edge)
		append(&vp, a, bo, ao); append(&vc, core, edge, edge)
	}
	draw_tris_vc(r, vp[:], vc[:])
}
