package runa

// cache.odin — memoised shaping with bounded LRU eviction.
//
// The Cache is the caller-owned mutable state for fast re-layout. It
// stores `[]Shaped_Glyph` keyed by `(font, size, axis_hash, text)`. On a
// hit, shape / measure / layout calls return without re-running GSUB /
// GPOS and without allocating — the zero-allocation-on-cache-hit
// guarantee lands here.
//
// The text key is *interned* — every distinct cache key holds its own
// string copy, so the caller may free the original buffer.
//
// Eviction policy: classic O(1) LRU. Entries live in a slot pool;
// each carries `prev` / `next` indices that thread a doubly-linked
// recency list. Hits move the slot to the head; inserts past
// `capacity` evict the tail. The slot pool means addresses stay
// stable across map rehashes — we index by `u32`, not by pointer.
//
// Default capacity is `DEFAULT_CACHE_CAPACITY` (4096 entries, roughly
// ~4-8 MB on typical body text). Pass `max_entries = 0` to `cache_make`
// for an unbounded cache (the old v1.0 behavior). High-churn UIs —
// code editors, log viewers, animated tickers — need a finite cap or
// memory grows without bound.

import "core:mem"
import "core:unicode/utf8"

import "parse"
import "shape"

// DEFAULT_CACHE_CAPACITY is the soft cap a default `cache_make()` lands
// on. Roughly 4-8 MB at typical body sizes — large enough for a window
// full of varied text but small enough that high-churn apps don't run
// the heap up over hours.
DEFAULT_CACHE_CAPACITY :: 4096

// Cache holds the caller-owned shape memoisation table. It's an opaque
// struct — callers don't reach into the field set, just pass `^Cache`
// to the shaping entry points.
//
// Thread safety: a `Cache` is **not** safe to share across threads
// without external synchronisation. `shape_text_cached` writes to the
// underlying slot pool on miss (and also on hit, to update the LRU
// list). Consumers with multi-threaded work (parallel layout passes,
// off-thread shaping for prefetch) either keep one `Cache` per thread
// or wrap calls in their own mutex.
Cache :: struct {
	allocator: mem.Allocator,
	// Slot pool. Index 0 is reserved as the "none" sentinel — every
	// link field uses 0 to mean "no neighbour" / "list empty" / "no
	// free slot". Live slots have `in_use = true`; recycled slots sit
	// on the free list (linked via `next`) with `in_use = false`.
	entries:   [dynamic]Cache_Entry,
	// key → slot index. Maps to 0 only if the key isn't present (map
	// lookup returns the zero value, which we treat as "no slot").
	index:     map[Shape_Key]u32,
	free_head: u32,                // singly-linked free list (uses next field); 0 = empty
	lru_head:  u32,                // most-recently-used slot; 0 = list empty
	lru_tail:  u32,                // least-recently-used slot; 0 = list empty
	capacity:  int,                // 0 = unbounded
}

// Shape_Key uniquely identifies a shaped run.
//
// `font` is compared by pointer — the caller's Font struct must live
// for the lifetime of the Cache. `text` is the caller's UTF-8 slice;
// the cache clones it on insert so the original buffer can vary.
// `axis_hash` folds the variable-font axis tuple into the key — at a
// different `wght` value, the same (font, size, text) produces
// different advances (via HVAR), so it must miss the cache.
@(private)
Shape_Key :: struct {
	font_ptr:  rawptr,
	size:      f32,
	axis_hash: u64,
	text:      string,                // interned by the cache on insert
	features:  bit_set[Feature],      // ligatures-on/off must not share a slot
}

@(private)
Cache_Entry :: struct {
	key:    Shape_Key,
	glyphs: []Shaped_Glyph,
	width:  f32,                     // sum of x_advance — measure-text shortcut
	prev:   u32,                     // earlier in LRU list (more recently used); 0 = head
	next:   u32,                     // later in LRU list (less recently used) OR next free slot when !in_use; 0 = tail / end-of-free-list
	in_use: bool,
}

// cache_make allocates a new shape cache. `max_entries` is the soft
// capacity — once the cache holds that many distinct keys, every
// subsequent miss evicts the least-recently-used entry to make room.
// Pass `max_entries = 0` to disable eviction entirely (the old v1.0
// unbounded behaviour; suitable for short-lived caches or workloads
// with a known finite key set).
cache_make :: proc(allocator := context.allocator, max_entries: int = DEFAULT_CACHE_CAPACITY) -> Cache {
	c := Cache{
		allocator = allocator,
		index     = make(map[Shape_Key]u32, 64, allocator),
		capacity  = max_entries,
	}
	c.entries = make([dynamic]Cache_Entry, 0, 64, allocator)
	// Reserve slot 0 as the sentinel.
	append(&c.entries, Cache_Entry{})
	return c
}

