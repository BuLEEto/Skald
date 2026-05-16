package raster

// color_brush.odin — COLRv1 brush-aware rasterizer.
//
// Reads `Colr_Brush_Layer`s (each glyph mask paired with a brush) and
// composites them into a single RGBA bitmap. Compared to the COLRv0
// path in `color.odin` this version evaluates colours per pixel for
// linear, radial, and sweep gradient brushes, in addition to flat
// solid fills.
//
// Geometry per kind:
//   - Linear: project the pixel centre onto the (p0, p1) axis and
//     pick the colour at parameter t in [0, 1].
//   - Radial: solve the quadratic (1-t)*c0 + t*c1 / (1-t)*r0 + t*r1
//     so the implied circle passes through the pixel. The smaller
//     non-negative root is the gradient parameter.
//   - Sweep: read the pixel's angle from the centre via atan2, map
//     to [start_angle, end_angle].
//
// The composite pipeline stays straight-alpha source-over for v0.9;
// 27-mode-aware blending lands alongside this in color_composite.odin.

import "../parse"
import "core:math"

// rasterize_colr_brush_layers composites every brush layer onto an
// RGBA bitmap. `layers` is in back-to-front order.
rasterize_colr_brush_layers :: proc(
	layers:       []parse.Colr_Brush_Layer,
	palette:      ^parse.Cpal,
	palette_idx:  u16,
	foreground:   [4]u8,
	glyf:         ^parse.Glyf,
	loca:         ^parse.Loca,
	units_per_em: u16,
	size:         f32,
	edges:        ^[dynamic]Edge,
	allocator := context.allocator,
) -> (bm: Color_Bitmap, x_offset, y_offset: int, err: Rast_Error) {

	if size <= 0 || units_per_em == 0 { err = .Invalid_Size; return }
	if len(layers) == 0 { return }

	Layer_Render :: struct {
		bitmap:         Bitmap,
		x_off, y_off:   int,
		brush:          parse.Colr_Brush,
		composite_mode: u8,
	}
	renders := make([dynamic]Layer_Render, 0, len(layers), context.temp_allocator)
	defer {
		for &r in renders { bitmap_destroy(&r.bitmap, allocator) }
	}

	outline := parse.Outline{}
	defer parse.outline_destroy(&outline)

	for lyr in layers {
		oerr := parse.glyf_outline(glyf, loca, lyr.glyph_id, &outline)
		if oerr != .None { continue }
		if len(outline.contour_ends) == 0 { continue }

		layer_bm, xo, yo, rerr := rasterize(&outline, units_per_em, size, edges, allocator = allocator)
		if rerr != .None { continue }
		if layer_bm.width == 0 || layer_bm.height == 0 {
			bitmap_destroy(&layer_bm, allocator)
			continue
		}
		append(&renders, Layer_Render{bitmap = layer_bm, x_off = xo, y_off = yo, brush = lyr.brush, composite_mode = lyr.composite_mode})
	}
	if len(renders) == 0 { return }

	// Union-bbox the layer placements.
	x_min, y_min := renders[0].x_off, renders[0].y_off
	x_max := renders[0].x_off + renders[0].bitmap.width
	y_max := renders[0].y_off + renders[0].bitmap.height
	for r in renders {
		if r.x_off                   < x_min { x_min = r.x_off }
		if r.y_off                   < y_min { y_min = r.y_off }
		if r.x_off + r.bitmap.width  > x_max { x_max = r.x_off + r.bitmap.width }
		if r.y_off + r.bitmap.height > y_max { y_max = r.y_off + r.bitmap.height }
	}
	width  := x_max - x_min
	height := y_max - y_min
	if width <= 0 || height <= 0 { return }

	canvas := make([]u8, width * height * 4, allocator)
	if canvas == nil { err = .Out_Of_Memory; return }
	bm = Color_Bitmap{width = width, height = height, pixels = canvas}
	x_offset, y_offset = x_min, y_min

	// Per-pixel scale from font-units to pixel space. Same convention
	// the analytic rasterizer uses: 1 design unit = (size / upem) px,
	// y axis flipped so y_off+height−1 is at the design-unit y_min.
	pixel_scale := f32(size) / f32(units_per_em)

	for &r in renders {
		dx := r.x_off - x_min
		dy := r.y_off - y_min

		// Pre-compute gradient parameters in pixel-space for fast
		// per-pixel evaluation. Each kind uses a different eval struct
		// because the math diverges (line projection / quadratic /
		// atan2); the shared piece is the layer-origin pixel-space
		// transform.
		linear: Linear_Eval
		radial: Radial_Eval
		sweep:  Sweep_Eval
		switch r.brush.kind {
		case .Linear: linear = init_linear_eval(r.brush, pixel_scale, r.x_off, r.y_off, r.bitmap.height)
		case .Radial: radial = init_radial_eval(r.brush, pixel_scale, r.x_off, r.y_off)
		case .Sweep:  sweep  = init_sweep_eval(r.brush,  pixel_scale, r.x_off, r.y_off)
		case .Solid:
		}

		for sy in 0..<r.bitmap.height {
			ty := dy + sy
			if ty < 0 || ty >= height { continue }
			for sx in 0..<r.bitmap.width {
				tx := dx + sx
				if tx < 0 || tx >= width { continue }
				mask := r.bitmap.pixels[sy * r.bitmap.width + sx]
				if mask == 0 { continue }

				// Resolve the brush colour for this pixel.
				color: [4]u8
				switch r.brush.kind {
				case .Linear:
					color = eval_linear(linear, &r.brush, palette, palette_idx, foreground, sx, sy)
				case .Radial:
					color = eval_radial(radial, &r.brush, palette, palette_idx, foreground, sx, sy)
				case .Sweep:
					color = eval_sweep(sweep, &r.brush, palette, palette_idx, foreground, sx, sy)
				case .Solid:
					color = solid_color(r.brush, palette, palette_idx, foreground)
				}

				idx := (ty * width + tx) * 4
				composite_pixel(canvas[idx:idx + 4], color, mask, r.brush, r.composite_mode)
			}
		}
	}
	return
}

