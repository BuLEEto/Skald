# runa API reference (v1.0.0)

Pure-Odin text engine — parse, shape, line-break, raster, atlas.
Public API lives in three layers: the **facade** in `runa.odin`,
the **packages** (`parse`, `shape`, `itemize`, `bidi`, `linebreak`,
`raster`), and the **examples**. Most callers only need the facade.

## Stability

v0.9 froze the public API. Patch releases continue to land
implementation improvements (perf, accuracy, conformance) but
signatures stay source-compatible — every breaking change has a
**`### Breaking changes`** entry in [`CHANGELOG.md`](CHANGELOG.md).

## Facade — `runa.odin`

### Font lifecycle

```odin
font_load     :: proc(data: []u8, allocator := context.allocator) -> (Font, Error)
font_destroy  :: proc(f: ^Font)
```

`data` is caller-owned; `font_destroy` releases the parser's
side-allocations but leaves the source bytes alone.

### Variations

```odin
font_axes              :: proc(f: ^Font) -> []Axis
font_set_variation     :: proc(f: ^Font, axis: Axis_Tag, value: f32) -> Error
font_reset_variations  :: proc(f: ^Font)
```

`value` is in user-axis units (e.g. weight 400). The library
applies `avar` mapping internally. Affects `font_glyph_outline`,
`font_glyph_advance`, `shape_text`, and `layout_paragraph`. Works
for `gvar` (TrueType-variable) **and** CFF2 fonts.

### Glyphs

```odin
font_lookup_glyph  :: proc(f: ^Font, codepoint: rune) -> Glyph_ID
font_glyph_advance :: proc(f: ^Font, gid: Glyph_ID) -> u16
font_glyph_outline :: proc(f: ^Font, gid: Glyph_ID, out: ^Outline) -> Error
font_has_color_layers :: proc(f: ^Font, gid: Glyph_ID) -> bool
font_color_layers     :: proc(f: ^Font, gid: Glyph_ID, allocator := context.allocator) -> ([]parse.Colr_Layer, Error)
font_palette_color    :: proc(f: ^Font, entry_idx: u16) -> [4]u8
```

`font_glyph_outline` reuses the caller's `Outline` so repeated
calls don't reallocate. The COLRv1 brush-aware path is selected
automatically inside `raster_glyph`.

### Layout

```odin
Paragraph_Opts :: struct {
    fonts:     Font_Stack,
    size:      f32,
    direction: Direction,
    max_width: f32,
    align:     Align,
    language:  parse.Tag,
}

layout_paragraph :: proc(text: string, opts: Paragraph_Opts,
                         cache: ^Cache = nil,
                         allocator := context.allocator) -> ([]Line, Error)
measure_text     :: proc(text: string, opts: Paragraph_Opts) -> (width, height: f32)
line_destroy     :: proc(l: ^Line, allocator := context.allocator)
```

