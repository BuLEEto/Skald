/*
Thai word-break dictionary.

Thai text has no inter-word spaces, so UAX #14's default SA-class
resolution to AL produces "the whole sentence is one word"
behaviour — line-breaking only happens at clearly demarcated
boundaries (punctuation, spaces inserted around foreign content).

This module embeds the PyThaiNLP `words_th.txt` corpus (~62 k
entries) and builds a trie at process start for fast longest-match
word segmentation. The trie's children are encoded as a flat array
of (rune, node-index) records sorted per parent so a binary search
locates the next node in O(log fanout) per UTF-8 codepoint.

API:

    thai_segment_breaks(text, breaks)
        Walk `text`. For every maximal run of Thai SA-class
        codepoints, run the longest-match scanner; every word
        boundary it produces is marked in `breaks` (byte index).
        Caller composes the result with the standard LB rules.

References: PyThaiNLP `pythainlp/corpus/words_th.txt` (CC-BY-SA);
verbatim corpus in `tools/ucd/thai_words.txt`.
*/
package linebreak

import "base:runtime"

import "core:strings"
import "core:sync"

// THAI_DICT compiles in the PyThaiNLP word-break dictionary. OFF by default:
// the CC-BY-SA corpus stays out of the binary and Thai falls back to
// grapheme-cluster breaks. Enable with `-define:RUNA_THAI_DICT=true` (and then
// honour the corpus's CC-BY-SA attribution + share-alike).
THAI_DICT :: #config(RUNA_THAI_DICT, false)