// composite_pixel applies one COLRv1 composite mode over a single
// canvas pixel. All 28 spec'd modes are implemented:
//   - Porter–Duff: Clear, Src, Dest, SrcOver, DestOver, SrcIn,
//     DestIn, SrcOut, DestOut, SrcAtop, DestAtop, Xor.
//   - Mathematical separable blends: Plus, Screen, Overlay, Darken,
//     Lighten, ColorDodge, ColorBurn, HardLight, SoftLight,
//     Difference, Exclusion, Multiply.
//   - HSL non-separable: HSL-Hue, HSL-Saturation, HSL-Color,
//     HSL-Luminosity.
//
// The blend operations are evaluated in un-premultiplied RGBA, then
// composited with the destination using the standard alpha-aware
// W3C compositing formula:
//   out_a   = src_a + dst_a*(1 - src_a)
//   out_rgb = (1 - src_a/out_a)*dst_rgb + (src_a/out_a)*[blend(src,dst)]
// test_composite_pixel is the test-only entry into the otherwise-
// private compositor. Lets the raster test suite pin the blend math
// for the 28 spec'd modes without exposing the rest of the
// rasterizer internals.
test_composite_pixel :: proc(dst: []u8, color: [4]u8, mask: u8, mode: u8) {
	composite_pixel(dst, color, mask, parse.Colr_Brush{}, mode)
}

