package skald

import "core:math"
import vk "vendor:vulkan"

// Vertex is one corner of a batched primitive. Every vertex of a primitive
// carries the same center, half_size, radius, kind, and (for textured paths)
// UV so the fragment shader can branch on `kind` to choose between:
//
//   kind=0 — rounded-box SDF
//   kind=1 — glyph: sample the bound R8Unorm atlas as coverage
//   kind=2 — image: sample the bound RGBA texture and modulate by color
//
// Which texture "bound" means depends on the range's bind group — the
// default bind group points at the glyph atlas; image draws swap in a
// per-image bind group whose texture slot holds that image's texture.
//
// Memory cost is ~56 bytes per vertex; we accept it to keep the batched draw
// path a single indexed draw call no matter what mix of rects, text, and
// images the frame contains (modulo one extra call per image for the bind-
// group swap).
@(private)
Vertex :: struct {
	pos:       [2]f32,
	color:     [4]f32,
	center:    [2]f32,
	half_size: [2]f32,
	radius:    f32,
	kind:      f32, // 0 = SDF, 1 = glyph (R8 alpha), 2 = image (RGBA modulate)
	uv:        [2]f32,
}

// Batch_Range is a slice of the index buffer that shares a single scissor
// rectangle and descriptor set. frame_end issues one DrawIndexed per
// non-empty range in order; push_clip/pop_clip start new ranges, and each
// image draw brackets itself in its own range so binding 1 points at that
// image's texture for the duration of its draw.
//
// `index_start` is absolute into batch.indices; count is derived as the
// start of the next range (or total index count for the last range).
// `bind_group == 0` means "use the pipeline's default descriptor set" (the
// one pointing at the glyph atlas). A non-zero override is used as-is.
@(private)
Batch_Range :: struct {
	clip:        [4]u32, // x, y, w, h in framebuffer pixels
	index_start: u32,
	bind_group:  vk.DescriptorSet,
}

// Batch collects draw calls produced during one frame. Flushed to the GPU
// in `frame_end` as a sequence of DrawIndexed calls — one per clip range —
// all feeding from the same vertex/index buffers.
//
// `clip_stack` holds pending clip rects in f32 so intersections stay clean;
// they're converted to integer scissor at range-open time.
@(private)
Batch :: struct {
	vertices:   [dynamic]Vertex,
	indices:    [dynamic]u32,
	ranges:     [dynamic]Batch_Range,
	clip_stack: [dynamic]Rect,
}

