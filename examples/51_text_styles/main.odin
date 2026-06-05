package example_text_styles

// text_input `styles`: restyle byte ranges of the EDITABLE buffer for syntax
// highlighting and headings. The app recomputes `[]Text_Style` from the buffer
// every frame in `view` and hands it to text_input; the field measures per run,
// so the caret, selection and clicks stay exact even where bold / italic / size
// change glyph metrics. Each Text_Style{start, end, …} carries colour, weight,
// italic, font, and size.
//
// Two highlighters here, both recomputed live as you edit:
//   - `syntax`   — real Odin highlighting via core:odin/tokenizer (the way
//                  you'd actually do it): keywords bold, comments italic,
//                  strings/numbers coloured.
//   - `headings` — "# " / "## " lines get a larger per-run size, which makes
//                  those visual lines taller.

import "core:strings"
import tok "core:odin/tokenizer"
import "gui:skald"

State :: struct { code, doc: string }

Msg :: union { Code_Changed, Doc_Changed }
Code_Changed :: distinct string
Doc_Changed  :: distinct string

init :: proc() -> State {
	// Spaces, not tabs — text_input renders a literal tab as tofu (caret
	// offsets must stay byte-exact, so tab expansion is a separate concern).
	code := `package main

import "core:fmt"

main :: proc() {
    fmt.println("Hello, World!")
}`
	doc := `# Welcome
A normal paragraph at the base font size.
## Getting started
Headings use a larger per-run size, so these lines
are taller than the body. Click and scroll through them.`
	return {code = strings.clone(code), doc = strings.clone(doc)}
}

set :: proc(dst: ^string, s: string) { delete(dst^); dst^ = strings.clone(s) }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Code_Changed: set(&out.code, string(v))
	case Doc_Changed:  set(&out.doc, string(v))
	}
	return out, {}
}

// syntax tokenises `src` and emits one Text_Style per styled token. The Skald
// part is the last two lines per token: turn (kind → style) into a byte range.
// Anything style_for skips (identifiers, punctuation) just inherits the field
// foreground.
syntax :: proc(src: string) -> []skald.Text_Style {
	out := make([dynamic]skald.Text_Style, 0, 256, context.temp_allocator)
	t: tok.Tokenizer
	tok.init(&t, src, "<buf>", proc(pos: tok.Pos, msg: string, args: ..any) {})
	for {
		token := tok.scan(&t)
		if token.kind == .EOF || token.kind == .Invalid { break }
		st, ok := style_for(token.kind)
		if !ok { continue }
		st.start = token.pos.offset
		st.end   = st.start + len(token.text)
		append(&out, st)
	}
	return out[:]
}

style_for :: proc(k: tok.Token_Kind) -> (st: skald.Text_Style, ok: bool) {
	#partial switch k {
	case .Comment:                return {color = {0.50, 0.55, 0.60, 1}, italic = true}, true
	case .String, .Rune:          return {color = {0.55, 0.80, 0.45, 1}}, true
	case .Integer, .Float, .Imag: return {color = {0.45, 0.78, 0.85, 1}}, true
	}
	if k > .B_Keyword_Begin && k < .B_Keyword_End {
		return {color = {0.80, 0.58, 0.92, 1}, weight = .Bold}, true
	}
	return {}, false
}

// headings styles whole "# " / "## " lines at a larger size — the variable
// line-height path; the line grows to fit the bigger glyphs.
headings :: proc(src: string) -> []skald.Text_Style {
	out := make([dynamic]skald.Text_Style, 0, 16, context.temp_allocator)
	col := skald.Color{0.72, 0.86, 1.0, 1}
	i := 0
	for i < len(src) {
		le := i
		for le < len(src) && src[le] != '\n' { le += 1 }
		line := src[i:le]
		if strings.has_prefix(line, "## ") {
			append(&out, skald.Text_Style{start = i, end = le, size = 22, weight = .Bold, color = col})
		} else if strings.has_prefix(line, "# ") {
			append(&out, skald.Text_Style{start = i, end = le, size = 30, weight = .Bold, color = col})
		}
		i = le + 1
	}
	return out[:]
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text("text_input styles", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.text("Live Odin syntax highlighting — keywords bold, comments italic, strings green. Edit it:",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.text_input(ctx, s.code, proc(v: string) -> Msg { return Code_Changed(v) },
			width = 540, height = 230, multiline = true, styles = syntax(s.code)),
		skald.spacer(th.spacing.lg),
		skald.text("Headings — a per-run size makes the whole line taller:",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.text_input(ctx, s.doc, proc(v: string) -> Msg { return Doc_Changed(v) },
			width = 540, height = 160, multiline = true, line_spacing = 4, styles = headings(s.doc)),
		padding = th.spacing.xl, cross_align = .Start, spacing = 0,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — text_input styles",
		size   = {600, 660},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
