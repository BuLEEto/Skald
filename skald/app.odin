package skald

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "vendor:sdl3"
import vk "vendor:vulkan"

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

	// window_flags is the caller's override of the SDL window flags
	// Skald passes to `SDL_CreateWindow`. Zero value (`{}`) preserves
	// Skald's default of `{.RESIZABLE}` so existing apps keep working.
	// Any non-empty value replaces that default — Skald still ORs in
	// its two non-negotiable flags (`.VULKAN`, `.HIGH_PIXEL_DENSITY`)
	// because the renderer and DPI scaling contract both require them,
	// but every other flag is the caller's call.
	//
	// Typical uses:
	//   window_flags = {.BORDERLESS, .ALWAYS_ON_TOP}  // dock / HUD
	//   window_flags = {.TRANSPARENT, .RESIZABLE}     // overlay
	//   window_flags = {.UTILITY}                     // tool window
	window_flags: sdl3.WindowFlags,

	// on_window_open fires once after the SDL window is created and
	// before the render loop starts. The callback receives the live
	// `^Window`, whose `handle: ^sdl3.Window` is usable with any SDL3
	// API — including `sdl3.GetWindowProperties` for extracting the
	// X11 `Display*` + `Window` or the macOS `NSWindow*` when an app
	// needs to set platform properties Skald doesn't wrap (dock type,
	// struts, level, shadow, etc.). Purely additive; no Msg round-trip.
	// Optional — leave nil to skip.
	on_window_open: proc(w: ^Window),

	// on_window_focus_lost fires once when a window stops being the
	// foreground window (user clicked another app, switched workspaces,
	// Alt-Tabbed away). Fires for both primary and secondary windows,
	// passing the `Window_Id` of whichever one lost focus. Typical
	// use: auto-dismiss popovers / notifications / transient overlays
	// on click-away — return a Msg that flips your "is popover open"
	// state or fires `cmd_close_window`. Optional; nil means "ignore
	// focus changes."
	on_window_focus_lost: proc(window: Window_Id) -> Msg,
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

	// window identifies which window this view call is for. Single-window
	// apps never need to inspect it — it always equals `main_window` (the
	// id of the primary window). Multi-window apps compare against ids
	// returned from `cmd_open_window` so one `view` proc can switch on id
	// to render different subtrees in each window.
	window:   Window_Id,
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
		window   = parent_ctx.window,
	}

	v := sub_view(sub_state, &sub_ctx)

	for m in sub_msgs^ { send(parent_ctx, to_parent(m)) }
	return v
}

