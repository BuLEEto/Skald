package skald

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "vendor:sdl3"

// App is the elm-style application record. An application is four things:
// a small piece of state, a message union describing every event the app
// can respond to, an `update` that advances state in response to a
// message, and a `view` that turns the current state into a declarative
// View tree. `run` wires them together inside a window + render loop.
//
// State and Msg are compile-time type parameters (`$State, $Msg`) so the
// framework stays strongly typed end-to-end — the `update` proc sees the
// app's real message union, not a rawptr or an interface.
App :: struct($State, $Msg: typeid) {
	title:  string,
	size:   Size,
	theme:  Theme,
	// labels are the framework-supplied user-visible strings (search
	// placeholder, picker placeholders, month / weekday names, AM/PM).
	// Zero-value falls back to `labels_en()` at startup, so existing
	// apps behave identically to pre-i18n builds. Apps shipping other
	// locales call `labels_en()` as a seed and override the fields
	// they need. See `skald/labels.odin`.
	labels: Labels,

	// init returns the app's starting state. Called once, before the
	// window opens — don't rely on any renderer or input subsystem.
	init:   proc() -> State,

	// update advances `state` in response to `msg` and returns a
	// `Command(Msg)` describing any side effects the framework should
	// perform (timers, follow-up msgs, batched effects). Return `{}`
	// when no side effect is needed. Must stay synchronous and pure —
	// all time / IO work belongs in the returned Command.
	update: proc(state: State, msg: Msg) -> (State, Command(Msg)),

	// view turns the current state into a declarative View tree. Pure
	// in the same sense as update: read state, read ctx.input, emit
	// widgets and Msgs; do not mutate state or talk to the outside
	// world.
	view:   proc(state: State, ctx: ^Ctx(Msg)) -> View,

	// on_system_theme_change fires when the OS flips its light/dark
	// preference while the app is running. Optional — leave nil to
	// ignore live theme switches. The callback receives the new value
	// and returns a Msg that lands in the regular queue; typical apps
	// pattern-match and swap `theme` inside their State. Initial
	// startup theme is chosen via `App.theme`; call `system_theme()`
	// in main to seed it.
	on_system_theme_change: proc(new_theme: System_Theme) -> Msg,

	// initial_window_state overrides `size` at launch and restores a
	// previously-persisted position. Zero value (all fields zero) means
	// "use `size` and let the WM place the window" — identical to not
	// setting it, so existing apps keep working. Typical use: deserialize
	// from disk in `main` and pass here.
	initial_window_state: Window_State,

	// on_window_state_change fires whenever the user resizes or moves
	// the window. Apps persist the new state so the next launch can
	// restore it via `initial_window_state`. Optional — leave nil to
	// ignore window geometry changes entirely. Debounced at the
	// platform layer, not per-event, so a drag produces one callback
	// on release rather than hundreds during the drag.
	on_window_state_change: proc(new_state: Window_State) -> Msg,
}

// Window_State captures everything needed to restore a window's
// on-screen footprint between launches. Apps marshal/unmarshal this
// however they persist their state (JSON, plain text, binary blob) and
// round-trip it through `App.initial_window_state` + the callback
// returned by `App.on_window_state_change`.
//
// `maximized` is a hint — when true the window opens maximized regardless
// of `size`/`pos` (those get used on the subsequent unmaximize). Leave
// every field zero to mean "first launch, let the WM decide."
Window_State :: struct {
	pos:       [2]i32, // logical pixels, top-left; {0, 0} = unset
	size:      Size,
	maximized: bool,
}

// Ctx is the per-frame context handed to `view`. It carries the theme,
// a pointer to this frame's input snapshot, and the message queue that
// widgets push into.
//
// The pointer fields are only valid for the duration of a single `view`
// call — don't stash `ctx.input` or `ctx.msgs` in persistent state. The
// queue itself is drained into `app.update` at the top of the next frame.
//
// `Ctx` is parameterized by the app's Msg type so widget builders keep
// their message factories typed: `skald.button(ctx, "Save", Msg.Save)`
// stays strongly typed end-to-end rather than routing through `any`.
Ctx :: struct($Msg: typeid) {
	theme:   ^Theme,
	labels:  ^Labels,
	input:   ^Input,
	msgs:    ^[dynamic]Msg,
	widgets: ^Widget_Store,
	// renderer is threaded through so widgets that need to measure text
	// during their builder (e.g. click-to-position a caret, compute a
	// selection highlight) can call `measure_text` without buffering the
	// request to render-time. It's nil outside of `run` — unit tests
	// constructing a Ctx by hand don't need a live GPU context.
	renderer: ^Renderer,
}

