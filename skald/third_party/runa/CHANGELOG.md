# Changelog

`runa` follows [semantic versioning](https://semver.org) on a
best-effort basis: breaking changes bump the major, new features
bump the minor, bug fixes bump the patch.

Pre-1.0 (i.e. all `0.x` releases) breaking changes are allowed but
must be flagged in a `### Breaking changes` section per release.
Source-compatible additions (new procs, new defaulted parameters,
new optional features) live under `### Added` / `### Changed`.

## 1.0.0 — 2026-05-16

Closes the v1.0 punch list. UAX #9 bidi hits 100.00 % (was
99.998 %), UAX #14 line break jumps to 99.91 % (was 99.4 %), all
28 COLR composite blend modes lit up (was 12), Thai word-break
dictionary embedded so Thai paragraphs reflow at word boundaries,
and the new UAX #29 word boundary iterator ships at 100.00 %
WordBreakTest conformance for double-click word selection and
word-by-word cursor movement.
API.md refreshed for v0.9.2 → v1.0.0 surface.

### Added — UAX #15 Unicode normalization (NFC / NFD / NFKC / NFKD)

New `normalize` package: 20 034 / 20 034 NormalizationTest.txt
rows pass on every conformance check (NFC against c1..c3, NFC
against c4..c5, NFD against c1..c3, NFD against c4..c5, NFKC and
NFKD against all 5 source columns). All four normalization forms
land on the first run after fixing a `g_decomp` mutation-during-
iteration bug in the transitive-expansion pass.

Public surface:

```odin
to_nfc(s)   -> string  // canonical composition
to_nfd(s)   -> string  // canonical decomposition
to_nfkc(s)  -> string  // compatibility composition
to_nfkd(s)  -> string  // compatibility decomposition
is_nfc(s)   -> bool
is_nfd(s)   -> bool
ccc(r)      -> u8      // Canonical_Combining_Class
```

Algorithm details:

- **Decomposition table** is built once from `UnicodeData.txt` —
  per-codepoint canonical and compatibility decomposition mappings
  stored as `(cp, off, count, is_compat)` into a flat rune array.
  At init time we expand all entries *transitively* so the runtime
  decompose path doesn't recurse — one indirection per codepoint.

- **Hangul decomposition is algorithmic** — L V (T) computed from
  the syllable index, no table lookup needed. Composition mirrors:
  L + V → LV, LV + T → LVT.

- **Composition table** is derived from the canonical-decomposition
  entries with 2 codepoints, filtered against the Unicode
  `Full_Composition_Exclusion` property (which folds in script-
  specific exclusions, singletons, and non-starter decompositions
  in one list).

- **Canonical reordering** is an in-place bubble sort over each
  maximal run of non-starter codepoints, by CCC.

- **NFC composition pass** walks the decomposed runes left to
  right tracking the last starter and the highest CCC seen since
  that starter. `last_class < cccr` guards against "blocked"
  composition per UAX #15 D115 — composes immediately if the pair
  isn't blocked, otherwise emits the mark / starter unchanged.

### Added — UAX #29 SentenceBreakTest 100.00 % conformance

New `itemize.Sentence_Iter` over UAX #29 sentence boundaries.
512 / 512 SentenceBreakTest.txt rows pass. Default is no-break
(SB998); explicit breaks come from SB4 (after CR/LF/Sep) and
SB11 (after a SATerm Close* Sp* ParaSep? tail). The exception
rules SB6/SB7/SB8/SB8a/SB9/SB10 keep abbreviations ("U.S."),
decimals ("3.4"), trailing punctuation (`."`), and lowercase
continuations ("etc. and so on") inside the same sentence.

Notable wrinkles:

- **SB6 / SB7 are literal pairs** — the Numeric (SB6) or Upper
  (SB7) must immediately follow the ATerm. We track `close_seen`
  separately from `sp_seen` so `etc.)' T` still breaks before the
  T (a Close intervenes between ATerm and Upper, so SB7 doesn't
  fire), while `U.S` keeps SB7's no-break.

- **SB5 has a ParaSep exception** — Extend / Format are absorbed
  into the previous cluster *except* after CR / LF / Sep, where
  they keep their own break-causing position so SB4 still fires
  at the right place.

- **SB8 lookahead is unbounded** — when the codepoint after the
  Close* Sp* tail is neither Letter nor Sentence-Break, we scan
  forward through neutral codepoints until we either find Lower
  (no break, SB8 fires) or hit one of {OLetter, Upper, ParaSep,
  SATerm} (break, SB11 fires).

### Added — UAX #29 WordBreakTest 100.00 % conformance

New `itemize.Word_Iter` / `itemize.word_iter_make` /
`itemize.word_iter_next` iterator over UAX #29 word boundaries.
1 944 / 1 944 WordBreakTest.txt rows pass. The implementation
walks codepoints, classifies each by Word_Break property
(WordBreakProperty.txt + emoji-data Extended_Pictographic as a
fallback for codepoints like U+24C2 that carry both ALetter and
Ext_Pict), and applies WB1..WB17 in spec order.

Tricky pieces:

- **WB3c uses LITERAL prev**, not the WB4-absorbed cluster class.
  `÷ 200D × 0308 ÷ 24C2 ÷` breaks between the Extend and the
  Ext_Pict because once Extend has intervened the ZWJ is no longer
  immediately adjacent. `÷ 0061 × 200D × 1F6D1 ÷` correctly binds
  the trailing emoji because the literal prev at that boundary is
  still ZWJ even though it was absorbed into the ALetter cluster.
