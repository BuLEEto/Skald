# runa

A pure-Odin modern text engine — parsing, itemization, shaping,
line-breaking, rasterization. Built first to replace fontstash +
stb_truetype in [Skald](https://github.com/BuLEEto/Skald), designed
to be useful for any Odin project that needs production-quality text.

**Status:** v0.9.2 — *"13 complex scripts shape."*
UAX #9 bidi at **99.998 %**, UAX #29 graphemes at 100 %, CFF2
variable instances, COLRv1 emoji with true linear / radial / sweep
gradients + composite blend modes, GPOS mark-to-ligature, frozen
API ([`API.md`](API.md)), and per-script shaping for **Devanagari,
Bengali, Gujarati, Kannada, Odia, Tamil, Telugu, Malayalam,
Gurmukhi, Thai, Lao, Khmer, Myanmar** — all verified against
HarfBuzz byte-for-byte on canonical syllables. v1.0 final remains
the Thai word-break dictionary and a few Myanmar / Khmer cluster
edge cases. Full scoreboard in [`CHANGELOG.md`](CHANGELOG.md).

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

## What's left for v1.0

- Thai word-break dictionary (line layout needs a dictionary; current
  Thai shaping is correct, line breaking falls back to ASCII rules).
- Complex Khmer multi-consonant clusters with COENG-driven subscripts.
- Full Myanmar shaping (medial reorder, asat handling, kinzi).
- Two remaining bidi BidiCharacterTest mismatches in deep-nested empty
  RLE/PDF cases — spec-vs-impl ambiguities that need a deeper rework.

Per-feature deliverables and conformance numbers live in [`CHANGELOG.md`](CHANGELOG.md).

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

v0.9-rc1 is shipping — API frozen ([`API.md`](API.md)), bidi at
100 %, graphemes at 100 %, COLRv1 gradients + composite modes
real, CFF2 variations real. v1.0 final work picks up the Indic
family (Devanagari, Bengali, Tamil, Telugu, Kannada, Malayalam,
Gurmukhi, Gujarati, Odia) and SEA scripts (Thai, Lao, Myanmar,
Khmer) — each shaper is its own module sharing a state-core, so
the work parallelises. See [`CONTRIBUTING.md`](CONTRIBUTING.md)
for build / test instructions and the open-work pointer list.