// draw_rect queues a rectangle for this frame. radius is the corner radius
// in pixels; radius=0 produces a sharp rectangle (still anti-aliased on
// the outer edge for free, courtesy of the SDF fragment shader).
//
// The rect is in pixel coordinates with origin at the window's top-left;
// w and h extend right and down. Colors must be linear (use `rgb` / `rgba`
// for sRGB hex).
//
// Calls are cheap — they append to CPU-side buffers. The actual GPU draw
// happens once in `frame_end`.
draw_rect :: proc(r: ^Renderer, rect: Rect, color: Color, radius: f32 = 0) {
	center    := [2]f32{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
	half_size := [2]f32{rect.w * 0.5,          rect.h * 0.5}
	// Clamp radius so it never exceeds the shorter half-extent — otherwise
	// the SDF degenerates into a pill or worse.
	rr := min(radius, min(half_size.x, half_size.y))

	col := color
	col[3] *= r.alpha_multiplier
	base := u32(len(r.batch.vertices))
	v := Vertex{color = col, center = center, half_size = half_size, radius = rr}

	v.pos = {rect.x,          rect.y         }; append(&r.batch.vertices, v)
	v.pos = {rect.x + rect.w, rect.y         }; append(&r.batch.vertices, v)
	v.pos = {rect.x + rect.w, rect.y + rect.h}; append(&r.batch.vertices, v)
	v.pos = {rect.x,          rect.y + rect.h}; append(&r.batch.vertices, v)

	append(&r.batch.indices,
		base + 0, base + 1, base + 2,
		base + 0, base + 2, base + 3,
	)
}

// draw_shadow queues a soft SDF shadow for `rect`. The shadow extends
// `blur` pixels beyond the rect in every direction with a quadratic
// falloff, starting at full `color.a` at the rect edge and fading to 0
// at blur distance. `radius` should match the corner radius of the
// widget casting the shadow so the shadow hugs its silhouette.
//
// Used by the overlay pipeline (render_overlays) to lift every popover
// — dropdowns, date / time / color pickers, menus, dialogs — above the
// page. Callers can also invoke it directly for bespoke depth effects;
// it's cheap (one quad) and batches with the rest of the frame.
draw_shadow :: proc(
	r:      ^Renderer,
	rect:   Rect,
	radius: f32,
	blur:   f32,
	color:  Color,
	offset: [2]f32 = {0, 4},
) {
	if blur <= 0 { return }
	// Offset the shadow source rect — positive y pushes the shadow down,
	// matching light-from-above convention.
	sx := rect.x + offset.x
	sy := rect.y + offset.y
	center    := [2]f32{sx + rect.w * 0.5, sy + rect.h * 0.5}
	half_size := [2]f32{rect.w * 0.5,       rect.h * 0.5}
	rr        := min(radius, min(half_size.x, half_size.y))

	// The quad itself must extend by `blur` in each direction so the
	// fragment shader has room to fade from opaque (inside the source
	// rect) to zero (at the blur edge).
	qx := sx - blur
	qy := sy - blur
	qw := rect.w + 2*blur
	qh := rect.h + 2*blur

	col := color
	col[3] *= r.alpha_multiplier
	base := u32(len(r.batch.vertices))
	v := Vertex{
		color     = col,
		center    = center,
		half_size = half_size,
		radius    = rr,
		kind      = 4,
		uv        = {blur, 0},
	}
	v.pos = {qx,      qy     }; append(&r.batch.vertices, v)
	v.pos = {qx + qw, qy     }; append(&r.batch.vertices, v)
	v.pos = {qx + qw, qy + qh}; append(&r.batch.vertices, v)
	v.pos = {qx,      qy + qh}; append(&r.batch.vertices, v)

	append(&r.batch.indices,
		base + 0, base + 1, base + 2,
		base + 0, base + 2, base + 3,
	)
}

// draw_gradient_rect queues a rectangle whose four corners carry independent
// colors — the fragment shader's per-vertex color interpolation gives us a
// bilinear gradient for free. Useful for the color picker's saturation/value
// square (TL=white, TR=hue, BL=BR=black) and hue strip segments.
//
// Corner order: top-left, top-right, bottom-right, bottom-left. Same SDF
// path as `draw_rect`, so rounded corners and edge AA still work.
draw_gradient_rect :: proc(
	r:      ^Renderer,
	rect:   Rect,
	c_tl, c_tr, c_br, c_bl: Color,
	radius: f32 = 0,
) {
	center    := [2]f32{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
	half_size := [2]f32{rect.w * 0.5,          rect.h * 0.5}
	rr := min(radius, min(half_size.x, half_size.y))

	tl := c_tl; tl[3] *= r.alpha_multiplier
	tr := c_tr; tr[3] *= r.alpha_multiplier
	br := c_br; br[3] *= r.alpha_multiplier
	bl := c_bl; bl[3] *= r.alpha_multiplier
	base := u32(len(r.batch.vertices))
	v := Vertex{center = center, half_size = half_size, radius = rr}

	v.pos = {rect.x,          rect.y         }; v.color = tl; append(&r.batch.vertices, v)
	v.pos = {rect.x + rect.w, rect.y         }; v.color = tr; append(&r.batch.vertices, v)
	v.pos = {rect.x + rect.w, rect.y + rect.h}; v.color = br; append(&r.batch.vertices, v)
	v.pos = {rect.x,          rect.y + rect.h}; v.color = bl; append(&r.batch.vertices, v)

	append(&r.batch.indices,
		base + 0, base + 1, base + 2,
		base + 0, base + 2, base + 3,
	)
}

// batch_push_glyph appends a textured quad sampling the glyph atlas. Used
// internally by `draw_text`. The quad carries kind=1 so the fragment shader
// takes the atlas-sampling branch.
@(private)
batch_push_glyph :: proc(r: ^Renderer, x0, y0, x1, y1, s0, t0, s1, t1: f32, color: Color) {
	col := color
	col[3] *= r.alpha_multiplier
	base := u32(len(r.batch.vertices))
	v := Vertex{color = col, kind = 1}

	v.pos = {x0, y0}; v.uv = {s0, t0}; append(&r.batch.vertices, v)
	v.pos = {x1, y0}; v.uv = {s1, t0}; append(&r.batch.vertices, v)
	v.pos = {x1, y1}; v.uv = {s1, t1}; append(&r.batch.vertices, v)
	v.pos = {x0, y1}; v.uv = {s0, t1}; append(&r.batch.vertices, v)

	append(&r.batch.indices,
		base + 0, base + 1, base + 2,
		base + 0, base + 2, base + 3,
	)
}

// batch_push_image appends a textured RGBA quad that samples from the
// caller-supplied descriptor set. Brackets the quad in its own
// Batch_Range so the descriptor swap (binding 1 → this image's texture
// view) is scoped: subsequent shape/text draws land in a fresh
// default-descriptor range opened at the end. `pos` is the destination
// rect in framebuffer pixels; `uv` is `{u0, v0, u1, v1}` so callers can
// pass a sub-region of the texture (e.g. for Cover-fit crop). `tint`
// modulates the sampled color — pass `{1, 1, 1, 1}` for no tint.
@(private)
batch_push_image :: proc(
	r:         ^Renderer,
	bind_group: vk.DescriptorSet,
	pos:        Rect,
	uv:         [4]f32,
	tint:       Color,
) {
	// Current clip intersection. Mirrors clip_open_range's behavior so the
	// image honors any active push_clip without us tracking clip state here.
	current_clip: Rect
	if len(r.batch.clip_stack) > 0 {
		current_clip = r.batch.clip_stack[len(r.batch.clip_stack) - 1]
	} else {
		current_clip = Rect{0, 0, f32(r.fb_size.x), f32(r.fb_size.y)}
	}
	scissor := rect_to_scissor(current_clip, r.fb_size_px, r.scale)

	// Open an image-dedicated range. If the current range is still empty
	// (no draws since it opened) we rewrite it in place so we don't leave
	// a zero-count range for frame_end to skip.
	n := len(r.batch.ranges)
	if n > 0 && r.batch.ranges[n - 1].index_start == u32(len(r.batch.indices)) {
		r.batch.ranges[n - 1].clip       = scissor
		r.batch.ranges[n - 1].bind_group = bind_group
	} else {
		append(&r.batch.ranges, Batch_Range{
			clip        = scissor,
			index_start = u32(len(r.batch.indices)),
			bind_group  = bind_group,
		})
	}

	t := tint
	t[3] *= r.alpha_multiplier
	base := u32(len(r.batch.vertices))
	v := Vertex{color = t, kind = 2}
	v.pos = {pos.x,         pos.y        }; v.uv = {uv[0], uv[1]}; append(&r.batch.vertices, v)
	v.pos = {pos.x + pos.w, pos.y        }; v.uv = {uv[2], uv[1]}; append(&r.batch.vertices, v)
	v.pos = {pos.x + pos.w, pos.y + pos.h}; v.uv = {uv[2], uv[3]}; append(&r.batch.vertices, v)
	v.pos = {pos.x,         pos.y + pos.h}; v.uv = {uv[0], uv[3]}; append(&r.batch.vertices, v)

	append(&r.batch.indices,
		base + 0, base + 1, base + 2,
		base + 0, base + 2, base + 3,
	)

	// Re-open a default-bind-group range so subsequent shape/text draws
	// don't inherit the image's bind group. Inherits the same clip —
	// the caller hasn't changed it.
	append(&r.batch.ranges, Batch_Range{
		clip        = scissor,
		index_start = u32(len(r.batch.indices)),
	})
}

// draw_triangles queues a list of triangles as solid-color geometry
// (shader kind=3 — no SDF, no texture, just vertex color). `verts` is a
// flat list of triangle corners: every three consecutive points form
// one triangle. No winding requirement (the pipeline has no face
// culling), so callers don't have to match CCW or CW order.
//
// This is the low-level primitive behind `draw_stroke` and any
// custom-brush code that wants to emit geometry directly. Prefer the
// higher-level helper unless you need bespoke tessellation.
draw_triangles :: proc(r: ^Renderer, verts: [][2]f32, color: Color) {
	n := len(verts)
	if n < 3 { return }

	base := u32(len(r.batch.vertices))
	v := Vertex{color = color, kind = 3}
	for p in verts {
		v.pos = p
		append(&r.batch.vertices, v)
	}

	// One triangle per 3 consecutive verts. Truncate a stray 1-2 leftovers
	// rather than reading out of bounds.
	tri_count := n / 3
	for i in 0 ..< tri_count {
		idx := u32(i * 3)
		append(&r.batch.indices, base + idx, base + idx + 1, base + idx + 2)
	}
}

// draw_triangle_strip queues a strip-ordered vertex list: triangles are
// formed from each consecutive triple (v[i], v[i+1], v[i+2]) for i in
// 0..N-3. Equivalent to GL's TRIANGLE_STRIP topology but expanded into
// TriangleList so it shares the pipeline with every other primitive.
//
// Uses shader kind=3 (solid vertex color). Needs at least 3 vertices.
// Caller typically builds a ribbon — left/right edge vertices
// alternating — and passes it here. For strokes, `draw_stroke` does
// the ribbon math for you.
draw_triangle_strip :: proc(r: ^Renderer, verts: [][2]f32, color: Color) {
	n := len(verts)
	if n < 3 { return }

	base := u32(len(r.batch.vertices))
	v := Vertex{color = color, kind = 3}
	for p in verts {
		v.pos = p
		append(&r.batch.vertices, v)
	}

	// One triangle per consecutive triple, index-expanded so the list
	// topology produces the same geometry a strip would.
	for i in 0 ..< n - 2 {
		append(&r.batch.indices, base + u32(i), base + u32(i + 1), base + u32(i + 2))
	}
}

// Stroke_Sample is one point along a stylus (or mouse) path: position
// in pixel coordinates plus a 0..1 pressure value. `draw_stroke`
// consumes a slice of these to produce a filled ribbon whose width at
// sample i is `base_width * pressure_i`.
Stroke_Sample :: struct {
	pos:      [2]f32,
	pressure: f32,
}

// draw_stroke renders a pressure-varying filled polyline as a triangle
// ribbon. Width at sample i is `base_width * clamp(pressure_i, 0, 1)`.
// Endpoints are flat (no end caps) — circular caps and round joins are
// deferred until there's a showcase app asking for them. Zero-length or
// single-sample inputs draw nothing.
//
// Ribbon math: for each sample, the perpendicular to the local tangent
// direction is used to emit a left/right vertex pair. Interior samples
// use the averaged direction of the adjacent segments so corners stay
// continuous; endpoints use the single adjacent segment. This produces
// a single triangle strip with no duplicated vertices and no
// pipeline / pass changes.
//
// Allocates on `context.temp_allocator` — the ribbon vertices live as
// long as the frame arena, which matches the render pass's lifetime
// exactly.
draw_stroke :: proc(r: ^Renderer, samples: []Stroke_Sample,
                    base_width: f32, color: Color) {
	n := len(samples)
	if n < 2 || base_width <= 0 { return }

	verts := make([dynamic][2]f32, 0, n * 2, context.temp_allocator)

	// Previous perpendicular direction, carried between samples. When a
	// segment is too short to trust (duplicate points, sub-pixel jitter)
	// we re-use the previous perp instead of falling back to a fixed
	// axis — that's what was causing the ribbon to flip 90° at low
	// pen velocity and produce horn-shaped spikes in the render.
	prev_px:  f32 = 0
	prev_py:  f32 = -1 // points "up" in a y-down coord space
	have_prev: bool = false

	unit_seg :: proc(a, b: [2]f32) -> (dx, dy: f32, ok: bool) {
		dx = b.x - a.x
		dy = b.y - a.y
		mag := math.sqrt(dx * dx + dy * dy)
		if mag < 1e-6 { return 0, 0, false }
		return dx / mag, dy / mag, true
	}

	for i in 0 ..< n {
		s := samples[i]
		half_w := base_width * clamp(s.pressure, 0, 1) * 0.5
		if half_w <= 0 { half_w = 0.5 }

		// Average the unit-length segment directions going in and out
		// of this sample. Unit vectors bound the sum to [0, 2] so two
		// nearly opposite segments (hairpin) cancel to a small vector
		// and we fall back to the previous perp rather than producing
		// a wildly-rotated one.
		in_dx,  in_dy,  has_in  := f32(0), f32(0), false
		out_dx, out_dy, has_out := f32(0), f32(0), false
		if i > 0     { in_dx,  in_dy,  has_in  = unit_seg(samples[i - 1].pos, s.pos) }
		if i < n - 1 { out_dx, out_dy, has_out = unit_seg(s.pos, samples[i + 1].pos) }

		dx, dy: f32
		ok := false
		if has_in && has_out {
			dx = (in_dx  + out_dx) * 0.5
			dy = (in_dy  + out_dy) * 0.5
			mag := math.sqrt(dx * dx + dy * dy)
			if mag > 1e-3 {
				dx /= mag; dy /= mag; ok = true
			}
		}
		if !ok && has_in  { dx, dy, ok = in_dx,  in_dy,  true  }
		if !ok && has_out { dx, dy, ok = out_dx, out_dy, true  }

		px, py: f32
		if ok {
			// Rotate 90° clockwise for framebuffer y-down space.
			px, py =  dy, -dx
			prev_px, prev_py = px, py
			have_prev = true
		} else if have_prev {
			px, py = prev_px, prev_py
		} else {
			px, py = 0, -1
		}

		append(&verts, [2]f32{s.pos.x + px * half_w, s.pos.y + py * half_w}) // right
		append(&verts, [2]f32{s.pos.x - px * half_w, s.pos.y - py * half_w}) // left
	}

	draw_triangle_strip(r, verts[:], color)
}

@(private)
batch_reset :: proc(b: ^Batch) {
	clear(&b.vertices)
	clear(&b.indices)
	clear(&b.ranges)
	clear(&b.clip_stack)
}

@(private)
batch_destroy :: proc(b: ^Batch) {
	delete(b.vertices)
	delete(b.indices)
	delete(b.ranges)
	delete(b.clip_stack)
}
