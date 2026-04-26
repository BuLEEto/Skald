package example_image

import "gui:skald"

// Phase 14 showcase: the image primitive. A single square source
// (MooMoo.png, 1000×1000 RGBA) is reused across every slot so the
// differences between fit modes and tints are obvious — same pixels
// in, different geometry out.
//
//   .Cover   — scale to fill the slot, crop overflow via UV trim (default)
//   .Contain — scale to fit inside the slot, letterbox the shorter axis
//   .Fill    — stretch to fill, ignoring aspect ratio
//   .None    — native size, centered (suited to icons shipped at 1:1)
//
// The bottom row demonstrates tinting: feeding a flat color through
// the `tint` modulator recolors (or fades) the sampled RGBA without
// needing a separate asset per accent.

ASSET           :: "examples/20_image/assets/MooMoo.png"
GENERATED_NAME  :: "demo://gradient-checkerboard"

State :: struct {
	// Bumped on every Regenerate click so view's lazy-load branch knows
	// to call `image_load_pixels` again under the same name — exercising
	// the replace path (DeviceWaitIdle + free old + register new).
	regen_seed: int,
}

Msg :: union {
	Regenerate,
}
Regenerate :: struct{}

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch _ in m {
	case Regenerate:
		out.regen_seed += 1
	}
	return out, {}
}

on_regen :: proc() -> Msg { return Regenerate{} }

@(private)
last_loaded_seed := -1

// Generate a 256×256 RGBA buffer. `seed` shifts the hue + the
// checkerboard offset so each call produces a visually distinct image.
make_demo_pixels :: proc(seed: int) -> []u8 {
	W :: 256
	H :: 256
	pixels := make([]u8, W * H * 4, context.temp_allocator)
	hue_shift := u8(seed * 47)
	for y in 0..<H {
		for x in 0..<W {
			i := (y * W + x) * 4
			r := u8((x * 255) / (W - 1)) + hue_shift
			g := u8((y * 255) / (H - 1)) + hue_shift / 2
			b := u8(255 - r/2 - g/2)
			if ((x / 32) + (y / 32) + seed) % 2 == 0 {
				r = r / 3
				g = g / 3
				b = b / 3
			}
			pixels[i+0] = r
			pixels[i+1] = g
			pixels[i+2] = b
			pixels[i+3] = 255
		}
	}
	return pixels
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Register / re-register the generated pixels under a synthetic name.
	// First load is the same lifecycle as a CAD viewer pushing rasterized
	// output, a PDF page render, etc. Subsequent calls (when the user
	// clicks Regenerate) hit `image_load_pixels`'s replace path —
	// DeviceWaitIdle, free old GPU resources, register new.
	if last_loaded_seed != s.regen_seed && ctx.renderer != nil {
		pixels := make_demo_pixels(s.regen_seed)
		skald.image_load_pixels(ctx.renderer, GENERATED_NAME, 256, 256, pixels)
		last_loaded_seed = s.regen_seed
	}

	// Each slot is a fixed-size rect — the image fills that slot using
	// its chosen fit mode. The bg rect painted *under* each image makes
	// the slot visible so letterboxing (Contain) reads clearly.
	slot :: proc(
		ctx:   ^skald.Ctx(Msg),
		label: string,
		fit:   skald.Image_Fit,
		w:     f32 = 220,
		h:     f32 = 160,
	) -> skald.View {
		th := ctx.theme
		return skald.col(
			skald.text(label, th.color.fg, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.col(
				skald.image(ctx, ASSET, width = w, height = h, fit = fit),
				width  = w,
				height = h,
				bg     = th.color.surface,
				radius = 6,
			),
		)
	}

	fits_row := skald.row(
		slot(ctx, ".Cover (default)", .Cover,   w = 220, h = 160),
		// Wide slot exaggerates letterboxing for a square source.
		slot(ctx, ".Contain",         .Contain, w = 260, h = 160),
		// Tall slot + Fill shows the stretch clearly.
		slot(ctx, ".Fill",            .Fill,    w = 140, h = 160),
		// MooMoo is 1000×1000 — at native size it overflows any reasonable
		// slot, so `.None` here crops to the slot via the renderer's
		// auto-clip. Useful for icons shipped at 1:1; less interesting for
		// big artwork.
		slot(ctx, ".None (native, cropped)", .None, w = 220, h = 160),
		spacing = th.spacing.lg,
	)

	tint_row := skald.row(
		slot(ctx, "tint: white (default)", .Cover, w = 180, h = 140),
		skald.col(
			skald.text("tint: 50% alpha", th.color.fg, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.col(
				skald.image(ctx, ASSET,
					width = 180, height = 140, fit = .Cover,
					tint = {1, 1, 1, 0.5}),
				width  = 180,
				height = 140,
				bg     = th.color.surface,
				radius = 6,
			),
		),
		skald.col(
			skald.text("tint: warm primary", th.color.fg, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.col(
				skald.image(ctx, ASSET,
					width = 180, height = 140, fit = .Cover,
					tint = th.color.primary),
				width  = 180,
				height = 140,
				bg     = th.color.surface,
				radius = 6,
			),
		),
		spacing = th.spacing.lg,
	)

	// Demonstration of `image_load_pixels`: a procedural buffer
	// registered under a synthetic name, drawn the same way as any
	// file-loaded image (same `image()` call, same fit modes). The
	// Regenerate button calls image_load_pixels again under the same
	// name, exercising the replace path.
	pixels_row := skald.row(
		skald.col(
			skald.text("image_load_pixels (256×256 generated)",
				th.color.fg, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.col(
				skald.image(ctx, GENERATED_NAME, width = 220, height = 160, fit = .Cover),
				width  = 220,
				height = 160,
				bg     = th.color.surface,
				radius = 6,
			),
		),
		skald.col(
			skald.text(".Contain (letterboxed)",
				th.color.fg, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.col(
				skald.image(ctx, GENERATED_NAME, width = 260, height = 160, fit = .Contain),
				width  = 260,
				height = 160,
				bg     = th.color.surface,
				radius = 6,
			),
		),
		skald.col(
			skald.spacer(th.spacing.lg + th.font.size_sm),
			skald.button(ctx, "Regenerate", on_regen()),
			cross_align = .Start,
		),
		spacing = th.spacing.lg,
	)

	return skald.col(
		skald.text("Skald — Images", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Same MooMoo.png, four fit modes and three tints.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.lg),

		fits_row,
		skald.spacer(th.spacing.xl),

		tint_row,
		skald.spacer(th.spacing.xl),

		pixels_row,

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Images",
		size   = {1060, 560},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