// drain_window_ops processes queued `cmd_open_window` / `cmd_close_window`
// requests. Called each frame after the msg-drain pass so newly-opened
// windows appear in the same frame the triggering action landed. Open
// creates the SDL window, spins up a per-window Vulkan surface +
// swapchain + sync, appends a `Window_Target` to `r.targets`, and fires
// `on_result(new_id)` onto the msg queue. Close tears down and removes.
// Closing the primary target is a no-op — use `should_close` on the
// primary's platform window instead.
@(private)
drain_window_ops :: proc(
	r:          ^Renderer,
	ops:        ^[dynamic]Window_Op($Msg),
	msgs:       ^[dynamic]Msg,
	close_reg:  ^[dynamic]Window_Close_Reg(Msg),
	open_clear: Color,
) {
	for op in ops {
		switch op.kind {
		case .Open:
			// Allocate + open the new SDL window.
			new_w := new(Window)
			w, ok := window_open(op.desc.title, op.desc.size, op.desc.initial_state, op.desc.flags)
			if !ok {
				free(new_w)
				continue
			}
			new_w^ = w
			if op.desc.on_open != nil { op.desc.on_open(new_w) }

			// New target carries its own widget store + batch. The
			// platform `^Window` is heap-allocated (unlike the primary
			// target's, which points at `run`'s stack local) so flag
			// it owned so `renderer_destroy` and
			// `drain_window_ops`.Close can free it correctly.
			target := new(Window_Target)
			target.platform       = new_w
			target.platform_owned = true
			target.widgets        = new(Widget_Store)
			widget_store_init(target.widgets)

			// Vulkan surface for the new window, then swapchain + sync
			// through the existing `cur`-driven initializers.
			prev := r.cur
			r.cur = target
			target.window = new_w.handle
			if !sdl3.Vulkan_CreateSurface(new_w.handle, r.instance, nil, &target.surface) {
				fmt.eprintfln("skald: Vulkan_CreateSurface (secondary): %s", sdl3.GetError())
				// Unwind.
				widget_store_destroy(target.widgets)
				free(target.widgets)
				free(target)
				window_destroy(new_w)
				free(new_w)
				r.cur = prev
				continue
			}
			if !vk_create_swapchain(r, new_w) ||
			   !vk_create_commands_and_sync(r) ||
			   !vk_create_render_finished_semaphores(r) ||
			   !target_vk_init(r, target, &r.pipeline, &r.text) {
				// Best-effort unwind — walk back through everything
				// that might have partially succeeded. Each vk_destroy_*
				// is defensive against zero handles so it's safe even
				// when the failing step was the first one.
				target_vk_destroy(r, target, &r.pipeline)
				vk_destroy_render_finished_semaphores(r)
				vk_destroy_commands_and_sync(r)
				vk_destroy_swapchain(r)
				sdl3.Vulkan_DestroySurface(r.instance, target.surface, nil)
				widget_store_destroy(target.widgets)
				free(target.widgets)
				free(target)
				window_destroy(new_w)
				free(new_w)
				r.cur = prev
				continue
			}

			append(&r.targets, target)

			// First-frame flicker fix. A freshly-created Vulkan
			// swapchain has undefined contents — on X11 with a
			// compositor, those undefined pixels sample from whatever
			// was last in that GPU memory and flash on screen for a
			// frame or two before the app's real view paints over
			// them. Running a clear-and-present pass right now means
			// the compositor's first sample is the app's background
			// colour, not leftovers from the previous tenant.
			//
			// frame_begin + frame_end with an empty batch is exactly
			// the "paint nothing, present" sequence we need — the
			// renderer's clear-on-load plus its end-of-frame
			// transition-to-PRESENT_SRC do the work.
			r.cur = target
			if frame_begin(r, target.platform, open_clear) {
				frame_end(r)
			}

			r.cur = prev

			// Hand the new id back to the app via the on_result callback,
			// and register the on_close callback so X-close and programmatic
			// close both dispatch it on teardown.
			id := Window_Id(target)
			if op.on_result != nil {
				append(msgs, op.on_result(id))
			}
			if op.on_close != nil {
				append(close_reg, Window_Close_Reg(Msg){id = id, on_close = op.on_close})
			}

		case .Close:
			if len(r.targets) == 0 { continue }
			primary := r.targets[0]
			// Can't close the primary — app uses its window's X button
			// or should_close for that.
			if Window_Id(primary) == op.id { continue }

			// Find the target by id (pointer equality).
			idx := -1
			for t, i in r.targets {
				if Window_Id(t) == op.id { idx = i; break }
			}
			if idx < 0 { continue }

			target := r.targets[idx]
			dispatch_window_close(close_reg, msgs, Window_Id(target))

			// Serialize with any in-flight GPU work tied to this surface.
			if r.device != nil { vk.DeviceWaitIdle(r.device) }

			prev := r.cur
			r.cur = target
			target_vk_destroy(r, target, &r.pipeline)
			batch_destroy(&target.batch)
			vk_destroy_commands_and_sync(r)
			vk_destroy_swapchain(r)
			if target.surface != 0 && r.instance != nil {
				sdl3.Vulkan_DestroySurface(r.instance, target.surface, nil)
			}
			if target.widgets != nil {
				widget_store_destroy(target.widgets)
				free(target.widgets)
			}
			if target.platform != nil {
				// window_destroy, not window_close — we're closing a
				// secondary mid-run; SDL itself stays alive.
				window_destroy(target.platform)
				free(target.platform)
			}
			free(target)
			r.cur = prev if prev != target else primary

			ordered_remove(&r.targets, idx)
		}
	}
	clear(ops)
}

