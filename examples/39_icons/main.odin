package example_icons

import "gui:skald"

// Icon-font example: register a Font Awesome 6 Solid TTF as a fallback
// for the default font, then use the PUA codepoints inline alongside
// regular text. Same `text(...)` / `button(...)` calls as anywhere else
// in the framework — fontstash routes any glyph missing from Inter to
// the next font in the fallback chain.
//
// The bundled `fa-solid-900.ttf` is SIL OFL 1.1 (see assets/LICENSE.fa.txt).
// Browse the catalogue + codepoints at https://fontawesome.com/icons.

FA_SOLID_TTF :: #load("assets/fa-solid-900.ttf", []byte)

// A handful of common Solid icons — Font Awesome's PUA codepoints. Use
// the `\uXXXX` escape directly in strings, or copy from the search box
// on fontawesome.com.
ICON_HOUSE  :: ""
ICON_SAVE   :: ""  // floppy-disk
ICON_TRASH  :: ""
ICON_GEAR   :: ""
ICON_SEARCH :: ""  // magnifying-glass
ICON_HEART  :: ""
ICON_STAR   :: ""
ICON_BELL   :: ""
ICON_USER   :: ""
ICON_CHECK  :: ""

State :: struct {}

Msg :: union {
	Pressed,
}

Pressed :: distinct string

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	return s, {}
}

on_press :: proc(label: string) -> Msg { return Pressed(label) }

@(private)
fonts_ready: bool

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Lazy one-shot fallback registration. ctx.renderer is live by the
	// first frame; the package-level flag keeps font_load idempotent.
	if !fonts_ready && ctx.renderer != nil {
		fa := skald.font_load(ctx.renderer, "fa-solid", FA_SOLID_TTF)
		skald.font_add_fallback(ctx.renderer, skald.font_default(ctx.renderer), fa)
		fonts_ready = true
	}

	// Icons inline with text — no special widget, just regular `text` /
	// `button`. Fontstash sees the PUA codepoints, falls back to FA.
	return skald.col(
		skald.text("Skald — Icon fonts", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Font Awesome 6 Solid registered as a fallback to Inter.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.lg),

		skald.text("Inline with body text", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.text(
			ICON_HOUSE + "  Home   " +
			ICON_SEARCH + "  Search   " +
			ICON_BELL + "  Notifications   " +
			ICON_USER + "  Account",
			th.color.fg, th.font.size_md),
		skald.spacer(th.spacing.lg),

		skald.text("Buttons", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.row(
			skald.button(ctx, ICON_SAVE  + "  Save",   on_press("Save")),
			skald.button(ctx, ICON_TRASH + "  Delete", on_press("Delete")),
			skald.button(ctx, ICON_GEAR  + "  Settings", on_press("Settings")),
			spacing = th.spacing.sm,
		),
		skald.spacer(th.spacing.lg),

		skald.text("Glyph-only at large sizes", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.row(
			skald.text(ICON_HEART, {0.95, 0.30, 0.40, 1}, 48),
			skald.text(ICON_STAR,  {0.95, 0.78, 0.20, 1}, 48),
			skald.text(ICON_CHECK, {0.30, 0.80, 0.45, 1}, 48),
			spacing = th.spacing.lg,
		),

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Icon fonts",
		size   = {640, 520},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
