# Contributing to runa

runa is a pure-Odin modern text engine. The v0.9 public API is
frozen at [`API.md`](API.md); pre-1.0 internal changes are allowed
and tracked in [`CHANGELOG.md`](CHANGELOG.md) under each release's
*Breaking changes* section.

If you've found a bug, want a feature, or have a strong opinion
about the API, the issue tracker is the place. If you want to
write code, read on.

## Where the work is

13 complex scripts shape on canonical syllables. The remaining v1.0
items are the *long tail* — cluster edge cases, line-layout polish,
and the last 0.002 % of the bidi conformance corpus.

- **Thai word-break dictionary.** Shaping is correct; line layout
  falls back to ASCII rules. A small bundled dictionary is the v1.0
  fix.
- **Khmer complex clusters.** Simple syllables and AA ligation work;
  COENG-driven multi-consonant subscript chains need a dedicated
  Khmer cluster engine.
- **Full Myanmar shaping.** Simple syllables + medial RA / medial YA
  work. Full coverage needs medial reorder, asat handling, kinzi.
- **Bidi BD18 / RLE deep nesting.** Two BidiCharacterTest cases
  diverge from ICU on deep-nested empty RLE/PDF sequences;
  spec-vs-impl ambiguities that need a deeper rework.
- **GPOS lookup type 6** (mark-to-mark) — last GPOS lookup type
  missing; matters for stacked diacritics in Vietnamese, Devanagari.
- **HSL composite modes** in COLR — current coverage is 13 of the
  25 spec modes; the harder PDF modes fall back to SrcOver.

Issues labelled `good-first-issue` pick small scoped chunks of
the above; `help-wanted` flags larger ones where having a native
speaker of the target script would be a big win for correctness.

## Build & test

```
odin check . -no-entry-point          # type-check the library
odin test  tests/parse                # parser tests
odin test  tests/raster               # rasterizer smoke tests
odin test  tests/runa                 # facade integration tests
odin test  tests/bidi                 # UAX #9 conformance harness
odin test  tests/itemize              # UAX #29 grapheme conformance
odin test  tests/linebreak            # UAX #14 conformance harness
```

Most font-dependent tests need files dropped into `tests/fonts/`
first — see [`tests/fonts/README.md`](tests/fonts/README.md) for
the list and licences.

## Style

- Public procs have a multi-line doc comment: one-sentence summary,
  when the caller wants this vs alternatives, failure modes, brief
  example for non-trivial calls.
- Public types get the same. Field-level explanations sit inline as
  `// comment` after the field declaration.
- Errors are values: `(T, Error)` return everywhere. No `Maybe(T)`
  in the public surface. No panics on malformed input.
- Allocator threading: every alloc-capable proc takes
  `allocator := context.allocator` as the last named parameter.
- Imports: `core:*` first, then `vendor:*`, then local
  packages, blank line between groups.

## Pull-request flow

- Open the PR against `main`.
- CI runs the test matrix on Linux / macOS / Windows; all three
  green required before merge.
- For new features, include a regression test under `tests/<module>/`.
- For Unicode-affecting changes, include the conformance-test delta
  (e.g., LineBreakTest.txt pass-rate before / after).
- Squash on merge unless the PR has a deliberate intermediate
  history that's useful for review.

## Licence

By contributing you agree that your code ships under the project's
[zlib licence](LICENSE).