when THAI_DICT {

@(private="file")
THAI_DICT_DATA :: #load("../tools/ucd/thai_words.txt", string)

@(private="file")
Trie_Node :: struct {
	child_start: u32,                                    // index into g_thai_children
	child_count: u32,
	terminal:    bool,                                   // word ends here
}

@(private="file")
Trie_Child :: struct {
	r:   rune,
	idx: u32,                                            // index into g_thai_nodes
}

@(private="file") g_thai_nodes:    []Trie_Node
@(private="file") g_thai_children: []Trie_Child
@(private="file") g_thai_once:     sync.Once

// thai_segment_breaks walks `text` (a rune slice) and marks each
// interior codepoint index in `breaks` that's a word boundary
// inside a Thai run. `breaks` must have length `len(text)`; caller
// composes these opportunities with the standard LB rules.
thai_segment_breaks :: proc(text: []rune, breaks: []bool) {
	i := 0
	for i < len(text) {
		if text[i] >= 0x0E00 && text[i] <= 0x0E7F {
			// Build the trie lazily — only once Thai actually appears.
			sync.once_do(&g_thai_once, init_thai_trie)
			if len(g_thai_nodes) == 0 { return }
			run_lo := i
			j := i
			for j < len(text) && text[j] >= 0x0E00 && text[j] <= 0x0E7F { j += 1 }
			thai_run_breaks(text, run_lo, j, breaks)
			i = j
		} else {
			i += 1
		}
	}
}

@(private)
thai_run_breaks :: proc(text: []rune, lo, hi: int, breaks: []bool) {
	p := lo
	for p < hi {
		match_end := longest_match(text, p, hi)
		if match_end == p {
			p += 1
			continue
		}
		p = match_end
		if p < hi { breaks[p] = true }
	}
}

@(private)
longest_match :: proc(text: []rune, start, end: int) -> int {
	node_idx: u32 = 0
	best := start
	for pos := start; pos < end; pos += 1 {
		next_idx, ok := trie_child(node_idx, text[pos])
		if !ok { break }
		node_idx = next_idx
		if g_thai_nodes[node_idx].terminal { best = pos + 1 }
	}
	return best
}

@(private)
trie_child :: proc(parent: u32, r: rune) -> (u32, bool) {
	node := g_thai_nodes[parent]
	if node.child_count == 0 { return 0, false }
	lo := int(node.child_start)
	hi := lo + int(node.child_count)
	for lo < hi {
		mid := (lo + hi) / 2
		c := g_thai_children[mid]
		switch {
		case r < c.r: hi = mid
		case r > c.r: lo = mid + 1
		case:         return c.idx, true
		}
	}
	return 0, false
}

@(private="file")
Build_Node :: struct {
	children: map[rune]u32,
	terminal: bool,
}

@(private="file")
init_thai_trie :: proc() {
	context.allocator = runtime.heap_allocator()

	// Build phase: keep children as maps for cheap insertion. Then
	// flatten into sorted arrays for fast lookup.
	nodes := make([dynamic]Build_Node, 0, 64 * 1024)
	defer {
		for &n in nodes { delete(n.children) }
		delete(nodes)
	}
	append(&nodes, Build_Node{children = make(map[rune]u32)})

	insert :: proc(nodes: ^[dynamic]Build_Node, word: string) {
		node_idx: u32 = 0
		i := 0
		for i < len(word) {
			r, sz := utf8_decode_one(word, i)
			i += sz
			next, found := nodes[node_idx].children[r]
			if !found {
				// Allocate the new child BEFORE we touch the parent's
				// map again — the append may reallocate `nodes`,
				// invalidating any pointer into it. Take the map by
				// value lookup, then re-fetch the parent's map
				// reference after the append.
				append(nodes, Build_Node{children = make(map[rune]u32)})
				next = u32(len(nodes) - 1)
				nodes[node_idx].children[r] = next
			}
			node_idx = next
		}
		nodes[node_idx].terminal = true
	}

	data := THAI_DICT_DATA
	for line in strings.split_lines_iterator(&data) {
		w := strings.trim_space(line)
		if len(w) == 0 || w[0] == '#' { continue }
		if !is_pure_thai_word(w) { continue }
		insert(&nodes, w)
	}

	// Flatten.
	n := len(nodes)
	total_children := 0
	for i in 0..<n { total_children += len(nodes[i].children) }

	out_nodes    := make([]Trie_Node,  n,              context.allocator)
	out_children := make([]Trie_Child, total_children, context.allocator)

	child_cursor: u32 = 0
	for i in 0..<n {
		mn := &nodes[i]
		out_nodes[i] = Trie_Node{
			child_start = child_cursor,
			child_count = u32(len(mn.children)),
			terminal    = mn.terminal,
		}
		buf := make([dynamic]Trie_Child, 0, len(mn.children), context.temp_allocator)
		for r, idx in mn.children {
			append(&buf, Trie_Child{r = r, idx = idx})
		}
		// Insertion sort — small fan-out.
		for k in 1..<len(buf) {
			j := k
			for j > 0 && buf[j - 1].r > buf[j].r {
				buf[j - 1], buf[j] = buf[j], buf[j - 1]
				j -= 1
			}
		}
		for c in buf {
			out_children[child_cursor] = c
			child_cursor += 1
		}
	}
	g_thai_nodes    = out_nodes
	g_thai_children = out_children
}

@(private="file")
is_pure_thai_word :: proc(w: string) -> bool {
	i := 0
	count := 0
	for i < len(w) {
		r, sz := utf8_decode_one(w, i)
		if r < 0x0E00 || r > 0x0E7F { return false }
		count += 1
		i += sz
	}
	return count >= 1
}

@(private)
utf8_decode_one :: proc(s: string, off: int) -> (rune, int) {
	if off >= len(s) { return 0, 0 }
	b0 := s[off]
	if b0 < 0x80          { return rune(b0), 1 }
	if b0 < 0xC0          { return 0xFFFD, 1 }
	if b0 < 0xE0 && off + 2 <= len(s) {
		return rune(u32(b0 & 0x1F)<<6 | u32(s[off + 1] & 0x3F)), 2
	}
	if b0 < 0xF0 && off + 3 <= len(s) {
		return rune(u32(b0 & 0x0F)<<12 | u32(s[off + 1] & 0x3F)<<6 | u32(s[off + 2] & 0x3F)), 3
	}
	if b0 < 0xF8 && off + 4 <= len(s) {
		return rune(u32(b0 & 0x07)<<18 | u32(s[off + 1] & 0x3F)<<12 | u32(s[off + 2] & 0x3F)<<6 | u32(s[off + 3] & 0x3F)), 4
	}
	return 0xFFFD, 1
}

} else {

// Grapheme-cluster fallback when the dictionary isn't compiled in: mark a break
// before each non-combining char of a Thai run, so long Thai still wraps
// somewhere without the CC-BY-SA corpus. Not word-accurate, but non-crashing.
thai_segment_breaks :: proc(text: []rune, breaks: []bool) {
	i := 0
	for i < len(text) {
		if text[i] >= 0x0E00 && text[i] <= 0x0E7F {
			j := i
			for j < len(text) && text[j] >= 0x0E00 && text[j] <= 0x0E7F { j += 1 }
			for k in i + 1 ..< j {
				if !sa_resolves_to_cm(text[k]) { breaks[k] = true }
			}
			i = j
		} else {
			i += 1
		}
	}
}

}
