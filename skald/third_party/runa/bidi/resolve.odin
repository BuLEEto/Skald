/*
UAX #9 bidi resolution.

Pipeline:

  1. P2 / P3   Determine paragraph base direction (caller-supplied
               or auto-detect via `paragraph_direction`).
  2. X1 .. X8  Explicit embedding / override / isolate stack.
               Assigns each codepoint an embedding level (and an
               effective Bidi_Class after override / formatting-code
               filtering).
  3. W1 .. W7  Resolve weak types (NSM inheritance, EN ↔ AN context,
               ES / CS bridging, ET runs, EN ← L) per level run.
  4. N0        Resolve neutrals inside bracket pairs (BD16).
  5. N1 / N2   Resolve remaining neutrals to the surrounding
               strong direction or the embedding direction.
  6. I1 / I2   Assign implicit levels — bump strong types whose
               natural direction disagrees with their embedding.
  7. L1        Reset paragraph-end whitespace + line-end whitespace
               to the paragraph base level.
  8. L2        Visual reorder (`reorder_runs`).

What is *not* done at this revision:
  - Full isolating-run-sequence concatenation across isolates
    (X-rules + isolate-aware run grouping). v0.6 polish.
  - Mirrored-glyph substitution (L4) — that's a shaper concern.
  - L3 (combining-mark wrapping at line boundaries).

References: UAX #9 §3.3.
*/
package bidi

import "core:mem"

// MAX_LEVEL is the UAX #9 §3.3 cap. 125 even, 126 odd.
MAX_LEVEL :: 125

// Maximum directional-status stack depth — UAX #9 §3.3.2 caps at
// MAX_LEVEL + 2 frames.
MAX_DEPTH :: MAX_LEVEL + 2

// Run is one contiguous span of codepoints sharing the same embedding
// level. The visual order of the paragraph is the concatenation of
// runs reordered per L2.
Run :: struct {
	byte_start: int,
	byte_end:   int,
	level:      u8,
}

// resolve_levels runs the bidi pipeline on `text` at paragraph
// direction `base_dir` and returns one embedding level per codepoint
// plus the byte-offset map. Allocates both slices from `allocator`;
// scratch lives in `context.temp_allocator`.
resolve_levels :: proc(text: string, base_dir: Direction, allocator := context.allocator) -> (levels: []u8, byte_indices: []int) {
	base_level: u8 = base_dir == .RTL ? 1 : 0

	// Codepoint count + cmap-style buffer build.
	cp_count := 0
	for _ in text { cp_count += 1 }

	levels       = make([]u8,  cp_count, allocator)
	byte_indices = make([]int, cp_count, allocator)
	classes := make([]Bidi_Class, cp_count, context.temp_allocator)
	runes   := make([]rune,       cp_count, context.temp_allocator)
	defer delete(classes, context.temp_allocator)
	defer delete(runes,   context.temp_allocator)

	// Snapshot the unmodified bidi classes for use by L1 — W / N
	// rules will mutate `classes[]` and L1 needs the *original*
	// Bidi_Class to identify S, B, WS, isolate-formatting chars.
	orig_classes := make([]Bidi_Class, cp_count, context.temp_allocator)

	i := 0
	off := 0
	for r in text {
		byte_indices[i] = off
		runes[i] = r
		c := bidi_class(r)
		classes[i] = c
		orig_classes[i] = c
		i += 1
		off += utf8_byte_len_b(r)
	}
	if cp_count == 0 { return }

	// X-rule pass: assigns `levels[i]` and rewrites `classes[i]` per
	// the directional stack. Formatting codes (LRE/RLE/PDF/etc.)
	// resolve to BN after this pass, which W/N rules then treat as
	// invisible. `valid_isolate[i]` is set for isolate initiators
	// that successfully pushed a frame (and the PDIs that match
	// them) — used to group level runs into isolating run sequences.
	valid_isolate := make([]bool, cp_count, context.temp_allocator)
	apply_x_rules(runes, classes, levels, base_level, valid_isolate)

	// Group level runs into isolating run sequences and resolve W/N/I
	// per ISR. For paragraphs with no valid isolates each level run
	// is its own ISR, which collapses to the simple per-run pipeline.
	resolve_isolating_runs(runes, classes, levels, valid_isolate, base_level)

	// L1: paragraph & segment separators always reset to the
	// paragraph embedding level (UAX #9 §3.4 L1 items 1 & 2).
	// L1 uses the *original* bidi class, since W / N rules will
	// have rewritten the resolved class by the time we get here.
	for k in 0..<cp_count {
		c := orig_classes[k]
		if c == .B || c == .S { levels[k] = base_level }
	}
	// L1 item 3: whitespace / isolate-formatting characters
	// preceding an S or B separator.
	{
		k := 0
		for k < cp_count {
			c := orig_classes[k]
			if c == .WS || c == .LRI || c == .RLI || c == .FSI || c == .PDI {
				start := k
				for k < cp_count {
					cc := orig_classes[k]
					if cc != .WS && cc != .LRI && cc != .RLI && cc != .FSI && cc != .PDI { break }
					k += 1
				}
				next: Bidi_Class = k < cp_count ? orig_classes[k] : .ON
				if next == .S || next == .B {
					for m in start..<k { levels[m] = base_level }
				}
			} else {
				k += 1
			}
		}
	}
	// L1 item 4: trailing whitespace / isolate-formatting characters.
	for k := cp_count - 1; k >= 0; k -= 1 {
		c := orig_classes[k]
		if c == .WS || c == .B || c == .S || c == .LRI || c == .RLI || c == .FSI || c == .PDI {
			levels[k] = base_level
		} else {
			break
		}
	}
	return
}

