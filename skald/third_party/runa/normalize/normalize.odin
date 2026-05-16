/*
UAX #15 Unicode normalization.

Public surface:

  to_nfd(s, allocator) -> string   canonical decomposition
  to_nfc(s, allocator) -> string   canonical composition
  to_nfkd(s, allocator) -> string  compatibility decomposition
  to_nfkc(s, allocator) -> string  compatibility composition

  is_nfd(s) -> bool                quick-check (true ⇒ in NFD; false ⇒ unknown — caller can fall back to to_nfd then compare)
  is_nfc(s) -> bool                quick-check
  ccc(r) -> u8                     Canonical_Combining_Class lookup

The decomposition mapping, combining class, and composition
exclusion tables are derived from the embedded UCD data files
(UnicodeData.txt + DerivedNormalizationProps.txt) and built once
per process via `sync.Once`. Lookups are binary searches on
sorted range / entry tables — same shape as the other Unicode
property tables in `itemize/` and `bidi/`.

Algorithm references: UAX #15 §1.3 (D108..D119), §9 (Hangul);
spec test data lives at `tools/ucd/NormalizationTest.txt`.
*/
package normalize

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Hangul algorithmic constants (UAX #15 §9).
// ---------------------------------------------------------------------------
@(private="file") S_BASE :: rune(0xAC00)
@(private="file") L_BASE :: rune(0x1100)
@(private="file") V_BASE :: rune(0x1161)
@(private="file") T_BASE :: rune(0x11A7)
@(private="file") L_COUNT :: 19
@(private="file") V_COUNT :: 21
@(private="file") T_COUNT :: 28
@(private="file") N_COUNT :: V_COUNT * T_COUNT     // 588
@(private="file") S_COUNT :: L_COUNT * N_COUNT     // 11172

// ---------------------------------------------------------------------------
// Embedded UCD data + property tables.
// ---------------------------------------------------------------------------
@(private="file") UCD_UNICODE_DATA :: #load("../tools/ucd/UnicodeData.txt", string)
@(private="file") UCD_NORM_PROPS   :: #load("../tools/ucd/DerivedNormalizationProps.txt", string)

@(private="file")
CCC_Range :: struct { start, end: rune, ccc: u8 }

@(private="file")
Decomp_Entry :: struct {
	cp:        rune,
	off:       u32,  // offset into g_decomp_runes
	count:     u8,   // number of runes in the decomposition
	is_compat: bool, // true ⇒ compat decomposition (NFKD only); false ⇒ canonical
}

@(private="file")
Compose_Entry :: struct {
	l, c, result: rune
}

@(private="file") g_ccc_ranges:    []CCC_Range
@(private="file") g_decomp:        []Decomp_Entry
@(private="file") g_decomp_runes:  []rune
@(private="file") g_compose:       []Compose_Entry  // sorted by (l, c)
@(private="file") g_full_excl:     []rune           // Full_Composition_Exclusion (sorted)
@(private="file") g_load_once:     sync.Once

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

ccc :: proc(r: rune) -> u8 {
	sync.once_do(&g_load_once, init_tables)
	lo, hi := 0, len(g_ccc_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_ccc_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.ccc
		}
	}
	return 0
}

to_nfd :: proc(s: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	return normalize_decompose(s, false, allocator)
}

to_nfkd :: proc(s: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	return normalize_decompose(s, true, allocator)
}

to_nfc :: proc(s: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	decomposed := normalize_decompose(s, false, context.temp_allocator)
	return normalize_compose(decomposed, allocator)
}

to_nfkc :: proc(s: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	decomposed := normalize_decompose(s, true, context.temp_allocator)
	return normalize_compose(decomposed, allocator)
}

is_nfd :: proc(s: string) -> bool {
	// Conservative check: returns true only if the string is in NFD.
	// Re-runs to_nfd and compares — slow but always correct. A faster
	// implementation could use the NFD_Quick_Check property table.
	out := to_nfd(s, context.temp_allocator)
	return out == s
}

is_nfc :: proc(s: string) -> bool {
	out := to_nfc(s, context.temp_allocator)
	return out == s
}

// ---------------------------------------------------------------------------
// Decomposition (NFD / NFKD).
// ---------------------------------------------------------------------------

