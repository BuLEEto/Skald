package skald

import "core:time"

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
// underlying operation completes.
@(private)
process_command :: proc(
	cmd:     Command($Msg),
	msgs:    ^[dynamic]Msg,
	pending: ^[dynamic]Pending_Delay(Msg),
	io:      ^Io_State(Msg),
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
			process_command(child, msgs, pending, io)
		}
	case .Async:
		process_async(cmd.async, io)
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