// ---- X rules ----------------------------------------------------

@(private)
Stack_Entry :: struct {
	level:    u8,
	override: Bidi_Class,        // .ON when no override
	isolate:  bool,
}

@(private)
apply_x_rules :: proc(runes: []rune, classes: []Bidi_Class, levels: []u8, base_level: u8, valid_isolate: []bool) {
	stack := make([dynamic]Stack_Entry, 0, 64, context.temp_allocator)
	defer delete(stack)
	append(&stack, Stack_Entry{level = base_level, override = .ON, isolate = false})

	// Parallel stack of ISI positions — pops to a PDI when the
	// isolate frame is popped, so we can flag both ends of the
	// matched pair for ISR grouping.
	isi_stack := make([dynamic]int, 0, 16, context.temp_allocator)
	defer delete(isi_stack)

	overflow_iso  := 0
	overflow_emb  := 0
	valid_iso     := 0

	for i in 0..<len(classes) {
		c := classes[i]
		top := &stack[len(stack) - 1]

		#partial switch c {
		case .RLE:
			// X2: push a new RLE frame.
			new_level := next_odd(top.level)
			if new_level <= MAX_LEVEL && overflow_iso == 0 && overflow_emb == 0 {
				append(&stack, Stack_Entry{level = new_level, override = .ON, isolate = false})
			} else if overflow_iso == 0 {
				overflow_emb += 1
			}
			levels[i] = top.level
			classes[i] = .BN
			continue
		case .LRE:
			// X3: push a new LRE frame.
			new_level := next_even(top.level)
			if new_level <= MAX_LEVEL && overflow_iso == 0 && overflow_emb == 0 {
				append(&stack, Stack_Entry{level = new_level, override = .ON, isolate = false})
			} else if overflow_iso == 0 {
				overflow_emb += 1
			}
			levels[i] = top.level
			classes[i] = .BN
			continue
		case .RLO:
			// X4: push RLE-level with R override.
			new_level := next_odd(top.level)
			if new_level <= MAX_LEVEL && overflow_iso == 0 && overflow_emb == 0 {
				append(&stack, Stack_Entry{level = new_level, override = .R, isolate = false})
			} else if overflow_iso == 0 {
				overflow_emb += 1
			}
			levels[i] = top.level
			classes[i] = .BN
			continue
		case .LRO:
			// X5: push LRE-level with L override.
			new_level := next_even(top.level)
			if new_level <= MAX_LEVEL && overflow_iso == 0 && overflow_emb == 0 {
				append(&stack, Stack_Entry{level = new_level, override = .L, isolate = false})
			} else if overflow_iso == 0 {
				overflow_emb += 1
			}
			levels[i] = top.level
			classes[i] = .BN
			continue
		case .RLI:
			// X5a: assign current level + apply override, then push
			// isolate frame.
			levels[i] = top.level
			if top.override != .ON { classes[i] = top.override }
			new_level := next_odd(top.level)
			if new_level <= MAX_LEVEL && overflow_iso == 0 && overflow_emb == 0 {
				valid_iso += 1
				append(&stack, Stack_Entry{level = new_level, override = .ON, isolate = true})
				append(&isi_stack, i)
				valid_isolate[i] = true
			} else {
				overflow_iso += 1
			}
			continue
		case .LRI:
			levels[i] = top.level
			if top.override != .ON { classes[i] = top.override }
			new_level := next_even(top.level)
			if new_level <= MAX_LEVEL && overflow_iso == 0 && overflow_emb == 0 {
				valid_iso += 1
				append(&stack, Stack_Entry{level = new_level, override = .ON, isolate = true})
				append(&isi_stack, i)
				valid_isolate[i] = true
			} else {
				overflow_iso += 1
			}
			continue
		case .FSI:
			// X5c: scan ahead to the matching PDI for the first
			// strong type. R / AL → behave as RLI (odd push), else as
			// LRI (even push). Nested isolates are skipped via a
			// local depth counter.
			levels[i] = top.level
			if top.override != .ON { classes[i] = top.override }

			is_rli := false
			{
				depth := 0
				scan: for j := i + 1; j < len(classes); j += 1 {
					cj := classes[j]
					#partial switch cj {
					case .LRI, .RLI, .FSI:
						depth += 1
					case .PDI:
						if depth == 0 { break scan }
						depth -= 1
					case:
						if depth > 0 { continue }
						if cj == .L { break scan }
						if cj == .R || cj == .AL { is_rli = true; break scan }
					}
				}
			}
			new_level := is_rli ? next_odd(top.level) : next_even(top.level)
			if new_level <= MAX_LEVEL && overflow_iso == 0 && overflow_emb == 0 {
				valid_iso += 1
				append(&stack, Stack_Entry{level = new_level, override = .ON, isolate = true})
				append(&isi_stack, i)
				valid_isolate[i] = true
			} else {
				overflow_iso += 1
			}
			continue
		case .PDI:
			// X6a: pop until isolate frame.
			if overflow_iso > 0 {
				overflow_iso -= 1
			} else if valid_iso > 0 {
				overflow_emb = 0
				for len(stack) > 1 && !stack[len(stack) - 1].isolate {
					pop(&stack)
				}
				if len(stack) > 1 {
					pop(&stack)
				}
				valid_iso -= 1
				if len(isi_stack) > 0 {
					pop(&isi_stack)
					valid_isolate[i] = true
				}
			}
			top = &stack[len(stack) - 1]
			levels[i] = top.level
			if top.override != .ON { classes[i] = top.override }
			continue
		case .PDF:
			// X7: pop one non-isolate frame.
			if overflow_iso > 0 {
				// PDF inside an overflowing isolate is a no-op.
			} else if overflow_emb > 0 {
				overflow_emb -= 1
			} else if len(stack) > 1 && !stack[len(stack) - 1].isolate {
				pop(&stack)
			}
			levels[i] = stack[len(stack) - 1].level
			classes[i] = .BN
			continue
		case .B:
			// Paragraph separator — assigned the paragraph level.
			levels[i] = base_level
			continue
		case .BN:
			// Boundary neutral keeps the current level.
			levels[i] = top.level
			continue
		}

		// X6: any other class — assign current level and apply
		// override.
		levels[i] = top.level
		if top.override != .ON { classes[i] = top.override }
	}
}