@(private)
composite_pixel :: proc(dst: []u8, color: [4]u8, mask: u8, b: parse.Colr_Brush, mode: u8) {
	src_a := f32(color[3]) * f32(mask) / (255.0 * 255.0)
	if mode == parse.COMPOSITE_CLEAR {
		dst[0] = 0; dst[1] = 0; dst[2] = 0; dst[3] = 0
		return
	}
	if src_a == 0 && mode != parse.COMPOSITE_DEST {
		return
	}
	sr := f32(color[0]) / 255.0
	sg := f32(color[1]) / 255.0
	sb := f32(color[2]) / 255.0
	dst_a := f32(dst[3]) / 255.0
	dr    := f32(dst[0]) / 255.0
	dg    := f32(dst[1]) / 255.0
	db    := f32(dst[2]) / 255.0

	out_a, or, og, ob: f32

	switch mode {
	// ---- Porter–Duff ----------------------------------------------
	case parse.COMPOSITE_SRC:
		out_a = src_a
		or, og, ob = sr, sg, sb
	case parse.COMPOSITE_DEST:
		return                                          // canvas unchanged
	case parse.COMPOSITE_SRC_OVER:
		out_a = src_a + dst_a * (1.0 - src_a)
		if out_a == 0 { return }
		or = (sr * src_a + dr * dst_a * (1.0 - src_a)) / out_a
		og = (sg * src_a + dg * dst_a * (1.0 - src_a)) / out_a
		ob = (sb * src_a + db * dst_a * (1.0 - src_a)) / out_a
	case parse.COMPOSITE_DEST_OVER:
		out_a = src_a + dst_a * (1.0 - src_a)
		if out_a == 0 { return }
		or = (dr * dst_a + sr * src_a * (1.0 - dst_a)) / out_a
		og = (dg * dst_a + sg * src_a * (1.0 - dst_a)) / out_a
		ob = (db * dst_a + sb * src_a * (1.0 - dst_a)) / out_a
	case parse.COMPOSITE_SRC_IN:
		out_a = src_a * dst_a
		or, og, ob = sr, sg, sb
	case parse.COMPOSITE_DEST_IN:
		out_a = src_a * dst_a
		or, og, ob = dr, dg, db
	case parse.COMPOSITE_SRC_OUT:
		out_a = src_a * (1.0 - dst_a)
		or, og, ob = sr, sg, sb
	case parse.COMPOSITE_DEST_OUT:
		out_a = dst_a * (1.0 - src_a)
		or, og, ob = dr, dg, db
	case parse.COMPOSITE_SRC_ATOP:
		// Source where destination exists; destination otherwise.
		out_a = dst_a
		if out_a == 0 { return }
		or = (sr * src_a * dst_a + dr * dst_a * (1.0 - src_a)) / out_a
		og = (sg * src_a * dst_a + dg * dst_a * (1.0 - src_a)) / out_a
		ob = (sb * src_a * dst_a + db * dst_a * (1.0 - src_a)) / out_a
	case parse.COMPOSITE_DEST_ATOP:
		out_a = src_a
		if out_a == 0 { return }
		or = (dr * dst_a * src_a + sr * src_a * (1.0 - dst_a)) / out_a
		og = (dg * dst_a * src_a + sg * src_a * (1.0 - dst_a)) / out_a
		ob = (db * dst_a * src_a + sb * src_a * (1.0 - dst_a)) / out_a
	case parse.COMPOSITE_XOR:
		out_a = src_a * (1.0 - dst_a) + dst_a * (1.0 - src_a)
		if out_a == 0 { return }
		or = (sr * src_a * (1.0 - dst_a) + dr * dst_a * (1.0 - src_a)) / out_a
		og = (sg * src_a * (1.0 - dst_a) + dg * dst_a * (1.0 - src_a)) / out_a
		ob = (sb * src_a * (1.0 - dst_a) + db * dst_a * (1.0 - src_a)) / out_a
	case parse.COMPOSITE_PLUS:
		out_a = src_a + dst_a
		if out_a > 1.0 { out_a = 1.0 }
		or = clamp01(sr + dr); og = clamp01(sg + dg); ob = clamp01(sb + db)

	// ---- Separable blends -----------------------------------------
	// All separable blends apply blend(src, dst) per channel then
	// composite source-over. blend_src_over packages the common
	// post-process; per-mode arms just compute the per-channel
	// blended value.
	case parse.COMPOSITE_SCREEN:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			blend_screen(sr, dr), blend_screen(sg, dg), blend_screen(sb, db))
	case parse.COMPOSITE_MULTIPLY:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			sr * dr, sg * dg, sb * db)
	case parse.COMPOSITE_DARKEN:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			min(sr, dr), min(sg, dg), min(sb, db))
	case parse.COMPOSITE_LIGHTEN:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			max(sr, dr), max(sg, dg), max(sb, db))
	case parse.COMPOSITE_OVERLAY:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			blend_overlay(sr, dr), blend_overlay(sg, dg), blend_overlay(sb, db))
	case parse.COMPOSITE_HARD_LIGHT:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			blend_overlay(dr, sr), blend_overlay(dg, sg), blend_overlay(db, sb))
	case parse.COMPOSITE_SOFT_LIGHT:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			blend_soft_light(sr, dr), blend_soft_light(sg, dg), blend_soft_light(sb, db))
	case parse.COMPOSITE_COLOR_DODGE:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			blend_color_dodge(sr, dr), blend_color_dodge(sg, dg), blend_color_dodge(sb, db))
	case parse.COMPOSITE_COLOR_BURN:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			blend_color_burn(sr, dr), blend_color_burn(sg, dg), blend_color_burn(sb, db))
	case parse.COMPOSITE_DIFFERENCE:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			abs_f32(sr - dr), abs_f32(sg - dg), abs_f32(sb - db))
	case parse.COMPOSITE_EXCLUSION:
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db,
			sr + dr - 2 * sr * dr, sg + dg - 2 * sg * dg, sb + db - 2 * sb * db)

	// ---- HSL non-separable blends ---------------------------------
	case parse.COMPOSITE_HSL_HUE:
		br, bg, bb := hsl_set_hue(dr, dg, db, sr, sg, sb)
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db, br, bg, bb)
	case parse.COMPOSITE_HSL_SAT:
		br, bg, bb := hsl_set_sat(dr, dg, db, hsl_sat(sr, sg, sb))
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db, br, bg, bb)
	case parse.COMPOSITE_HSL_COLOR:
		br, bg, bb := hsl_set_lum(sr, sg, sb, hsl_lum(dr, dg, db))
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db, br, bg, bb)
	case parse.COMPOSITE_HSL_LUM:
		br, bg, bb := hsl_set_lum(dr, dg, db, hsl_lum(sr, sg, sb))
		out_a, or, og, ob = blend_src_over(src_a, dst_a, dr, dg, db, br, bg, bb)

	case:
		// Unknown mode — Src over fallback (defensive only; all spec
		// modes are handled above).
		out_a = src_a + dst_a * (1.0 - src_a)
		if out_a == 0 { return }
		or = (sr * src_a + dr * dst_a * (1.0 - src_a)) / out_a
		og = (sg * src_a + dg * dst_a * (1.0 - src_a)) / out_a
		ob = (sb * src_a + db * dst_a * (1.0 - src_a)) / out_a
	}
	dst[0] = u8(clamp01(or)    * 255.0 + 0.5)
	dst[1] = u8(clamp01(og)    * 255.0 + 0.5)
	dst[2] = u8(clamp01(ob)    * 255.0 + 0.5)
	dst[3] = u8(clamp01(out_a) * 255.0 + 0.5)
	_ = src_a; _ = b
}