@(private="file")
normalize_decompose :: proc(s: string, compat: bool, allocator: runtime.Allocator) -> string {
	sync.once_do(&g_load_once, init_tables)
	context.allocator = allocator
	runes := make([dynamic]rune, 0, len(s))
	i := 0
	for i < len(s) {
		r, sz := utf8.decode_rune_in_string(s[i:])
		decompose_recursive(r, &runes, compat)
		i += sz
	}
	canonical_reorder(runes[:])
	// Encode back to UTF-8.
	b := strings.builder_make(0, len(s), allocator)
	for r in runes { strings.write_rune(&b, r) }
	delete(runes)
	return strings.to_string(b)
}

@(private="file")
decompose_recursive :: proc(r: rune, out: ^[dynamic]rune, compat: bool) {
	// Hangul algorithmic decomposition.
	if r >= S_BASE && r < S_BASE + S_COUNT {
		s_idx := r - S_BASE
		l := L_BASE + s_idx / rune(N_COUNT)
		v := V_BASE + (s_idx % rune(N_COUNT)) / rune(T_COUNT)
		t := T_BASE + s_idx % rune(T_COUNT)
		append(out, l)
		append(out, v)
		if t != T_BASE { append(out, t) }
		return
	}
	// Table lookup.
	idx, found := decomp_index(r)
	if !found {
		append(out, r)
		return
	}
	entry := g_decomp[idx]
	if entry.is_compat && !compat {
		// Compat decomposition exists but we're in canonical mode —
		// the codepoint is itself the canonical form.
		append(out, r)
		return
	}
	subs := g_decomp_runes[entry.off:entry.off + u32(entry.count)]
	for sub in subs {
		decompose_recursive(sub, out, compat)
	}
}

@(private="file")
decomp_index :: proc(r: rune) -> (int, bool) {
	lo, hi := 0, len(g_decomp)
	for lo < hi {
		mid := (lo + hi) / 2
		c := g_decomp[mid].cp
		switch {
		case r < c: hi = mid
		case r > c: lo = mid + 1
		case:       return mid, true
		}
	}
	return 0, false
}

@(private="file")
canonical_reorder :: proc(runes: []rune) {
	// In-place reordering — runes with CCC > 0 are sorted (stable) by
	// CCC within each maximal sequence of non-starter codepoints.
	// Uses pairwise bubble sort: a sufficient implementation for short
	// combining sequences in practice (rarely more than a handful).
	n := len(runes)
	for i := 1; i < n; i += 1 {
		c2 := ccc(runes[i])
		if c2 == 0 { continue }
		j := i
		for j > 0 {
			c1 := ccc(runes[j - 1])
			if c1 == 0 || c1 <= c2 { break }
			runes[j - 1], runes[j] = runes[j], runes[j - 1]
			j -= 1
		}
	}
}

// ---------------------------------------------------------------------------
// Composition (NFC / NFKC).
// ---------------------------------------------------------------------------

@(private="file")
normalize_compose :: proc(s: string, allocator: runtime.Allocator) -> string {
	sync.once_do(&g_load_once, init_tables)
	context.allocator = allocator
	runes := make([dynamic]rune, 0, len(s))
	defer delete(runes)

	last_starter_idx := -1  // index in `runes` of the most recent starter
	last_class       := -1  // ccc of the last rune appended after that starter (-1 = none)

	i := 0
	for i < len(s) {
		r, sz := utf8.decode_rune_in_string(s[i:])
		i += sz
		cccr := int(ccc(r))

		composed := false
		if last_starter_idx >= 0 && last_class < cccr {
			composite, ok := try_compose(runes[last_starter_idx], r)
			if ok {
				runes[last_starter_idx] = composite
				composed = true
				// last_class unchanged: r was consumed; trail of marks
				// since the starter still has whatever ccc it had.
			}
		}
		if composed { continue }

		append(&runes, r)
		if cccr == 0 {
			last_starter_idx = len(runes) - 1
			last_class = -1
		} else {
			last_class = cccr
		}
	}

	b := strings.builder_make(0, len(s), allocator)
	for r in runes { strings.write_rune(&b, r) }
	return strings.to_string(b)
}