// ---- W / N / I rules per isolating run sequence ------------------

// resolve_isolating_runs groups the level runs into isolating run
// sequences (UAX #9 §3.3.3 BD13), then runs W / N / I rules over each
// ISR as a single concatenated sequence. The ISR grouping respects
// matched isolate pairs from `valid_isolate` so the level runs on the
// outer side of an isolate share their W / N context.
@(private)
resolve_isolating_runs :: proc(runes: []rune, classes: []Bidi_Class, levels: []u8, valid_isolate: []bool, base_level: u8) {
	n := len(classes)
	if n == 0 { return }

	// Step 1: enumerate level runs (max-contiguous same-level spans).
	Level_Run :: struct { lo, hi: int, level: u8 }
	runs := make([dynamic]Level_Run, 0, 16, context.temp_allocator)
	defer delete(runs)

	run_lo := 0
	for j in 1..=n {
		if j == n || levels[j] != levels[run_lo] {
			append(&runs, Level_Run{lo = run_lo, hi = j, level = levels[run_lo]})
			run_lo = j
		}
	}
	if len(runs) == 0 { return }

	// Step 2: group level runs into ISRs per UAX #9 BD13: a level run
	// continues an existing ISR iff it begins with a matched PDI
	// that closes a valid isolate initiator at the end of an
	// earlier run. Embedding push/pop (RLE / LRE / PDF) normally
	// splits level runs *without* joining them.
	//
	// Exception: when the intervening level runs are *all-BN* (i.e.
	// completely X9-removed — empty RLE+PDF chains), they don't
	// contribute any visible content. Two same-level non-BN runs
	// separated only by all-BN runs effectively share their
	// surroundings and should belong to the same ISR. This matches
	// the reference impl's behaviour for the deeply-nested empty
	// embedding cases in BidiCharacterTest.
	is_all_bn_run :: proc(classes: []Bidi_Class, lo, hi: int) -> bool {
		for k in lo..<hi { if classes[k] != .BN { return false } }
		return true
	}

	isr_runs := make([dynamic][dynamic]int, 0, 8, context.temp_allocator)
	defer {
		for &lst in isr_runs { delete(lst) }
		delete(isr_runs)
	}
	isolate_stack := make([dynamic]int, 0, 8, context.temp_allocator)
	defer delete(isolate_stack)

	// Track the most recent non-all-BN run's level + ISR ID. To
	// "tunnel" through empty embeddings (all-BN intervening runs),
	// require them to be at a *higher* level than the surrounding
	// real runs — i.e. they represent deeper nesting, not a
	// neighbouring scope. The minimum level seen across intervening
	// all-BN runs since the last real run captures this.
	prev_real_level: u8 = 0
	prev_real_isr   := -1
	prev_real_seen  := false
	intervening_min_bn_level: u8 = 0
	saw_bn_gap := false

	for r in 0..<len(runs) {
		run := runs[r]
		first_class := classes[run.lo]

		if is_all_bn_run(classes, run.lo, run.hi) {
			if saw_bn_gap {
				if run.level < intervening_min_bn_level { intervening_min_bn_level = run.level }
			} else {
				intervening_min_bn_level = run.level
				saw_bn_gap = true
			}
			continue
		}

		isr_id: int
		joined := false
		if first_class == .PDI && valid_isolate[run.lo] && len(isolate_stack) > 0 {
			isr_id = pop(&isolate_stack)
			joined = true
		} else if prev_real_seen && saw_bn_gap &&
		          prev_real_level == run.level &&
		          intervening_min_bn_level > run.level {
			// Same outer level, only deeper-nested empty embeddings
			// between us → rejoin the previous real run's ISR.
			isr_id = prev_real_isr
			joined = true
		}
		if !joined {
			isr_id = len(isr_runs)
			new_isr := make([dynamic]int, 0, 4, context.temp_allocator)
			append(&isr_runs, new_isr)
		}
		append(&isr_runs[isr_id], r)

		prev_real_level = run.level
		prev_real_isr   = isr_id
		prev_real_seen  = true
		saw_bn_gap      = false

		last_class := classes[run.hi - 1]
		if (last_class == .LRI || last_class == .RLI || last_class == .FSI) && valid_isolate[run.hi - 1] {
			append(&isolate_stack, isr_id)
		}
	}

	// I1 promotes `levels[]` per ISR; later ISRs would then read
	// already-promoted neighbour levels when computing sos/eos. Take a
	// snapshot of the X-rules levels here so all ISRs see the same
	// boundary directions regardless of processing order.
	x_levels := make([]u8, n, context.temp_allocator)
	copy(x_levels, levels)

	// Step 3: per-ISR W / N / I.
	for isr_idx in 0..<len(isr_runs) {
		run_indices := isr_runs[isr_idx]
		if len(run_indices) == 0 { continue }

		// Flatten run_indices → positions[] in logical order, skipping
		// X9-removed BN characters so W/N rules see the underlying
		// strong/weak sequence without spurious neutral gaps.
		positions_d := make([dynamic]int, 0, 16, context.temp_allocator)
		for ri in run_indices {
			rn := runs[ri]
			for p in rn.lo..<rn.hi {
				if classes[p] == .BN { continue }
				append(&positions_d, p)
			}
		}
		positions := positions_d[:]
		if len(positions) == 0 { continue }

		first_run := runs[run_indices[0]]
		last_run  := runs[run_indices[len(run_indices) - 1]]

		// sos / eos per UAX #9 §3.3.3: parity of max(adjacent-level,
		// this-level), with paragraph base as sentinel at boundaries.
		// Read from the X-rules snapshot to avoid contamination from
		// other ISRs' I1 promotions.
		prev_level := base_level
		if first_run.lo > 0 { prev_level = x_levels[first_run.lo - 1] }
		next_level := base_level
		if last_run.hi  < n { next_level = x_levels[last_run.hi] }

		sos_level := prev_level if prev_level > first_run.level else first_run.level
		eos_level := next_level if next_level > last_run.level  else last_run.level
		sos: Bidi_Class = (sos_level & 1 == 1) ? .R : .L
		eos: Bidi_Class = (eos_level & 1 == 1) ? .R : .L

		resolve_isolating_run(runes, classes, levels, positions, sos, eos)
	}
}