// dispatch_window_close fires + unregisters the on_close callback for
// a window that's about to be torn down. Called by both the drain_window_ops
// close path and the secondary-X-close auto-teardown in the run loop,
// so either path reaches app code identically.
@(private)
dispatch_window_close :: proc(
	close_reg: ^[dynamic]Window_Close_Reg($Msg),
	msgs:      ^[dynamic]Msg,
	id:        Window_Id,
) {
	for r, i in close_reg {
		if r.id == id {
			if r.on_close != nil {
				append(msgs, r.on_close(id))
			}
			ordered_remove(close_reg, i)
			return
		}
	}
}

// run opens a window, initializes the renderer, and enters the main loop:
// drain queued messages, call `view`, render, present. The view tree is
// allocated from `context.temp_allocator`, which is reset at the end of
// every frame — so `view` implementations can allocate freely via the
// `skald.col` / `skald.row` / `skald.clip` builders without leaking.
run :: proc(app: App($State, $Msg)) {
	w, ok := window_open(app.title, app.size, app.initial_window_state, app.window_flags)
	if !ok { return }
	defer window_close(&w)

	// Post-create native-tweaks hook. Fires once, before any render work,
	// so apps can set X11 window types, macOS window levels, etc. without
	// forking Skald. The callback sees the live `^Window` and can
	// extract the underlying `^sdl3.Window` via `w.handle`.
	if app.on_window_open != nil { app.on_window_open(&w) }

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

	// windows_pending accumulates cmd_open_window / cmd_close_window
	// requests from update. Drained after each msg-drain pass, before
	// the next render, so newly-opened windows render in the same
	// frame the triggering action was processed in.
	windows_pending: [dynamic]Window_Op(Msg)
	defer delete(windows_pending)

	// close_reg tracks `on_close` callbacks registered at open time.
	// The user hitting a window's X button and an app-issued
	// cmd_close_window both go through the same dispatch path — if
	// there's a registration for the closing window, we fire its Msg
	// just before teardown, so state that holds the Window_Id can
	// clear itself.
	close_reg: [dynamic]Window_Close_Reg(Msg)
	defer delete(close_reg)

	// The primary target's Widget_Store was heap-allocated inside
	// renderer_init. Alias it here so the rest of run() reads naturally.
	// Secondary windows (multi-window apps) get their own stores via
	// cmd_open_window.
	widgets := r.targets[0].widgets

	// Async I/O is ticked from the same thread that owns this loop, so
	// we acquire the nbio thread-local event loop once here and release
	// at shutdown. `io` tracks every in-flight operation; its slots hold
	// stable pointers that the raw-ptr-typed nbio callbacks write into.
	if err := nbio.acquire_thread_event_loop(); err != nil { return }
	defer nbio.release_thread_event_loop()

	io: Io_State(Msg)
	io_state_init(&io, w.handle)
	defer io_state_destroy(&io)

	// Worker-thread mailbox. `cmd_thread` work runs on background
	// threads and posts results here; the run loop drains it at the
	// top of each frame. Defer waits for outstanding workers at
	// shutdown so their writes don't land in freed memory.
	tpool: Thread_Pool(Msg)
	thread_pool_init(&tpool)
	defer thread_pool_destroy(&tpool)

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
		// Multi-window event pump: collect every open target's platform
		// window into a temp slice, reset each one's per-frame edges,
		// then let the dispatcher route SDL events by windowID. With
		// only the primary open it's identical to `window_pump(&w)`.
		plats := make([dynamic]^Window, 0, len(r.targets), context.temp_allocator)
		for t in r.targets { append(&plats, t.platform) }
		windows_pump(plats[:])

		// Focus-lost dispatch. Fires once per target whose window
		// stopped being foreground this frame. Apps use this to
		// auto-dismiss popovers / notifications on click-away —
		// typically by returning a Msg that flips State or issues
		// `cmd_close_window`.
		if app.on_window_focus_lost != nil {
			for t in r.targets {
				if t.platform != nil && t.platform.focus_lost {
					append(&msgs, app.on_window_focus_lost(Window_Id(t)))
				}
			}
		}

		// Secondary windows closed via their native X button set their
		// own `platform.should_close`. Tear them down immediately so
		// the render loop doesn't paint into a dead swapchain. Primary's
		// close drives app exit via the outer `for !w.should_close`
		// below — not touched here.
		{
			i := 1
			for i < len(r.targets) {
				t := r.targets[i]
				if t.platform != nil && t.platform.should_close {
					// Fire the app's on_close callback before teardown
					// so its Msg handler can clear any Window_Id stashed
					// in State — can't do it after, since the id (a
					// pointer to the freed target) would be dangling.
					dispatch_window_close(&close_reg, &msgs, Window_Id(t))

					if r.device != nil { vk.DeviceWaitIdle(r.device) }
					prev := r.cur
					r.cur = t
					target_vk_destroy(&r, t, &r.pipeline)
					batch_destroy(&t.batch)
					vk_destroy_commands_and_sync(&r)
					vk_destroy_swapchain(&r)
					if t.surface != 0 && r.instance != nil {
						sdl3.Vulkan_DestroySurface(r.instance, t.surface, nil)
					}
					if t.widgets != nil {
						widget_store_destroy(t.widgets)
						free(t.widgets)
					}
					if t.platform != nil {
						window_destroy(t.platform)
						free(t.platform)
					}
					free(t)
					r.cur = prev if prev != t else r.targets[0]
					ordered_remove(&r.targets, i)
					continue
				}
				i += 1
			}
		}

		// Resize handling runs per-target so a secondary window that
		// gets resized (rare but legal for non-borderless popovers)
		// rebuilds its own swapchain, not the primary's.
		for t in r.targets {
			if t.platform.resized {
				r.cur = t
				renderer_resize(&r, t.platform)
			}
		}
		r.cur = r.targets[0]

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

		// Drain any worker-thread results posted via `cmd_thread`. Same
		// frame contract as the io drain — if a worker finished before
		// this tick its Msg is delivered to update right now.
		thread_fired := thread_pool_drain(&tpool, &msgs)

		caret_blink_due := had_focus &&
			time.since(last_render) >= CARET_BLINK_PERIOD

		// Multi-window: any target that's dirty forces a re-render of the
		// whole frame. Any individual window having pending deadlines,
		// events, or a resize this frame means we paint at least once —
		// the per-target render loop then re-paints every window so their
		// view trees stay fresh.
		any_events, any_resized, any_widget_deadline := false, false, false
		now_ns := time.now()._nsec
		for t in r.targets {
			if t.platform.had_events { any_events = true }
			if t.platform.resized    { any_resized = true }
			if t.widgets.next_frame_deadline_ns != 0 &&
			   now_ns >= t.widgets.next_frame_deadline_ns {
				any_widget_deadline = true
			}
		}

		dirty := first_frame || any_events || any_resized ||
			w.system_theme_changed || delay_fired || io_fired ||
			thread_fired ||
			len(msgs) > 0 || caret_blink_due || any_widget_deadline ||
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

		// Per-target render pass. Single-window apps iterate once (the
		// primary target). Multi-window apps iterate every open target —
		// each has its own platform window (so its own input + geometry),
		// its own Widget_Store (so focus + modal scope don't leak across
		// windows), its own vertex/index buffers and descriptor set (so
		// two targets submitting in the same frame can't race), and
		// runs its own frame_begin / view / frame_end against its own
		// swapchain. fb_size travels via push constants, so every draw
		// carries the current window's dimensions without touching
		// shared state. No DeviceWaitIdle between targets.
		had_focus = false
		primary := r.targets[0]
		for t in r.targets {
			r.cur = t
			t_widgets := t.widgets
			t_w       := t.platform

			// Capture last frame's modal rect before frame_reset wipes it
			// so both the focus-trap filter (inside widget_advance_focus)
			// and the backdrop-click preprocessor (below, post-reset) can
			// read the same source of truth.
			modal_rect_prev := t_widgets.modal_rect

			// Tab / Shift-Tab is the one input the framework intercepts
			// before widgets see it. The previous frame's focusables list
			// is still live (widget_store_frame_reset clears it below), so
			// we can cycle focus now; the widget that gains focus will see
			// any subsequent keystrokes in the same frame via its builder.
			if .Tab in t_w.input.keys_pressed {
				widget_advance_focus(t_widgets, .Shift in t_w.input.modifiers)
			}

			// F12 toggles the debug inspector overlay. In release builds
			// (ODIN_DEBUG off) the whole gating proc compiles to nothing,
			// so users can't trip it by pressing F12 on a shipped app.
			when ODIN_DEBUG {
				inspector_handle_toggle(t_widgets, &t_w.input, t_w.input.mouse_pos)
			}

			widget_store_frame_reset(t_widgets)

			// Modal dialog interception. A left-press outside the card is
			// swallowed — `mouse_pressed[.Left]` and `mouse_released[.Left]`
			// are zeroed so nothing underneath the scrim fires. The click
			// does *not* dismiss the dialog: accidental backdrop clicks
			// losing typed input is worse than requiring an explicit Cancel
			// or Escape. Matches macOS/GNOME sheet behavior. Buttons already
			// held aren't touched — only the edge event is swallowed.
			if modal_rect_prev.w > 0 && modal_rect_prev.h > 0 {
				mp := t_w.input.mouse_pos
				if t_w.input.mouse_pressed[.Left] &&
				   !rect_contains_point(modal_rect_prev, mp) {
					// Popovers anchored inside the dialog (color_picker's
					// HSV grid, select dropdown, etc.) can spill outside
					// the card. Their cards stamp into overlay_rects_prev,
					// so a click inside any of them still belongs to the
					// dialog's content layer and must pass through.
					over_popover := false
					for rr in t_widgets.overlay_rects_prev {
						if rect_contains_point(rr, mp) { over_popover = true; break }
					}
					if !over_popover {
						t_w.input.mouse_pressed[.Left]  = false
						t_w.input.mouse_released[.Left] = false
					}
				}
			}

			// Frame pipeline (order matters):
			//   1. view    — builds the tree, hit-tests, pushes Msgs. Strings
			//                inside Msgs are allocated from the frame arena.
			//   2. render  — draws the tree that view just produced.
			//   3. update  — (outside the target loop) drains the Msgs into
			//                `state`.
			//   4. free_all temp — (outside the target loop) arena reset.
			//
			// The visible effect is one frame of lag between a *view* msg
			// and the resulting state change — a button click updates state
			// for the *next* frame's view call.
			if frame_begin(&r, t_w, th.color.bg) {
				ctx := Ctx(Msg){
					theme    = &th,
					labels   = &lbls,
					input    = &t_w.input,
					msgs     = &msgs,
					widgets  = t_widgets,
					renderer = &r,
					window   = Window_Id(t),
				}
				v := app.view(state, &ctx)
				win_size := [2]f32{f32(t_w.size_logical.x), f32(t_w.size_logical.y)}
				render_view(&r, v, {0, 0}, win_size)
				// Overlays (dropdowns, tooltips, menus) drew nothing during
				// the main pass — they only queued themselves. Drain the
				// queue now so they sit on top in draw order.
				render_overlays(&r)
				// Debug inspector paints on the primary window only — the
				// FPS / RSS readout is app-level info, not per-window, and
				// multiplying it across every popover would be noise.
				when ODIN_DEBUG {
					if t == primary {
						dt_ms := f32(time.duration_milliseconds(time.since(last_render)))
						inspector_push_frame_time(t_widgets, dt_ms)
						inspector_render(&r, t_widgets, &t_w.input)
					}
				}
				frame_end(&r)
			}

			// Text input mode is per-window: SDL3 tracks it on the window
			// handle, so each target sets its own based on what this
			// frame's view asked for.
			window_set_text_input(t_w, t_widgets.wants_text_input)
			had_focus = had_focus || t_widgets.wants_text_input
		}

		// Bench sampling + last_render live outside the per-target loop
		// so we count one frame per iteration of the outer loop rather
		// than one per window — the benchmark is measuring frame cadence,
		// not render invocations.
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
				process_command(cmd, &msgs, &pending, &io, &windows_pending, &tpool)
			}
			// Drain window-op requests between each msg batch so a follow-up
			// `cmd_now` that reacts to a newly-opened window's id lands in
			// the same frame. Also ensures the on_result msg from an Open
			// is immediately available to the next iteration of this loop.
			if len(windows_pending) > 0 {
				drain_window_ops(&r, &windows_pending, &msgs, &close_reg, th.color.bg)
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
