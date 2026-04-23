#version 450

// Skald's unified vertex stage, ported 1:1 from skald/shader.wgsl.
// Every vertex carries the data for all four fragment-path kinds so a
// single pipeline handles rects, text, images, and solid triangles
// without rebinds.

layout(location = 0) in vec2  in_pos;        // pixel, top-left origin
layout(location = 1) in vec4  in_color;      // linear, straight alpha
layout(location = 2) in vec2  in_center;     // rect center
layout(location = 3) in vec2  in_half_size;  // half-extents
layout(location = 4) in float in_radius;     // corner radius
layout(location = 5) in float in_kind;       // 0=rect 1=glyph 2=image 3=solid
layout(location = 6) in vec2  in_uv;         // atlas UV

layout(location = 0) out vec4  v_color;
layout(location = 1) out vec2  v_frag_pos;
layout(location = 2) out vec2  v_center;
layout(location = 3) out vec2  v_half_size;
layout(location = 4) out float v_radius;
layout(location = 5) out float v_kind;
layout(location = 6) out vec2  v_uv;

layout(set = 0, binding = 0) uniform Uniforms {
    vec2 fb_size;
} u;

void main() {
    vec2 ndc = vec2(
        in_pos.x * 2.0 / u.fb_size.x - 1.0,
        1.0 - in_pos.y * 2.0 / u.fb_size.y
    );
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_color     = in_color;
    v_frag_pos  = in_pos;
    v_center    = in_center;
    v_half_size = in_half_size;
    v_radius    = in_radius;
    v_kind      = in_kind;
    v_uv        = in_uv;
}
