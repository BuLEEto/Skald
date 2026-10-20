# runa API reference (v1.5.1)

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
// Per-call OpenType feature overrides, HarfBuzz-style: a tag + an on/off value.
Feature_Setting :: struct { tag: parse.Tag, value: u32 }   // value 0 = off, else on
feature :: proc(name: string, on := true) -> Feature_Setting      // feature("smcp")
@(rodata) NO_LIGATURES := [3]Feature_Setting{ … }   // ligatures-off set; pass NO_LIGATURES[:]

// The deprecated `disable_features` names only the three ligature features.
Feature :: enum u8 { Ligatures, Contextual_Ligatures, Contextual_Alternates }

// Does the font actually carry a GSUB feature (e.g. "smcp"), so a caller can
// fall back — faking small caps from scaled capitals where it doesn't.
font_has_feature :: proc(font: ^Font, name: string,
                         script_tag := parse.LATN_SCRIPT, language_tag := parse.DFLT_LANG) -> bool

Paragraph_Opts :: struct {
    fonts:     Font_Stack,
    size:      f32,
    direction: Direction,
    max_width: f32,
    align:     Align,
    language:  parse.Tag,
    features:  []Feature_Setting,         // e.g. {feature("smcp"), feature("onum")};
                                          // feeds layout AND measurement
    disable_features: bit_set[Feature],   // DEPRECATED — prefer `features`/NO_LIGATURES
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
4. UAX #14 line-break + width fit; Thai runs word-break via the opt-in
   PyThaiNLP dictionary (`-define:RUNA_THAI_DICT=true`, CC-BY-SA) or, by
   default, fall back to grapheme-cluster breaks
5. UAX #9 L2 visual reorder per line

`cache: ^Cache` is optional — pass one to amortize shape work
across calls; zero-allocation cache hits are verified by the
test suite.

### Line breaking (Knuth–Plass)

Total-fit line breaking — every break in a paragraph chosen together
to even the lines, in the Knuth–Plass style. The core runs over an
abstract box/glue/penalty item stream the caller measures (each word
shaped once, its advances summed into a box width), so it is
font-agnostic and a multi-style caller (per-run styles, drop caps)
builds the items itself.

```odin
Break_Item   :: linebreak.Item   // Box | Glue | Penalty
Break_Params :: linebreak.Break_Params
Break_Point  :: linebreak.Break  // { item: int, ratio: f32, flagged: bool }

break_box     :: proc(width: f32) -> Break_Item
break_glue    :: proc(width, stretch, shrink: f32) -> Break_Item
break_penalty :: proc(p: f32, width: f32 = 0, flagged := false) -> Break_Item

// line_widths is one width per line; the last repeats (first-line indent,
// drop-cap lines, hanging markers). Returns one Break per line.
break_lines  :: proc(items: []Break_Item, line_widths: []f32, params: Break_Params,
                     allocator := context.allocator) -> (breaks: []Break_Point, ok: bool)
break_greedy :: proc(items: []Break_Item, line_widths: []f32,
                     allocator := context.allocator) -> []Break_Point

// Single-font convenience: shapes `text`, builds the items (words→boxes,
// spaces→glue, soft hyphens→flagged penalties), breaks to `line_widths`.
// Break opportunities come from runa's UAX #14 engine, so it wraps every
// script (CJK/Thai included), not just space-separated text.
Text_Line  :: struct { start, end: int, ratio: f32, hyphenated: bool }
break_text :: proc(font: ^Font, text: string, size: f32, line_widths: []f32,
                   params: Break_Params = {}, hyphen_penalty: f32 = 50,
                   cache: ^Cache = nil, allocator := context.allocator) -> ([]Text_Line, bool)
```

`Break_Params` tunes the optimisation: `tolerance`, `line_penalty`,
`flagged_demerits` (two hyphenated lines in a row), `fitness_demerits`
(adjacent lines of very different tightness), `final_hyphen_demerits`
(hyphenating the last full line), `max_consecutive_hyphens` (a hard
cap), and `ragged` (even the lines by cost without spreading them).
The four demerit fields take `0` to mean "use the default" and a
negative to disable; they are strong **nudges, not absolute rules** —
e.g. `final_hyphen_demerits` defaults to `1e6`, enough to avoid a
last-line hyphen in normal text but still yielding when the only
alternative is a catastrophically loose line. A soft hyphen is a
flagged penalty whose width is the font's hyphen, drawn only where a
line actually breaks there. Hyphenation itself stays with the caller
(feed U+00AD soft hyphens — runa optimises over them, it doesn't ship
Liang patterns). When no total-fit solution exists the breaker widens
tolerance and finally falls back to `break_greedy`, so a result always
comes back. A chapter (~500 paragraphs) reflows in single-digit ms.

### Cache

```odin
cache_make         :: proc(allocator := context.allocator,
                           max_entries: int = 4096) -> Cache
cache_destroy      :: proc(c: ^Cache)
cache_size         :: proc(c: ^Cache) -> int
cache_capacity     :: proc(c: ^Cache) -> int
cache_set_capacity :: proc(c: ^Cache, max_entries: int)
```

The shape cache holds memoised `[]Shaped_Glyph` keyed by
`(font, size, axis_state, text)`. Cache hits return the same slice
across calls with zero heap allocations.

Eviction is **classic O(1) LRU** with a soft cap of `max_entries`
(default 4096, roughly 4-8 MB at body sizes). When inserting past
the cap, the least-recently-used entry is evicted and its glyph
storage + interned text key are freed. Pass `max_entries = 0` to
disable eviction entirely — suitable for short-lived caches or
workloads with a known finite key set, but unbounded growth on
high-churn unique text.

`cache_size` / `cache_capacity` / `cache_set_capacity` exist for
apps that want to monitor or tune the cache at runtime (e.g. an
editor that grows the cap as the document gets bigger, or a
debug overlay that displays cache pressure).

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
                     atlas: ^Atlas, allocator := context.allocator,
                     hint: bool = true) -> (Atlas_Slot, Error)
```

`hint: true` (the default) enables the minimal Latin autohinter —
pulls outline Y coordinates onto integer pixel rows for the
baseline, x-height, cap-height, ascender, and descender blue
zones, with relative-snap suppression of round-letter overshoot.
Fixes the unhinted "fluffy bottom-of-S lip" and "lump on round
caps at body sizes" artifacts without a TrueType bytecode
interpreter.

Latin-only — non-Latin fonts have `_hint_metrics.valid = false`,
so the hinter is silently a no-op on Arabic / Devanagari / CJK
fonts (it would distort more than help under this heuristic).

Pass `hint: false` to force unhinted outline rendering — e.g.
for "honest pixel" display work, design-comparison screenshots,
or callers that have visually calibrated against pre-v1.1
unhinted output.

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

## Unicode conformance

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

## Known gaps

- **CFF2 ligature component tracking** — GPOS lookup type 5
  (mark-to-ligature) currently attaches all marks to the last
  component of the ligature. Proper per-component bookkeeping
  requires GSUB ligature substitution to record component spans
  on the output glyph.
- **TrueType hinting** — modern displays don't need it; only
  added if real demand emerges.
- **Hyphenation dictionaries (Liang)** — the caller supplies soft
  hyphens (U+00AD); runa's Knuth–Plass breaker optimises over them
  but doesn't ship language patterns. (Total-fit breaking itself
  landed in 1.5.0 — see **Line breaking** above.)