@(private)
clamp01 :: proc(v: f32) -> f32 {
	if v < 0 { return 0 }
	if v > 1 { return 1 }
	return v
}

@(private)
abs_f32 :: proc(v: f32) -> f32 { return v if v >= 0 else -v }

// blend_src_over packages the alpha-aware source-over composite that
// every separable / HSL blend shares: out = (1-Sa)*Da*D + Sa*B(S,D),
// where B(S,D) is the per-channel blended value.
@(private)
blend_src_over :: proc(src_a, dst_a, dr, dg, db, br, bg, bb: f32) -> (out_a, or, og, ob: f32) {
	out_a = src_a + dst_a * (1.0 - src_a)
	if out_a == 0 { return }
	// W3C compositing: out = (Sa*Da)*B + (1-Da)*Sa*S + (1-Sa)*Da*D.
	// Equivalent to: out = Sa*Da*B + Sa*(1-Da)*S' + ... but for the
	// purpose of separable blends B already encodes the post-blend
	// colour. We mix B with D weighted by Da and Sa:
	or = (1.0 - src_a) * dr * dst_a + src_a * br * dst_a + src_a * (1.0 - dst_a) * br / 1.0
	og = (1.0 - src_a) * dg * dst_a + src_a * bg * dst_a + src_a * (1.0 - dst_a) * bg / 1.0
	ob = (1.0 - src_a) * db * dst_a + src_a * bb * dst_a + src_a * (1.0 - dst_a) * bb / 1.0
	// Normalise by out_a so the output is straight (un-premul) alpha.
	or /= out_a
	og /= out_a
	ob /= out_a
	return
}

