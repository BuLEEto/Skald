/*
Indic_Syllabic_Category + Indic_Positional_Category lookups for
the Indic shaper.

The shaper uses these two UCD properties to:
  - Classify each codepoint as Consonant / Vowel / Matra / Halant /
    Nukta / Bindu / etc. for syllable-boundary detection.
  - Place reorderable items (pre-base matras, reph) in the right
    visual position before GSUB feature application.

Both tables load lazily on first call from embedded UCD data
(`IndicSyllabicCategory.txt`, `IndicPositionalCategory.txt`).
Stored as sorted range tables + binary search per codepoint —
same shape as `bidi/property.odin` and `linebreak/property.odin`.

References: UCD §3.4 (Indic properties); OpenType
`Indic2 shaping model` documentation.
*/
package shape

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// Indic_Syllabic_Category values from UCD. Names follow the spec
// short forms so cross-referencing the data file is direct.
ISC :: enum u8 {
	Other,
	Bindu,
	Visarga,
	Avagraha,
	Nukta,
	Virama,                                              // dead consonant marker (Halant)
	Pure_Killer,
	Invisible_Stacker,
	Vowel_Independent,
	Vowel_Dependent,                                     // matra
	Vowel,
	Consonant_Placeholder,
	Consonant,
	Consonant_Dead,
	Consonant_With_Stacker,
	Consonant_Prefixed,
	Consonant_Preceding_Repha,
	Consonant_Initial_Postfixed,
	Consonant_Succeeding_Repha,
	Consonant_Subjoined,
	Consonant_Medial,
	Consonant_Final,
	Consonant_Head_Letter,
	Modifying_Letter,
	Tone_Letter,
	Tone_Mark,
	Gemination_Mark,
	Cantillation_Mark,
	Register_Shifter,
	Syllable_Modifier,
	Consonant_Killer,
	Non_Joiner,
	Joiner,
	Number_Joiner,
	Number,
	Brahmi_Joining_Number,
	Symbol,
	Consonant_Catalan_Conjoiner,
	Consonant_Final_Letter,                              // some scripts
}

// Indic_Positional_Category — where a glyph sits visually relative
// to the base consonant cluster.
IPC :: enum u8 {
	Other,
	Right,
	Left,
	Visual_Order_Left,                                   // pre-base matra encoded after the consonant
	Left_And_Right,
	Top,
	Bottom,
	Top_And_Bottom,
	Top_And_Right,
	Top_And_Left,
	Top_And_Left_And_Right,
	Bottom_And_Right,
	Bottom_And_Left,
	Top_And_Bottom_And_Right,
	Top_And_Bottom_And_Left,
	Overstruck,
}

@(private="file")
ISC_Range :: struct { start, end: rune, cls: ISC }
@(private="file")
IPC_Range :: struct { start, end: rune, cls: IPC }

@(private="file") g_isc_ranges:    []ISC_Range
@(private="file") g_isc_load_once: sync.Once
@(private="file") g_ipc_ranges:    []IPC_Range
@(private="file") g_ipc_load_once: sync.Once

@(private="file") ISC_DATA :: #load("../tools/ucd/IndicSyllabicCategory.txt",   string)
@(private="file") IPC_DATA :: #load("../tools/ucd/IndicPositionalCategory.txt", string)

isc_class :: proc(r: rune) -> ISC {
	sync.once_do(&g_isc_load_once, init_isc_table)
	lo, hi := 0, len(g_isc_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_isc_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .Other
}

ipc_class :: proc(r: rune) -> IPC {
	sync.once_do(&g_ipc_load_once, init_ipc_table)
	lo, hi := 0, len(g_ipc_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_ipc_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .Other
}

@(private="file")
init_isc_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]ISC_Range, 0, 1024)
	data := ISC_DATA
	for line in strings.split_lines_iterator(&data) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		semi := strings.index_byte(t, ';')
		if semi < 0 { continue }
		cp_part := strings.trim_space(t[:semi])
		name    := strings.trim_space(t[semi + 1:])
		cls, ok := isc_from_name(name)
		if !ok { continue }
		start, end := parse_cp_range(cp_part)
		if start == 0 && end == 0 && cp_part != "0000" { continue }
		append(&tmp, ISC_Range{start = start, end = end, cls = cls})
	}
	sort_isc(tmp[:])
	g_isc_ranges = tmp[:]
}

@(private="file")
init_ipc_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]IPC_Range, 0, 512)
	data := IPC_DATA
	for line in strings.split_lines_iterator(&data) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		semi := strings.index_byte(t, ';')
		if semi < 0 { continue }
		cp_part := strings.trim_space(t[:semi])
		name    := strings.trim_space(t[semi + 1:])
		cls, ok := ipc_from_name(name)
		if !ok { continue }
		start, end := parse_cp_range(cp_part)
		if start == 0 && end == 0 && cp_part != "0000" { continue }
		append(&tmp, IPC_Range{start = start, end = end, cls = cls})
	}
	sort_ipc(tmp[:])
	g_ipc_ranges = tmp[:]
}

