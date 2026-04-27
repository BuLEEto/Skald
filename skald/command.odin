package skald

import "core:time"
import "vendor:sdl3"

// Command describes a side effect that `update` asks the framework to
// perform — scheduling a timer, dispatching a follow-up message, or
// bundling several of those together. Returning `{}` (a zero-value
// Command with `kind = .None`) is the no-effect path, and most of an
// application's `update` branches will take that path.
//
// The elm/iced convention is that `view` stays pure and `update` stays
// synchronous: neither can directly mutate the outside world. Anything
// that needs to talk to a clock, the filesystem, or a network socket is
// described by a Command and executed by the runtime. That separation
// is what makes the program easy to test and easy to reason about —
// every state transition is still `(state, msg) -> state'`.
//
// Implementation: a flat struct with a kind tag rather than a parameterized
// union. Odin's parameterized unions compile fine here, but the flat
// struct keeps `cmd_batch`'s `children: []Command(Msg)` recursion
// trivially expressible and makes `update` call sites tidy (callers can
// write `return s, {}` without naming a variant).
Command :: struct($Msg: typeid) {
	kind:     Command_Kind,
	msg:      Msg,
	seconds:  f32,
	children: []Command(Msg),
	// async carries the per-op descriptor for `.Async` commands (file
	// reads, future sockets, etc). Allocated into `context.temp_allocator`
	// by the constructor and consumed by `process_async` on the same
	// frame, so the pointer's short lifetime is fine.
	async:    ^Async_Op(Msg),
	// window_op carries the per-op descriptor for `.Open_Window` /
	// `.Close_Window` commands. Same lifetime contract as `async` —
	// temp-allocated by the constructor, picked up by process_command
	// on the same frame.
	window_op: ^Window_Op(Msg),
	// thread_op carries the per-op descriptor for `.Thread` commands.
	// `rawptr` (rather than `^Thread_Op(Msg)`) avoids a circular type
	// dependency with `skald/thread.odin`, where the Job carried
	// inside the op is monomorphised against the concrete `T` payload
	// type at the cmd_thread call site. Cast back to `^Thread_Op(Msg)`
	// inside `thread_op_spawn`. Heap-allocated (not temp-arena) — the
	// worker thread may outlive the dispatch frame.
	thread_op: rawptr,
}

// Command_Kind discriminates a `Command`. `.None` is the zero value so
// `return state, {}` from an update branch means "no effect" without
// needing a helper constructor.
Command_Kind :: enum u8 {
	None,
	Now,
	Delay,
	Batch,
	Async,
	Open_Window,
	Close_Window,
	Thread,
}

// Window_Desc describes a window to be opened by `cmd_open_window`. Mirrors
// the shape of `App`'s window-related fields — title, size, initial state,
// SDL flags, and the native-tweak hook — so apps can spawn secondary
// windows with the same ergonomics as the main window at startup.
Window_Desc :: struct {
	title:         string,
	size:          Size,
	initial_state: Window_State,
	flags:         sdl3.WindowFlags,
	// on_open fires once after the new window is created and its Vulkan
	// surface+swapchain are live, giving this specific window the same
	// pre-render tweak hook `App.on_window_open` gives the primary. Ideal
	// spot for X11 `_NET_WM_WINDOW_TYPE_DOCK` hinting per popover.
	on_open:       proc(w: ^Window),
}

// Window_Op_Kind discriminates between open + close requests on the
// shared `Window_Op` payload.
Window_Op_Kind :: enum u8 {
	Open,
	Close,
}

// Window_Op is the payload carried by `.Open_Window` and `.Close_Window`
// commands. Heap-allocated into the frame arena by the constructors
// (`cmd_open_window` / `cmd_close_window`); consumed during command
// processing, which hands the op to the run loop via a pending list.
Window_Op :: struct($Msg: typeid) {
	kind:      Window_Op_Kind,
	desc:      Window_Desc,                // valid when kind == .Open
	on_result: proc(id: Window_Id) -> Msg, // fires after Open completes with the new window's id
	on_close:  proc(id: Window_Id) -> Msg, // fires when this window tears down — either via cmd_close_window OR the user hitting its X
	id:        Window_Id,                  // valid when kind == .Close
}

