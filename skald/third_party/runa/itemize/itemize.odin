/*
Package itemize splits a UTF-8 paragraph into runs by script (UAX #24).
Each run is a maximal substring whose codepoints share a script (with
the UAX #24 resolution rules for `Common` and `Inherited` folding into
the surrounding context).

v0.1 ships script segmentation; per-codepoint font fallback is the
caller's concern at the layout layer. v0.5 will fuse this with bidi
embedding levels so each run is one (script, direction, font) tuple.

See README.md.
*/
package itemize

// Run is one segmented sub-string of the paragraph.
//
//   byte_start / byte_end : UTF-8 byte offsets into the input string.
//   script                : the resolved Script_Code that applies to
//                           every codepoint in the run.
//
// `Common` and `Inherited` codepoints inherit the surrounding run's
// script per the resolution rules in UAX #24 §5.
Run :: struct {
	byte_start: int,
	byte_end:   int,
	script:     Script_Code,
}

// segment walks `text` and appends one Run per script transition to
// `out`. The caller's dynamic array is kept across calls so the
// itemizer can be re-used without re-allocating.
//
// Resolution rules implemented:
//
//   - `Inherited` codepoints fold into the previous codepoint's
//     resolved script. At sot, they fold into the next non-Inherited
//     codepoint's script (or `Common` if none).
//   - `Common` codepoints fold into the previous run's resolved
//     script if it isn't `Common` / `Unknown`; otherwise they keep
//     their own `Common` script until a stronger script appears.
//   - `Unknown` codepoints start a new `Unknown` run (no folding —
//     the caller can decide what to do with them).
//
// Empty paragraphs produce zero runs.
segment :: proc(text: string, out: ^[dynamic]Run) {
	if len(text) == 0 { return }

	cur_script: Script_Code = UNKNOWN
	run_start  := 0
	has_run := false
	byte_off  := 0

	for r in text {
		byte_len: int
		switch {
		case r < 0x80:    byte_len = 1
		case r < 0x800:   byte_len = 2
		case r < 0x10000: byte_len = 3
		case:             byte_len = 4
		}

		s := script_of(r)

		// Inherited folds into the run we're already in.
		if s == INHERITED { byte_off += byte_len; continue }

		// Common folds when we already have a real run going, but
		// keeps its own `Common` script if it's the leading codepoint.
		if s == COMMON && has_run && cur_script != COMMON && cur_script != UNKNOWN {
			byte_off += byte_len
			continue
		}

		if !has_run {
			cur_script = s
			run_start  = byte_off
			has_run    = true
		} else if s != cur_script {
			append(out, Run{byte_start = run_start, byte_end = byte_off, script = cur_script})
			cur_script = s
			run_start  = byte_off
		}
		byte_off += byte_len
	}
	if has_run {
		append(out, Run{byte_start = run_start, byte_end = byte_off, script = cur_script})
	}
}
