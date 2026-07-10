#+build linux
package skald

// Wayland drag-OUT (request 019 / 012 Layer 2-OUT): start a real
// wl_data_device drag so an app can drag an item OUT to another client (a
// browser's upload area, a file manager, an editor).
//
// SDL3 exposes no drag-source API and hides its input serials, so we talk the
// wayland protocol directly: reuse SDL's existing wl_display + wl_surface (so
// we stay the SAME client — SDL's serials + surface focus are valid for us),
// bind our own seat / data_device_manager on a private event queue, and a
// second wl_pointer purely to read the button-press serial start_drag needs.
//
// Portability: libwayland-client is loaded at RUNTIME via dlopen (not linked),
// exactly as SDL loads its own wayland backend — so X11 / wayland-less Linux
// links and runs fine; this whole file is #+build linux (other platforms get
// the no-op stub in wayland_dragout_other.odin); and every entry point is a
// no-op unless we're actually on a wayland session. In-window DnD is unaffected.

import "base:runtime"
import "core:dynlib"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"
import linux "core:sys/linux"
import sdl3 "vendor:sdl3"

DRAGOUT_DEBUG :: #config(SKALD_DRAGOUT_DEBUG, false)

@(private="file")
dlog :: proc(args: ..any) {
	when DRAGOUT_DEBUG {
		context = runtime.default_context()
		fmt.eprint("[dragout] ")
		fmt.eprintln(..args)
	}
}

// ------------------------------------------------------------------ types

@(private="file") Proxy     :: distinct rawptr
@(private="file") Interface :: distinct rawptr

WL_MARSHAL_FLAG_DESTROY :: u32(1)

// wl_argument: an 8-byte union; the marshaller reads the field named by the
// request signature, so 32-bit fields leaving the high bytes dirty is fine.
@(private="file")
Argument :: struct #raw_union {
	i: i32, u: u32, f: i32, s: cstring, o: rawptr, n: u32, a: rawptr, h: i32,
}

// request opcodes (verified against core wayland.xml ordering)
@(private="file") OP_DISPLAY_GET_REGISTRY   :: u32(1)
@(private="file") OP_REGISTRY_BIND          :: u32(0)
@(private="file") OP_SEAT_GET_POINTER       :: u32(0)
@(private="file") OP_DDM_CREATE_SOURCE      :: u32(0)
@(private="file") OP_DDM_GET_DATA_DEVICE    :: u32(1)
@(private="file") OP_DATA_DEVICE_START_DRAG :: u32(0)
@(private="file") OP_DATA_SOURCE_OFFER      :: u32(0)
@(private="file") OP_DATA_SOURCE_DESTROY    :: u32(1)
@(private="file") OP_DATA_SOURCE_SET_ACTIONS:: u32(2)
@(private="file") OP_SHM_CREATE_POOL        :: u32(0)
@(private="file") OP_SHM_POOL_CREATE_BUFFER :: u32(0)
@(private="file") OP_SHM_POOL_DESTROY       :: u32(1)
@(private="file") OP_COMPOSITOR_CREATE_SURF :: u32(0)
@(private="file") OP_SURFACE_DESTROY        :: u32(0)
@(private="file") OP_SURFACE_ATTACH         :: u32(1)
@(private="file") OP_SURFACE_DAMAGE         :: u32(2)
@(private="file") OP_SURFACE_COMMIT         :: u32(6)

@(private="file") DND_ACTION_COPY      :: u32(1)
@(private="file") DND_ACTION_MOVE      :: u32(2)
@(private="file") SHM_FORMAT_ARGB8888  :: u32(0)

// wl_seat.capabilities bitmask (wayland.xml): pointer=1, keyboard=2, touch=4.
@(private="file") WL_SEAT_CAPABILITY_POINTER :: u32(1)

// dlsym'd function-pointer types
@(private="file") Marshal_Proc          :: #type proc "c" (p: Proxy, opcode: u32, iface: Interface, version: u32, flags: u32, args: [^]Argument) -> Proxy
@(private="file") Add_Listener_Proc      :: #type proc "c" (p: Proxy, impl: rawptr, data: rawptr) -> i32
@(private="file") Get_Version_Proc       :: #type proc "c" (p: Proxy) -> u32
@(private="file") Create_Wrapper_Proc    :: #type proc "c" (p: Proxy) -> Proxy
@(private="file") Wrapper_Destroy_Proc   :: #type proc "c" (p: Proxy)
@(private="file") Set_Queue_Proc         :: #type proc "c" (p: Proxy, queue: rawptr)
@(private="file") Create_Queue_Proc      :: #type proc "c" (display: rawptr) -> rawptr
@(private="file") Roundtrip_Queue_Proc   :: #type proc "c" (display: rawptr, queue: rawptr) -> i32
@(private="file") Dispatch_Pending_Proc  :: #type proc "c" (display: rawptr, queue: rawptr) -> i32
@(private="file") Flush_Proc             :: #type proc "c" (display: rawptr) -> i32