// ---- Per-channel blend functions -----------------------------------

@(private) blend_screen      :: proc(s, d: f32) -> f32 { return s + d - s * d }

@(private)
blend_overlay :: proc(s, d: f32) -> f32 {
	if d <= 0.5 { return 2 * s * d }
	return 1 - 2 * (1 - s) * (1 - d)
}

@(private)
blend_color_dodge :: proc(s, d: f32) -> f32 {
	if d == 0 { return 0 }
	if s == 1 { return 1 }
	v := d / (1 - s)
	return clamp01(v)
}

@(private)
blend_color_burn :: proc(s, d: f32) -> f32 {
	if d == 1 { return 1 }
	if s == 0 { return 0 }
	v := 1 - (1 - d) / s
	return clamp01(v)
}

@(private)
blend_soft_light :: proc(s, d: f32) -> f32 {
	// W3C soft-light formula.
	if s <= 0.5 {
		return d - (1 - 2 * s) * d * (1 - d)
	}
	gd: f32
	if d <= 0.25 { gd = ((16 * d - 12) * d + 4) * d } else { gd = sqrt_f32(d) }
	return d + (2 * s - 1) * (gd - d)
}

@(private)
sqrt_f32 :: proc(v: f32) -> f32 {
	// Cheap sqrt — accurate enough for blend math, no math import.
	if v <= 0 { return 0 }
	x: f32 = v
	for _ in 0..<8 { x = 0.5 * (x + v / x) }
	return x
}

// ---- HSL helpers ----------------------------------------------------
//
// Non-separable blends operate on the source/dest as colour triples
// in a perceptual sense — they swap hue, saturation, or luminosity
// rather than mixing per-channel. The HSL functions implement the
// W3C "non-separable" blend definitions verbatim.

@(private)
hsl_lum :: proc(r, g, b: f32) -> f32 {
	return 0.3 * r + 0.59 * g + 0.11 * b
}

@(private)
hsl_sat :: proc(r, g, b: f32) -> f32 {
	return max(r, max(g, b)) - min(r, min(g, b))
}

@(private)
hsl_set_lum :: proc(r, g, b, l: f32) -> (or, og, ob: f32) {
	d := l - hsl_lum(r, g, b)
	or, og, ob = r + d, g + d, b + d
	or, og, ob = hsl_clip_color(or, og, ob)
	return
}

@(private)
hsl_clip_color :: proc(r, g, b: f32) -> (or, og, ob: f32) {
	or, og, ob = r, g, b
	l := hsl_lum(or, og, ob)
	mn := min(or, min(og, ob))
	mx := max(or, max(og, ob))
	if mn < 0 {
		denom := l - mn
		if denom != 0 {
			or = l + (or - l) * l / denom
			og = l + (og - l) * l / denom
			ob = l + (ob - l) * l / denom
		}
	}
	if mx > 1 {
		denom := mx - l
		if denom != 0 {
			or = l + (or - l) * (1 - l) / denom
			og = l + (og - l) * (1 - l) / denom
			ob = l + (ob - l) * (1 - l) / denom
		}
	}
	return
}

