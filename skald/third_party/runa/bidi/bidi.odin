/*
Package bidi implements the UAX #9 bidirectional algorithm — paragraph
text in logical order in, embedding levels and visual reorder map out.

v0.5 lands the foundation:
  - `bidi_class(rune)` — per-codepoint Bidi_Class lookup over an
    embedded Unicode 17.0 DerivedBidiClass.txt.
  - `Direction` enum + `paragraph_direction(text)` — UAX #9 P2 / P3,
    the "first strong character" heuristic that resolves a paragraph's
    base direction when the caller didn't pin one.

Embedding-level resolution (the full UAX #9 X-rule pipeline plus
BD16 bracket pairs) is the next chunk — once it lands, Arabic +
Hebrew shaping have a logical-to-visual reorder map to consume.

See UAX #9.
*/
package bidi

// Direction is the paragraph base direction.
//
//   .LTR / .RTL : explicit.
//   .Neutral    : `paragraph_direction` found no strong character and
//                 leaves the choice to the caller (UAX #9 says treat
//                 as LTR by default, but we surface Neutral so the
//                 caller can override).
Direction :: enum u8 {
	LTR,
	RTL,
	Neutral,
}

// paragraph_direction walks `text` looking for the first character
// with a strong directional class (L, R, or AL) and returns the
// matching Direction. Implements UAX #9 P2 / P3 — the rule the
// Unicode spec applies when no embedding override is in play.
//
// LRI / RLI / FSI isolates skip their contents (UAX #9 P2), so a
// paragraph that opens with an explicit isolate still picks up the
// first strong character outside that isolate.
paragraph_direction :: proc(text: string) -> Direction {
	isolate_depth := 0
	for r in text {
		cls := bidi_class(r)
		// Track isolate depth so we skip content inside isolates per
		// P2's "ignoring any characters between an isolate initiator
		// and its matching PDI" rule.
		#partial switch cls {
		case .LRI, .RLI, .FSI:
			isolate_depth += 1
			continue
		case .PDI:
			if isolate_depth > 0 { isolate_depth -= 1 }
			continue
		}
		if isolate_depth > 0 { continue }

		#partial switch cls {
		case .L:        return .LTR
		case .R, .AL:   return .RTL
		}
	}
	return .Neutral
}