@(private="file")
Api :: struct {
	marshal:          Marshal_Proc,
	add_listener:     Add_Listener_Proc,
	get_version:      Get_Version_Proc,
	create_wrapper:   Create_Wrapper_Proc,
	wrapper_destroy:  Wrapper_Destroy_Proc,
	set_queue:        Set_Queue_Proc,
	create_queue:     Create_Queue_Proc,
	roundtrip_queue:  Roundtrip_Queue_Proc,
	dispatch_pending: Dispatch_Pending_Proc,
	flush:            Flush_Proc,

	iface_registry:    Interface,
	iface_seat:        Interface,
	iface_pointer:     Interface,
	iface_ddm:         Interface,
	iface_data_device: Interface,
	iface_data_source: Interface,
	iface_shm:         Interface,
	iface_shm_pool:    Interface,
	iface_buffer:      Interface,
	iface_compositor:  Interface,
	iface_surface:     Interface,
}

// listener vtables (field order must match wayland.xml event order)
@(private="file")
Registry_Listener :: struct {
	global:        proc "c" (data: rawptr, reg: Proxy, name: u32, iface: cstring, version: u32),
	global_remove: proc "c" (data: rawptr, reg: Proxy, name: u32),
}
@(private="file")
Seat_Listener :: struct {
	capabilities: proc "c" (data: rawptr, seat: Proxy, capabilities: u32),
	name:         proc "c" (data: rawptr, seat: Proxy, name: cstring),
}
@(private="file")
Pointer_Listener :: struct {
	enter:  proc "c" (data: rawptr, p: Proxy, serial: u32, surface: rawptr, sx, sy: i32),
	leave:  proc "c" (data: rawptr, p: Proxy, serial: u32, surface: rawptr),
	motion: proc "c" (data: rawptr, p: Proxy, time: u32, sx, sy: i32),
	button: proc "c" (data: rawptr, p: Proxy, serial: u32, time: u32, button: u32, state: u32),
	axis:   proc "c" (data: rawptr, p: Proxy, time: u32, axis: u32, value: i32),
	// v5+ events are never delivered to our v1 pointer; left nil.
	frame:                   proc "c" (data: rawptr, p: Proxy),
	axis_source:             proc "c" (data: rawptr, p: Proxy, axis_source: u32),
	axis_stop:               proc "c" (data: rawptr, p: Proxy, time: u32, axis: u32),
	axis_discrete:           proc "c" (data: rawptr, p: Proxy, axis: u32, discrete: i32),
	axis_value120:           proc "c" (data: rawptr, p: Proxy, axis: u32, value120: i32),
	axis_relative_direction: proc "c" (data: rawptr, p: Proxy, axis: u32, direction: u32),
}
@(private="file")
Source_Listener :: struct {
	target:             proc "c" (data: rawptr, src: Proxy, mime: cstring),
	send:               proc "c" (data: rawptr, src: Proxy, mime: cstring, fd: i32),
	cancelled:          proc "c" (data: rawptr, src: Proxy),
	dnd_drop_performed: proc "c" (data: rawptr, src: Proxy),
	dnd_finished:       proc "c" (data: rawptr, src: Proxy),
	action:             proc "c" (data: rawptr, src: Proxy, dnd_action: u32),
}

// ------------------------------------------------------------------ state

@(private="file")
g: struct {
	tried:       bool, // load attempted
	ok:          bool, // lib + symbols loaded
	api:         Api,
	display:     rawptr,
	queue:       rawptr,
	bound:       bool,
	unavailable: bool, // drag-out determined impossible (e.g. pointer-less seat); latched
	seat:        Proxy,
	seat_caps:   u32,  // wl_seat.capabilities bitmask
	ddm:         Proxy,
	ddm_version: u32,
	pointer:     Proxy,
	data_device: Proxy,
	shm:         Proxy,
	compositor:  Proxy,
	last_serial: u32,
	// active drag
	active:       bool,
	source:       Proxy,
	send_data:    []u8, // heap copy written on `send`, freed on end
	icon_surface: Proxy,
	icon_buffer:  Proxy,
}