// hsl_set_sat — replace the saturation of a colour triple, preserving
// its hue and luminosity. Operates on the per-channel ordering of
// (r, g, b) sorted into (min, mid, max).
@(private)
hsl_set_sat :: proc(r, g, b, s: f32) -> (or, og, ob: f32) {
	// Identify the (min, mid, max) channels by value, apply the
	// saturation s as max - min, project mid linearly between them.
	or, og, ob = r, g, b
	// Bubble sort the channel indices by their current value so we
	// know which slot is min / mid / max.
	idx := [3]int{0, 1, 2}
	vals := [3]f32{r, g, b}
	for i in 1..<3 {
		j := i
		for j > 0 && vals[idx[j - 1]] > vals[idx[j]] {
			idx[j - 1], idx[j] = idx[j], idx[j - 1]
			j -= 1
		}
	}
	lo, mid, hi := idx[0], idx[1], idx[2]
	out := [3]f32{0, 0, 0}
	if vals[hi] > vals[lo] {
		out[mid] = (vals[mid] - vals[lo]) * s / (vals[hi] - vals[lo])
		out[hi]  = s
	} else {
		out[mid] = 0
		out[hi]  = 0
	}
	out[lo] = 0
	return out[0], out[1], out[2]
}

@(private)
hsl_set_hue :: proc(target_r, target_g, target_b, src_r, src_g, src_b: f32) -> (or, og, ob: f32) {
	// Take the hue of source by transferring its saturation+hue
	// combo onto the target's luminosity. Implemented as
	// set_lum(set_sat(src, sat(target)), lum(target)).
	r, g, b := hsl_set_sat(src_r, src_g, src_b, hsl_sat(target_r, target_g, target_b))
	return hsl_set_lum(r, g, b, hsl_lum(target_r, target_g, target_b))
}

// solid_color resolves a Solid brush (or a gradient that we treat
// as solid for v0.5) into an 8-bit RGBA colour.
@(private)
solid_color :: proc(b: parse.Colr_Brush, palette: ^parse.Cpal, palette_idx: u16, foreground: [4]u8) -> [4]u8 {
	col := foreground
	if b.palette_index != parse.COLR_FOREGROUND_PALETTE_INDEX {
		c := parse.cpal_lookup(palette, palette_idx, b.palette_index)
		col = [4]u8{c.r, c.g, c.b, c.a}
	}
	// Apply brush-level alpha if specified (Solid brushes carry it;
	// Linear / Radial keep alpha=1 and rely on per-stop alpha).
	if b.alpha < 1.0 {
		col[3] = u8(f32(col[3]) * b.alpha + 0.5)
	}
	return col
}

// Linear_Eval precomputes the constants needed to project a pixel
// (sx, sy) onto the gradient axis. The pixel's local-bitmap coord
// (sx, sy) plus the layer's (x_off, y_off, height) tell us where the
// pixel sits in absolute pixel space; we then transform that to
// font-unit space and project onto (p0, p1).
@(private)
Linear_Eval :: struct {
	// Pixel-space gradient endpoints (after the same scaling as the
	// glyph mask).
	px0, py0:  f32,
	px1, py1:  f32,
	len_sq:    f32,                                    // |p1 - p0|² in pixel-space units
	// Layer origin in pixel-space (top-left of the bitmap, in the
	// same coord system as endpoints).
	origin_x:  f32,
	origin_y:  f32,
	// Pixel-row Y flip: glyph mask rows are y-down from origin_y;
	// gradient endpoints come from font-unit y-up coords.
	height_px: int,
}

@(private)
init_linear_eval :: proc(b: parse.Colr_Brush, pixel_scale: f32, layer_x_off, layer_y_off, height_px: int) -> Linear_Eval {
	// Convert font-unit endpoints to pixel-space. The y axis flips
	// because glyf y-up vs raster y-down.
	px0 := b.p0[0] * pixel_scale
	py0 := -b.p0[1] * pixel_scale
	px1 := b.p1[0] * pixel_scale
	py1 := -b.p1[1] * pixel_scale
	dx := px1 - px0
	dy := py1 - py0
	return Linear_Eval{
		px0 = px0, py0 = py0,
		px1 = px1, py1 = py1,
		len_sq    = dx * dx + dy * dy,
		origin_x  = f32(layer_x_off),
		origin_y  = f32(layer_y_off),
		height_px = height_px,
	}
}

