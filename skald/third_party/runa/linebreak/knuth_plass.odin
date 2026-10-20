package linebreak

// Total-fit line breaking (Knuth & Plass, "Breaking Paragraphs into Lines",
// 1981): choose every break in a paragraph together to minimise how loose or
// tight the lines are, instead of filling one line at a time. The paragraph
// is a stream of items — boxes (unbreakable material), glue (stretchable
// space) and penalties (candidate breaks) — and `break_lines` returns the
// optimal set of breakpoints with each line's adjustment ratio.
//
// The caller measures text into items (words shaped once, their advances
// summed into box widths); this package doesn't shape or know about fonts. A
// soft hyphen is a flagged penalty whose width is the hyphen that appears
// only if the line breaks there. Line widths are per-line, so a first-line
// indent, the lines beside a drop cap, or a hanging marker all fit.

import "core:mem"

Item_Kind :: enum u8 { Box, Glue, Penalty }

// Item is one element of the paragraph stream. For a Box, only `width` is
// used; for Glue, `width`/`stretch`/`shrink`; for Penalty, `penalty`/`width`
// (the material drawn if broken here, e.g. a hyphen) and `flagged`.
Item :: struct {
	kind:    Item_Kind,
	width:   f32,
	stretch: f32,
	shrink:  f32,
	penalty: f32,
	flagged: bool,
}

// A break at a penalty this negative is forced; one this positive is
// forbidden. (Finite values in between are ordinary costs.)
PENALTY_FORCED  :: f32(-1e9)
PENALTY_INHIBIT :: f32( 1e9)

box     :: proc(width: f32) -> Item { return {kind = .Box, width = width} }
glue    :: proc(width, stretch, shrink: f32) -> Item { return {kind = .Glue, width = width, stretch = stretch, shrink = shrink} }
penalty :: proc(p: f32, width: f32 = 0, flagged := false) -> Item { return {kind = .Penalty, penalty = p, width = width, flagged = flagged} }

// Break_Params tunes the optimisation. Zero values get sensible defaults
// (see `break_defaults`), so `{}` is a reasonable justified setting.
// For the four demerit fields a zero means "use the default" and a negative
// means "disable" (so {} is a sensible justified setting, and a demerit can
// still be switched off deliberately). They are strong nudges, not absolute
// rules — a catastrophically bad alternative can still outweigh one.
Break_Params :: struct {
	tolerance:       f32,  // max |adjustment ratio| a line may have (looser = more candidates). <=0 → 2
	line_penalty:    f32,  // demerits added per line, discouraging extra lines. 0 → 10, <0 off
	flagged_demerits: f32, // demerits when two lines in a row end at a flagged (hyphen) break. 0 → 3000, <0 off
	fitness_demerits: f32, // demerits when adjacent lines differ by >1 fitness class. 0 → 3000, <0 off
	final_hyphen_demerits: f32, // demerits for hyphenating the last full line. 0 → 1e6, <0 off (5000 is too weak to matter)
	max_consecutive_hyphens: int, // hard cap on hyphenated lines in a row (0 → no cap)
	ragged:          bool, // ragged-right: even the lines by cost but don't spread them (ratio reported 0)
}

// Break is one line's result: the item index it breaks at, the adjustment
// ratio its spaces take (0 in ragged mode), and whether it ends at a flagged
// (hyphen) break so the caller draws the hyphen.
Break :: struct {
	item:    int,
	ratio:   f32,
	flagged: bool,
}

// break_defaults fills the zero-valued fields of `p` with sensible defaults,
// so `{}` is a reasonable justified setting. For the demerit fields a zero
// means "use the default" and a negative means "disable" (clamped to 0) — so a
// caller can still switch a demerit off deliberately.
break_defaults :: proc(p: Break_Params) -> Break_Params {
	demerit :: proc(v, dflt: f32) -> f32 {
		if v == 0 { return dflt }
		return v < 0 ? 0 : v
	}
	r := p
	if r.tolerance <= 0 { r.tolerance = 2 }
	r.line_penalty          = demerit(r.line_penalty, 10)
	r.flagged_demerits      = demerit(r.flagged_demerits, 3000)
	r.fitness_demerits      = demerit(r.fitness_demerits, 3000)
	r.final_hyphen_demerits = demerit(r.final_hyphen_demerits, 1e6)
	return r
}

@(private="file")
Totals :: struct { width, stretch, shrink: f32 }

@(private="file")
Node :: struct {
	position:       int,
	line:           int,
	fitness:        int,
	totals:         Totals,   // running sums skipped past this break's trailing discardables
	demerits:       f32,
	ratio:          f32,      // ratio of the line ending at this node
	flagged:        bool,     // that line ended at a flagged break
	consec_flagged: int,      // flagged lines in a row ending here
	prev:           int,      // pool index of the previous node, -1 at the paragraph start
}