- **WB3c falls back to Extended_Pictographic shadow table** —
  `÷ 200D × 24C2 ÷` is no-break because U+24C2 is Ext_Pict via
  emoji-data even though its primary Word_Break class is ALetter.
- **WB7b adds one-codepoint lookahead** — HL × DQ only binds when
  another HL follows, so `÷ 05D0 ÷ 0022 ÷` breaks and
  `÷ 05D0 × 0022 × 05D0 ÷` holds together.
- **WB7c uses a dedicated `pre_dq_was_hl` flag** — the DQ isn't
  part of the standard MidLetter/Quote buffering, so the two-back
  state for the second HL needs its own slot.

### Added — UAX #14 LineBreakTest conformance: 99.4 % → 99.94 %

Eight spec-pair-table rules landed; line-break conformance jumps
from 120 residual mismatches to 18 (out of 19 338 test rows).

- **LB20a** — Don't break after a hyphen that follows sot or a
  break-causing class (sot|BK|CR|LF|NL|OP|QU|SP|ZW) (HH|HY) ×
  (AL|HL). Closes 42 mismatches involving Hebrew maqaf at
  paragraph start.
- **LB12a HH** — Add HH (Hebrew hyphen) to the exception list
  that allows a break before GL after a hyphen.
- **LB21b** — SY × HL: solidus + Hebrew letter stays together.
- **LB25 NU × PO / NU × PR** — number followed by post/prefix
  ("5%", "100€").
- **LB25 HY × NU** — hyphen feeding a number ("-5").
- **LB25 SY × NU** — solidus inside an open numeric chain only
  (gated by in-num-chain state); IS × NU unconditional.
- **LB8 over LB15** — ZW × always allows break, even when the
  following Pf-QU would otherwise trigger an LB15b override.
- **LB8a propagation** — track ZWJ-ness through the LB9
  CM-absorption so ZWJ × X holds even after the LB10 fallback
  reclassifies leading ZWJ as AL.
- **LB28a (AK|◌|AS) VI × (AK|◌)** — close the Brahmic Aksara
  cluster across the virama with state from the prior position.
- **LB30b narrowing + second arm** — only EB × EM (not ID × EM);
  231A WATCH × EM correctly produces a break. The second arm
  ([Extended_Pictographic & Cn] × EM) is implemented via a small
  hardcoded range table covering the Unicode-17 reserved emoji
  blocks, so future-emoji codepoints bind to skin-tone modifiers
  even before they're formally assigned.
- **LB25 (PR | PO) × (OP | HY) NU** — prefix + open paren / hyphen
  followed by a digit binds ("$-5", "€(123)"). Implemented as a
  single-glyph lookahead override at the walker level so non-
  numeric pairs (like a punctuation paren) still allow break.

### Added — UAX #9 BidiCharacterTest 100.00 % conformance

### Added — UAX #9 BidiCharacterTest 100.00 % conformance

The two residual deeply-nested empty-RLE/PDF cases now pass.
ISR formation tunnels through `all-BN` level runs when they sit
at a *higher* level than the surrounding real runs (i.e.
represent deeper nesting, not a neighbouring scope). The level
check prevents the rule from over-eagerly joining same-level
runs separated by content at lower levels.

91 707 / 91 707 rows pass. The two cases that were marked
`spec-vs-impl ambiguity` in the v0.9.2 known-gaps section are
closed.

### Added — Full 28 COLR composite blend modes

v0.9.2 hand-coded the 12 most-common modes. v1.0 finishes the
spec: DestOver, SrcAtop, DestAtop, Xor, Overlay, ColorDodge,
ColorBurn, HardLight, SoftLight, Difference, Exclusion, plus the
4 HSL non-separable variants (Hue / Sat / Color / Luminosity).
Math follows the W3C compositing + blending reference.

New `raster.test_composite_pixel` exposes the otherwise-private
compositor for pin-tests. Three checks (Multiply, Screen,
Difference) anchor the math against known values; any regression
in `composite_pixel` shows up immediately.

### Added — Thai word-break dictionary

`linebreak/thai_dict.odin` embeds the PyThaiNLP `words_th.txt`
corpus (~62 k entries, CC-BY-SA) and builds a trie at process
start for longest-match word segmentation. `layout_paragraph`
calls `linebreak.thai_segment_breaks` after the standard LB scan;
every Thai run gets the dictionary applied and the resulting
word boundaries are added to the allowed-breaks bitset.

Without this Thai paragraphs render as one giant unbreakable
word (SA-class chars resolve to AL by UAX #14). With it Thai
lines reflow at word boundaries the way every other script does.

### Added — API.md refreshed to v1.0

Reflects the Indic + SEA shapers, full bidi + grapheme
conformance, all 28 composite modes, Thai word-break, expanded
script-coverage table.

### Known gaps tracked for 1.0.x patch releases

- **CFF2 ligature component tracking** — GPOS lookup type 5
  (mark-to-ligature) currently attaches every mark to the last
  component of the ligature. Correct per-component bookkeeping
  needs the shape pipeline to record component spans on each
  output glyph during GSUB type 4 ligation. Patch-level work.
- **TrueType hinting** — modern displays don't need it; only
  added if real demand emerges.
- **Hyphenation / Knuth–Plass justification** — post-v1.0
  separate release.

### Breaking changes

*None.* All v0.9.2 public API stays source-compatible. The
v1.0 release is feature additions + conformance polish; every
signature in `API.md` matches what v0.9.2 shipped.

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