@(private="file") reg_listener := Registry_Listener{
	global = on_global, global_remove = on_global_remove,
}
@(private="file") seat_listener := Seat_Listener{
	capabilities = on_seat_capabilities, name = on_seat_name,
}
// Every event the compositor can deliver to a v1 pointer / a data source MUST
// have a non-nil handler — the dispatcher indexes the vtable by event opcode and
// calls it blind, so a nil slot (e.g. the motion fired on the first mouse move)
// is a crash. v5+ pointer events are never sent to our v1 pointer, so those
// stay nil.
@(private="file") ptr_listener := Pointer_Listener{
	enter = on_p_enter, leave = on_p_leave, motion = on_p_motion,
	button = on_p_button, axis = on_p_axis,
}
@(private="file") src_listener := Source_Listener{
	target = on_src_target, send = on_src_send, cancelled = on_src_done,
	dnd_drop_performed = on_src_noop, dnd_finished = on_src_done, action = on_src_action,
}

// ------------------------------------------------------------ marshal glue

@(private="file")
sym :: proc(lib: dynlib.Library, name: string, $T: typeid) -> T {
	p, ok := dynlib.symbol_address(lib, name)
	z: T
	if !ok || p == nil { return z }
	return transmute(T)p
}

@(private="file")
load_lib :: proc() -> bool {
	context = runtime.default_context()
	lib, ok := dynlib.load_library("libwayland-client.so.0")
	if !ok { dlog("dlopen libwayland-client failed"); return false }
	a := &g.api
	a.marshal          = sym(lib, "wl_proxy_marshal_array_flags", Marshal_Proc)
	a.add_listener     = sym(lib, "wl_proxy_add_listener", Add_Listener_Proc)
	a.get_version      = sym(lib, "wl_proxy_get_version", Get_Version_Proc)
	a.create_wrapper   = sym(lib, "wl_proxy_create_wrapper", Create_Wrapper_Proc)
	a.wrapper_destroy  = sym(lib, "wl_proxy_wrapper_destroy", Wrapper_Destroy_Proc)
	a.set_queue        = sym(lib, "wl_proxy_set_queue", Set_Queue_Proc)
	a.create_queue     = sym(lib, "wl_display_create_queue", Create_Queue_Proc)
	a.roundtrip_queue  = sym(lib, "wl_display_roundtrip_queue", Roundtrip_Queue_Proc)
	a.dispatch_pending = sym(lib, "wl_display_dispatch_queue_pending", Dispatch_Pending_Proc)
	a.flush            = sym(lib, "wl_display_flush", Flush_Proc)
	a.iface_registry    = Interface(sym(lib, "wl_registry_interface", rawptr))
	a.iface_seat        = Interface(sym(lib, "wl_seat_interface", rawptr))
	a.iface_pointer     = Interface(sym(lib, "wl_pointer_interface", rawptr))
	a.iface_ddm         = Interface(sym(lib, "wl_data_device_manager_interface", rawptr))
	a.iface_data_device = Interface(sym(lib, "wl_data_device_interface", rawptr))
	a.iface_data_source = Interface(sym(lib, "wl_data_source_interface", rawptr))
	a.iface_shm         = Interface(sym(lib, "wl_shm_interface", rawptr))
	a.iface_shm_pool    = Interface(sym(lib, "wl_shm_pool_interface", rawptr))
	a.iface_buffer      = Interface(sym(lib, "wl_buffer_interface", rawptr))
	a.iface_compositor  = Interface(sym(lib, "wl_compositor_interface", rawptr))
	a.iface_surface     = Interface(sym(lib, "wl_surface_interface", rawptr))

	if a.marshal == nil || a.add_listener == nil || a.create_queue == nil ||
	   a.iface_registry == nil || a.iface_seat == nil || a.iface_ddm == nil {
		dlog("missing libwayland symbols")
		return false
	}
	return true
}

// marshal a request that creates no new object
@(private="file")
req :: proc(p: Proxy, opcode: u32, args: []Argument, flags: u32 = 0) {
	g.api.marshal(p, opcode, nil, g.api.get_version(p), flags, raw_data(args))
}