@(private="file")
kp_line_width :: proc(widths: []f32, line: int) -> f32 {
	if len(widths) == 0 { return 0 }
	return widths[min(line, len(widths) - 1)]
}

// break_lines finds the optimal breaks for `items` into lines of the given
// widths (one per line; the last repeats for any further lines). Returns one
// Break per line. `ok` is false only for empty input. If no breaking fits
// within `tolerance`, it widens the tolerance and, failing that, falls back
// to a greedy fit, so a result always comes back.
break_lines :: proc(items: []Item, line_widths: []f32, params: Break_Params, allocator := context.allocator) -> (breaks: []Break, ok: bool) {
	if len(items) == 0 || len(line_widths) == 0 { return nil, false }
	p := break_defaults(params)

	// Work on a stream that ends in a forced break so the last line is
	// resolved: a finishing glue (lets the last line stay short) then a
	// forced penalty, unless the caller already ended that way.
	work := items
	last := items[len(items) - 1]
	if last.kind != .Penalty || last.penalty > PENALTY_FORCED {
		buf := make([dynamic]Item, 0, len(items) + 2, context.temp_allocator)
		append(&buf, ..items)
		append(&buf, glue(0, 1e7, 0))
		append(&buf, penalty(PENALTY_FORCED))
		work = buf[:]
	}

	if b, got := kp_optimal(work, line_widths, p, allocator); got { return b, true }
	// Loosen once, then fall back to greedy — always return something.
	loose := p
	loose.tolerance = 1e4
	if b, got := kp_optimal(work, line_widths, loose, allocator); got { return b, true }
	return break_greedy(work, line_widths, allocator), true
}

@(private="file")
compute_sum :: proc(items: []Item, brk: int, sum: Totals) -> Totals {
	// Totals from the start through the discardables that follow a break at
	// `brk`, so the next line begins at the next box.
	r := sum
	for i := brk; i < len(items); i += 1 {
		it := items[i]
		#partial switch it.kind {
		case .Box: return r
		case .Glue: r.width += it.width; r.stretch += it.stretch; r.shrink += it.shrink
		case .Penalty:
			if it.penalty <= PENALTY_FORCED && i > brk { return r }
		}
	}
	return r
}

@(private="file")
kp_consider :: proc(items: []Item, line_widths: []f32, p: Break_Params, pool: ^[dynamic]Node, active: ^[dynamic]int, sum: Totals, index: int) {
	it := items[index]
	forced := it.kind == .Penalty && it.penalty <= PENALTY_FORCED

	Cand :: struct { node: int, demerits: f32, ratio: f32, used: bool }
	cands: [4]Cand
	for &c in cands { c.demerits = 1e30 }

	w := 0
	for w < len(active) {
		ai := active[w]
		a  := pool[ai]
		target := kp_line_width(line_widths, a.line)

		width := sum.width - a.totals.width
		if it.kind == .Penalty { width += it.width }

		ratio: f32
		if width < target {
			// Underfull. With no glue to stretch (a lone word), the line
			// can't be justified — a very loose, high-badness ratio, so the
			// optimiser takes it only as a last resort (and the loosen pass
			// still can, where a tight one can't).
			st := sum.stretch - a.totals.stretch
			ratio = st > 0 ? (target - width) / st : 1e4
		} else if width > target {
			// Overfull. With no glue to shrink, the line can't fit — a ratio
			// past -1, which deactivates the node (never set an overfull line).
			sh := sum.shrink - a.totals.shrink
			ratio = sh > 0 ? (target - width) / sh : -1e4
		}

		// Deactivate a node a line can no longer be reached from: overfull
		// (ratio < -1), or we're at a forced break (nothing survives it).
		if ratio < -1 || forced {
			ordered_remove(active, w)
		} else {
			w += 1
		}

		if ratio >= -1 && ratio <= p.tolerance {
			this_flagged := it.kind == .Penalty && it.flagged
			consec := this_flagged ? a.consec_flagged + 1 : 0
			capped := p.max_consecutive_hyphens > 0 && this_flagged && consec > p.max_consecutive_hyphens
			if !capped {
				ar := abs(ratio)
				base := p.line_penalty + 100 * ar * ar * ar
				d: f32
				if it.kind == .Penalty && it.penalty >= 0 && it.penalty < PENALTY_INHIBIT {
					d = base * base + it.penalty * it.penalty
				} else if it.kind == .Penalty && it.penalty > PENALTY_FORCED && it.penalty < 0 {
					d = base * base - it.penalty * it.penalty
				} else {
					d = base * base
				}
				if this_flagged && a.flagged { d += p.flagged_demerits }
				// Discourage a hyphen on the last full line: at the final
				// (forced) break, if the line we're joining to ended flagged.
				if forced && a.flagged { d += p.final_hyphen_demerits }

				fitness := 3
				if      ratio < -0.5 { fitness = 0 }
				else if ratio <= 0.5 { fitness = 1 }
				else if ratio <= 1.0 { fitness = 2 }
				if abs(fitness - a.fitness) > 1 { d += p.fitness_demerits }

				d += a.demerits
				if d < cands[fitness].demerits {
					cands[fitness] = Cand{node = ai, demerits = d, ratio = ratio, used = true}
				}
			}
		}
	}

	new_totals := compute_sum(items, index, sum)
	for c, fit in cands {
		if !c.used { continue }
		a := pool[c.node]
		this_flagged := it.kind == .Penalty && it.flagged
		append(pool, Node{
			position       = index,
			line           = a.line + 1,
			fitness        = fit,
			totals         = new_totals,
			demerits       = c.demerits,
			ratio          = c.ratio,
			flagged        = this_flagged,
			consec_flagged = this_flagged ? a.consec_flagged + 1 : 0,
			prev           = c.node,
		})
		append(active, len(pool) - 1)
	}
}

