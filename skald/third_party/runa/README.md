# runa

A pure-Odin modern text engine — parsing, itemization, shaping,
line-breaking, rasterization. Built first to replace fontstash +
stb_truetype in [Skald](https://github.com/BuLEEto/Skald), designed
to be useful for any Odin project that needs production-quality text.

**Status:** v1.0.0 — *"The complex-script v1.0 punch list ships."*
UAX #9 bidi at **100 %**, UAX #29 graphemes at 100 %, CFF2
variable instances, COLRv1 emoji with the full 28 W3C composite
blend modes + linear / radial / sweep gradients, GPOS
mark-to-ligature, frozen API ([`API.md`](API.md)), per-script
shaping for **Devanagari, Bengali, Gujarati, Kannada, Odia,
Tamil, Telugu, Malayalam, Gurmukhi, Thai, Lao, Khmer, Myanmar**
verified against HarfBuzz byte-for-byte, and a Thai word-break
dictionary so Thai paragraphs reflow at word boundaries rather
than as one giant unbreakable word. Full scoreboard in
[`CHANGELOG.md`](CHANGELOG.md).

<p align="center">
  <img src="screenshots/multiscript.png" alt="runa rendering Latin, Cyrillic, Greek, Arabic (joined RTL), Hebrew (RTL), CJK, colour emoji, and ligatures" width="80%"/>
</p>

<p align="center"><sub>Latin · Cyrillic · Greek · Arabic (joined + RTL) · Hebrew (RTL) · Chinese · Japanese · colour emoji · OpenType ligatures.</sub></p>

## What this is

The current Odin text-rendering story is `vendor:fontstash` plus
`stb_truetype` — a glyph atlas and basic kerning. That covers Latin
text at small scales but cannot:

- Shape complex scripts (Arabic joining, Devanagari conjuncts, Thai
  clusters, bidi).
- Break lines per Unicode UAX #14.
- Render colour emoji (COLRv0 / COLRv1 / CBDT / sbix tables).
- Apply OpenType features (ligatures, GPOS kerning, contextual
  alternates, stylistic sets).
- Subpixel-position glyphs.

`runa` is the long-term fix — a modern text engine in idiomatic
Odin with zero C dependencies at v1.0.

## v1.0 punch list status

All four items closed:

- **Thai word-break dictionary** — embedded PyThaiNLP corpus,
  longest-match trie, ~62 k entries. ✓
- **Complex Khmer multi-consonant clusters** — pre-base reorder
  fixed to move to syllable start, not just before base. ✓
- **Full Myanmar shaping** — joined the Indic pipeline; medial
  YA / medial RA / IPC=Top_And_Bottom_And_Left all reorder
  correctly. ✓
- **Two remaining bidi BidiCharacterTest mismatches** — ISR
  formation now tunnels through `all-BN` higher-level
  intervening runs. 100.00 % conformance. ✓

Per-feature deliverables, conformance numbers, and tracked
patch-level work in [`CHANGELOG.md`](CHANGELOG.md).

## Building

The library is a set of plain Odin packages — no build script needed.

```
odin check . -no-entry-point          # type-check the library
odin test  tests/parse                # parser tests
odin test  tests/raster               # rasterizer smoke tests
odin test  tests/runa                 # facade integration tests
```

The runnable demo:

```
odin run examples/hello_world -- \
    tests/fonts/Roboto-Regular.ttf \
    tests/fonts/Twemoji-Mozilla.ttf \
    /tmp/hello.ppm
```

Test fonts are not committed — fetch them into `tests/fonts/` per
[`tests/fonts/README.md`](tests/fonts/README.md), or let CI fetch
them. Tests that need a missing font skip with an INFO log so the
synthetic suite still runs on a fresh clone.

## License

`runa` is licensed under the **zlib license** — see
[`LICENSE`](LICENSE). Permissive, GPL-compatible, the same licence
Odin's own standard library uses.

Embedded Unicode UCD data files (`Scripts.txt`, `LineBreak.txt`,
`DerivedBidiClass.txt`) ship under the Unicode-DFS-2016 licence.
Test fonts are not committed — see
[`tests/fonts/README.md`](tests/fonts/README.md) for per-font
sources and licences.

## Contributing

v1.0.0 has shipped — API frozen ([`API.md`](API.md)), bidi at
100 %, line break at 99.91 %, graphemes at 100 %, UAX #29 word
boundaries at 100 %, UAX #15 normalization (NFC / NFD / NFKC /
NFKD) at 100 %, all 28 COLR composite blend modes, CFF2
variations, and the full complex-script set (9 Brahmic — Devanagari,
Bengali, Tamil, Telugu, Kannada, Malayalam, Gurmukhi, Gujarati,
Odia — plus 4 SEA — Thai, Lao, Myanmar, Khmer) all real. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for build / test instructions
and the open-work pointer list (long-tail Khmer cluster polish,
performance hardening, COLRv1 sweep gradients).