cache_destroy :: proc(c: ^Cache) {
	// Walk every slot and free the entries that are still live (the
	// free-list slots have nil glyphs / "" text already).
	for i in 1..<len(c.entries) {
		entry := &c.entries[i]
		if entry.in_use {
			delete(entry.glyphs, c.allocator)
			delete(entry.key.text, c.allocator)
		}
	}
	delete(c.entries)
	delete(c.index)
	c^ = {}
}

// cache_size returns the number of entries currently held in the cache.
cache_size :: proc(c: ^Cache) -> int {
	return len(c.index)
}

// cache_capacity returns the configured soft cap. 0 means unbounded.
cache_capacity :: proc(c: ^Cache) -> int {
	return c.capacity
}

// cache_set_capacity changes the soft cap at runtime. If the new cap is
// smaller than the current size, evicts least-recently-used entries
// until size fits. Pass 0 to disable eviction.
cache_set_capacity :: proc(c: ^Cache, max_entries: int) {
	c.capacity = max_entries
	if max_entries <= 0 { return }
	for len(c.index) > max_entries {
		if !evict_lru_tail(c) { break }
	}
}

// shape_text_cached returns a slice of Shaped_Glyph for the given
// (font, text, size), reusing a cached buffer if one exists. Cache
// hits make zero heap allocations.
//
// The returned slice is owned by the Cache; do not modify it, and do
// not retain it past `cache_destroy` (or past an eviction — if you
// retain a slice across more cache misses than the cap, it might be
// freed under you. In practice this only matters if you hold a slice
// across many subsequent `shape_text_cached` calls; the same pattern
// already exists in any LRU cache).
shape_text_cached :: proc(font: ^Font, text: string, size: f32, c: ^Cache, script_tag: parse.Tag = parse.LATN_SCRIPT, language_tag: parse.Tag = parse.DFLT_LANG, disable_features: bit_set[Feature] = {}) -> []Shaped_Glyph {
	axis_hash := hash_axis_values(font._axis_values)
	key := Shape_Key{font_ptr = font, size = size, axis_hash = axis_hash, text = text, features = disable_features}

	if slot_idx, ok := c.index[key]; ok && slot_idx != 0 {
		lru_move_to_head(c, slot_idx)
		return c.entries[slot_idx].glyphs
	}

	// Miss. Make room first if we're at the cap, so the new entry
	// doesn't push us over.
	if c.capacity > 0 && len(c.index) >= c.capacity {
		evict_lru_tail(c)
	}

	// Allocate a slot (recycle from free list, or grow the pool).
	slot_idx := acquire_slot(c)

	// Clone the text so the caller's buffer can vary.
	owned_text := strings_clone(text, c.allocator)
	stored_key := Shape_Key{font_ptr = font, size = size, axis_hash = axis_hash, text = owned_text, features = disable_features}

	buf := make([dynamic]Shaped_Glyph, 0, max(8, len(text)), c.allocator)
	shape_into(font, owned_text, size, &buf, script_tag, language_tag, disable_features)
	glyphs := buf[:]

	w: f32 = 0
	for g in glyphs { w += g.x_advance }

	entry := &c.entries[slot_idx]
	entry.key    = stored_key
	entry.glyphs = glyphs
	entry.width  = w
	entry.in_use = true

	c.index[stored_key] = slot_idx
	lru_insert_at_head(c, slot_idx)
	return glyphs
}

// measure_text_cached is the same shape-and-sum-advances cycle as
// `measure_text`, but reuses the Cache's per-run shape buffer. Cache
// hits do not allocate.
measure_text_cached :: proc(text: string, opts: Paragraph_Opts, c: ^Cache) -> (width, height: f32) {
	if len(opts.fonts) == 0 || opts.size <= 0 { return 0, 0 }
	// For multi-font runs, walk codepoints once to find the picks.
	// Use the decoder's actual byte advance (not `utf8_byte_len(r)`,
	// which derives length from the rune VALUE and over-counts for
	// invalid UTF-8 input — see the same fix in `layout_paragraph`).
	byte_off := 0
	cur_font: ^Font
	run_start := 0
	for byte_off < len(text) {
		r, byte_len := utf8.decode_rune_in_string(text[byte_off:])
		picked := pick_font_for_rune(opts.fonts, r)
		if picked != cur_font && cur_font != nil {
			gs := shape_text_cached(cur_font, text[run_start:byte_off], opts.size, c, disable_features = opts.disable_features)
			for sg in gs { width += sg.x_advance }
			run_start = byte_off
		}
		cur_font = picked
		byte_off += byte_len
	}
	if cur_font != nil {
		gs := shape_text_cached(cur_font, text[run_start:byte_off], opts.size, c, disable_features = opts.disable_features)
		for sg in gs { width += sg.x_advance }
	}

	for f in opts.fonts {
		s := opts.size / f32(f.units_per_em)
		h := (f.ascent - f.descent + f.line_gap) * s
		if h > height { height = h }
	}
	return
}