// marshal a constructor request; args must hold the new_id slot ({n=0})
@(private="file")
req_new :: proc(p: Proxy, opcode: u32, iface: Interface, version: u32, args: []Argument) -> Proxy {
	return g.api.marshal(p, opcode, iface, version, 0, raw_data(args))
}

// wl_registry.bind for a generic new_id: wire takes (name, iface_name, version, id)
@(private="file")
registry_bind :: proc(reg: Proxy, name: u32, iface: Interface, iface_name: string, version: u32) -> Proxy {
	cname := strings.clone_to_cstring(iface_name, context.temp_allocator)
	args := []Argument{ {u = name}, {s = cname}, {u = version}, {n = 0} }
	return g.api.marshal(reg, OP_REGISTRY_BIND, iface, version, 0, raw_data(args))
}

// ------------------------------------------------------------- callbacks

@(private="file")
on_global :: proc "c" (data: rawptr, reg: Proxy, name: u32, iface: cstring, version: u32) {
	context = runtime.default_context()
	switch string(iface) {
	case "wl_seat":
		g.seat = registry_bind(reg, name, g.api.iface_seat, "wl_seat", 1)
		// Listen for capabilities the instant the proxy exists, before any
		// dispatch of its events, so `ensure` can read whether this seat has a
		// pointer at all before it tries to bind one.
		g.api.add_listener(g.seat, &seat_listener, nil)
	case "wl_data_device_manager":
		g.ddm_version = min(version, 3)
		g.ddm = registry_bind(reg, name, g.api.iface_ddm, "wl_data_device_manager", g.ddm_version)
	case "wl_shm":
		g.shm = registry_bind(reg, name, g.api.iface_shm, "wl_shm", 1)
	case "wl_compositor":
		g.compositor = registry_bind(reg, name, g.api.iface_compositor, "wl_compositor", min(version, 4))
	}
}
@(private="file") on_global_remove :: proc "c" (data: rawptr, reg: Proxy, name: u32) {}

@(private="file") on_seat_capabilities :: proc "c" (data: rawptr, seat: Proxy, capabilities: u32) { g.seat_caps = capabilities }
@(private="file") on_seat_name :: proc "c" (data: rawptr, seat: Proxy, name: cstring) {}

@(private="file") on_p_enter :: proc "c" (data: rawptr, p: Proxy, serial: u32, surface: rawptr, sx, sy: i32) { g.last_serial = serial }
@(private="file") on_p_button :: proc "c" (data: rawptr, p: Proxy, serial: u32, time: u32, button: u32, state: u32) { g.last_serial = serial }
@(private="file") on_p_leave :: proc "c" (data: rawptr, p: Proxy, serial: u32, surface: rawptr) {}
@(private="file") on_p_motion :: proc "c" (data: rawptr, p: Proxy, time: u32, sx, sy: i32) {}
@(private="file") on_p_axis :: proc "c" (data: rawptr, p: Proxy, time: u32, axis: u32, value: i32) {}

@(private="file") on_src_target :: proc "c" (data: rawptr, src: Proxy, mime: cstring) {}
@(private="file") on_src_action :: proc "c" (data: rawptr, src: Proxy, dnd_action: u32) {}
@(private="file") on_src_noop :: proc "c" (data: rawptr, src: Proxy) {}

@(private="file")
on_src_send :: proc "c" (data: rawptr, src: Proxy, mime: cstring, fd: i32) {
	context = runtime.default_context()
	dlog("source.send mime", string(mime), "->", len(g.send_data), "bytes (target pulled the data)")
	if g.send_data != nil {
		posix.write(posix.FD(fd), raw_data(g.send_data), c.size_t(len(g.send_data)))
	}
	posix.close(posix.FD(fd))
}
@(private="file")
on_src_done :: proc "c" (data: rawptr, src: Proxy) {
	context = runtime.default_context()
	dragout_finish()
}

// ------------------------------------------------------------- lifecycle

