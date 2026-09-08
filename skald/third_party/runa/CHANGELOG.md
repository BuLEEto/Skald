# Changelog

`runa` follows [semantic versioning](https://semver.org) on a
best-effort basis: breaking changes bump the major, new features
bump the minor, bug fixes bump the patch.

Pre-1.0 (i.e. all `0.x` releases) breaking changes are allowed but
must be flagged in a `### Breaking changes` section per release.
Source-compatible additions (new procs, new defaulted parameters,
new optional features) live under `### Added` / `### Changed`.

## 1.2.3 — 2026-07-25

### Fixed

- **A single combining mark severed Arabic cursive joining.** Any harakat
  broke the chain, so all vocalised Arabic rendered as disconnected
  isolated forms — `بَب` shaped to three isolated BEHs.

  `ArabicShaping.txt` omits `Joining_Type=T` characters by design,
  defining them as the unlisted Mn/Me/Cf codepoints. runa returned its
  non-joining sentinel for everything unlisted, which the state machine
  treats as chain-breaking. `joining_type` now derives the Transparent
  set from General_Category, still consulting the explicit listing first
  — ZWJ and ZWNJ are both `Cf` but listed `C` / `U`.

  `بب`, `بَب`, `بَبَب` and `مُحَمَّد` now match HarfBuzz glyph-for-glyph.
  `test_transparent_table_matches_ucd` sweeps the whole codepoint space
  against the vendored UCD so a bad table regeneration cannot pass
  silently.

- **Default-ignorables no longer paint.** U+061C ARABIC LETTER MARK
  rendered as a visible 0.6 em glyph mid-word; LRM / RLM / soft hyphen /
  variation selectors were likewise drawn. They now emit a zero-advance
  space, matching HarfBuzz, while still doing their job in the joining
  and bidi passes — ZWNJ continues to break the cursive chain.
  Regression: `test_default_ignorables_do_not_paint`.

### Known gaps

- **Ligatures do not skip marks.** `لَا` still fails to form the lam-alef
  ligature: HarfBuzz `[291, 704]`, runa `[47, 291, 667]`. GSUB matching is
  adjacency-only and never consults `Lookup_Info.flag`, so
  `LOOKUP_FLAG_IGNORE_MARKS` is ignored and the fatha blocks the match.
  Needs a GDEF parser. The joining fix is a prerequisite for this, not a
  substitute.
- **`shape_run` does not normalize.** Quranic Arabic depends on it
  (ALEF + MADDAH), and it also shows up in Hebrew nikud: `שָׁלוֹם` shapes
  with two combining marks in the opposite order to HarfBuzz
  (`… 100 79 96` vs `… 79 100 96`) because the canonical reordering
  pass is missing. The `normalize` package implements NFC/NFD/NFKC/NFKD
  at 100 % conformance; the shaper just does not call it.
- **Malayalam diverges from HarfBuzz on common words** — `കാര്യം`
  (*kāryaṃ*) shapes to `[23 64 148 49 6]` against HarfBuzz's
  `[23 64 50 160 6]`. Devanagari NGA conjuncts (`कङ्क`) likewise. Common
  Devanagari is unaffected (`नमस्ते`, `हिन्दी` match). README's script
  table now states this rather than claiming byte-for-byte parity across
  all 13 scripts.

## 1.2.2 — 2026-07-25

### Fixed

- **Indic reph reordering corrupted glyph order before punctuation.** A
  Devanagari word ending in RA + VIRAMA followed by any non-Indic
  character — space, comma, digit, Latin letter, or the danda `।` —
  emitted that character *ahead of* the syllable: `कर् क` shaped to
  `[ka, space, reph, ka]`. Bengali, Kannada, Gujarati and Odia share the
  code path.

  When a reph leads a syllable with no base after it, `identify_base`
  fell back to an index pointing past the syllable, at the next
  syllable's first glyph, which `reorder_reph` then rotated into the
  cluster. Same defect as the 1.2.1 crash — that fix guarded the crash
  site, which only fires when the index runs off the whole buffer, so
  with a following character it corrupted silently instead of panicking.

  1.2.2 fixes the root, and recognises an independent vowel as a base
  candidate: the OpenType vowel-based syllable `[Ra H] V …` is
  spec-sanctioned, so `र्अ` must keep emitting the reph after its vowel.

### Known gaps surfaced while fixing the above

Pre-existing, none introduced by this release:

- ~~Arabic combining marks resolve to `Joining_Type=X`, so a single fatha
  severs cursive joining: vocalised Arabic renders disconnected.~~
  **Fixed in 1.2.3.**
- `rphf` is applied buffer-wide with no positional gate, so runa forms a
  reph where HarfBuzz declines to (no base present). The 1.2.2 tests pin
  the *ordering*, which HarfBuzz agrees with, not this composition.
- Cluster indices desync after ligation (`resize` truncates from the
  right; GSUB removes from the middle), so glyphs after a ligature report
  an earlier byte offset.
- The Indic v1-script-tag retry fires whenever a v2 feature matched
  nothing, applying v1-only lookups to fonts that ship v2.
- GPOS mark attachment omits the base's `hmtx` advance; `abvm` / `blwm` /
  `dist` are never applied; `Lookup_Info.flag` is ignored.
- Cursive joining is gated on `script == "arab"`, so Syriac never gets
  init / medi / fina.

## 1.2.1 — 2026-05-26

### Fixed

- **Indic shaper out-of-bounds crash on a lone reph.** A Devanagari
  cluster ending in RA + Virama with no following base consonant (e.g.
  `र्`) made `reorder_reph` compute `base_idx == len` and index past the
  glyph buffer — a panic, and a denial-of-service vector for anything
  shaping untrusted text. The reorder now bails when the reph has no
  base consonant. Regression: `test_devanagari_lone_reph`.

- **Glyph-bitmap allocation is now bounded.** `raster_glyph` accepted any
  positive size, and the bitmap dimensions (`bbox × size`) were unbounded —
  so a pathological size, or a malicious font with an absurd glyph bbox,
  could drive an enormous allocation (OOM). `raster_glyph` now rejects
  non-finite / non-positive / absurd sizes, and bitmap allocation refuses
  dimensions past `RASTER_MAX_DIM` (4096) for both alpha and COLR paths.
  Regression: `test_bitmap_make_dimension_cap`.

Both found by fuzzing the engine (font parse + shape + raster) under
AddressSanitizer / MemorySanitizer.

## 1.2.0 — 2026-05-22

Headline: **`runa.Cache` is now bounded.** v1.x shipped an unbounded
shape cache — the `(font, size, axis_state, text)` → glyphs map
grew without limit. Static-text UIs (cookbooks, chat windows with
a finite peer list) never noticed. High-churn UIs hit a real heap
leak: Skald measured ~100 MB / minute / 100 unique-strings-per-tick
in a stress test, which matches the math for typical body text
(~900 bytes per cache entry × cache misses without eviction).

The cache now evicts the least-recently-used entry once it holds
`max_entries` distinct keys. Default cap is `4096` entries (roughly
4-8 MB on body text). High-churn workloads — code editors, log
viewers, animated tickers, file managers — now have bounded memory
without changing call sites.

### Added

- `cache_size(c)`, `cache_capacity(c)`, `cache_set_capacity(c, n)`
  for monitoring + runtime tuning. Useful for editor apps that
  want to grow the cap as the document gets bigger, or debug
  overlays that surface cache pressure.
- `cache_make` now accepts `max_entries: int = 4096`. Pass `0` to
  disable eviction entirely — restores the v1.0 unbounded
  behaviour, suitable for short-lived caches or workloads with a
  known finite key set.

### Changed

- `runa.Cache` internals: replaced the `map[Shape_Key]Cache_Entry`
  with a slot-pool + intrusive doubly-linked list + key→index map.
  O(1) per hit (with LRU move-to-head), O(1) per miss-with-evict.
  The `Cache` struct is documented as opaque so the field rename
  doesn't break source compatibility.
- `cache_make()` (no args) now caps the cache at 4096 entries by
  default. Callers who were relying on unbounded growth — there's
  not many obvious reasons to want this, but the back-compat hatch
  is `cache_make(context.allocator, 0)`.

### Implementation notes

- LRU bookkeeping is index-based, not pointer-based — entries live
  in `[dynamic]Cache_Entry` and link via `u32` indices, so map
  rehashes / array growths don't invalidate links.
- Eviction order is per the dedicated stress test in
  `tests/runa/font_test.odin`: a sticky key touched after each
  batch of new inserts survives 20 unique-string evictions with
  the same slice identity, confirming the LRU policy.
- Tracking-allocator coverage: 500-insert stress over a 16-slot
  cap allocates and frees every byte (484 evictions + 16 destroys),
  no leaks under `mem.Tracking_Allocator`.

## 1.0.1 — 2026-05-17

### Fixed

- **Slice out-of-bounds on invalid UTF-8 in run-splitting walks**
  (`SIGILL` / "Illegal instruction" crash). The codepoint loops in
  `layout_paragraph`, `measure_text`, `measure_text_cached`,
  `wrap_glyphs`, and `bidi.resolve_levels` derived the per-codepoint
  byte advance from the decoded rune *value* (`utf8_byte_len(r)`).
  For valid UTF-8 that matched Odin's range-over-string. For invalid
  UTF-8 the iterator returns `U+FFFD` after consuming 1 raw byte,
  while `utf8_byte_len(U+FFFD)` returns 3 — so the byte counter
  over-counted by 2 per invalid byte and eventually exceeded
  `len(text)`. The next slice into `text` then went out of bounds
  and the runtime trapped. Replaced the walks with
  `utf8.decode_rune_in_string` so the byte advance always matches
  the decoder's actual consumption. Surfaces in any caller passing
  text from the network, clipboard, or partially-decoded buffers;
  triggered in practice by an incoming Nostr chat message.

## 1.1.0 — 2026-05-21

Headline: **autohinter on by default.** v1.0 shipped with a known
fluffiness artifact at body text sizes — round letters (S, O, c,
e, o) had a stray partial-coverage row at the top and bottom of
their bowls because the outline's natural sub-pixel overshoot got
rasterised as a fractional row of antialiased coverage. v1.1
defaults to running the Latin autohinter we built between 1.0 and
1.1, which snaps blue zones and suppresses sub-pixel overshoot.
Text at 10-30 px on 96 DPI looks visibly cleaner; display sizes
(above ~50 px) are unaffected because overshoot is preserved
there by design.

### Breaking changes (visual)

`raster_glyph`'s `hint` parameter defaults to `true` (was `false`
in v1.0.x). Anyone who visually calibrated against the v1.0
unhinted output — golden image comparisons, hand-tuned letter
spacing, screenshot diffs — will see those break.

