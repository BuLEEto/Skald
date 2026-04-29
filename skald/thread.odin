package skald

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"
import sdl3 "vendor:sdl3"

// `cmd_thread` runs a synchronous proc on a dedicated worker thread and
// posts its return value back to the main thread as a Msg, where it
// flows through `update` like any other event. The point: blocking
// libraries (postgres, sqlite, sync HTTP, large-file parsers) keep
// working as-is, and the UI never freezes.
//
// ⚠️  WORKER CONTRACT — VIOLATIONS ARE DATA RACES, NOT COMPILE ERRORS.
//
//   1. The work proc runs on a *different OS thread*. Don't touch ANY
//      Skald state from inside it — no `ctx`, no renderer, no widget
//      store, no view-tree procs, no read or mutate of `state`. Snapshot
//      what you need into the typed payload; it's copied by value at
//      dispatch.
//   2. Strings + slices in your payload (in) and your returned Msg (out)
//      must be heap-allocated, NOT temp-arena. The worker has no Skald
//      frame arena and the main-thread temp allocator gets reset under
//      it. Use `strings.clone` for outputs.
//   3. One call → one Msg out. Don't loop forever inside the worker.
//   4. Errors are part of your Msg union (`Query_Failed{err}`). DON'T
//      panic — an Odin assertion in a worker terminates the whole
//      process before `update` ever sees it.
//
// See also: docs/gotchas.md ("cmd_thread workers must not touch Skald
// state") and docs/cookbook.md ("Run a blocking library on a background
// thread") for fuller treatment.
//
// Two arities are supported via `cmd_thread_simple` (no params) and the
// payload-bearing variant. Pick the second whenever the work depends
// on state — the by-value snapshot is what protects you from aliasing
// live state.
//
//     // No params:
//     return out, skald.cmd_thread_simple(Msg, do_recount)
//
//     do_recount :: proc() -> Msg {
//         n := slow_count()
//         return Recount_Done{count = n}
//     }
//
//     // With a params snapshot:
//     return out, skald.cmd_thread(Msg, Query_Params{search = state.draft},
//                                  do_search)
//
//     do_search :: proc(p: Query_Params) -> Msg {
//         conn := postgres.pool_acquire(g_pool)
//         defer postgres.pool_release(g_pool, conn)
//         rows := postgres.query(conn, "SELECT ... WHERE name LIKE $1",
//                                p.search)
//         return Search_Done{rows = rows}  // rows own heap-allocated strings
//     }
//
// Cancellation, progress reporting, and a thread pool are deliberately
// out-of-scope for v1. Apps wanting cancellation include a request-id
// in the payload and let `update` ignore stale results.

// Thread_Pool is the per-app mailbox where worker threads deposit
// completed Msgs and the main loop drains them at the top of each
// frame. One per `App`, owned by `run`'s stack.
@(private)
Thread_Pool :: struct($Msg: typeid) {
	lock:    sync.Mutex,
	msgs:    [dynamic]Msg, // posted by workers, drained on the main thread
	active:  int,          // atomic: in-flight workers; shutdown waits on this
	wake_id: u32,          // SDL custom-event id, registered once at startup
}

// Thread_Op is the typed payload of a `.Thread` Command. It's
// allocated by `cmd_thread` (heap, not temp-arena, because the worker
// outlives the dispatch frame), and consumed by `process_command`
// which spawns the worker and frees the op once spawn succeeds.
@(private)
Thread_Op :: struct($Msg: typeid) {
	// runner is the monomorphised trampoline that knows how to cast
	// `data` back to its concrete `^Job` type, call the user's work
	// proc, and push the resulting Msg through `pool`.
	runner: proc(data: rawptr),
	// data is `^Job` (a struct private to the polymorphic instance of
	// `cmd_thread` that produced this op). Owned by the worker.
	data:   rawptr,
	// pool is filled in by `process_command` just before spawn — the
	// op-creation site (`cmd_thread`) doesn't have access to the
	// run-loop's pool, so the trampoline can't capture it directly.
	// The `Job` struct stores a back-pointer to this `Thread_Op`, so
	// the worker reads pool through `op.pool` after process_command
	// has written it.
	pool:   ^Thread_Pool(Msg),
}

// thread_pool_init registers a unique SDL event id for waking the main
// loop when a worker completes. Called once during `run` setup.
@(private)
thread_pool_init :: proc(p: ^Thread_Pool($Msg)) {
	p.msgs = make([dynamic]Msg)
	id := sdl3.RegisterEvents(1)
	if id == 0xFFFFFFFF {
		fmt.eprintfln("skald: SDL_RegisterEvents failed (cmd_thread wakes will be missed; lazy-redraw apps may stutter on async results)")
		// id of 0 is invalid for user events; we'll still post but the
		// wake won't dispatch. Workers that complete will be drained on
		// the next input event.
	}
	p.wake_id = id
}

// thread_pool_drain pulls every completed Msg into `msgs` and returns
// true when any were drained — the caller uses that to dirty the
// frame so view runs on the same tick.
@(private)
thread_pool_drain :: proc(p: ^Thread_Pool($Msg), msgs: ^[dynamic]Msg) -> bool {
	if len(p.msgs) == 0 { return false }
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	if len(p.msgs) == 0 { return false }
	for m in p.msgs { append(msgs, m) }
	clear(&p.msgs)
	return true
}

