# Contributing

Skald is open source under the [zlib license](LICENSE). Contributions
are welcome — bug reports, doc fixes, small features, and particularly
the open work areas listed below.

## Reporting issues

File issues with:
- What you ran (example name, build command, platform)
- What you expected
- What happened instead (paste the full error, not a screenshot of
  text — text is greppable)
- For rendering bugs, a screenshot helps

## Small fixes

Send a PR. If the change is under ~30 lines, there's no need to
discuss first — we'll either take it or suggest a tweak. Larger
changes are easier to land if you open an issue first so we can
agree on direction before you invest real time.

## Open work areas

These are the concrete things Skald would benefit from that the
current maintainers either don't have bandwidth for or can't QA
alone. If you want to pick one up, file an issue tagging it so
we can coordinate.

### Complex-script shaping + bidi (high value)

Skald currently renders **Latin, Cyrillic, Greek, and CJK** correctly
(the last with a bundled or caller-supplied fallback font). Complex
scripts — **Arabic, Hebrew, Devanagari and other Indic scripts,
Thai, Khmer, Myanmar, Tibetan** — render glyphs but without the
contextual reshaping those scripts require to be *linguistically*
correct.

Landing this takes three pieces:

1. **A shaper.** Accepts `(font, text_run, script_tag)` and returns
   positioned glyphs with correct contextual forms. For Arabic this
   means picking isolated / initial / medial / final letter forms;
   for Indic, cluster reordering; for Thai, tone-mark stacking. See
   `skald/text.odin` for where this hook needs to live — glyph
   lookup today goes through `fontstash`; shaping would sit between
   `measure_text` / `draw_text` and the atlas.

2. **The Unicode Bidirectional Algorithm.** So mixed-direction runs
   ("the word الكلمة here") reorder visually per Unicode Annex #9.
   Lives alongside the shaper; needs to inform layout.

3. **RTL flow in layout widgets.** `row`, `form_row`, `text_input`
   caret/selection, and anything with `cross_align = .Start` need
   an "align to writing direction" mode. Touches
   `skald/layout.odin` broadly.

**Ideal contributor**: reads Arabic or Hindi natively, so they can
validate the output looks right to a reader of the language. A
non-native contributor can write the machinery, but real QA
absolutely needs a native speaker.

**Scope the work small**: starting with Arabic-only or Hebrew-only
is totally fine. The framework's Rule #1 is "land what you can
actually test." A pure-Odin Arabic shaper is meaningful in its own
right and doesn't require us to rewrite HarfBuzz in one go.

Tracking issue: #193.

### Native macOS menu bar (moderate)

Skald's `menu_bar` widget currently renders inside the app window
on all platforms. On macOS, this is non-native — Mac apps put their
menus in the top-of-screen system bar via AppKit.

Landing this means, on macOS only:

- Replace the in-window `menu_bar` render with NSMenu / NSMenuItem
  installations via `foreign` Objective-C runtime calls from Odin
- Route menu-item selections back into the app's Msg queue
- Hide the in-window bar on macOS (so it doesn't double up)

See `skald/platform_title_other.odin` for the existing
platform-conditional shim — this would be a fuller companion on
macOS.

Tracking issue: #188.

### macOS live-resize smooth reflow (moderate)

When the user drags a window corner on macOS, Cocoa's resize-
tracking loop blocks the main thread and Skald's event pump stops
firing. The compositor stretches the last rendered framebuffer
until release. Linux/Windows reflow smoothly during drag.

The fix is `SDL_AddEventWatch` + a re-entrant render path from the
callback. Requires careful thought about the per-frame arena and
`widget_store_frame_reset` to not blow up when re-entered.

Tracking issue: #191.

### macOS RSS reader (small)

`_bench_rss_kb` in `skald/app.odin` returns -1 on macOS. The
Linux branch reads `/proc/self/statm`. For macOS, use the Mach API
(`mach_task_basic_info`) to get `resident_size` and shift-right to
get KB.

Tracking issue: #192.

## Style

- Match the existing code's shape. Skald has a distinctive
  formatting style (tight, few blank lines, comments that explain
  *why* not *what*). New code should feel like it belongs.
- Docstrings on every new public proc. Comment style in existing
  files is a good reference.
- No emoji in committed code unless the user explicitly asks.
- Keep PRs focused — one change per PR. "Fixes #123 and also
  refactors layout" is harder to review than two separate PRs.

## Running the examples + bench

```bash
./build.sh 00_gallery run    # build + run the full widget gallery
./bench.sh                    # frame-time + RSS across canonical examples
```

Before submitting a PR that touches the renderer or widgets, run
`./bench.sh` before and after — significant regressions on
`00_gallery` should be called out in the PR description.

## Thanks

Same credits as the README — Skald stands on Odin, SDL3, Vulkan,
MoltenVK, fontstash, stb, and Inter. Any PR adding substantial
new functionality should feel free to add a line to the
Acknowledgments section of README.md noting its origin, if
appropriate.