Two recovery options:

- **Accept the new default.** Most callers will look visibly
  cleaner with no other change.
- **Pass `hint: false` explicitly.** Forces the v1.0 behavior on
  a per-call basis. The flag still exists; we just flipped the
  default.

Non-Latin fonts (Arabic, Devanagari, CJK, Khmer, etc.) are
unaffected — the autohinter detects missing reference glyphs at
font load and silently no-ops on those fonts.

### How the autohinter works

`raster/autohint.odin` (~200 LOC). At font load we sample seven
reference glyphs to extract blue zones:

  H.y_max  → cap_height
  x.y_max  → x_height
  l.y_max  → ascender
  p.y_min  → descender
  o.y_min  → round_bottom (overshoot below baseline)
  o.y_max  → round_x_height (overshoot above x-height)
  O.y_max  → round_cap_height (overshoot above cap-height)

At raster time each blue zone is scaled and snapped to an integer
pixel row. Outline Y coordinates get remapped linearly between
snapped zones. Round-zone snaps are computed *relative to* their
flat anchor: if the pre-scale overshoot is < 0.5 px, the round
zone snaps to the same row as the flat zone (suppress); if it's
larger, it snaps to ±round(gap) rows (preserve). The relative
threshold avoids the half-pixel-straddle bug where independent
rounding could emit a 1-px gap from a 0.2-px overshoot.