@(private)
resolve_isolating_run :: proc(runes: []rune, classes: []Bidi_Class, levels: []u8, positions: []int, sos, eos: Bidi_Class) {
	n := len(positions)
	if n == 0 { return }
	// All positions in the ISR share the same embedding level by
	// construction; pull it once for I1 / I2 and N2 default direction.
	run_level := levels[positions[0]]

	// N0 needs the *pre-W1* NSM positions for its tail rule.
	orig_nsm := make([]bool, n, context.temp_allocator)
	for k in 0..<n {
		if classes[positions[k]] == .NSM { orig_nsm[k] = true }
	}

	// W1: NSM takes the class of the preceding char (sos at start).
	for k in 0..<n {
		pk := positions[k]
		if classes[pk] != .NSM { continue }
		if k == 0 {
			classes[pk] = sos
		} else {
			prev := classes[positions[k - 1]]
			#partial switch prev {
			case .LRI, .RLI, .FSI, .PDI:
				classes[pk] = .ON
			case:
				classes[pk] = prev
			}
		}
	}

	// W2: EN preceded by AL (no L/R between) becomes AN.
	for k in 0..<n {
		pk := positions[k]
		if classes[pk] != .EN { continue }
		for j := k - 1; j >= 0; j -= 1 {
			pc := classes[positions[j]]
			if pc == .L || pc == .R { break }
			if pc == .AL { classes[pk] = .AN; break }
		}
	}

	// W3: AL → R.
	for k in 0..<n {
		pk := positions[k]
		if classes[pk] == .AL { classes[pk] = .R }
	}

	// W4: ES between two ENs → EN. CS between two ENs → EN, between
	// two ANs → AN.
	if n >= 3 {
		for k in 1..<n - 1 {
			pk := positions[k]
			l := classes[positions[k - 1]]
			r := classes[positions[k + 1]]
			#partial switch classes[pk] {
			case .ES:
				if l == .EN && r == .EN { classes[pk] = .EN }
			case .CS:
				if l == .EN && r == .EN { classes[pk] = .EN }
				if l == .AN && r == .AN { classes[pk] = .AN }
			}
		}
	}

	// W5: ET adjacent to EN → EN.
	for k in 0..<n {
		pk := positions[k]
		if classes[pk] != .ET { continue }
		for j := k + 1; j < n; j += 1 {
			cj := classes[positions[j]]
			if cj == .ET { continue }
			if cj == .EN { classes[pk] = .EN }
			break
		}
		if classes[pk] == .EN { continue }
		for j := k - 1; j >= 0; j -= 1 {
			cj := classes[positions[j]]
			if cj == .ET { continue }
			if cj == .EN { classes[pk] = .EN }
			break
		}
	}

	// W6: residual ET / ES / CS → ON.
	for k in 0..<n {
		pk := positions[k]
		#partial switch classes[pk] {
		case .ET, .ES, .CS: classes[pk] = .ON
		}
	}

	// W7: EN preceded by L (no R between) becomes L. sos acts as
	// sentinel when the scan falls off the start.
	for k in 0..<n {
		pk := positions[k]
		if classes[pk] != .EN { continue }
		found_strong := false
		for j := k - 1; j >= 0; j -= 1 {
			cj := classes[positions[j]]
			if cj == .L { classes[pk] = .L; found_strong = true; break }
			if cj == .R { found_strong = true; break }
		}
		if !found_strong && sos == .L {
			classes[pk] = .L
		}
	}

	// N0: bracket pairs.
	resolve_bracket_pairs(runes, classes, positions, sos, orig_nsm)

	// N1 / N2: neutrals between same-direction strong types take that
	// direction; otherwise take embedding direction (run-level parity).
	embedding_dir: Bidi_Class = (run_level & 1 == 1) ? .R : .L
	for k := 0; k < n; {
		if !is_neutral_n(classes[positions[k]]) { k += 1; continue }
		start := k
		for k < n && is_neutral_n(classes[positions[k]]) { k += 1 }
		end := k

		left: Bidi_Class
		if start == 0 {
			left = sos
		} else {
			left = strong_dir_of(classes[positions[start - 1]], sos)
		}
		right: Bidi_Class
		if end == n {
			right = eos
		} else {
			right = strong_dir_of(classes[positions[end]], eos)
		}
		fill: Bidi_Class = left if left == right else embedding_dir
		for m in start..<end { classes[positions[m]] = fill }
	}

	// I1 / I2: implicit level assignment.
	for k in 0..<n {
		pk := positions[k]
		L := run_level
		#partial switch classes[pk] {
		case .L:
			if run_level & 1 == 1 { L = run_level + 1 }
		case .R:
			if run_level & 1 == 0 { L = run_level + 1 }
		case .EN, .AN:
			if run_level & 1 == 0 { L = run_level + 2 }
			else                   { L = run_level + 1 }
		}
		if L > MAX_LEVEL { L = MAX_LEVEL }
		levels[pk] = L
	}
}