`layout_paragraph` runs the full pipeline:
1. itemize into (font, script) runs (UAX #24 script segmentation)
2. UAX #9 bidi resolve when the text contains any RTL codepoints
3. shape each run via `shape_text` (GSUB + GPOS, with the Indic /
   Arabic / SEA shaper paths dispatched by script tag)
4. UAX #14 line-break + width fit; Thai runs are word-broken via
   the embedded PyThaiNLP dictionary so paragraphs reflow at
   word boundaries rather than the whole-sentence-as-one-word
   default
5. UAX #9 L2 visual reorder per line

`cache: ^Cache` is optional — pass one to amortize shape work
across calls; zero-allocation cache hits are verified by the
test suite.

### Segmentation iterators (UAX #29)

```odin
grapheme_iter_make :: proc(text: string) -> Grapheme_Iter
grapheme_iter_next :: proc(it: ^Grapheme_Iter) -> (lo, hi: int, ok: bool)

word_iter_make :: proc(text: string) -> Word_Iter
word_iter_next :: proc(it: ^Word_Iter) -> (lo, hi: int, ok: bool)

sentence_iter_make :: proc(text: string) -> Sentence_Iter
sentence_iter_next :: proc(it: ^Sentence_Iter) -> (lo, hi: int, ok: bool)
```

Each iterator yields `(byte_lo, byte_hi)` per segment; `ok = false`
ends iteration. Use for double-click word selection, sentence-level
TTS, grapheme-aware cursor movement, etc.

### Unicode normalization (UAX #15)

```odin
to_nfc  :: proc(s: string, allocator := context.allocator) -> string
to_nfd  :: proc(s: string, allocator := context.allocator) -> string
to_nfkc :: proc(s: string, allocator := context.allocator) -> string
to_nfkd :: proc(s: string, allocator := context.allocator) -> string

is_nfc :: proc(s: string) -> bool
is_nfd :: proc(s: string) -> bool

ccc :: proc(r: rune) -> u8     // Canonical_Combining_Class
```

Each `to_nfX` returns a freshly-allocated UTF-8 string in the
requested form; the caller owns the result.

### Rasterization (atlas)

```odin
raster_glyph :: proc(font: ^Font, gid: Glyph_ID, size: f32, subpx_x: u8,
                     atlas: ^Atlas, allocator := context.allocator) -> (Atlas_Slot, Error)
```

Renders one glyph into the shared atlas at the requested subpixel
offset. COLRv0 / COLRv1 emoji are auto-detected and rasterized
through the colour-bitmap path (RGBA pages); mono glyphs land on
alpha pages. The COLRv1 brush-aware rasterizer (linear / radial /
sweep gradients + the 28 W3C composite blend modes) is preferred
over the v0 flat-fill path when the font carries a v1
BaseGlyphList.

## Packages

| Package | Purpose |
|---|---|
| `parse` | OpenType table readers — head, maxp, cmap, hmtx, hhea, loca, glyf, CFF, CFF2, GSUB (types 1, 4, 5, 6), GPOS (types 1, 2, 4, 5, 6), GDEF, fvar, avar, gvar, HVAR, MVAR, COLR (v0 + v1), CPAL, kern. |
| `shape` | GSUB substitution + GPOS positioning. Per-script logic: Arabic joining state machine + Indic cluster reordering for all 9 Brahmic families and Myanmar / Khmer / Thai / Lao. |
| `itemize` | UTF-8 → runs by script (UAX #24) + UAX #29 grapheme cluster + word boundary + sentence boundary iterators. |
| `bidi` | UAX #9 bidirectional algorithm — 100 % BidiCharacterTest conformance. |
| `linebreak` | UAX #14 line break opportunities + width-fit splitter, plus the embedded Thai word-break dictionary. |
| `raster` | Analytic-coverage scanline rasterizer + atlas allocator (shelf packing, alpha + RGBA pages). |
| `normalize` | UAX #15 canonical / compatibility normalization. `to_nfc / to_nfd / to_nfkc / to_nfkd`, `is_nfc / is_nfd`, plus `ccc(r)` for combining class lookups. |

## Unicode conformance (v0.9.2)

| Standard | Conformance |
|---|---|
| UAX #9 bidirectional | **100.00 %** (91 707 / 91 707 BidiCharacterTest.txt rows) |
| UAX #14 line break | **99.94 %** (19 326 / 19 338 LineBreakTest.txt rows; 12 residual cases are large compound sentences — French quotation-mark patterns, Chinese with directional quotes, multi-currency math expressions, and one Balinese Aksara cluster lookahead) |
| UAX #24 script segmentation | 100 % (per-codepoint script lookup) |
| UAX #29 grapheme clusters | **100.00 %** (766 / 766 GraphemeBreakTest.txt rows) |
| UAX #29 word boundaries | **100.00 %** (1 944 / 1 944 WordBreakTest.txt rows) |
| UAX #29 sentence boundaries | **100.00 %** (512 / 512 SentenceBreakTest.txt rows) |
| UAX #15 normalization | **100.00 %** (20 034 / 20 034 NormalizationTest.txt rows; all four forms NFC/NFD/NFKC/NFKD) |

## Script coverage

| Script | Status | Verified via |
|---|---|---|
| Latin / Cyrillic / Greek | ✓ production | golden tests, FiraCode ligatures |
| Hebrew | ✓ production | RTL bidi pipeline |
| Arabic | ✓ production | Joining state machine + isol/init/medi/fina substitution |
| Devanagari / Bengali / Gujarati / Kannada / Odia / Tamil / Telugu / Malayalam / Gurmukhi | ✓ production | Indic shaper pipeline; HarfBuzz reference comparison |
| Thai / Lao | ✓ production | Standard GSUB; Thai word-break dictionary |
| Khmer / Myanmar | ✓ production | Indic pipeline + per-script flags; canonical syllables match HarfBuzz |
| CJK | ✓ via cmap | No script-specific reordering needed |
| Colour emoji | ✓ production | COLRv0 + COLRv1 + CBDT + sbix; 28 composite blend modes |

## Examples

| Path | Demonstrates |
|---|---|
| `examples/hello_world` | Latin + COLRv0 emoji, end-to-end through the atlas |
| `examples/rtl_demo`    | Mixed Latin + Hebrew + Arabic through bidi + Arabic shaper |
| `examples/basic`       | Minimal `font_load` → `shape_text` smoke test |

## Tools

| Path | Purpose |
|---|---|
| `tools/bench.odin`            | Perf harness. Output snapshot in `bench/results/`. |
| `tools/bidi_conformance.odin` | UAX #9 BidiCharacterTest runner. |
| `tools/lb_conformance.odin`   | UAX #14 LineBreakTest runner. |
| `tools/gb_conformance.odin`   | UAX #29 GraphemeBreakTest runner. |
| `tools/deep_stress.odin`      | 2 000-iter end-to-end loop under `Tracking_Allocator` for leak detection. Outlines every glyph of CFF1 + CFF2 fonts and shapes a Devanagari sample set. |
| `tools/bit_flip_fuzz.odin`    | Bit-flipped corpus fuzz — runs glyph extraction + shape against mangled SFNTs and asserts no panics. |

## Known gaps for v1.0 final

- **CFF2 ligature component tracking** — GPOS lookup type 5
  (mark-to-ligature) currently attaches all marks to the last
  component of the ligature. Proper per-component bookkeeping
  requires GSUB ligature substitution to record component spans
  on the output glyph.
- **TrueType hinting** — modern displays don't need it; only
  added if real demand emerges.
- **Hyphenation / Knuth–Plass justification** — post-v1.0
  separate release.
