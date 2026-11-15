#version 450

// Skald's unified fragment stage, ported 1:1 from skald/shader.wgsl.
// Branches on `kind`:
//   0 — rounded-box SDF with fwidth AA (rects, buttons, borders)
//   1 — sample R8 atlas, multiply alpha (text glyphs)
//   2 — sample RGBA atlas, modulate by color (images)
//   3 — solid vertex color (strokes, raw triangles)
//   4 — rounded-box soft shadow (SDF + v_uv.x blur radius)

layout(location = 0) in vec4  v_color;
layout(location = 1) in vec2  v_frag_pos;
layout(location = 2) in vec2  v_center;
layout(location = 3) in vec2  v_half_size;
layout(location = 4) in vec4  v_radius;
layout(location = 5) in float v_kind;
layout(location = 6) in vec2  v_uv;

layout(location = 0) out vec4 out_color;

// Binding 0 — the only descriptor in the set, since fb_size moved to
// push constants. Per-image draws rebind this slot to their own
// texture via Batch_Range.bind_group.
layout(set = 0, binding = 0) uniform sampler2D atlas;

// r holds the four corner radii in the order top-left, top-right,
// bottom-right, bottom-left. p is relative to the box centre with +x right
// and +y down (framebuffer space), so the active corner is chosen by the
// sign of p.
float sd_rounded_box(vec2 p, vec2 hs, vec4 r) {
    float rr = (p.x > 0.0) ? (p.y > 0.0 ? r.z : r.y)   // right: bottom-right / top-right
                           : (p.y > 0.0 ? r.w : r.x);  // left:  bottom-left  / top-left
    vec2 q = abs(p) - hs + vec2(rr);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - rr;
}

void main() {
    if (v_kind < 0.5) {
        vec2  local = v_frag_pos - v_center;
        float d     = sd_rounded_box(local, v_half_size, v_radius);
        float aa    = fwidth(d) * 0.5;
        float cov   = 1.0 - smoothstep(-aa, aa, d);
        out_color   = vec4(v_color.rgb, v_color.a * cov);
        return;
    }
    if (v_kind < 1.5) {
        float a = texture(atlas, v_uv).r;
        // Stem-darken glyph coverage. The fontstash atlas is rasterised
        // with perceptual (sRGB) coverage in mind but we blend in linear
        // space (SRGB framebuffer → hw linear blend), which over-thins
        // dark-on-light text. Raising coverage by a gamma curve (~1/1.55)
        // thickens strokes so light-theme text doesn't read fuzzy.
        // The dark theme tolerates the same curve because bright-on-dark
        // strokes pick up only ~1 % extra weight for any given coverage.
        a = pow(a, 1.0 / 1.55);
        out_color = vec4(v_color.rgb, v_color.a * a);
        return;
    }
    if (v_kind < 2.5) {
        vec4 tex = texture(atlas, v_uv);
        vec4 c   = tex * v_color;
        // Optional rounded corners: v_radius=0 skips (plain image), else the
        // same SDF that rounds rects masks the quad's corners.
        if (v_radius.x + v_radius.y + v_radius.z + v_radius.w > 0.0) {
            vec2  local = v_frag_pos - v_center;
            float d     = sd_rounded_box(local, v_half_size, v_radius);
            float aa    = fwidth(d) * 0.5;
            c.a        *= 1.0 - smoothstep(-aa, aa, d);
        }
        out_color = c;
        return;
    }
    if (v_kind < 3.5) {
        out_color = v_color;
        return;
    }
    // kind == 4: soft SDF shadow. v_uv.x carries the blur radius (in
    // framebuffer pixels). The quad's half_size is the SHADOW's rect
    // (slightly smaller than the visible popover so the shadow hugs the
    // edges), and the quad itself is expanded by `blur` in every
    // direction to give the fragment shader room to fade out.
    vec2  local = v_frag_pos - v_center;
    float d     = sd_rounded_box(local, v_half_size, v_radius);
    float blur  = max(v_uv.x, 1.0);
    // Gauss-ish falloff: 1 at d=0, 0 at d=blur. Squaring the smoothstep
    // gives a softer toe that reads as depth rather than a hard edge.
    float t     = clamp(d / blur, 0.0, 1.0);
    float a     = 1.0 - t;
    a           = a * a;   // gentler toe
    out_color   = vec4(v_color.rgb, v_color.a * a);
}