// ---- N0: bracket pair direction ---------------------------------

@(private)
Bracket_Frame :: struct {
	open_idx: int,
	close:    rune,                            // matching close codepoint
}

// resolve_bracket_pairs operates on the ISR's logical-index sequence
// `positions`. Indices into pairs are ISR-local (0..len(positions));
// translate to global via positions[k] for the underlying class /
// rune arrays.
@(private)
resolve_bracket_pairs :: proc(runes: []rune, classes: []Bidi_Class, positions: []int, sos: Bidi_Class, orig_nsm: []bool) {
	n := len(positions)
	embedding_l := sos // sos parity == embedding direction for the ISR

	// BD16: build the list of bracket pairs within this ISR.
	stack := make([dynamic]Bracket_Frame, 0, 16, context.temp_allocator)
	defer delete(stack)
	pairs := make([dynamic][2]int, 0, 8, context.temp_allocator)
	defer delete(pairs)

	// BD16 stack overflow: per the reference implementation, once
	// the stack saturates we abandon bracket detection for the
	// whole ISR. Partial pairing produces visually inconsistent
	// output, so it's safer to fall through to the neutral
	// resolution rules — matches ICU's behaviour, which is what
	// BidiCharacterTest is generated against.
	BD16_STACK_LIMIT :: 63
	overflowed := false
	for k in 0..<n {
		if overflowed { break }
		r := runes[positions[k]]
		t := bidi_paired_bracket_type(r)
		#partial switch t {
		case .Open:
			if len(stack) >= BD16_STACK_LIMIT { overflowed = true; break }
			match := bidi_paired_bracket(r)
			append(&stack, Bracket_Frame{open_idx = k, close = match})
		case .Close:
			for j := len(stack) - 1; j >= 0; j -= 1 {
				if brackets_match(stack[j].close, r) {
					append(&pairs, [2]int{stack[j].open_idx, k})
					resize(&stack, j)                       // pop this frame *and* anything above
					break
				}
			}
		}
	}
	if overflowed { clear(&pairs) }

	// UAX #9 N0 processes pairs in opening-position order; pairs are
	// appended in close-discovery order, which is reverse for nested
	// input. Insertion-sort by opening index — N <= 63 here.
	for i in 1..<len(pairs) {
		cur := pairs[i]
		j := i
		for j > 0 && pairs[j - 1][0] > cur[0] {
			pairs[j] = pairs[j - 1]
			j -= 1
		}
		pairs[j] = cur
	}

	for p in pairs {
		saw_matching := false
		saw_opposite := false
		for k := p[0] + 1; k < p[1]; k += 1 {
			s := strong_dir_of(classes[positions[k]], .ON)
			if s == .ON { continue }
			if s == embedding_l { saw_matching = true; break }
			saw_opposite = true
		}

		dir: Bidi_Class
		switch {
		case saw_matching:
			dir = embedding_l // N0.b
		case saw_opposite:
			// N0.c: opposite strong inside → walk back through the
			// ISR; if a preceding strong matches the *opposite*
			// direction, use it. Otherwise fall back to embedding.
			dir = embedding_l
			for j := p[0] - 1; j >= 0; j -= 1 {
				s := strong_dir_of(classes[positions[j]], .ON)
				if s != .ON {
					if s != embedding_l { dir = s }
					break
				}
			}
		case:
			// N0.d: no strong inside — bracket pair unchanged; N1/N2
			// resolves as part of the surrounding neutral sequence.
			continue
		}
		// Only retype brackets that are still neutral. A bracket whose
		// class was already promoted to a strong type by an X-rule
		// override (LRO / RLO applied to the same codepoint) keeps that
		// override — N0 should not silently undo it. Matches the
		// behaviour exercised by BidiCharacterTest.
		open_pos  := positions[p[0]]
		close_pos := positions[p[1]]
		if classes[open_pos]  != .L && classes[open_pos]  != .R { classes[open_pos]  = dir }
		if classes[close_pos] != .L && classes[close_pos] != .R { classes[close_pos] = dir }

		// N0 tail: characters that were originally NSM (before W1)
		// and immediately follow either bracket adopt the resolved
		// direction.
		for k := p[0] + 1; k < n; k += 1 {
			if !orig_nsm[k] { break }
			classes[positions[k]] = dir
		}
		for k := p[1] + 1; k < n; k += 1 {
			if !orig_nsm[k] { break }
			classes[positions[k]] = dir
		}
	}
}