// ---- Slot pool + LRU list internals ------------------------------------

@(private)
acquire_slot :: proc(c: ^Cache) -> u32 {
	if c.free_head != 0 {
		idx := c.free_head
		c.free_head = c.entries[idx].next
		c.entries[idx] = Cache_Entry{}                  // wipe stale fields
		return idx
	}
	append(&c.entries, Cache_Entry{})
	return u32(len(c.entries) - 1)
}

@(private)
release_slot :: proc(c: ^Cache, idx: u32) {
	c.entries[idx] = Cache_Entry{next = c.free_head}    // in_use = false (zero value)
	c.free_head = idx
}

@(private)
lru_insert_at_head :: proc(c: ^Cache, idx: u32) {
	entry := &c.entries[idx]
	entry.prev = 0
	entry.next = c.lru_head
	if c.lru_head != 0 {
		c.entries[c.lru_head].prev = idx
	} else {
		// List was empty before this insert; this slot is both head and tail.
		c.lru_tail = idx
	}
	c.lru_head = idx
}

@(private)
lru_unlink :: proc(c: ^Cache, idx: u32) {
	entry := &c.entries[idx]
	prev := entry.prev
	next := entry.next
	if prev != 0 {
		c.entries[prev].next = next
	} else {
		c.lru_head = next
	}
	if next != 0 {
		c.entries[next].prev = prev
	} else {
		c.lru_tail = prev
	}
}

@(private)
lru_move_to_head :: proc(c: ^Cache, idx: u32) {
	if c.lru_head == idx { return }
	lru_unlink(c, idx)
	lru_insert_at_head(c, idx)
}

@(private)
evict_lru_tail :: proc(c: ^Cache) -> bool {
	idx := c.lru_tail
	if idx == 0 { return false }
	entry := &c.entries[idx]
	// Free owned storage. Order matters — pull the map entry first
	// so the freed string isn't visible as a key in between steps.
	delete_key(&c.index, entry.key)
	delete(entry.glyphs, c.allocator)
	delete(entry.key.text, c.allocator)
	lru_unlink(c, idx)
	release_slot(c, idx)
	return true
}

// ---- Misc helpers (unchanged from prior cache.odin) --------------------

// hash_axis_values folds a (small) array of normalised axis values
// into a u64 cache-key component. The hash is collision-resistant
// enough for variable-font use — fonts ship up to ~13 axes and
// callers re-use the same axis tuple across many shape calls, so
// the input domain is tiny. FNV-1a 64-bit over the raw f32 bits.
@(private)
hash_axis_values :: proc(values: []f32) -> u64 {
	h: u64 = 0xCBF29CE484222325
	for v in values {
		bits := transmute(u32)v
		for i in 0..<4 {
			h ~= u64((bits >> (uint(i) * 8)) & 0xFF)
			h *= 0x100000001B3
		}
	}
	return h
}

// strings_clone copies `s` into `allocator`. core:strings's clone uses
// context.allocator; we need an explicit one for cache ownership.
@(private)
strings_clone :: proc(s: string, allocator: mem.Allocator) -> string {
	if len(s) == 0 { return "" }
	buf := make([]u8, len(s), allocator)
	copy(buf, transmute([]u8)s)
	return string(buf)
}

// shape_into shapes one run into an existing dynamic buffer. Internal
// helper for the cache; mirrors `shape_text` but doesn't allocate the
// output buffer itself.
@(private)
shape_into :: proc(font: ^Font, text: string, size: f32, out: ^[dynamic]Shaped_Glyph, script_tag, language_tag: parse.Tag, disable_features: bit_set[Feature] = {}) {
	inputs := shape.Shape_Inputs{
		cmap         = &font._cmap,
		hmtx         = &font._hmtx,
		gsub         = &font._gsub if font._has_gsub else nil,
		gpos         = &font._gpos if font._has_gpos else nil,
		hvar         = &font._hvar if font._has_hvar else nil,
		axis_values  = font._axis_values,
		units_per_em = font.units_per_em,
	}
	opts := shape.Shape_Run_Opts{script = script_tag, language = language_tag, disable_features = disable_features}
	shape.shape_run(&inputs, opts, text, size, out)
}
