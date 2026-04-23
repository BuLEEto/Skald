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

ASSET :: "examples/20_image/assets/MooMoo.png"

State :: struct {}
Msg   :: struct {}

init   :: proc() -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

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

	return skald.col(
		skald.text("Skald — Images", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Same MooMoo.png, four fit modes and three tints.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.lg),

		fits_row,
		skald.spacer(th.spacing.xl),

		tint_row,

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
