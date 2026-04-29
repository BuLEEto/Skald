package example_threads

import "core:fmt"
import "core:strings"
import "core:time"
import "gui:skald"

// `cmd_thread` showcase: the work proc sleeps to simulate a slow
// blocking call (DB query, sync HTTP, big-file parse), runs on a
// background thread, and posts its result back as a Msg. The UI stays
// fully interactive — the spinner keeps spinning, the click counter
// keeps incrementing, the queued-jobs label updates live as workers
// complete.
//
// Two flavours demonstrated:
//   * cmd_thread_simple — no params; recompute a static dataset.
//   * cmd_thread        — typed by-value payload; snapshot of the
//                         current input is copied into the worker so
//                         it never aliases live state.

State :: struct {
	clicks:        int,            // bumped on every Counter button click —
	                                // proves the UI isn't blocked
	jobs_in_flight: int,
	last_count:    int,
	last_query:    string,         // heap-owned, replaced on completion
	last_err:      string,         // heap-owned
	search_draft:  string,         // heap-owned
	job_seq:       int,            // monotonically-increasing tag, so a
	                                // late-arriving stale result doesn't
	                                // overwrite a newer one
}

Msg :: union {
	Click,
	Run_Slow_Count,
	Run_Search,
	Search_Draft_Changed,
	Count_Done,
	Search_Done,
}

Click                :: struct{}
Run_Slow_Count       :: struct{}
Run_Search           :: struct{}
Search_Draft_Changed :: distinct string
Count_Done :: struct {
	job_id: int,
	value:  int,
}
Search_Done :: struct {
	job_id:  int,
	summary: string,
	err:     string,
}

init :: proc() -> State {
	return State{
		last_query   = strings.clone(""),
		last_err     = strings.clone(""),
		search_draft = strings.clone(""),
	}
}

// slow_count is the simple worker: no params, returns a Msg.
//
// Sleeps for 3 seconds so a human watcher has a clear window to confirm
// the spinner keeps spinning and the click counter keeps rising — both
// would freeze instantly if the main thread were blocked.
slow_count :: proc() -> Msg {
	time.sleep(3 * time.Second)
	total := 0
	for i in 1..=10_000_000 { total += i }
	return Count_Done{value = total}
}

// Search_Params is the typed snapshot the payload-bearing variant uses.
// `term` is heap-owned at dispatch time so the worker doesn't read live
// app state. The cookbook page on cmd_thread reinforces this rule.
Search_Params :: struct {
	job_id: int,
	term:   string,
}

run_search :: proc(p: Search_Params) -> Msg {
	// Variable-latency simulation so concurrent searches arrive out of
	// order and the job_id ordering invariant gets exercised.
	delay := 200 + (p.job_id * 137) % 600
	time.sleep(time.Duration(delay) * time.Millisecond)
	if len(p.term) == 0 {
		return Search_Done{
			job_id = p.job_id,
			err    = strings.clone("empty search term"),
		}
	}
	summary := fmt.aprintf("[%d] hit %d rows for %q (%d ms)",
		p.job_id,
		len(p.term) * 7 + 3,
		p.term,
		delay)
	return Search_Done{job_id = p.job_id, summary = summary}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Click:
		out.clicks += 1

	case Run_Slow_Count:
		out.jobs_in_flight += 1
		return out, skald.cmd_thread_simple(Msg, slow_count)

	case Run_Search:
		out.job_seq += 1
		out.jobs_in_flight += 1
		// Snapshot the current draft into a heap-owned copy. The worker
		// reads its own private string — even if the user keeps typing
		// the search box's draft, this in-flight job sees a stable value.
		params := Search_Params{
			job_id = out.job_seq,
			term   = strings.clone(out.search_draft),
		}
		return out, skald.cmd_thread(Msg, params, run_search)

	case Search_Draft_Changed:
		delete(out.search_draft)
		out.search_draft = strings.clone(string(v))

	case Count_Done:
		out.jobs_in_flight -= 1
		out.last_count = v.value

	case Search_Done:
		out.jobs_in_flight -= 1
		// Drop stale results: only keep the highest job_id we've seen.
		// Without this, a slow search submitted earlier could overwrite
		// a newer one's results — the "race" the user notices when they
		// type fast.
		if v.job_id < out.job_seq && len(v.err) == 0 {
			delete(v.summary)
			return out, {}
		}
		delete(out.last_query)
		delete(out.last_err)
		out.last_query = v.summary
		out.last_err   = v.err
	}
	return out, {}
}