@(private="file")
ensure :: proc(display: rawptr) -> bool {
	if !g.tried { g.tried = true; g.ok = load_lib() }
	if !g.ok || display == nil { return false }
	if g.unavailable { return false } // determined once (e.g. no pointer); don't rebind every frame
	if g.bound && g.display == display { return true }
	context = runtime.default_context()

	g.display = display
	g.queue = g.api.create_queue(display)
	if g.queue == nil { return false }

	// registry on a wrapper bound to our private queue, so children inherit it
	wrap := g.api.create_wrapper(Proxy(display))
	g.api.set_queue(wrap, g.queue)
	registry := req_new(wrap, OP_DISPLAY_GET_REGISTRY, g.api.iface_registry,
		g.api.get_version(Proxy(display)), []Argument{ {n = 0} })
	g.api.wrapper_destroy(wrap)
	g.api.add_listener(registry, &reg_listener, nil)
	g.api.roundtrip_queue(display, g.queue) // globals -> on_global binds seat + ddm

	if g.seat == nil || g.ddm == nil { dlog("no seat/ddm"); return false }

	// A seat can lack a pointer entirely — touch-only, or a headless comp with
	// no input devices. Binding wl_pointer on such a seat is a fatal protocol
	// error that kills the whole client, so read the seat's capabilities first
	// (delivered on the roundtrip after bind) and, if there's no pointer, leave
	// drag-out permanently inert — it can't work without one anyway.
	g.api.roundtrip_queue(display, g.queue) // -> on_seat_capabilities
	if g.seat_caps & WL_SEAT_CAPABILITY_POINTER == 0 {
		dlog("seat has no pointer capability; drag-out inert")
		g.unavailable = true
		return false
	}

	// second pointer (serial capture) + our own data device
	g.pointer = req_new(g.seat, OP_SEAT_GET_POINTER, g.api.iface_pointer,
		g.api.get_version(g.seat), []Argument{ {n = 0} })
	g.api.add_listener(g.pointer, &ptr_listener, nil)
	g.data_device = req_new(g.ddm, OP_DDM_GET_DATA_DEVICE, g.api.iface_data_device,
		g.api.get_version(g.ddm), []Argument{ {n = 0}, {o = rawptr(g.seat)} })
	g.api.roundtrip_queue(display, g.queue)

	g.bound = true
	dlog("bound ok, ddm v", g.ddm_version)
	return true
}

// make_icon uploads premultiplied BGRA pixels into a wl_shm buffer (stored in
// g.icon_buffer) and returns a wl_surface carrying it, for use as the drag
// icon. Returns nil if shm/compositor are unavailable or the upload fails.
@(private="file")
make_icon :: proc(px: []u8, w, h: int) -> Proxy {
	if g.shm == nil || g.compositor == nil || w <= 0 || h <= 0 { return nil }
	stride := w * 4
	size := stride * h
	if len(px) < size { return nil }

	fd, ferr := linux.memfd_create("skald-dragicon", {})
	if ferr != .NONE { return nil }
	if linux.ftruncate(fd, i64(size)) != .NONE { linux.close(fd); return nil }
	addr, merr := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE { linux.close(fd); return nil }
	mem.copy(addr, raw_data(px), size)
	linux.munmap(addr, uint(size))

	pool := req_new(g.shm, OP_SHM_CREATE_POOL, g.api.iface_shm_pool, g.api.get_version(g.shm),
		[]Argument{ {n = 0}, {h = i32(fd)}, {i = i32(size)} })
	g.icon_buffer = req_new(pool, OP_SHM_POOL_CREATE_BUFFER, g.api.iface_buffer, g.api.get_version(pool),
		[]Argument{ {n = 0}, {i = 0}, {i = i32(w)}, {i = i32(h)}, {i = i32(stride)}, {u = SHM_FORMAT_ARGB8888} })
	req(pool, OP_SHM_POOL_DESTROY, nil, WL_MARSHAL_FLAG_DESTROY) // buffer keeps the memory
	surface := req_new(g.compositor, OP_COMPOSITOR_CREATE_SURF, g.api.iface_surface,
		g.api.get_version(g.compositor), []Argument{ {n = 0} })

	g.api.flush(g.display) // send the fd (create_pool) before we close it
	linux.close(fd)
	return surface
}