Latin-only. The heuristic is built for the Latin stem structure
and would damage glyph shapes on Arabic / Devanagari / CJK.
Variable fonts work fine — hint metrics use the default-instance
glyph extents.

What this version doesn't do (and may add in 1.2 if the artifacts
surface in real use):

- **Vertical stem-width snapping.** Y is hinted; X stems still
  rely on the 4-bucket subpixel-X positioning. No visible artifact
  reported yet, but the foundation is asymmetric.
- **Per-glyph stem detection.** Crossbar of `e`, dot of `i`,
  middle stroke of `a`, etc. are positioned by linear
  interpolation between blue zones, not by individual stem
  analysis. Real FreeType-style autohinters do this.

### Added — Autohinter blue-zone snap + overshoot suppression

`raster_glyph(..., hint: true)` is the default. The full
autohinter story across multiple iterations:

- **Blue-zone snap** — baseline / x-height / cap-height / ascender
  / descender snap to integer pixel rows with linear interpolation
  between them.
- **Round-bottom suppression** — sample `o.y_min` (or `O` as
  fallback) for the overshoot below baseline.
- **Round-top suppression (lowercase)** — sample `o.y_max` for the
  overshoot above x-height.
- **Round-top suppression (uppercase)** — sample `O.y_max` for the
  overshoot above cap-height.