// send pushes a message onto the ctx's queue. Equivalent to
// `append(ctx.msgs, m)` but reads more clearly at widget call sites.
send :: proc(ctx: ^Ctx($Msg), m: Msg) {
	append(ctx.msgs, m)
}

// map_msg embeds a sub-component's view in the parent's tree while
// translating its Msg type. A sub-component is any `view` proc shaped
// like `proc(State, ^Ctx(Sub_Msg)) -> View` — the same shape as App.view.
// The child runs with a proxy Ctx whose msg queue is drained on return:
// every child msg is passed through `to_parent` and pushed onto the
// parent's queue so `app.update` sees them in the parent's Msg type.
//
// Widgets created inside the sub-view register with the parent's
// Widget_Store, so auto-IDs and Tab traversal behave as if the children
// were inlined directly. This is the elm/iced composition primitive —
// without it, every widget in every sub-tree would have to know the
// outer app's Msg type.
//
//     Msg :: union { Left_Counter: Counter_Msg, Right_Counter: Counter_Msg }
//
//     wrap_left  :: proc(m: Counter_Msg) -> Msg { return Msg.Left_Counter(m)  }
//     wrap_right :: proc(m: Counter_Msg) -> Msg { return Msg.Right_Counter(m) }
//
//     skald.row(
//         skald.map_msg(ctx, state.left,  counter.view, wrap_left),
//         skald.map_msg(ctx, state.right, counter.view, wrap_right),
//     )
map_msg :: proc(
	parent_ctx: ^Ctx($Parent_Msg),
	sub_state:  $Sub_State,
	sub_view:   proc(Sub_State, ^Ctx($Sub_Msg)) -> View,
	to_parent:  proc(Sub_Msg) -> Parent_Msg,
) -> View {
	sub_msgs := new([dynamic]Sub_Msg, context.temp_allocator)
	sub_msgs^ = make([dynamic]Sub_Msg, context.temp_allocator)

	sub_ctx := Ctx(Sub_Msg){
		theme    = parent_ctx.theme,
		labels   = parent_ctx.labels,
		input    = parent_ctx.input,
		msgs     = sub_msgs,
		widgets  = parent_ctx.widgets,
		renderer = parent_ctx.renderer,
	}

	v := sub_view(sub_state, &sub_ctx)

	for m in sub_msgs^ { send(parent_ctx, to_parent(m)) }
	return v
}