@(private="file")
dragout_finish :: proc() {
	if !g.active { return }
	if g.source != nil {
		g.api.marshal(g.source, OP_DATA_SOURCE_DESTROY, nil,
			g.api.get_version(g.source), WL_MARSHAL_FLAG_DESTROY, nil)
		g.source = nil
	}
	if g.icon_surface != nil {
		g.api.marshal(g.icon_surface, OP_SURFACE_DESTROY, nil,
			g.api.get_version(g.icon_surface), WL_MARSHAL_FLAG_DESTROY, nil)
		g.icon_surface = nil
	}
	if g.icon_buffer != nil {
		g.api.marshal(g.icon_buffer, 0, nil, // wl_buffer.destroy = opcode 0
			g.api.get_version(g.icon_buffer), WL_MARSHAL_FLAG_DESTROY, nil)
		g.icon_buffer = nil
	}
	if g.send_data != nil { delete(g.send_data); g.send_data = nil }
	g.active = false
	if g.display != nil { g.api.flush(g.display) }
	dlog("drag finished")
}

// ----------------------------------------------------- package entry points
// (mirrored as no-ops in wayland_dragout_other.odin)

// dragout_init wires up the wayland objects for `win` if it's a wayland
// session, so the second pointer starts capturing serials immediately. No-op
// off wayland. Safe to call repeatedly.
dragout_init :: proc(win: ^sdl3.Window) {
	if win == nil { return }
	props := sdl3.GetWindowProperties(win)
	display := sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil)
	if display == nil { return } // not a wayland session
	ensure(display)
}

// dragout_pump dispatches our private queue (serial updates, source send /
// finished callbacks). Call once per frame.
dragout_pump :: proc() {
	if !g.ok || g.queue == nil { return }
	g.api.dispatch_pending(g.display, g.queue)
	g.api.flush(g.display) // push any pending requests to the compositor
}

dragout_in_progress :: proc() -> bool { return g.active }

// dragout_start_native promotes an in-window drag to a real wl_data_device
// drag carrying `data` under MIME types `mimes`. Returns false (caller keeps
// the in-window drag) off wayland or if no input serial is available yet.
dragout_start_native :: proc(win: ^sdl3.Window, mimes: []string, data: []u8,
                             icon_px: []u8 = nil, icon_w: int = 0, icon_h: int = 0,
                             hotspot_x: int = 0, hotspot_y: int = 0) -> bool {
	if win == nil || len(mimes) == 0 { return false }
	props := sdl3.GetWindowProperties(win)
	display := sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil)
	surface := sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_WAYLAND_SURFACE_POINTER, nil)
	if display == nil || surface == nil { return false }
	if !ensure(display) { return false }
	if g.last_serial == 0 { dlog("no serial captured yet"); return false }
	context = runtime.default_context()

	g.source = req_new(g.ddm, OP_DDM_CREATE_SOURCE, g.api.iface_data_source,
		g.api.get_version(g.ddm), []Argument{ {n = 0} })
	g.api.add_listener(g.source, &src_listener, nil)
	for m in mimes {
		cm := strings.clone_to_cstring(m, context.temp_allocator)
		req(g.source, OP_DATA_SOURCE_OFFER, []Argument{ {s = cm} })
	}
	if g.ddm_version >= 3 {
		req(g.source, OP_DATA_SOURCE_SET_ACTIONS, []Argument{ {u = DND_ACTION_COPY | DND_ACTION_MOVE} })
	}
	g.send_data = make([]u8, len(data))
	copy(g.send_data, data)

	// Offscreen-rendered ghost as the drag icon (stage 2); nil if unavailable.
	g.icon_surface = nil
	g.icon_buffer  = nil
	icon := make_icon(icon_px, icon_w, icon_h)
	g.icon_surface = icon

	// start_drag(source, origin=surface, icon, serial)
	req(g.data_device, OP_DATA_DEVICE_START_DRAG,
		[]Argument{ {o = rawptr(g.source)}, {o = surface}, {o = rawptr(icon)}, {u = g.last_serial} })
	if icon != nil {
		// Negative attach offset sets the icon hotspot, so the grab point stays
		// under the cursor — matching the in-window ghost (no jump at handoff).
		hx := i32(clamp(hotspot_x, 0, icon_w))
		hy := i32(clamp(hotspot_y, 0, icon_h))
		req(icon, OP_SURFACE_ATTACH, []Argument{ {o = rawptr(g.icon_buffer)}, {i = -hx}, {i = -hy} })
		req(icon, OP_SURFACE_DAMAGE, []Argument{ {i = 0}, {i = 0}, {i = i32(icon_w)}, {i = i32(icon_h)} })
		req(icon, OP_SURFACE_COMMIT, nil)
	}
	g.active = true
	g.api.flush(display)
	dlog("start_drag sent, serial", g.last_serial, "mimes", len(mimes), "icon", icon != nil)
	return true
}
