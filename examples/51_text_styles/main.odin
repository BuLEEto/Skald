package example_text_styles

// text_input `styles`: restyle byte ranges of the *editable* buffer for
// syntax highlighting and headings. Each Text_Style{start, end, ...} carries
// colour / weight / italic / font / size; the field measures per run, so the
// caret, selection and clicks stay exact even where glyph metrics change — a
// per-run `size` also makes that visual line taller.
//
// The app owns the highlighting: recompute `styles` from the buffer every
// frame in `view` and hand them in. Two highlighters below —
//   - keywords  -> bold + colour   (a tiny stand-in for a real lexer)
//   - "# "/"## " lines -> larger size (variable line height)

import "core:strings"
import "gui:skald"

State :: struct { code, doc: string }

Msg :: union { Code_Changed, Doc_Changed }
Code_Changed :: distinct string
Doc_Changed  :: distinct string

KEYWORDS := []string{"package", "import", "proc", "struct", "return", "for", "if", "else", "in"}

init :: proc() -> State {
	// Spaces, not tabs: text_input renders a literal tab as tofu (caret
	// offsets stay byte-exact, so tab expansion is a separate concern).
	code := `package main

main :: proc() {
    for i in 0..<3 {
        if i > 0 {
            // edit me — keywords restyle live
        }
    }
}`
	doc := `# Heading One
Body text under the heading, at the base size.
## Heading Two
More body. Headings use a larger per-run size, so these
lines are taller — click and scroll through them.`
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

// highlight bolds + colours every keyword. A real editor would lex the
// buffer; scanning identifiers keeps the example dependency-free.
highlight :: proc(src: string) -> []skald.Text_Style {
	out := make([dynamic]skald.Text_Style, 0, 64, context.temp_allocator)
	kw  := skald.Color{0.80, 0.58, 0.92, 1}
	i := 0
	for i < len(src) {
		if !is_ident(src[i]) { i += 1; continue }
		start := i
		for i < len(src) && is_ident(src[i]) { i += 1 }
		if is_keyword(src[start:i]) {
			append(&out, skald.Text_Style{start = start, end = i, color = kw, weight = .Bold})
		}
	}
	return out[:]
}

// headings renders whole "# "/"## " lines at a larger size — the variable
// line-height path. The line's height grows to fit the bigger glyphs.
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

is_ident :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}
is_keyword :: proc(w: string) -> bool {
	for k in KEYWORDS { if k == w { return true } }
	return false
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text("text_input styles", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.text("Keyword highlighting — keywords go bold + coloured as you type:",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.text_input(ctx, s.code, proc(v: string) -> Msg { return Code_Changed(v) },
			width = 520, height = 200, multiline = true, styles = highlight(s.code)),
		skald.spacer(th.spacing.lg),
		skald.text("Headings — a per-run size makes the whole line taller:",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.text_input(ctx, s.doc, proc(v: string) -> Msg { return Doc_Changed(v) },
			width = 520, height = 200, multiline = true, line_spacing = 6, styles = headings(s.doc)),
		padding = th.spacing.xl, cross_align = .Start, spacing = 0,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — text_input styles",
		size   = {600, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