@(private="file")
parse_cp_range :: proc(s: string) -> (start, end: rune) {
	if dot := strings.index(s, ".."); dot >= 0 {
		a, _ := strconv.parse_u64_of_base(s[:dot],     16)
		b, _ := strconv.parse_u64_of_base(s[dot + 2:], 16)
		return rune(a), rune(b)
	}
	a, _ := strconv.parse_u64_of_base(s, 16)
	return rune(a), rune(a)
}

@(private="file")
sort_isc :: proc(rs: []ISC_Range) {
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
sort_ipc :: proc(rs: []IPC_Range) {
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
isc_from_name :: proc(s: string) -> (ISC, bool) {
	switch s {
	case "Other":                       return .Other, true
	case "Bindu":                       return .Bindu, true
	case "Visarga":                     return .Visarga, true
	case "Avagraha":                    return .Avagraha, true
	case "Nukta":                       return .Nukta, true
	case "Virama":                      return .Virama, true
	case "Pure_Killer":                 return .Pure_Killer, true
	case "Invisible_Stacker":           return .Invisible_Stacker, true
	case "Vowel_Independent":           return .Vowel_Independent, true
	case "Vowel_Dependent":             return .Vowel_Dependent, true
	case "Vowel":                       return .Vowel, true
	case "Consonant_Placeholder":       return .Consonant_Placeholder, true
	case "Consonant":                   return .Consonant, true
	case "Consonant_Dead":              return .Consonant_Dead, true
	case "Consonant_With_Stacker":      return .Consonant_With_Stacker, true
	case "Consonant_Prefixed":          return .Consonant_Prefixed, true
	case "Consonant_Preceding_Repha":   return .Consonant_Preceding_Repha, true
	case "Consonant_Initial_Postfixed": return .Consonant_Initial_Postfixed, true
	case "Consonant_Succeeding_Repha":  return .Consonant_Succeeding_Repha, true
	case "Consonant_Subjoined":         return .Consonant_Subjoined, true
	case "Consonant_Medial":            return .Consonant_Medial, true
	case "Consonant_Final":             return .Consonant_Final, true
	case "Consonant_Head_Letter":       return .Consonant_Head_Letter, true
	case "Modifying_Letter":            return .Modifying_Letter, true
	case "Tone_Letter":                 return .Tone_Letter, true
	case "Tone_Mark":                   return .Tone_Mark, true
	case "Gemination_Mark":             return .Gemination_Mark, true
	case "Cantillation_Mark":           return .Cantillation_Mark, true
	case "Register_Shifter":            return .Register_Shifter, true
	case "Syllable_Modifier":           return .Syllable_Modifier, true
	case "Consonant_Killer":            return .Consonant_Killer, true
	case "Non_Joiner":                  return .Non_Joiner, true
	case "Joiner":                      return .Joiner, true
	case "Number_Joiner":               return .Number_Joiner, true
	case "Number":                      return .Number, true
	case "Brahmi_Joining_Number":       return .Brahmi_Joining_Number, true
	case "Symbol":                      return .Symbol, true
	case "Consonant_Catalan_Conjoiner": return .Consonant_Catalan_Conjoiner, true
	case "Consonant_Final_Letter":      return .Consonant_Final_Letter, true
	}
	return .Other, false
}

@(private="file")
ipc_from_name :: proc(s: string) -> (IPC, bool) {
	switch s {
	case "NA":                       return .Other, true
	case "Right":                    return .Right, true
	case "Left":                     return .Left, true
	case "Visual_Order_Left":        return .Visual_Order_Left, true
	case "Left_And_Right":           return .Left_And_Right, true
	case "Top":                      return .Top, true
	case "Bottom":                   return .Bottom, true
	case "Top_And_Bottom":           return .Top_And_Bottom, true
	case "Top_And_Right":            return .Top_And_Right, true
	case "Top_And_Left":             return .Top_And_Left, true
	case "Top_And_Left_And_Right":   return .Top_And_Left_And_Right, true
	case "Bottom_And_Right":         return .Bottom_And_Right, true
	case "Bottom_And_Left":          return .Bottom_And_Left, true
	case "Top_And_Bottom_And_Right": return .Top_And_Bottom_And_Right, true
	case "Top_And_Bottom_And_Left":  return .Top_And_Bottom_And_Left, true
	case "Overstruck":               return .Overstruck, true
	}
	return .Other, false
}