- **Relative-snap** — round-zone snap is computed against the flat
  anchor's gap, not via independent rounding. Avoids the
  half-pixel straddle bug where flat=17, round=18 from
  independent rounding even when the actual overshoot is 0.2 px.

Five raster tests pin the behavior: identity (no-op when
metrics.valid=false), baseline snap (fractional baseline lands
on integer row), top suppression at body size, bottom
suppression at body size, top-and-bottom shrinkage end-to-end on
Roboto O, and the half-pixel straddle regression.

### Other v1.x progress that landed between 1.0 and 1.1

This minor release also includes the work shipped on the 1.0.x
patch series: UAX #29 word + sentence iterators, UAX #15
normalization, line-break conformance polish. See the 1.0.x
section below.

## 1.0.0 — 2026-05-16

Closes the v1.0 punch list. UAX #9 bidi hits 100.00 % (was
99.998 %), UAX #14 line break jumps to 99.91 % (was 99.4 %), all
28 COLR composite blend modes lit up (was 12), Thai word-break
dictionary embedded so Thai paragraphs reflow at word boundaries,
and the new UAX #29 word boundary iterator ships at 100.00 %
WordBreakTest conformance for double-click word selection and
word-by-word cursor movement.
API.md refreshed for v0.9.2 → v1.0.0 surface.

### Fixed — Autohinter: relative snap for round zones

Round-zone suppression was using *independent* `math.round` on
each zone's pre-scale, which silently misbehaved when the flat
and round pre-scales straddled a half-pixel boundary. Concrete
case from Skald's body-text bench:

  cap_height_pre        = 17.46    →  round  →  17
  round_cap_height_pre  = 17.70    →  round  →  18

Real overshoot was 0.24 px (well under half a pixel) but
independent rounding emitted a 1-px gap, the lerp band preserved
it, and round capitals (C, S, O) showed a stray "lump" pixel at
the top at body sizes (12-14 px).

Fix: round-zone snap is now *relative* to its flat anchor. The
gap between flat_pre and round_pre is computed directly; if it's
< 0.5 px, the round zone snaps to the same row as the flat anchor
(suppress); if >= 0.5 px, it snaps to ±round(gap) rows (preserve
overshoot). No more straddling-the-boundary surprises — the
suppression threshold is the actual pre-scale overshoot, not an
artifact of where the absolute pre-values fall on the pixel grid.

Applies to all three round zones (round_bottom, round_x_height,
round_cap_height). One new regression test pins the
Skald-reported case (cap=1490, round_cap=1510, UPM 2048, size 24
→ both snap to 17).

### Fixed — Autohinter: round-letter overshoot suppression (top too)