@(private="file")
kp_optimal :: proc(items: []Item, line_widths: []f32, p: Break_Params, allocator: mem.Allocator) -> (breaks: []Break, ok: bool) {
	pool   := make([dynamic]Node, 0, 64, context.temp_allocator)
	active := make([dynamic]int,  0, 64, context.temp_allocator)
	append(&pool, Node{position = 0, line = 0, fitness = 1, prev = -1})
	append(&active, 0)

	sum: Totals
	for i := 0; i < len(items); i += 1 {
		it := items[i]
		#partial switch it.kind {
		case .Box:
			sum.width += it.width
		case .Glue:
			if i > 0 && items[i - 1].kind == .Box {
				kp_consider(items, line_widths, p, &pool, &active, sum, i)
			}
			sum.width += it.width; sum.stretch += it.stretch; sum.shrink += it.shrink
		case .Penalty:
			if it.penalty < PENALTY_INHIBIT {
				kp_consider(items, line_widths, p, &pool, &active, sum, i)
			}
		}
	}

	if len(active) == 0 { return nil, false }

	best := active[0]
	for ai in active { if pool[ai].demerits < pool[best].demerits { best = ai } }

	tmp := make([dynamic]Break, 0, 16, context.temp_allocator)
	for n := best; n > 0; n = pool[n].prev {
		nd := pool[n]
		append(&tmp, Break{item = nd.position, ratio = p.ragged ? 0 : nd.ratio, flagged = nd.flagged})
	}
	breaks = make([]Break, len(tmp), allocator)
	for i in 0 ..< len(tmp) { breaks[i] = tmp[len(tmp) - 1 - i] }   // reverse: tmp is last-line-first
	return breaks, true
}

@(private="file")
greedy_flush :: proc(out: ^[dynamic]Break, items: []Item, line_widths: []f32, brk: int, w, st, sh: f32, line: int, flagged: bool) {
	target := kp_line_width(line_widths, line)
	width := w
	if items[brk].kind == .Penalty { width += items[brk].width }
	ratio: f32
	if      width < target { ratio = st > 0 ? (target - width) / st : 0 }
	else if width > target { ratio = sh > 0 ? (target - width) / sh : 0 }
	append(out, Break{item = brk, ratio = ratio, flagged = flagged})
}

// break_greedy fits one line at a time: break at the last glue that still fits
// (or a forced break), biased toward not overrunning. The safety net when no
// total-fit solution exists; also handy for very long paragraphs.
break_greedy :: proc(items: []Item, line_widths: []f32, allocator := context.allocator) -> []Break {
	out := make([dynamic]Break, 0, 16, allocator)
	if len(items) == 0 { return out[:] }

	line := 0
	start := 0
	last_glue := -1
	w, st, sh: f32

	i := 0
	for i < len(items) {
		it := items[i]
		target := kp_line_width(line_widths, line)
		#partial switch it.kind {
		case .Box:
			w += it.width
		case .Glue:
			if i > start && items[i - 1].kind == .Box { last_glue = i }
			w += it.width; st += it.stretch; sh += it.shrink
		case .Penalty:
			if it.penalty <= PENALTY_FORCED {
				greedy_flush(&out, items, line_widths, i, w, st, sh, line, it.flagged)
				line += 1; start = i + 1; last_glue = -1; w = 0; st = 0; sh = 0
				i += 1
				continue
			}
		}

		if w > target && last_glue > start {
			brk := last_glue
			lw, lst, lsh: f32
			for j := start; j < brk; j += 1 {
				jt := items[j]
				#partial switch jt.kind {
				case .Box: lw += jt.width
				case .Glue: lw += jt.width; lst += jt.stretch; lsh += jt.shrink
				}
			}
			greedy_flush(&out, items, line_widths, brk, lw, lst, lsh, line, false)
			line += 1; start = brk + 1; last_glue = -1; w = 0; st = 0; sh = 0
			i = brk + 1
			continue
		}
		i += 1
	}
	return out[:]
}
