# Changelog

`runa` follows [semantic versioning](https://semver.org) on a
best-effort basis: breaking changes bump the major, new features
bump the minor, bug fixes bump the patch.

Pre-1.0 (i.e. all `0.x` releases) breaking changes are allowed but
must be flagged in a `### Breaking changes` section per release.
Source-compatible additions (new procs, new defaulted parameters,
new optional features) live under `### Added` / `### Changed`.

## 0.9.2 — 2026-05-14

First public release. Pure-Odin modern text engine —
parse → itemize → shape → bidi → linebreak → rasterize → atlas,
all wired end-to-end with the bench / fuzz / golden / conformance
harnesses in place. API frozen at this revision; see
[`API.md`](API.md). Unicode version targeted: 17.0.

### What works

- **Parser**: OpenType / TrueType outlines (`glyf`, composite, CFF,
  CFF2 incl. non-default instance via Item Variation Store).
  Variable-font axes via `fvar` + `avar` + `gvar` + `HVAR` + `MVAR`.
  `cmap` (format 4 + 12), `hhea`, `hmtx`, `loca`, `maxp`, `head`,
  `GDEF`, `GSUB` (lookup types 1, 4, 5, 6 formats 1/2/3),
  `GPOS` (lookup types 2f1/f2, 4, 5, 6), `COLR` (v0 + v1), `CPAL`.
- **Shaper**: full GSUB feature application (`ccmp`, `locl`, `rlig`,
  `liga`, `clig`, `calt`); GPOS pair kerning + mark-to-base +
  mark-to-mark + mark-to-ligature; Arabic cursive-joining state
  machine producing `isol` / `init` / `medi` / `fina` forms.
- **Indic shaping for the full Brahmic family** —
  Devanagari, Bengali, Gujarati, Kannada, Odia, Tamil, Telugu,
  Malayalam, Gurmukhi. Syllable reorder (reph + pre-base matra),
  Indic feature pipeline in spec order (`locl` / `nukt` / `akhn` /
  `rphf` / `rkrf` / `pref` / `blwf` / `abvf` / `half` / `pstf` /
  `vatu` / `cjct` / `init` / `pres` / `abvs` / `blws` / `psts` /
  `haln`). v2 script tags tried first (`dev2`, `beng2`, etc.),
  fallback to v1 for legacy fonts. All 9 scripts verified
  byte-for-byte against HarfBuzz on canonical syllables.
- **SEA shaping (canonical syllables)** — Thai, Lao, Khmer,
  Myanmar shape correctly on the common syllable shapes
  (bare consonant, above / below vowels, pre-vowels, tones,
  simple medials). Thai / Lao route through standard GSUB
  (visual-order pre-vowels); Khmer uses the Indic pipeline
  with `Left`-IPC reorder; Myanmar handles medial RA / medial YA
  via the same path.
- **Bidi**: UAX #9 at **99.998 %** conformance against
  `BidiCharacterTest.txt` (91 705 / 91 707). Isolating-run
  sequences, FSI lookahead, N0 bracket pairs with canonical-
  equivalence matching, BD16 stack-overflow handling matching
  ICU, L1 segment separator reset, full X / W / N / I / L
  resolution.
- **Itemize**: UAX #24 script segmentation, UAX #29 extended
  grapheme clusters at **100.00 %** conformance against
  `GraphemeBreakTest.txt`. Handles Indic conjunct sequences,
  emoji ZWJ chains, regional-indicator pairs.
- **Linebreak**: UAX #14 pair-rule engine, plus LB15a/b context
  quotation, LB28a Aksara bind, LB30 East-Asian-Width OP, LB25
  number chains. **99.4 %** conformance against `LineBreakTest.txt`.
- **Rasterizer**: analytic-x scanline with 4× y super-sampling,
  4-bucket subpixel-x offset. TrueType + CFF + CFF2 outlines.
  Variable-font deltas applied to points before rasterization.
- **Colour glyphs**: COLRv0 layered, COLRv1 with linear / radial /
  sweep gradient rasterization, 13 of 25 spec composite blend
  modes (SrcOver / SrcIn / SrcOut / DestIn / DestOut / Plus /
  Screen / Multiply / Darken / Lighten / Clear / Src / Dest;
  others fall back to SrcOver).
- **Atlas**: shelf-packed with per-page dirty-rect tracking,
  alpha + RGBA pages, automatic page allocation on overflow.

### What's left for v1.0

- **Thai word-break dictionary** — shaping is correct, line layout
  currently falls back to ASCII rules.
- **Khmer complex clusters** — COENG-driven multi-consonant
  subscript chains need a dedicated cluster engine.
- **Full Myanmar shaping** — medial reorder, asat handling, kinzi.
- **Bidi deep-nested empty RLE/PDF** — 2 BidiCharacterTest cases
  diverge from ICU; spec-vs-impl ambiguities that need a deeper
  rework.
- **Remaining COLR composite modes** — HSL variants + the harder
  PDF blend modes (~5 % of real-world COLRv1 fonts).

### Perf

Snapshot in `bench/results/v0.9-rc1-baseline.txt`. Headline number:
5 000-word cold paragraph layout in 32.6 ms (target 30 ms; 1.09×,
within noise). Cache hits are zero-allocation. Indic / SEA work
didn't touch the Latin hot path — bench unchanged.

### Tested fonts

The test suite exercises eleven fonts when they're present in
`tests/fonts/` — see that directory's README for the list and
sources. CI fetches them on a best-effort basis; missing fonts
skip their tests rather than failing the build.

### API stability

`API.md` documents the v1.0-rc surface. v0.9 → v1.0 changes will
be additive only; existing call sites keep compiling unchanged.
v1.0 ships when the items in *What's left for v1.0* above land.