// Window_Close_Reg is the per-window close-callback registration. The
// run loop keeps a list of these, one per open secondary, and consults
// it whenever a target is torn down (programmatic close or X-button).
// Applied in-place so the Msg-parameterised proc pointer stays typed
// end-to-end without going through any rawptr shenanigans.
Window_Close_Reg :: struct($Msg: typeid) {
	id:       Window_Id,
	on_close: proc(id: Window_Id) -> Msg,
}

// cmd_open_window asks the runtime to create a secondary window. The new
// window shares the app's Vulkan device, pipeline, fonts and image
// cache with the main window — only the swapchain + per-frame sync are
// allocated fresh. Once the window is up, `on_result` fires with the
// new `Window_Id`; apps typically store that id on their State so their
// `view` proc can switch on `ctx.window` to render the right tree.
//
//     Msg :: union { ... Popover_Opened, Popover_Closed }
//
//     on_popover_opened :: proc(id: skald.Window_Id) -> Msg {
//         return Popover_Opened{id = id}
//     }
//
//     return state, skald.cmd_open_window(
//         {title = "Calendar", size = {240, 200}, flags = {.BORDERLESS, .ALWAYS_ON_TOP}},
//         on_popover_opened,
//     )
// `on_close` is optional — leave nil if the app doesn't need to hear
// about the window closing. Fires whenever the target tears down,
// whether that was a `cmd_close_window` dispatched by the app itself
// or the user clicking the window's native X button. The msg gives
// the app a chance to clear any `Window_Id` it has stashed in state.
cmd_open_window :: proc(
	desc: Window_Desc,
	on_result: proc(id: Window_Id) -> $Msg,
	on_close: proc(id: Window_Id) -> Msg = nil,
) -> Command(Msg) {
	op := new(Window_Op(Msg), context.temp_allocator)
	op^ = Window_Op(Msg){
		kind      = .Open,
		desc      = desc,
		on_result = on_result,
		on_close  = on_close,
	}
	return Command(Msg){kind = .Open_Window, window_op = op}
}

// cmd_close_window tears down a secondary window opened by
// `cmd_open_window`. Closing the primary (main) window is a no-op —
// use the window's close button or set `should_close` for that.
//
// `$Msg` must be passed explicitly because `cmd_close_window` has
// nothing else that carries the type (no payload, no callback). Apps
// write `skald.cmd_close_window(Msg, id)` — Msg is the app's top-level
// message type, already in scope at the call site.
cmd_close_window :: proc($Msg: typeid, id: Window_Id) -> Command(Msg) {
	op := new(Window_Op(Msg), context.temp_allocator)
	op^ = Window_Op(Msg){kind = .Close, id = id}
	return Command(Msg){kind = .Close_Window, window_op = op}
}

// cmd_now schedules `msg` to be delivered back to `update` on the same
// frame the originating command was returned from. This is useful for
// chaining follow-up state transitions without involving a widget —
// e.g., a "Save" button's handler that triggers a "Close_Dialog" after
// update applies the save.
//
// The runtime loops `update` until the msg queue is empty, so `.Now`
// cascades resolve before the next `view` call.
cmd_now :: proc(msg: $Msg) -> Command(Msg) {
	return Command(Msg){kind = .Now, msg = msg}
}