// eval_linear computes the gradient colour at pixel (sx, sy) inside
// the current layer's bitmap.
@(private)
eval_linear :: proc(g: Linear_Eval, b: ^parse.Colr_Brush, palette: ^parse.Cpal, palette_idx: u16, foreground: [4]u8, sx, sy: int) -> [4]u8 {
	if g.len_sq <= 1e-6 || len(b.stops) == 0 {
		// Degenerate gradient — fall back to first stop or foreground.
		return solid_color(b^, palette, palette_idx, foreground)
	}
	// Pixel centre coords in pixel-space (same frame as endpoints).
	abs_x := g.origin_x + f32(sx) + 0.5
	abs_y := g.origin_y + f32(sy) + 0.5

	// Project onto (p0, p1).
	vx := abs_x - g.px0
	vy := abs_y - g.py0
	dx := g.px1 - g.px0
	dy := g.py1 - g.py0
	t := (vx * dx + vy * dy) / g.len_sq
	if t < 0 { t = 0 }
	if t > 1 { t = 1 }

	return interpolate_stops(b.stops, t, palette, palette_idx, foreground)
}

@(private)
interpolate_stops :: proc(stops: []parse.Color_Stop, t: f32, palette: ^parse.Cpal, palette_idx: u16, foreground: [4]u8) -> [4]u8 {
	if len(stops) == 0 { return [4]u8{0, 0, 0, 0} }
	if t <= stops[0].offset    { return stop_color(stops[0], palette, palette_idx, foreground) }
	if t >= stops[len(stops) - 1].offset { return stop_color(stops[len(stops) - 1], palette, palette_idx, foreground) }

	// Find the bracketing pair.
	for i in 0..<len(stops) - 1 {
		a := stops[i]
		b := stops[i + 1]
		if t >= a.offset && t <= b.offset {
			span := b.offset - a.offset
			u: f32 = 0
			if span > 0 { u = (t - a.offset) / span }
			ca := stop_color(a, palette, palette_idx, foreground)
			cb := stop_color(b, palette, palette_idx, foreground)
			return [4]u8{
				lerp_u8(ca[0], cb[0], u),
				lerp_u8(ca[1], cb[1], u),
				lerp_u8(ca[2], cb[2], u),
				lerp_u8(ca[3], cb[3], u),
			}
		}
	}
	return stop_color(stops[len(stops) - 1], palette, palette_idx, foreground)
}

@(private)
stop_color :: proc(s: parse.Color_Stop, palette: ^parse.Cpal, palette_idx: u16, foreground: [4]u8) -> [4]u8 {
	col := foreground
	if s.palette_index != parse.COLR_FOREGROUND_PALETTE_INDEX {
		c := parse.cpal_lookup(palette, palette_idx, s.palette_index)
		col = [4]u8{c.r, c.g, c.b, c.a}
	}
	col[3] = u8(f32(col[3]) * s.alpha + 0.5)
	return col
}

@(private)
lerp_u8 :: proc(a, b: u8, t: f32) -> u8 {
	r := f32(a) + (f32(b) - f32(a)) * t
	if r < 0 { r = 0 }
	if r > 255 { r = 255 }
	return u8(r + 0.5)
}

// ---- Radial gradient -------------------------------------------------

@(private)
Radial_Eval :: struct {
	cx0, cy0:  f32,
	cx1, cy1:  f32,
	r0,  r1:   f32,
	origin_x:  f32,
	origin_y:  f32,
}

@(private)
init_radial_eval :: proc(b: parse.Colr_Brush, pixel_scale: f32, layer_x_off, layer_y_off: int) -> Radial_Eval {
	return Radial_Eval{
		cx0      =  b.p0[0] * pixel_scale,
		cy0      = -b.p0[1] * pixel_scale,
		cx1      =  b.p1[0] * pixel_scale,
		cy1      = -b.p1[1] * pixel_scale,
		r0       =  b.r0 * pixel_scale,
		r1       =  b.r1 * pixel_scale,
		origin_x = f32(layer_x_off),
		origin_y = f32(layer_y_off),
	}
}

