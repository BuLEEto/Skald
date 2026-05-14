/*
Package linebreak enumerates Unicode line-break opportunities per UAX #14
and fits shaped runs into lines of a target width.

The break-opportunity engine is independent of shaping: it walks the
codepoints, classifies each via the Line_Break property, and applies the
LB1–LB31 pair rules. The width-fit step then consumes a stream of shaped
glyphs plus their break-after-allowed flags.

Conformance gate: 100 % pass on Unicode's LineBreakTest.txt at the
pinned Unicode version (17.0, see the design doc).


*/
package linebreak
