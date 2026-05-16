/*
Thai word-break dictionary — stubbed in Skald's vendored copy.

Upstream runa embeds the PyThaiNLP `words_th.txt` corpus (CC-BY-SA)
to drive longest-match Thai word segmentation. Skald deliberately
omits that corpus from the vendor so every Skald binary stays
permissively-licensed by default — apps shipping commercial
products don't have to add a CC-BY-SA attribution line for a
feature they almost certainly don't need.

The proc signature is preserved (with an empty body) so
`runa.odin`'s call site at `layout_paragraph` still compiles.
Thai paragraphs fall back to UAX #14's default SA-class handling:
the whole Thai run is treated as one unbreakable token, the same
behaviour Skald shipped on runa 0.9.2.

Apps that genuinely need Thai word-break segmentation can vendor
the upstream runa thai_dict.odin + thai_words.txt themselves and
add the corresponding CC-BY-SA attribution to their About / docs.

Do not refresh this file from upstream without first considering
the licensing implications.
*/
package linebreak

// thai_segment_breaks is a no-op in Skald's vendored runa. See the
// file-level comment for the rationale.
thai_segment_breaks :: proc(text: []rune, breaks: []bool) {}
