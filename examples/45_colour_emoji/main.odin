package example_colour_emoji

import "gui:skald"

// Colour-emoji smoke test — calls `skald.font_use_default_emoji(r)`
// to register Skald's bundled Twemoji-Mozilla (COLRv0) as a fallback
// to Inter. Under the runa text backend (`SKALD_RUNA=1`) the emoji
// render in full colour; under the default fontstash backend they
// render as `.notdef` tofu (fontstash doesn't decode COLR tables).
//
// Run with: `SKALD_RUNA=1 ./build.sh 45_colour_emoji run`
//
// Apps that adopt this pattern need to add an attribution line for
// the Twemoji artwork — CC-BY-4.0. See
// `skald/assets/Twemoji-Mozilla-CCBY.txt` for the full notice.

State :: struct {}
Msg   :: struct {}

@(private)
fonts_ready: bool

init :: proc() -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// One-line opt-in for colour emoji on the first frame. Idempotent —
	// re-calling returns the cached handle.
	if !fonts_ready && ctx.renderer != nil {
		skald.font_use_default_emoji(ctx.renderer)
		fonts_ready = true
	}

	return skald.col(
		skald.text("Skald — Colour Emoji (runa)", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.md),
		skald.text("Twemoji glyphs render in full colour wherever Inter doesn't cover the codepoint.",
			th.color.fg_muted, th.font.size_md, max_width = 560),
		skald.spacer(th.spacing.lg),
		skald.text("Hello, world! 🦊", th.color.fg, th.font.size_display),
		skald.spacer(th.spacing.md),
		skald.text("Status: 🚀 shipped · 🐛 fixed · 🎉 celebrated", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.md),
		skald.text("Stars: ★ ★ ★ ☆ ☆", th.color.fg, th.font.size_md),
		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Colour Emoji",
		size   = {640, 360},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