// cmd_delay schedules `msg` to be delivered after `seconds` have
// elapsed. The delay is measured against wall-clock time; the runtime
// polls pending delays at the top of every frame and releases any that
// are due.
//
// The msg payload must stay valid until the delay fires, which can be
// many frames later — the framework does not copy it. For Msg variants
// carrying pointer-typed payloads (strings, slices), clone into a
// persistent allocator before wrapping in `cmd_delay`. POD payloads
// (enums, numbers, booleans) need no special handling.
//
//     return s, skald.cmd_delay(1.0, Msg.Tick)
cmd_delay :: proc(seconds: f32, msg: $Msg) -> Command(Msg) {
	return Command(Msg){kind = .Delay, seconds = seconds, msg = msg}
}

// cmd_batch bundles several commands into one. The runtime applies
// them in order; semantically `batch(a, b, c)` is equivalent to
// returning `a`, then `b`, then `c` from three separate update calls.
//
//     return s, skald.cmd_batch(
//         skald.cmd_delay(1.0, Tick_Msg{}),
//         skald.cmd_now(Save_Requested{}),
//     )
//
// Children are copied into `context.temp_allocator`; the command
// itself is typically returned from `update`, whose return value is
// processed before the frame arena resets.
cmd_batch :: proc(first: Command($Msg), rest: ..Command(Msg)) -> Command(Msg) {
	n := len(rest) + 1
	slice := make([]Command(Msg), n, context.temp_allocator)
	slice[0] = first
	for cmd, i in rest {
		slice[i+1] = cmd
	}
	return Command(Msg){kind = .Batch, children = slice}
}

// Pending_Delay holds a scheduled msg dispatch. `fire_at_ns` is the
// absolute wall-clock nanosecond value at which the msg should be
// released — same units as `time.now()._nsec`.
@(private)
Pending_Delay :: struct($Msg: typeid) {
	fire_at_ns: i64,
	msg:        Msg,
}

// process_command walks a command tree and applies its effects.
// `.Now` msgs go straight onto the frame's queue; `.Delay` commands
// get scheduled for a future frame; `.Batch` recurses into children;
// `.Async` hands the op off to nbio via `process_async`, which registers
// a pending slot that `drain_io` will convert back into a Msg once the
// underlying operation completes. `.Open_Window` / `.Close_Window`
// enqueue onto `windows_pending` — the run loop drains that list
// between the msg pass and the next frame, doing the actual SDL +
// Vulkan work where it has access to the renderer.
@(private)
process_command :: proc(
	cmd:              Command($Msg),
	msgs:             ^[dynamic]Msg,
	pending:          ^[dynamic]Pending_Delay(Msg),
	io:               ^Io_State(Msg),
	windows_pending:  ^[dynamic]Window_Op(Msg),
	thread_pool:      ^Thread_Pool(Msg),
) {
	switch cmd.kind {
	case .None:
		// no effect
	case .Now:
		append(msgs, cmd.msg)
	case .Delay:
		fire := time.now()._nsec + i64(f64(cmd.seconds) * f64(time.Second))
		append(pending, Pending_Delay(Msg){fire_at_ns = fire, msg = cmd.msg})
	case .Batch:
		for child in cmd.children {
			process_command(child, msgs, pending, io, windows_pending, thread_pool)
		}
	case .Async:
		process_async(cmd.async, io)
	case .Open_Window, .Close_Window:
		if cmd.window_op != nil {
			append(windows_pending, cmd.window_op^)
		}
	case .Thread:
		thread_op_spawn(cmd.thread_op, thread_pool)
	}
}

// drain_due_delays moves every pending delay whose deadline has passed
// onto the msg queue. Called once at the top of each frame so time-
// based messages show up alongside input-driven ones in the same update
// pass.
@(private)
drain_due_delays :: proc(
	pending: ^[dynamic]Pending_Delay($Msg),
	msgs:    ^[dynamic]Msg,
) {
	now_ns := time.now()._nsec
	i := 0
	for i < len(pending) {
		if pending[i].fire_at_ns <= now_ns {
			append(msgs, pending[i].msg)
			ordered_remove(pending, i)
		} else {
			i += 1
		}
	}
}
