/*
UAX #24 Script property lookup.

The Unicode `Script` property assigns one of 150+ codes to every
codepoint (Latin, Cyrillic, Greek, Hebrew, Arabic, Devanagari, Han,
…). `Common` and `Inherited` are the two "non-script" codes —
punctuation and digits live under `Common`, combining marks under
`Inherited` (their effective script is whatever the base character
they're attached to has).

We embed `tools/ucd/Scripts.txt` and lazy-parse on first call into
a sorted `[]Range` table, then binary-search per codepoint. Same
pattern as `linebreak/property.odin`; the codegen-baked two-stage
trie is the v0.5 polish step.

References: UAX #24, "Unicode Script Property",
`https://www.unicode.org/Public/UCD/latest/ucd/Scripts.txt`.
*/
package itemize

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// Script_Code identifies a Unicode script by its 4-letter ISO 15924
// code packed big-endian into a u32, so `Script_Code("Latn")` and the
// disk-form ScriptTag agree byte-for-byte.
Script_Code :: distinct u32

COMMON     :: Script_Code(0x436F6D6E)            // 'Comn' (Common)
INHERITED  :: Script_Code(0x5A696E68)            // 'Zinh' (Inherited)
UNKNOWN    :: Script_Code(0x5A7A7A7A)            // 'Zzzz' (Unknown)
LATIN      :: Script_Code(0x4C61746E)            // 'Latn'
GREEK      :: Script_Code(0x4772656B)            // 'Grek'
CYRILLIC   :: Script_Code(0x4379726C)            // 'Cyrl'
HEBREW     :: Script_Code(0x48656272)            // 'Hebr'
ARABIC     :: Script_Code(0x41726162)            // 'Arab'
DEVANAGARI :: Script_Code(0x44657661)            // 'Deva'
HAN        :: Script_Code(0x48616E69)            // 'Hani'
HIRAGANA   :: Script_Code(0x48697261)            // 'Hira'
KATAKANA   :: Script_Code(0x4B616E61)            // 'Kana'
HANGUL     :: Script_Code(0x48616E67)            // 'Hang'
THAI       :: Script_Code(0x54686169)            // 'Thai'

// `Range` is one row from `Scripts.txt`, with start/end codepoints
// folded together where the on-disk format groups them.
@(private="file")
Range :: struct {
	start, end: rune,
	script:     Script_Code,
}

@(private="file") g_ranges:    []Range
@(private="file") g_load_once: sync.Once

@(private="file")
SCRIPTS_DATA :: #load("../tools/ucd/Scripts.txt", string)

@(private="file") SCRIPTS_DATA_LINES := SCRIPTS_DATA

// script_of returns the Script_Code for `r`. Unassigned codepoints
// return `UNKNOWN`. Combining marks return `INHERITED`; the caller
// can fold that into the previous codepoint's script if needed.
script_of :: proc(r: rune) -> Script_Code {
	sync.once_do(&g_load_once, init_table)
	lo, hi := 0, len(g_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.script
		}
	}
	return UNKNOWN
}

@(private="file")
init_table :: proc() {
	context.allocator = runtime.heap_allocator()    // process-lifetime cache
	tmp := make([dynamic]Range, 0, 1024)
	for line in strings.split_lines_iterator(&SCRIPTS_DATA_LINES) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = strings.trim_space(trimmed[:hash])
		}
		semi := strings.index_byte(trimmed, ';')
		if semi < 0 { continue }
		cp_part   := strings.trim_space(trimmed[:semi])
		name_part := strings.trim_space(trimmed[semi + 1:])

		start, end: rune
		if dot := strings.index(cp_part, ".."); dot >= 0 {
			s, _ := strconv.parse_u64_of_base(cp_part[:dot], 16)
			e, _ := strconv.parse_u64_of_base(cp_part[dot + 2:], 16)
			start = rune(s); end = rune(e)
		} else {
			s, _ := strconv.parse_u64_of_base(cp_part, 16)
			start = rune(s); end = start
		}
		append(&tmp, Range{start = start, end = end, script = script_code_from_name(name_part)})
	}
	// Scripts.txt is grouped by script, not sorted by codepoint. Sort
	// in-place so binary search is valid.
	sort_ranges(tmp[:])
	g_ranges = tmp[:]
}

@(private="file")
sort_ranges :: proc(rs: []Range) {
	// Insertion sort: ~1000 ranges, runs in a few ms one-shot.
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
script_code_from_name :: proc(s: string) -> Script_Code {
	// Map the long Unicode script name to its 4-letter ISO 15924 code.
	// Covering the v0.1-relevant set explicitly; everything else
	// collapses to UNKNOWN, which is fine for layout decisions (the
	// real shaper picks a fallback font anyway).
	switch s {
	case "Common":                 return COMMON
	case "Inherited":              return INHERITED
	case "Unknown":                return UNKNOWN
	case "Latin":                  return LATIN
	case "Greek":                  return GREEK
	case "Cyrillic":               return CYRILLIC
	case "Hebrew":                 return HEBREW
	case "Arabic":                 return ARABIC
	case "Devanagari":             return DEVANAGARI
	case "Bengali":                return Script_Code(0x42656E67)         // 'Beng'
	case "Tamil":                  return Script_Code(0x54616D6C)         // 'Taml'
	case "Telugu":                 return Script_Code(0x54656C75)         // 'Telu'
	case "Kannada":                return Script_Code(0x4B6E6461)         // 'Knda'
	case "Malayalam":              return Script_Code(0x4D6C796D)         // 'Mlym'
	case "Gurmukhi":               return Script_Code(0x47757275)         // 'Guru'
	case "Gujarati":               return Script_Code(0x47756A72)         // 'Gujr'
	case "Oriya":                  return Script_Code(0x4F727961)         // 'Orya'
	case "Thai":                   return THAI
	case "Lao":                    return Script_Code(0x4C616F6F)         // 'Laoo'
	case "Myanmar":                return Script_Code(0x4D796D72)         // 'Mymr'
	case "Khmer":                  return Script_Code(0x4B686D72)         // 'Khmr'
	case "Han":                    return HAN
	case "Hiragana":               return HIRAGANA
	case "Katakana":               return KATAKANA
	case "Hangul":                 return HANGUL
	}
	return UNKNOWN
}