The first round_bottom fix only handled the bottom of round
letters. The top side has the same overshoot — `o`, `c`, `e`, `s`
extend slightly above x-height; `O`, `C`, `S` extend slightly
above cap-height — and Skald hit a mirrored fluff artifact at the
top of these letters once the bottom was fixed.

Added `round_x_height` (sampled from 'o.y_max') and
`round_cap_height` ('O.y_max') blue zones. apply_hint_y now has
bands x_height..round_x_height and cap_height..round_cap_height.
At body sizes both endpoints of each band snap to the same
integer row → the lerp collapses → overshoot suppressed. Same
display-size recovery as the bottom side.

End-to-end: Roboto 'O' at 14 px goes from 9×12 unhinted to 9×10
hinted — both fluff rows (top and bottom) gone.

### Fixed — Autohinter: round-letter overshoot suppression

The minimal Latin autohinter shipped without sampling the
`round_bottom` blue zone — the small (≤1 px sub-pixel) overshoot
that round letters (S, O, c, e, o) extend below the baseline so
the eye reads them at the same height as flat-bottom letters. At
body sizes that overshoot rasterises as a partial-coverage row at
the bottom of the bitmap — the visible "fluffy bottom-of-S lip"
artifact. The earlier autohinter's blue zones jumped straight from
baseline (0) to descender (~-7 px at body size), so a point at the
overshoot (~-0.2 px) interpolated almost-zero and the fluff row
survived.

Fix: sample `o.y_min` (or `O.y_min` as fallback) at font load,
add a `round_bottom` band to the snap. At body sizes the
sub-pixel overshoot pre-scale rounds to 0 = baseline_snap and
the entire round_bottom..baseline lerp collapses to 0 — the
overshoot is suppressed, the fluff row is gone, and the bitmap
shrinks by one row (verified end-to-end: O at 14 px goes from
9×12 unhinted to 9×11 hinted).

At display sizes (~85 px+ on Inter) the overshoot pre-scale
crosses 0.5 px and the natural integer round produces -1 px, so
the lerp recovers a real 1-px overshoot — which is what the font
designer intends to be visible at that scale. No threshold param
needed; the transition happens naturally where the math says it
should.

### Added — Minimal Latin autohinter (opt-in)

New `raster_glyph(..., hint: true)` flag enables a small Latin
blue-zone autohinter. At font load time we sample 'H', 'x', 'p',
'l' to extract cap-height / x-height / descender / ascender in
font units. At raster time those values are scaled and rounded to
integer pixel rows for the requested size; every outline Y is then
remapped linearly between the snapped zones. Points landing on a
blue zone are pixel-perfect; intermediate features drift
proportionally.

The visible effect: bottom-of-S / bottom-of-e / bottom-of-c at
body sizes (10-14 px on 96 DPI) no longer split across two
half-coverage rows. The unhinted-outline "fluffy" artifact goes
away. Designed as a non-blocking interim to a full FreeType-style
autohinter or TrueType bytecode interpreter, neither of which is
on the roadmap.

Latin-only. Non-Latin fonts (Arabic / Devanagari / CJK / Khmer)
miss the reference codepoints during sampling, so
`Font._hint_metrics.valid` stays `false` and the flag is silently
a no-op — the autohinter heuristic would damage glyph shapes more
than help on those scripts. The check is per-font, so a font that
lacks 'H' (a script-specific font with no Latin coverage)
gracefully degrades to unhinted rendering.

Other limitations baked in:

- **Y-only.** No vertical stem snapping yet — the symptom we're
  fixing is bottom-of-S fluffiness, which is purely a Y artifact.
  Subpixel-x positioning still works the same.
- **No overshoot preservation.** Round letters like O lose their
  small "below the baseline" overshoot at small sizes. Most
  hinting policies do this anyway at body sizes — overshoot is a
  display-size feature.
- **Linear interpolation between zones.** Real autohinters detect
  stems and snap them individually; this version just lerps. The
  bottom of S happens to coincide with the baseline blue zone in
  virtually every font, so the lerp gives the right answer there.

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
