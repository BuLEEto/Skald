package example_colour_emoji

import "gui:skald"

// Colour-emoji smoke test — emoji codepoints inside plain `text()`
// just render as full-colour Twemoji glyphs. Skald auto-registers
// Twemoji-Mozilla (COLRv0) as a fallback to Inter during `text_init`,
// so apps need zero setup. Under runa (the default text backend
// since 1.0) the glyphs render in full colour; if you opt into
// fontstash with `-define:SKALD_RUNA=false` they fall through to
// `.notdef` tofu (fontstash doesn't decode COLR tables).
//
// Run with: `./build.sh 45_colour_emoji run`
//
// Apps that ship a Skald binary are redistributing the Twemoji
// artwork — CC-BY-4.0. See `skald/assets/Twemoji-Mozilla-CCBY.txt`
// for the full attribution notice.

State :: struct {}
Msg   :: struct {}

init :: proc() -> State { return {} }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { return s, {} }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

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