// run opens a window, initializes the renderer, and enters the main loop:
// drain queued messages, call `view`, render, present. The view tree is
// allocated from `context.temp_allocator`, which is reset at the end of
// every frame — so `view` implementations can allocate freely via the
// `skald.col` / `skald.row` / `skald.clip` builders without leaking.
run :: proc(app: App($State, $Msg)) {
	w, ok := window_open(app.title, app.size, app.initial_window_state)
	if !ok { return }
	defer window_close(&w)

	// Track the last state we reported via on_window_state_change so
	// we only dispatch on actual changes, not every frame the pump
	// reconfirms the current geometry.
	last_window_state := app.initial_window_state

	r: Renderer
	if !renderer_init(&r, &w) { return }
	defer renderer_destroy(&r)

	th    := app.theme
	// Seed default English labels when the caller didn't supply any.
	// `Labels{}` has all-empty strings which would render blank
	// placeholders and blank month/weekday headers.
	lbls := app.labels
	if len(lbls.month_names[0]) == 0 { lbls = labels_en() }
	state := app.init()

	msgs: [dynamic]Msg
	defer delete(msgs)

	// pending holds delayed msgs that cmd_delay queued. They get
	// released into `msgs` each frame once their deadline passes. Heap-
	// allocated because these outlive the frame arena — by definition,
	// a delay spans multiple frames.
	pending: [dynamic]Pending_Delay(Msg)
	defer delete(pending)

	widgets: Widget_Store
	widget_store_init(&widgets)
	defer widget_store_destroy(&widgets)
	r.widgets = &widgets

	// Async I/O is ticked from the same thread that owns this loop, so
	// we acquire the nbio thread-local event loop once here and release
	// at shutdown. `io` tracks every in-flight operation; its slots hold
	// stable pointers that the raw-ptr-typed nbio callbacks write into.
	if err := nbio.acquire_thread_event_loop(); err != nil { return }
	defer nbio.release_thread_event_loop()

	io: Io_State(Msg)
	io_state_init(&io, w.handle)
	defer io_state_destroy(&io)

	// Lazy-redraw state. A frame is considered dirty (needs re-render)
	// when SDL delivered any event, the window resized, pending msgs
	// from async IO / delays / init are waiting for update, or the
	// previous frame had an active text-input focus (caret blink).
	// When not dirty we skip frame_begin/frame_end entirely, which
	// saves battery/GPU on idle windows.
	//
	// `first_frame` forces the initial render so the app paints
	// something before any input arrives.
	//
	// `caret_blink_period` drives a ~500 ms re-render cadence while a
	// text field is focused, keeping the caret animating even with no
	// events arriving. A single cmd_delay-equivalent timer threaded
	// through the wait below produces the same visible effect without
	// a real msg round-trip — we just unblock the event wait.
	CARET_BLINK_PERIOD :: time.Millisecond * 500
	IDLE_WAIT_MAX      :: time.Millisecond * 100
	first_frame := true
	last_render := time.now()
	had_focus   := false
	// Set true when the previous iteration's update loop ran any msg.
	// State may have changed without any input event to trigger the next
	// render, so we force a render this iteration to paint the new state.
	// Without this, an input event renders with the *old* state (the
	// view → render → update pipeline is one step ahead of itself), and
	// the user only sees the new state the next time something else
	// triggers a redraw — e.g. wheel-zoom only catching up on mouse-move.
	state_may_have_changed := false

	// Benchmark mode: env `SKALD_BENCH_FRAMES=N` makes the loop exit
	// after rendering N frames and prints a one-line stats summary to
	// stdout. Useful for perf CI and for the published-benchmarks doc.
	// Zero when unset → normal operation, no overhead.
	bench_frames_target := _bench_frames_from_env()
	bench_frames_seen   := 0
	bench_times         := make([dynamic]f64, 0,
		bench_frames_target if bench_frames_target > 0 else 0)
	defer delete(bench_times)
	bench_rss_start_kb  := _bench_rss_kb()

	for !w.should_close {
		window_pump(&w)
		if w.resized { renderer_resize(&r, &w) }
		if w.system_theme_changed && app.on_system_theme_change != nil {
			append(&msgs, app.on_system_theme_change(system_theme()))
		}

		// Window geometry change notification. Fired only when the
		// current state actually differs from the last-reported one,
		// so a noisy resize drag produces a steady trickle rather
		// than a deluge. Apps typically use this to persist geometry
		// for the next launch.
		if app.on_window_state_change != nil {
			cur := window_current_state(&w)
			if cur != last_window_state {
				append(&msgs, app.on_window_state_change(cur))
				last_window_state = cur
			}
		}

		// Release any delayed msgs whose deadline has passed. Done
		// before view so time-driven state changes show up alongside
		// input-driven ones in this frame's update pass.
		pre_delay_len := len(msgs)
		drain_due_delays(&pending, &msgs)
		delay_fired := len(msgs) > pre_delay_len

		// Tick the async event loop with a zero timeout (non-blocking)
		// and drain any completed ops into the msg queue. Any read that
		// finishes mid-frame will be seen by update in the same frame —
		// same contract as `drain_due_delays`.
		pre_io_len := len(msgs)
		nbio.tick(0)
		drain_io(&io, &msgs)
		io_fired := len(msgs) > pre_io_len

		caret_blink_due := had_focus &&
			time.since(last_render) >= CARET_BLINK_PERIOD

		widget_deadline_due := widgets.next_frame_deadline_ns != 0 &&
			time.now()._nsec >= widgets.next_frame_deadline_ns

		dirty := first_frame || w.had_events || w.resized ||
			w.system_theme_changed || delay_fired || io_fired ||
			len(msgs) > 0 || caret_blink_due || widget_deadline_due ||
			state_may_have_changed ||
			bench_frames_target > 0  // bench mode forces every frame

		if !dirty {
			// No state change this frame — skip the expensive render +
			// update pipeline. Block on SDL's event queue (up to
			// IDLE_WAIT_MAX or until the next pending delay deadline
			// fires, whichever is sooner) so we don't spin. Passing a
			// nil event pointer leaves any arriving event in the queue
			// for the next window_pump.
			wait_ms := i32(IDLE_WAIT_MAX / time.Millisecond)
			if had_focus {
				blink_rem := CARET_BLINK_PERIOD - time.since(last_render)
				ms := i32(blink_rem / time.Millisecond)
				if ms > 0 && ms < wait_ms { wait_ms = ms }
			}
			now_ns := time.now()._nsec
			for pd in pending {
				rem_ns := pd.fire_at_ns - now_ns
				if rem_ns <= 0 { wait_ms = 0; break }
				ms := i32(rem_ns / i64(time.Millisecond))
				if ms < wait_ms { wait_ms = ms }
			}
			// Widget-driven animation deadlines (tooltip delay, toast
			// auto-dismiss, indeterminate progress tick) set during the
			// last render via widget_request_frame_at. frame_reset clears
			// this on the next live frame, so a stale deadline only
			// survives across idle frames — which is exactly what we want.
			if widgets.next_frame_deadline_ns != 0 {
				rem_ns := widgets.next_frame_deadline_ns - now_ns
				if rem_ns <= 0 {
					wait_ms = 0
				} else {
					ms := i32(rem_ns / i64(time.Millisecond))
					if ms < wait_ms { wait_ms = ms }
				}
			}
			if wait_ms > 0 { _ = sdl3.WaitEventTimeout(nil, wait_ms) }
			free_all(context.temp_allocator)
			continue
		}

		// Capture last frame's modal rect before frame_reset wipes it
		// so both the focus-trap filter (inside widget_advance_focus)
		// and the backdrop-click preprocessor (below, post-reset) can
		// read the same source of truth.
		modal_rect_prev := widgets.modal_rect

		// Tab / Shift-Tab is the one input the framework intercepts
		// before widgets see it. The previous frame's focusables list
		// is still live (widget_store_frame_reset clears it below), so
		// we can cycle focus now; the widget that gains focus will see
		// any subsequent keystrokes in the same frame via its builder.
		if .Tab in w.input.keys_pressed {
			widget_advance_focus(&widgets, .Shift in w.input.modifiers)
		}

		// F12 toggles the debug inspector overlay. In release builds
		// (ODIN_DEBUG off) the whole gating proc compiles to nothing,
		// so users can't trip it by pressing F12 on a shipped app.
		when ODIN_DEBUG {
			inspector_handle_toggle(&widgets, &w.input, w.input.mouse_pos)
		}

		widget_store_frame_reset(&widgets)

		// Modal dialog interception. A left-press outside the card is
		// swallowed — `mouse_pressed[.Left]` and `mouse_released[.Left]`
		// are zeroed so nothing underneath the scrim fires. The click
		// does *not* dismiss the dialog: accidental backdrop clicks
		// losing typed input is worse than requiring an explicit Cancel
		// or Escape. Matches macOS/GNOME sheet behavior. Buttons already
		// held aren't touched — only the edge event is swallowed.
		if modal_rect_prev.w > 0 && modal_rect_prev.h > 0 {
			if w.input.mouse_pressed[.Left] &&
			   !rect_contains_point(modal_rect_prev, w.input.mouse_pos) {
				w.input.mouse_pressed[.Left]  = false
				w.input.mouse_released[.Left] = false
			}
		}

		// Frame pipeline (order matters):
		//   1. view    — builds the tree, hit-tests, pushes Msgs. Strings
		//                inside Msgs are allocated from the frame arena.
		//   2. render  — draws the tree that view just produced.
		//   3. update  — drains the Msgs into `state`, running in a loop
		//                so cmd_now cascades resolve in the same frame.
		//                Commands returned from update schedule further
		//                msgs (onto the frame queue for `.Now`, onto
		//                `pending` for `.Delay`).
		//   4. free_all temp — arena reset after update has consumed
		//                everything that pointed into it.
		//
		// The visible effect is one frame of lag between a *view* msg
		// and the resulting state change — a button click updates state
		// for the *next* frame's view call. cmd_now msgs cascade within
		// a single frame so e.g. Save → Close_Dialog both land before
		// the next render.
		if frame_begin(&r, &w, th.color.bg) {
			ctx := Ctx(Msg){
				theme    = &th,
				labels   = &lbls,
				input    = &w.input,
				msgs     = &msgs,
				widgets  = &widgets,
				renderer = &r,
			}
			v := app.view(state, &ctx)
			win_size := [2]f32{f32(w.size_logical.x), f32(w.size_logical.y)}
			render_view(&r, v, {0, 0}, win_size)
			// Overlays (dropdowns, tooltips, menus) drew nothing during
			// the main pass — they only queued themselves. Drain the
			// queue now so they sit on top in draw order.
			render_overlays(&r)
			// Debug inspector paints last so it floats over every app
			// surface. No-op in release builds — the whole proc is gated
			// behind `when ODIN_DEBUG`.
			when ODIN_DEBUG {
				// Sample wall-clock render gap for the FPS readout.
				// `last_render` still holds last frame's end timestamp;
				// the first frame reads 0 and is filtered out by the
				// smoothing proc.
				dt_ms := f32(time.duration_milliseconds(time.since(last_render)))
				inspector_push_frame_time(&widgets, dt_ms)
				inspector_render(&r, &widgets, &w.input)
			}
			frame_end(&r)

			// Bench sampling happens after frame_end so the time covers
			// the full view → render → present path.
			if bench_frames_target > 0 {
				frame_ms := time.duration_milliseconds(time.since(last_render))
				if !first_frame {
					append(&bench_times, f64(frame_ms))
				}
				bench_frames_seen += 1
				if bench_frames_seen >= bench_frames_target {
					_bench_emit_summary(
						bench_times[:],
						bench_rss_start_kb,
						_bench_rss_kb(),
					)
					w.should_close = true
				}
			}

			last_render = time.now()
			first_frame = false
		}

		// Toggle SDL3's text-input mode based on what this frame's view
		// claimed. Doing it after view (not on a KeyDown) means IME state
		// exactly matches whatever the app currently renders, including
		// when focus moves programmatically or a field unmounts.
		window_set_text_input(&w, widgets.wants_text_input)
		had_focus = widgets.wants_text_input

		// Drain msgs through update, looping until the queue is empty
		// so `.Now` commands fold back into this frame. Commands other
		// than `.Now` (delays, batches containing delays) enqueue onto
		// `pending` for later frames. A snapshot copy of `msgs` keeps
		// the iteration stable while update's returned commands may
		// append to `msgs` in the same pass.
		//
		// Clear state_may_have_changed before the loop: we rendered with
		// the pre-update state above, which is what the previous iteration
		// had asked us to paint. If update runs any msg below, set the
		// flag again so the next iteration paints the post-update state.
		state_may_have_changed = false
		for len(msgs) > 0 {
			state_may_have_changed = true
			frame_msgs := make([dynamic]Msg, context.temp_allocator)
			for msg in msgs { append(&frame_msgs, msg) }
			clear(&msgs)
			for msg in frame_msgs {
				new_state, cmd := app.update(state, msg)
				state = new_state
				process_command(cmd, &msgs, &pending, &io)
			}
		}

		free_all(context.temp_allocator)
	}
}