@(private="file")
try_compose :: proc(l, c: rune) -> (rune, bool) {
	// Hangul L + V → LV.
	l_idx := l - L_BASE
	if l_idx >= 0 && l_idx < rune(L_COUNT) {
		v_idx := c - V_BASE
		if v_idx >= 0 && v_idx < rune(V_COUNT) {
			return S_BASE + (l_idx * rune(V_COUNT) + v_idx) * rune(T_COUNT), true
		}
	}
	// Hangul LV + T → LVT (LV is a syllable with no T).
	s_idx := l - S_BASE
	if s_idx >= 0 && s_idx < rune(S_COUNT) && s_idx % rune(T_COUNT) == 0 {
		t_idx := c - T_BASE
		if t_idx > 0 && t_idx < rune(T_COUNT) {
			return l + t_idx, true
		}
	}
	// Table lookup over the precomposed pairs.
	lo, hi := 0, len(g_compose)
	for lo < hi {
		mid := (lo + hi) / 2
		e := g_compose[mid]
		switch {
		case e.l < l: lo = mid + 1
		case e.l > l: hi = mid
		case e.c < c: lo = mid + 1
		case e.c > c: hi = mid
		case:         return e.result, true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Table builder (called once via sync.Once on first lookup).
// ---------------------------------------------------------------------------

@(private="file")
init_tables :: proc() {
	context.allocator = runtime.heap_allocator()

	// Pass 1: scan DerivedNormalizationProps.txt for Full_Composition_Exclusion.
	excl_tmp := make([dynamic]rune, 0, 1024)
	{
		data := UCD_NORM_PROPS
		for line in strings.split_lines_iterator(&data) {
			t := strings.trim_space(line)
			if len(t) == 0 || t[0] == '#' { continue }
			if hash := strings.index_byte(t, '#'); hash >= 0 {
				t = strings.trim_space(t[:hash])
			}
			semi := strings.index_byte(t, ';')
			if semi < 0 { continue }
			cp_part   := strings.trim_space(t[:semi])
			name_part := strings.trim_space(t[semi + 1:])
			if name_part != "Full_Composition_Exclusion" { continue }
			s, e := parse_cp_range(cp_part)
			for cp := s; cp <= e; cp += 1 { append(&excl_tmp, cp) }
		}
	}
	insertion_sort_runes(excl_tmp[:])
	g_full_excl = excl_tmp[:]

	// Pass 2: scan UnicodeData.txt for CCC and decomposition mapping.
	ccc_tmp     := make([dynamic]CCC_Range, 0, 1024)
	decomp_tmp  := make([dynamic]Decomp_Entry, 0, 4096)
	dec_runes   := make([dynamic]rune, 0, 16384)
	compose_tmp := make([dynamic]Compose_Entry, 0, 2048)

	data := UCD_UNICODE_DATA
	for line in strings.split_lines_iterator(&data) {
		if len(line) == 0 || line[0] == '#' { continue }
		// Split into ; fields, take first 6.
		fields: [6]string
		nf := split_semicolons(line, fields[:])
		if nf < 6 { continue }
		cp_str    := fields[0]
		ccc_str   := fields[3]
		dec_str   := fields[5]

		cp_u, ok := strconv.parse_u64_of_base(cp_str, 16)
		if !ok { continue }
		cp := rune(cp_u)

		ccc_v, _ := strconv.parse_u64_of_base(ccc_str, 10)
		if ccc_v != 0 {
			append(&ccc_tmp, CCC_Range{start = cp, end = cp, ccc = u8(ccc_v)})
		}

		if len(dec_str) > 0 {
			is_compat := false
			ds := dec_str
			if ds[0] == '<' {
				is_compat = true
				rb := strings.index_byte(ds, '>')
				if rb < 0 { continue }
				ds = strings.trim_space(ds[rb + 1:])
			}
			// Parse the rune list.
			off := u32(len(dec_runes))
			count := 0
			for tok in strings.split_iterator(&ds, " ") {
				if len(tok) == 0 { continue }
				v, vok := strconv.parse_u64_of_base(tok, 16)
				if !vok { continue }
				append(&dec_runes, rune(v))
				count += 1
			}
			if count > 0 {
				append(&decomp_tmp, Decomp_Entry{cp = cp, off = off, count = u8(count), is_compat = is_compat})

				// If this is a canonical decomposition into TWO codepoints,
				// add a composition pair UNLESS the codepoint is in the
				// Full_Composition_Exclusion list.
				if !is_compat && count == 2 && !is_excluded(cp) {
					l := dec_runes[off]
					c := dec_runes[off + 1]
					append(&compose_tmp, Compose_Entry{l = l, c = c, result = cp})
				}
			}
		}
	}

	// Compact the CCC range list (merge adjacent codepoints with same value).
	{
		out := make([dynamic]CCC_Range, 0, len(ccc_tmp))
		for r in ccc_tmp {
			if len(out) > 0 && out[len(out) - 1].end + 1 == r.start && out[len(out) - 1].ccc == r.ccc {
				out[len(out) - 1].end = r.end
			} else {
				append(&out, r)
			}
		}
		g_ccc_ranges = out[:]
	}

	g_decomp = decomp_tmp[:]
	g_decomp_runes = dec_runes[:]

	// Sort the composition table by (l, c).
	sort_compose(compose_tmp[:])
	g_compose = compose_tmp[:]

	// Expand canonical decompositions transitively so the runtime
	// lookup doesn't recurse — every entry's decomposition runes
	// are already in fully-decomposed form. Re-build the rune array.
	// (Note: this rewrites the existing g_decomp_runes and per-entry
	// offsets to the fully-expanded form. We do canonical *and* compat
	// expansion independently — for compat entries, intermediate
	// canonical decompositions also need to expand.)
	rebuild_transitive_decomposition()
}

@(private="file")
rebuild_transitive_decomposition :: proc() {
	context.allocator = runtime.heap_allocator()
	new_runes := make([dynamic]rune, 0, len(g_decomp_runes) * 2)
	// Stash the new (off, count) pair for each entry into a parallel
	// slice. We can't mutate g_decomp's `off` field mid-iteration —
	// `expand_one` recurses through `decomp_index` + slices into
	// `g_decomp_runes`, both of which still need the old offsets.
	pending_off   := make([]u32, len(g_decomp), context.temp_allocator)
	pending_count := make([]u8,  len(g_decomp), context.temp_allocator)
	for i in 0..<len(g_decomp) {
		entry := g_decomp[i]
		buf := make([dynamic]rune, 0, 8, context.temp_allocator)
		subs := g_decomp_runes[entry.off:entry.off + u32(entry.count)]
		for sub in subs {
			expand_one(sub, &buf, entry.is_compat)
		}
		pending_off[i]   = u32(len(new_runes))
		pending_count[i] = u8(len(buf))
		for r in buf { append(&new_runes, r) }
	}
	for i in 0..<len(g_decomp) {
		g_decomp[i].off   = pending_off[i]
		g_decomp[i].count = pending_count[i]
	}
	g_decomp_runes = new_runes[:]
}

@(private="file")
expand_one :: proc(r: rune, out: ^[dynamic]rune, compat: bool) {
	// Hangul algorithmic: only L V (T) — don't recurse, those are atomic.
	if r >= S_BASE && r < S_BASE + S_COUNT {
		s_idx := r - S_BASE
		l := L_BASE + s_idx / rune(N_COUNT)
		v := V_BASE + (s_idx % rune(N_COUNT)) / rune(T_COUNT)
		t := T_BASE + s_idx % rune(T_COUNT)
		append(out, l); append(out, v)
		if t != T_BASE { append(out, t) }
		return
	}
	idx, ok := decomp_index(r)
	if !ok {
		append(out, r)
		return
	}
	entry := g_decomp[idx]
	if entry.is_compat && !compat {
		append(out, r)
		return
	}
	subs := g_decomp_runes[entry.off:entry.off + u32(entry.count)]
	for sub in subs {
		expand_one(sub, out, compat)
	}
}

@(private="file")
is_excluded :: proc(r: rune) -> bool {
	lo, hi := 0, len(g_full_excl)
	for lo < hi {
		mid := (lo + hi) / 2
		v := g_full_excl[mid]
		switch {
		case r < v: hi = mid
		case r > v: lo = mid + 1
		case:       return true
		}
	}
	return false
}

@(private="file")
parse_cp_range :: proc(s: string) -> (start, end: rune) {
	if dot := strings.index(s, ".."); dot >= 0 {
		a, _ := strconv.parse_u64_of_base(s[:dot], 16)
		b, _ := strconv.parse_u64_of_base(s[dot + 2:], 16)
		return rune(a), rune(b)
	}
	a, _ := strconv.parse_u64_of_base(s, 16)
	return rune(a), rune(a)
}

@(private="file")
split_semicolons :: proc(line: string, out: []string) -> int {
	s := line
	n := 0
	for n < len(out) {
		semi := strings.index_byte(s, ';')
		if semi < 0 {
			out[n] = s
			n += 1
			break
		}
		out[n] = s[:semi]
		n += 1
		s = s[semi + 1:]
	}
	return n
}

@(private="file")
insertion_sort_runes :: proc(rs: []rune) {
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1] > rs[j] {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
sort_compose :: proc(rs: []Compose_Entry) {
	// Insertion sort (good enough for ~2k entries, called once).
	for i in 1..<len(rs) {
		j := i
		for j > 0 {
			a := rs[j - 1]
			b := rs[j]
			less := b.l < a.l || (b.l == a.l && b.c < a.c)
			if !less { break }
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}
