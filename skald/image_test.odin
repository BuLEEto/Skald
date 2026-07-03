package skald

// White-box tests for rounded `image` corners. The textured sample needs a
// real GPU texture, but the new logic — `batch_push_image` arming the SDF
// mask, and radius reaching the render path — is inspectable off the batch.
// Mirrors opacity_test's vertex-readback approach; no GPU/decode needed.

import "core:testing"
import vk "vendor:vulkan"

// Zero handle — batch_push_image only stores it in a Batch_Range, never
// dereferences it on the headless append path.
@(private = "file")
NO_DSET: vk.DescriptorSet

@(private = "file")
img_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.alpha_multiplier = 1
	return r
}

@(private = "file")
img_free :: proc(r: ^Renderer) {
	batch_destroy(&r.batch)
	free(r.cur)
	free(r)
}

// radius = 0 must leave the SDF fields untouched so the fragment shader
// takes its byte-identical fast path (the request's no-regression clause).
@(test)
image_radius_zero_untouched :: proc(t: ^testing.T) {
	r := img_renderer()
	defer img_free(r)
	batch_reset(&r.batch)
	batch_push_image(r, NO_DSET, {0, 0, 100, 80}, {0, 0, 1, 1}, {1, 1, 1, 1})
	v := r.batch.vertices[0]
	testing.expectf(t, v.radius == 0, "radius 0 must not arm the mask, got %v", v.radius)
	testing.expectf(t, v.center == {0, 0} && v.half_size == {0, 0},
		"radius 0 must leave center/half_size zero, got %v / %v", v.center, v.half_size)
	testing.expectf(t, v.kind == 2, "image vert kind must be 2, got %v", v.kind)
}

// radius > 0 arms the mask: center/half_size describe the drawn quad so the
// rounded-box SDF clips the corners in the fragment shader.
@(test)
image_radius_arms_sdf :: proc(t: ^testing.T) {
	r := img_renderer()
	defer img_free(r)
	batch_reset(&r.batch)
	batch_push_image(r, NO_DSET, {10, 20, 100, 80}, {0, 0, 1, 1}, {1, 1, 1, 1}, 12)
	v := r.batch.vertices[0]
	testing.expectf(t, v.radius == 12, "radius must reach the vert, got %v", v.radius)
	testing.expectf(t, v.center == {60, 60}, "center must be the quad center, got %v", v.center)
	testing.expectf(t, v.half_size == {50, 40}, "half_size must be the quad half-extent, got %v", v.half_size)
}

// An over-large radius clamps to the shorter half-extent (pill, not garbage).
@(test)
image_radius_clamps :: proc(t: ^testing.T) {
	r := img_renderer()
	defer img_free(r)
	batch_reset(&r.batch)
	batch_push_image(r, NO_DSET, {0, 0, 100, 80}, {0, 0, 1, 1}, {1, 1, 1, 1}, 999)
	testing.expectf(t, r.batch.vertices[0].radius == 40,
		"radius must clamp to min half-extent (40), got %v", r.batch.vertices[0].radius)
}

// radius plumbs all the way through the render path: a decode-failure
// placeholder still rounds, so a bad path doesn't flash a hard-cornered box
// inside a rounded card.
@(test)
image_placeholder_respects_radius :: proc(t: ^testing.T) {
	r := img_renderer()
	defer img_free(r)
	batch_reset(&r.batch)
	render_view(r, View_Image{path = "/no/such/file.png", size = {100, 100}, fit = .Cover, tint = {1, 1, 1, 1}, radius = 10}, {0, 0}, {100, 100})
	found := false
	for v in r.batch.vertices {
		if v.radius == 10 { found = true; break }
	}
	testing.expect(t, found, "placeholder rect must carry the image radius")
}