// eval_radial solves for the gradient parameter t such that the
// interpolated circle (center (1-t)c0 + t c1, radius (1-t)r0 + t r1)
// passes through the pixel. The smaller non-negative real root of
// the quadratic in t wins.
@(private)
eval_radial :: proc(g: Radial_Eval, b: ^parse.Colr_Brush, palette: ^parse.Cpal, palette_idx: u16, foreground: [4]u8, sx, sy: int) -> [4]u8 {
	if len(b.stops) == 0 { return solid_color(b^, palette, palette_idx, foreground) }
	px := g.origin_x + f32(sx) + 0.5
	py := g.origin_y + f32(sy) + 0.5

	// Quadratic:  |p - ((1-t)c0 + t c1)|² = ((1-t)r0 + t r1)²
	// Expand:     a t² + b t + c = 0  with
	//   a = |c1-c0|² - (r1-r0)²
	//   b = -2 * ((p - c0)·(c1 - c0) + r0 * (r1 - r0))
	//   c = |p - c0|² - r0²
	dcx := g.cx1 - g.cx0
	dcy := g.cy1 - g.cy0
	dr  := g.r1  - g.r0
	pcx := px - g.cx0
	pcy := py - g.cy0

	A := dcx*dcx + dcy*dcy - dr*dr
	B := -2 * (pcx*dcx + pcy*dcy + g.r0 * dr)
	C := pcx*pcx + pcy*pcy - g.r0*g.r0

	t: f32
	if A == 0 {
		// Linear case (circles same radius): solve B t + C = 0.
		if B == 0 { return solid_color(b^, palette, palette_idx, foreground) }
		t = -C / B
	} else {
		disc := B*B - 4*A*C
		if disc < 0 { return [4]u8{0, 0, 0, 0} }
		sq := math.sqrt(disc)
		t0 := (-B - sq) / (2*A)
		t1 := (-B + sq) / (2*A)
		// Prefer the larger root, but clamp to [0, 1] so the gradient
		// covers the disc cleanly. This mirrors Skia's resolution.
		t = max(t0, t1)
	}
	if t < 0 { t = 0 }
	if t > 1 { t = 1 }
	return interpolate_stops(b.stops, t, palette, palette_idx, foreground)
}

// ---- Sweep gradient --------------------------------------------------

@(private)
Sweep_Eval :: struct {
	cx, cy:      f32,
	start, end:  f32,                                  // angles, radians
	origin_x:    f32,
	origin_y:    f32,
}

@(private)
init_sweep_eval :: proc(b: parse.Colr_Brush, pixel_scale: f32, layer_x_off, layer_y_off: int) -> Sweep_Eval {
	return Sweep_Eval{
		cx       =  b.p0[0] * pixel_scale,
		cy       = -b.p0[1] * pixel_scale,
		start    =  b.angle_start,
		end      =  b.angle_end,
		origin_x = f32(layer_x_off),
		origin_y = f32(layer_y_off),
	}
}

@(private)
eval_sweep :: proc(g: Sweep_Eval, b: ^parse.Colr_Brush, palette: ^parse.Cpal, palette_idx: u16, foreground: [4]u8, sx, sy: int) -> [4]u8 {
	if len(b.stops) == 0 { return solid_color(b^, palette, palette_idx, foreground) }
	px := g.origin_x + f32(sx) + 0.5
	py := g.origin_y + f32(sy) + 0.5
	// y is flipped in pixel-space relative to font-unit space, but
	// the gradient endpoints arrived in font-units. atan2 with the
	// already-flipped (cx, cy) gives a consistent rotation direction.
	a := math.atan2(py - g.cy, px - g.cx)
	span := g.end - g.start
	if span == 0 { return solid_color(b^, palette, palette_idx, foreground) }
	t := (a - g.start) / span
	if t < 0 { t = 0 }
	if t > 1 { t = 1 }
	return interpolate_stops(b.stops, t, palette, palette_idx, foreground)
}