// _bench_frames_from_env reads `SKALD_BENCH_FRAMES=N` and returns N,
// or 0 when unset / unparsable. 0 means "normal mode, no bench
// instrumentation" everywhere else.
@(private)
_bench_frames_from_env :: proc() -> int {
	s := os.get_env("SKALD_BENCH_FRAMES", context.temp_allocator)
	if len(s) == 0 { return 0 }
	n, ok := strconv.parse_int(s)
	if !ok || n < 0 { return 0 }
	return n
}

// _bench_rss_kb returns the process' resident set size in KB, or -1
// when unavailable. Linux only (reads /proc/self/statm); other OSes
// are best-effort — a future revision can plumb platform-specific
// calls in.
@(private)
_bench_rss_kb :: proc() -> i64 {
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
		if err != nil { return -1 }
		s := string(data)
		sp := strings.index_byte(s, ' ')
		if sp < 0 || sp+1 >= len(s) { return -1 }
		rest := s[sp+1:]
		sp2 := strings.index_byte(rest, ' ')
		if sp2 < 0 { return -1 }
		pages, pok := strconv.parse_i64(rest[:sp2])
		if !pok { return -1 }
		return pages * 4 // assume 4 KB pages — true on every Linux we target
	} else {
		return -1
	}
}

// _bench_emit_summary prints a single `SKALD_BENCH_STATS` line to
// stdout summarising the collected timings, formatted as key=value
// for easy grep + paste. One line so bench driver scripts can pipe
// this into a results file without parsing multi-line blocks.
@(private)
_bench_emit_summary :: proc(times_ms: []f64, rss_start_kb, rss_end_kb: i64) {
	if len(times_ms) == 0 {
		fmt.println("SKALD_BENCH_STATS frames=0")
		return
	}

	sorted := make([]f64, len(times_ms), context.temp_allocator)
	copy(sorted, times_ms)
	slice.sort(sorted)

	sum: f64 = 0
	for v in sorted { sum += v }
	avg := sum / f64(len(sorted))

	pct :: proc(s: []f64, p: f64) -> f64 {
		idx := int(p * f64(len(s)))
		if idx >= len(s) { idx = len(s) - 1 }
		return s[idx]
	}

	fmt.printfln(
		"SKALD_BENCH_STATS frames=%d avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f min_ms=%.3f max_ms=%.3f fps=%.1f rss_start_kb=%d rss_end_kb=%d rss_growth_kb=%d",
		len(times_ms),
		avg,
		pct(sorted, 0.50),
		pct(sorted, 0.95),
		pct(sorted, 0.99),
		sorted[0],
		sorted[len(sorted)-1],
		1000.0 / avg,
		rss_start_kb,
		rss_end_kb,
		rss_end_kb - rss_start_kb,
	)
}