// ---- helpers -----------------------------------------------------

@(private) is_neutral_n :: proc(c: Bidi_Class) -> bool {
	#partial switch c {
	case .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI: return true
	}
	return false
}

// strong_dir_of returns .L for L-direction, .R for R/EN/AN, or the
// passed `fallback` for non-strong classes.
@(private) strong_dir_of :: proc(c: Bidi_Class, fallback: Bidi_Class) -> Bidi_Class {
	#partial switch c {
	case .L:           return .L
	case .R, .EN, .AN: return .R
	}
	return fallback
}

@(private) next_odd  :: proc(L: u8) -> u8 { return L + ((L & 1) == 0 ? 1 : 2) }
@(private) next_even :: proc(L: u8) -> u8 { return L + ((L & 1) == 0 ? 2 : 1) }


// ---- reorder_runs (UAX #9 L2) ------------------------------------

// reorder_runs produces Visual-order Run entries from a logical-order
// `levels` array. Same as v0.5 first cut — caller is expected to use
// `Paragraph_Glyph.level` and apply the per-line reorder via the
// runa facade rather than this proc, but the proc stays for any
// consumer that wants to work at the codepoint-level reorder.
reorder_runs :: proc(levels: []u8, byte_indices: []int, text: string, allocator := context.allocator) -> []Run {
	n := len(levels)
	if n == 0 {
		return make([]Run, 0, allocator)
	}

	logical := make([dynamic]Run, 0, n / 2 + 1, context.temp_allocator)
	defer delete(logical)

	start := 0
	for i in 1..<n {
		if levels[i] != levels[start] {
			end_byte := byte_indices[i]
			append(&logical, Run{byte_start = byte_indices[start], byte_end = end_byte, level = levels[start]})
			start = i
		}
	}
	end_byte := len(text)
	append(&logical, Run{byte_start = byte_indices[start], byte_end = end_byte, level = levels[start]})

	visual := make([dynamic]Run, len(logical), context.temp_allocator)
	defer delete(visual)
	for r, i in logical { visual[i] = r }

	highest := u8(0)
	lowest_odd := u8(MAX_LEVEL + 1)
	for r in logical {
		if r.level > highest { highest = r.level }
		if r.level & 1 == 1 && r.level < lowest_odd { lowest_odd = r.level }
	}
	if lowest_odd <= MAX_LEVEL {
		for L := highest; L >= lowest_odd; L -= 1 {
			i := 0
			for i < len(visual) {
				if visual[i].level < L { i += 1; continue }
				j := i
				for j < len(visual) && visual[j].level >= L { j += 1 }
				reverse_runs(visual[i:j])
				i = j
			}
			if L == 0 { break }
		}
	}

	out := make([]Run, len(visual), allocator)
	for r, i in visual { out[i] = r }
	return out
}

@(private)
reverse_runs :: proc(rs: []Run) {
	for i in 0..<len(rs) / 2 {
		rs[i], rs[len(rs) - 1 - i] = rs[len(rs) - 1 - i], rs[i]
	}
}

@(private)
utf8_byte_len_b :: proc(r: rune) -> int {
	switch {
	case r < 0x80:    return 1
	case r < 0x800:   return 2
	case r < 0x10000: return 3
	}
	return 4
}

@(private)
_unused_mem := mem.Allocator{}
