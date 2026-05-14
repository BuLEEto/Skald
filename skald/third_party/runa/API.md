# runa API reference (v0.9-rc1)

Pure-Odin text engine — parse, shape, line-break, raster, atlas.
Public API lives in three layers: the **facade** in `runa.odin`,
the **packages** (`parse`, `shape`, `itemize`, `bidi`, `linebreak`,
`raster`), and the **examples**. Most callers only need the facade.

## Stability

v0.9-rc1 freezes the names below. Pre-1.0 patches may still adjust
**implementations** (perf, accuracy, error messages), but signatures
won't break without a **`### Breaking changes`** entry in
[`CHANGELOG.md`](CHANGELOG.md).

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
for `gvar` (TrueType-variable) **and** CFF2 fonts as of v0.9.

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
3. shape each run via `shape_text` (GSUB + GPOS)
4. UAX #14 line-break + width fit
5. UAX #9 L2 visual reorder per line

`cache: ^Cache` is optional — pass one to amortize shape work
across calls; zero-allocation cache hits are verified by the
test suite.

### Rasterization (atlas)

```odin
raster_glyph :: proc(font: ^Font, gid: Glyph_ID, size: f32, subpx_x: u8,
                     atlas: ^Atlas, allocator := context.allocator) -> (Atlas_Slot, Error)
```

Renders one glyph into the shared atlas at the requested subpixel
offset. COLRv0 / COLRv1 emoji are auto-detected and rasterized
through the colour-bitmap path (RGBA pages); mono glyphs land on
alpha pages. The COLRv1 brush-aware rasterizer (linear / radial /
sweep gradients + composite modes) is preferred over the v0
flat-fill path when the font carries a v1 BaseGlyphList.

## Packages

| Package | Purpose |
|---|---|
| `parse` | OpenType table readers — head, maxp, cmap, hmtx, hhea, loca, glyf, CFF, CFF2, GSUB, GPOS, GDEF, fvar, avar, gvar, HVAR, MVAR, COLR (v0 + v1), CPAL, kern. |
| `shape` | GSUB substitution + GPOS positioning. Per-script logic (Arabic joining state machine) lives here. |
| `itemize` | UTF-8 → runs by script (UAX #24) + UAX #29 grapheme cluster iterator. |
| `bidi` | UAX #9 bidirectional algorithm — 100 % BidiCharacterTest conformance. |
| `linebreak` | UAX #14 line break opportunities + width-fit splitter. 99.4 % LineBreakTest conformance. |
| `raster` | Analytic-coverage scanline rasterizer + atlas allocator (shelf packing, alpha + RGBA pages). |

## Unicode conformance (v0.9-rc1)

| Standard | Conformance |
|---|---|
| UAX #9 bidirectional | **100.00 %** (91 704 / 91 707 BidiCharacterTest.txt rows; 3 residual deep-nested empty-RLE/PDF edge cases where the reference impl diverges from the spec text) |
| UAX #14 line break | 99.4 % (LineBreakTest.txt; residual is rare Hebrew-letter + QU context states) |
| UAX #24 script segmentation | 100 % (per-codepoint script lookup) |
| UAX #29 grapheme clusters | **100.00 %** (766 / 766 GraphemeBreakTest.txt rows) |

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
| `tools/deep_stress.odin`      | 2 000-iter end-to-end loop under `Tracking_Allocator` for leak detection. Also outlines every glyph of two CFF1 + one CFF2 font. |
| `tools/bit_flip_fuzz.odin`    | Bit-flipped corpus fuzz — runs glyph extraction + shape against mangled SFNTs and asserts no panics. |

## Known gaps for v1.0

- **Complex-script shapers** — Indic family (Devanagari, Bengali,
  Tamil, Telugu, Kannada, Malayalam, Gurmukhi, Gujarati, Odia) and
  SEA scripts (Thai, Lao, Myanmar, Khmer). The grapheme cluster
  algorithm already handles their *cluster boundaries*; the
  per-script *reordering rules* (RPHF, BLWF, HALF, PSTF, PREF,
  etc.) land per-family in v1.0.
- **COLR composite blend modes** — v0.9 implements SrcOver / SrcIn
  / SrcOut / DestIn / DestOut / Plus / Multiply / Screen / Darken
  / Lighten / Clear / Src / Dest. HSL variants, Xor, SrcAtop,
  DestOver, DestAtop, Overlay, ColorDodge / Burn, SoftLight /
  HardLight, Difference, Exclusion fall back to SrcOver.
- **CFF2 ligature component tracking** — GPOS lookup type 5
  (mark-to-ligature) attaches marks to the *last* component until
  GSUB ligature substitution starts recording component spans.
- **TrueType hinting** — modern displays don't need it; only added
  if real demand emerges.
- **Hyphenation / Knuth–Plass justification** — post-v1.0 separate
  release.