on_click          :: proc() -> Msg { return Click{} }
on_run_count      :: proc() -> Msg { return Run_Slow_Count{} }
on_run_search     :: proc() -> Msg { return Run_Search{} }
on_search_changed :: proc(v: string) -> Msg { return Search_Draft_Changed(v) }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Live counter — the click button increments this. If the UI were
	// blocked during a slow worker, you couldn't bump it. Hammer it
	// while a job is running to prove the main thread stays responsive.
	clicks_label := fmt.tprintf("Clicks: %d", s.clicks)

	// In-flight jobs counter shows the runtime tracking workers, going
	// up at dispatch and down at completion.
	flight_label := fmt.tprintf("Jobs in flight: %d", s.jobs_in_flight)

	// Spinner self-drives a 60 Hz repaint via the animation system.
	// If the main thread were blocked by a worker, this would freeze
	// mid-rotation — that's the unambiguous "UI is responsive" test.
	// It's always present so a stopped spinner means the framework
	// failed, not that the spinner just isn't being asked to spin.
	spinner_row := skald.row(
		skald.spinner(ctx, size = 28),
		skald.spacer(th.spacing.sm),
		skald.text("Spinner stays smooth ⇒ main thread isn't blocked.",
			th.color.fg_muted, th.font.size_sm),
		cross_align = .Center,
	)

	count_label := fmt.tprintf("Last count: %d", s.last_count)

	last_search_view: skald.View
	if len(s.last_err) > 0 {
		last_search_view = skald.text(
			fmt.tprintf("Search error: %s", s.last_err),
			th.color.danger, th.font.size_md)
	} else if len(s.last_query) > 0 {
		last_search_view = skald.text(s.last_query,
			th.color.fg, th.font.size_md)
	} else {
		last_search_view = skald.text("(no search yet)",
			th.color.fg_muted, th.font.size_md)
	}

	return skald.col(
		skald.text("Skald — cmd_thread", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(
			"Background workers run sync code without freezing the UI. The Click button stays responsive while jobs run.",
			th.color.fg_muted, th.font.size_md, max_width = 600),
		skald.spacer(th.spacing.md),

		spinner_row,
		skald.spacer(th.spacing.lg),

		skald.row(
			skald.button(ctx, "Click me", on_click()),
			skald.text(clicks_label, th.color.fg, th.font.size_md),
			cross_align = .Center,
			spacing     = th.spacing.md,
		),
		skald.spacer(th.spacing.lg),

		skald.text("cmd_thread_simple  (~600 ms blocking work)",
			th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.row(
			skald.button(ctx, "Run slow count", on_run_count()),
			skald.text(count_label, th.color.fg_muted, th.font.size_md),
			cross_align = .Center,
			spacing     = th.spacing.md,
		),
		skald.spacer(th.spacing.lg),

		skald.text("cmd_thread  (typed payload, variable latency)",
			th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.row(
			skald.text_input(ctx, s.search_draft, on_search_changed,
				placeholder = "search term…",
				width       = 240),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, "Search", on_run_search()),
			cross_align = .Center,
		),
		skald.spacer(th.spacing.sm),
		last_search_view,
		skald.spacer(th.spacing.lg),

		skald.text(flight_label, th.color.fg_muted, th.font.size_sm),

		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — cmd_thread",
		size   = {640, 540},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