// thread_pool_destroy waits for outstanding workers and drops the
// queue. Without the wait, workers could write to freed memory.
// Called in the deferred shutdown path of `run`.
@(private)
thread_pool_destroy :: proc(p: ^Thread_Pool($Msg)) {
	for intrinsics.atomic_load(&p.active) > 0 {
		// Spin briefly. Outstanding workers should drain quickly; if any
		// is stuck (slow query, network timeout) the app waits — same
		// contract as draining nbio at shutdown.
		sdl3.Delay(1)
	}
	delete(p.msgs)
}

// thread_pool_wake fires the SDL custom-event so a sleeping main loop
// returns from `WaitEventTimeout` and drains the mailbox immediately.
// Safe to call from any thread — SDL_PushEvent is documented as
// thread-safe in SDL3.
@(private)
thread_pool_wake :: proc(p: ^Thread_Pool($Msg)) {
	if p.wake_id == 0 || p.wake_id == 0xFFFFFFFF { return }
	e: sdl3.Event
	e.type = sdl3.EventType(p.wake_id)
	_ = sdl3.PushEvent(&e)
}

// cmd_thread runs `work(payload)` on a fresh worker thread and emits
// its return value as a Msg. `payload` is copied by value at dispatch,
// giving the worker a private snapshot it can read without aliasing
// live app state. See the file-top doc for the contract.
//
// `Msg` and `T` must be passed explicitly — Odin's polymorphic-default
// rules don't infer them from the work proc's signature reliably, so
// we keep the call site noise minimal by demanding them up front.
cmd_thread :: proc($Msg: typeid,
                    payload: $T,
                    work: proc(payload: T) -> Msg) -> Command(Msg) {
	// Job carries everything the worker needs. Allocated on the
	// persistent heap (not the frame arena) because the worker may
	// outlive the frame it was dispatched from. The worker owns the
	// Job AND the back-pointer Op, freeing both on completion — that
	// way `process_command` doesn't have to keep the Op alive past
	// spawn (or know the local Job's layout to free it).
	Job :: struct {
		payload: T,
		work:    proc(p: T) -> Msg,
		op:      ^Thread_Op(Msg),
	}

	// runner is monomorphised per (Msg, T) call site. It runs on the
	// worker, pulls Job out of `data`, calls work, pushes the Msg
	// through op.pool, and frees Job + Op. SDL_PushEvent wakes the
	// main loop so a lazy-redraw app responds immediately.
	runner :: proc(data: rawptr) {
		j := cast(^Job) data
		msg := j.work(j.payload)
		pool := j.op.pool
		sync.lock(&pool.lock)
		append(&pool.msgs, msg)
		sync.unlock(&pool.lock)
		intrinsics.atomic_sub(&pool.active, 1)
		thread_pool_wake(pool)
		free(j.op)
		free(j)
	}

	op := new(Thread_Op(Msg))
	job := new(Job)
	job.payload = payload
	job.work    = work
	job.op      = op
	op.runner   = runner
	op.data     = job
	// op.pool stays nil here; process_command fills it before spawn.

	return Command(Msg){
		kind      = .Thread,
		thread_op = cast(rawptr) op,
	}
}

// cmd_thread_simple is the no-payload form for work that needs no
// runtime parameters (re-fetch the whole table, recompute a static
// dataset). Most call sites want the payload-bearing form so they
// can snapshot state safely.
cmd_thread_simple :: proc($Msg: typeid,
                           work: proc() -> Msg) -> Command(Msg) {
	Job :: struct {
		work: proc() -> Msg,
		op:   ^Thread_Op(Msg),
	}

	runner :: proc(data: rawptr) {
		j := cast(^Job) data
		msg := j.work()
		pool := j.op.pool
		sync.lock(&pool.lock)
		append(&pool.msgs, msg)
		sync.unlock(&pool.lock)
		intrinsics.atomic_sub(&pool.active, 1)
		thread_pool_wake(pool)
		free(j.op)
		free(j)
	}

	op := new(Thread_Op(Msg))
	job := new(Job)
	job.work = work
	job.op   = op
	op.runner = runner
	op.data   = job

	return Command(Msg){
		kind      = .Thread,
		thread_op = cast(rawptr) op,
	}
}

// thread_op_spawn is called by process_command when it sees a `.Thread`
// command. It writes the run-loop's pool into the op so the worker can
// find it, bumps the active-counter atomically, then dispatches the
// worker. After this call the Thread_Op heap allocation can be freed —
// the Job (and through it the runner + payload) is owned by the
// thread until completion.
@(private)
thread_op_spawn :: proc(op_raw: rawptr, pool: ^Thread_Pool($Msg)) {
	if op_raw == nil { return }
	op := cast(^Thread_Op(Msg)) op_raw
	op.pool = pool
	intrinsics.atomic_add(&pool.active, 1)

	// self_cleanup = true: thread frees its own ^Thread bookkeeping on
	// exit, so we don't need to track handles for join. The worker
	// itself is responsible for freeing both Job AND Op when work
	// completes — we keep Op alive past spawn precisely because the
	// worker reads `pool` through `j.op.pool`.
	t := thread.create_and_start_with_data(
		op.data, op.runner,
		init_context = runtime.default_context(),
		self_cleanup = true,
	)
	if t == nil {
		// Thread creation failed — undo the active bump so shutdown
		// doesn't wait forever, and free the heap allocations the
		// worker would have freed. The Job is type-erased so we can
		// only release Op + leak Job here. Creation failure is rare
		// (process-wide thread cap reached) and apps treat it as fatal.
		fmt.eprintfln("skald: thread.create_and_start failed; cmd_thread work will not run")
		intrinsics.atomic_sub(&pool.active, 1)
		free(op)
	}
}
