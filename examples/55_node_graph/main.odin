package example_node_graph

// A minimal node-graph editor on a single `canvas`. It's the worked example
// for building a custom, canvas-based widget: the drawing uses the vector
// primitives (draw_rect_outline, draw_circle, draw_bezier, draw_line), and the
// *interaction* shows the patterns a canvas author needs, since a canvas has no
// child widgets to lean on:
//
//   • pan / zoom, with the screen<->graph transform applied before hit-testing
//   • hit-testing your own scene (nodes, ports) in graph space
//   • drag with a press-latch (which node am I dragging) held in app State
//   • creating connections by dragging output port -> input port
//   • selection of nodes AND wires; Delete removes the selection
//   • editing a node in place via a `text_input` floated on `overlay(pin)`
//
// Interaction state lives in `State`, not per-widget — that's the Elm-arch
// answer to "where does my mouse state go." Input is polled from `ctx.input`
// in `view` and posted as `Msg`s (same pattern as examples/37_canvas).
//
// Controls: drag a node to move • drag empty space to pan • scroll to zoom •
// drag from a right-hand (output) port to a left-hand (input) port to connect •
// click a node or wire to select, Delete removes it • double-click a node to
// rename • right-click a node to delete.

import "gui:skald"
import "core:math"
import "core:strings"

NODE_W :: f32(150)
NODE_H :: f32(64)
PORT_R :: f32(6)
GRAB   :: f32(5) // extra px of slack around a port for grabbing

Node :: struct {
	id:    int,
	pos:   [2]f32, // graph-space top-left
	title: string,
}

Wire :: struct {
	from: int, // node id (its output port)
	to:   int, // node id (its input port)
}

State :: struct {
	nodes:   [dynamic]Node,
	wires:   [dynamic]Wire,
	next_id: int,

	pan:  [2]f32, // screen-space translation
	zoom: f32,

	// Interaction latches — held across frames, cleared on release.
	selected:  int, // selected node id, -1 = none (mutually exclusive with sel_wire)
	sel_wire:  int, // selected wire index, -1 = none
	drag_node: int, // node id being dragged, -1 = none
	drag_grab: [2]f32, // graph offset from the node origin to the grab point
	panning:   bool,
	wire_from: int, // node id whose output we're dragging a wire from, -1 = none
	editing:   int, // node id being renamed, -1 = none
	edit_buf:  string, // rename draft (persisted; cloned in update)

	// Per-frame snapshot for the painter (not persisted; refreshed in `view`).
	cursor_screen: [2]f32,
}

Msg :: union {
	PickNode,
	MoveNode,
	EndDrag,
	StartPan,
	PanBy,
	EndPan,
	Zoom,
	StartWire,
	EndWire,
	SelectWire,
	DeleteNode,
	DeleteWireAt,
	StartRename,
	RenameEdit,
	CommitRename,
	CancelRename,
}

PickNode     :: struct { id: int, grab: [2]f32 }
MoveNode     :: struct { g: [2]f32 }
EndDrag      :: struct {}
StartPan     :: struct {}
PanBy        :: struct { d: [2]f32 }
EndPan       :: struct {}
Zoom         :: struct { factor: f32, at, origin: [2]f32 }
StartWire    :: struct { id: int }
EndWire      :: struct { target: int } // -1 = cancel
SelectWire   :: struct { idx: int }
DeleteNode   :: struct { id: int }
DeleteWireAt :: struct { idx: int }
StartRename  :: struct { id: int }
RenameEdit   :: struct { text: string }
CommitRename :: struct {}
CancelRename :: struct {}

init :: proc() -> State {
	s := State{zoom = 1, selected = -1, sel_wire = -1, drag_node = -1, wire_from = -1, editing = -1}
	add_node(&s, {60, 60}, "Input")
	add_node(&s, {320, 130}, "Transform")
	add_node(&s, {580, 80}, "Output")
	append(&s.wires, Wire{from = 0, to = 1})
	return s
}

add_node :: proc(s: ^State, pos: [2]f32, title: string) {
	append(&s.nodes, Node{id = s.next_id, pos = pos, title = title})
	s.next_id += 1
}

// ---- geometry helpers -----------------------------------------------------

in_center  :: proc(n: Node) -> [2]f32 { return {n.pos.x, n.pos.y + NODE_H * 0.5} }
out_center :: proc(n: Node) -> [2]f32 { return {n.pos.x + NODE_W, n.pos.y + NODE_H * 0.5} }

to_screen :: proc(g, origin, pan: [2]f32, zoom: f32) -> [2]f32 { return origin + pan + g * zoom }
to_graph  :: proc(s, origin, pan: [2]f32, zoom: f32) -> [2]f32 { return (s - origin - pan) / zoom }

dist :: proc(a, b: [2]f32) -> f32 { d := b - a; return math.sqrt(d.x * d.x + d.y * d.y) }

node_by_id :: proc(s: ^State, id: int) -> (Node, bool) {
	for n in s.nodes { if n.id == id { return n, true } }
	return {}, false
}

// node_at returns the topmost node id whose body contains graph point `g`, or -1.
node_at :: proc(s: ^State, g: [2]f32) -> int {
	#reverse for n in s.nodes {
		if g.x >= n.pos.x && g.x <= n.pos.x + NODE_W &&
		   g.y >= n.pos.y && g.y <= n.pos.y + NODE_H {
			return n.id
		}
	}
	return -1
}

// port_at returns the node id whose output (want_out) or input port is within
// grabbing distance of graph point `g`, or -1.
port_at :: proc(s: ^State, g: [2]f32, want_out: bool) -> int {
	#reverse for n in s.nodes {
		c := want_out ? out_center(n) : in_center(n)
		if dist(g, c) <= PORT_R + GRAB { return n.id }
	}
	return -1
}

// seg_dist is the distance from point p to segment a-b.
seg_dist :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	denom := ab.x * ab.x + ab.y * ab.y
	t: f32 = 0
	if denom > 1e-6 {
		t = clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / denom, 0, 1)
	}
	return dist(p, a + ab * t)
}

// wire_hit tests whether screen point `cursor` is near the wire bezier a→d
// (same control points as draw_wire): flatten to a polyline, check segments.
wire_hit :: proc(a, d, cursor: [2]f32, zoom: f32) -> bool {
	dx := abs(d.x - a.x) * 0.5 + 24 * zoom
	c1 := [2]f32{a.x + dx, a.y}
	c2 := [2]f32{d.x - dx, d.y}
	prev := a
	for i in 1 ..= 18 {
		t := f32(i) / f32(18)
		u := 1 - t
		p := u * u * u * a + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * d
		if seg_dist(cursor, prev, p) <= 6 { return true }
		prev = p
	}
	return false
}

// wire_at returns the index of the wire under screen point `cursor`, or -1.
wire_at :: proc(s: ^State, origin, cursor: [2]f32) -> int {
	for w, i in s.wires {
		fn, ok1 := node_by_id(s, w.from)
		tn, ok2 := node_by_id(s, w.to)
		if !ok1 || !ok2 { continue }
		a := to_screen(out_center(fn), origin, s.pan, s.zoom)
		d := to_screen(in_center(tn), origin, s.pan, s.zoom)
		if wire_hit(a, d, cursor, s.zoom) { return i }
	}
	return -1
}

// ---- update ---------------------------------------------------------------

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case PickNode:
		out.selected = v.id
		out.sel_wire = -1
		out.drag_node = v.id
		out.drag_grab = v.grab

	case MoveNode:
		if idx := index_of(&out, out.drag_node); idx >= 0 {
			out.nodes[idx].pos = v.g - out.drag_grab
		}

	case EndDrag:
		out.drag_node = -1

	case StartPan:
		out.panning = true
		out.selected = -1
		out.sel_wire = -1

	case PanBy:
		out.pan += v.d

	case EndPan:
		out.panning = false

	case Zoom:
		nz := clamp(out.zoom * v.factor, 0.3, 3)
		// Keep the graph point under the cursor fixed while zooming.
		g := (v.at - v.origin - out.pan) / out.zoom
		out.pan = v.at - v.origin - g * nz
		out.zoom = nz

	case StartWire:
		out.wire_from = v.id

	case EndWire:
		if out.wire_from >= 0 && v.target >= 0 && v.target != out.wire_from {
			// Replace any existing wire into the target's input, then connect.
			for i := len(out.wires) - 1; i >= 0; i -= 1 {
				if out.wires[i].to == v.target { ordered_remove(&out.wires, i) }
			}
			append(&out.wires, Wire{from = out.wire_from, to = v.target})
		}
		out.wire_from = -1
		out.sel_wire = -1 // wire indices shifted

	case SelectWire:
		out.sel_wire = v.idx
		out.selected = -1

	case DeleteNode:
		if idx := index_of(&out, v.id); idx >= 0 {
			ordered_remove(&out.nodes, idx)
		}
		for i := len(out.wires) - 1; i >= 0; i -= 1 {
			if out.wires[i].from == v.id || out.wires[i].to == v.id {
				ordered_remove(&out.wires, i)
			}
		}
		if out.selected == v.id { out.selected = -1 }
		if out.drag_node == v.id { out.drag_node = -1 }
		out.sel_wire = -1 // wire indices shifted

	case DeleteWireAt:
		if v.idx >= 0 && v.idx < len(out.wires) { ordered_remove(&out.wires, v.idx) }
		out.sel_wire = -1

	case StartRename:
		n, _ := node_by_id(&out, v.id)
		out.editing = v.id
		out.edit_buf = strings.clone(n.title)
		// Entering edit mode cancels any in-flight canvas gesture.
		out.drag_node = -1
		out.panning = false
		out.wire_from = -1

	case RenameEdit:
		out.edit_buf = strings.clone(v.text) // clone: the Msg string is transient

	case CommitRename:
		if idx := index_of(&out, out.editing); idx >= 0 {
			out.nodes[idx].title = out.edit_buf
		}
		out.editing = -1

	case CancelRename:
		out.editing = -1
	}
	return out, {}
}

on_rename :: proc(v: string) -> Msg { return RenameEdit{v} }

index_of :: proc(s: ^State, id: int) -> int {
	for n, i in s.nodes { if n.id == id { return i } }
	return -1
}

// ---- paint ----------------------------------------------------------------

paint :: proc(s: ^State, p: skald.Canvas_Painter) {
	th := skald.theme_dark()
	b := p.bounds
	skald.draw_rect(p.r, b, th.color.bg, 0)

	// Grid: faint lines every 40 graph units, following pan/zoom.
	grid := skald.rgba(0xffffff12)
	step := 40 * s.zoom
	if step >= 6 {
		ox := math.mod(s.pan.x, step); if ox < 0 { ox += step }
		for x := b.x + ox; x < b.x + b.w; x += step {
			skald.draw_line(p.r, {x, b.y}, {x, b.y + b.h}, 1, grid)
		}
		oy := math.mod(s.pan.y, step); if oy < 0 { oy += step }
		for y := b.y + oy; y < b.y + b.h; y += step {
			skald.draw_line(p.r, {b.x, y}, {b.x + b.w, y}, 1, grid)
		}
	}

	// Wires (behind nodes). The selected wire draws thicker in the accent colour.
	for w, i in s.wires {
		fn, ok1 := node_by_id(s, w.from)
		tn, ok2 := node_by_id(s, w.to)
		if !ok1 || !ok2 { continue }
		a := to_screen(out_center(fn), b_origin(b), s.pan, s.zoom)
		d := to_screen(in_center(tn),  b_origin(b), s.pan, s.zoom)
		col := th.color.fg_muted
		ww  := f32(2)
		if i == s.sel_wire { col = th.color.primary; ww = 3.5 }
		draw_wire(p.r, a, d, col, s.zoom, ww)
	}
	// Live wire being dragged.
	if s.wire_from >= 0 {
		if fn, ok := node_by_id(s, s.wire_from); ok {
			a := to_screen(out_center(fn), b_origin(b), s.pan, s.zoom)
			draw_wire(p.r, a, s.cursor_screen, th.color.primary, s.zoom)
		}
	}

	// Nodes.
	for n in s.nodes {
		tl := to_screen(n.pos, b_origin(b), s.pan, s.zoom)
		rect := skald.Rect{tl.x, tl.y, NODE_W * s.zoom, NODE_H * s.zoom}
		rad := 8 * s.zoom
		skald.draw_rect(p.r, rect, th.color.surface, rad)
		if s.selected == n.id {
			skald.draw_rect_outline(p.r, rect, 2, th.color.primary, rad, true)
		} else {
			skald.draw_rect_outline(p.r, rect, 1, th.color.border, rad, true)
		}
		skald.draw_text(p.r, n.title, rect.x + 12 * s.zoom, rect.y + 10 * s.zoom,
			th.color.fg, 14 * s.zoom)

		ic := to_screen(in_center(n),  b_origin(b), s.pan, s.zoom)
		oc := to_screen(out_center(n), b_origin(b), s.pan, s.zoom)
		skald.draw_circle(p.r, ic, PORT_R * s.zoom, th.color.fg_muted, true)
		skald.draw_circle(p.r, oc, PORT_R * s.zoom, th.color.primary, true)
	}
}

b_origin :: proc(b: skald.Rect) -> [2]f32 { return {b.x, b.y} }

// draw_wire is the classic node-editor cubic: horizontal tangents at both ends.
draw_wire :: proc(r: ^skald.Renderer, a, d: [2]f32, color: skald.Color, zoom: f32, w: f32 = 2) {
	dx := abs(d.x - a.x) * 0.5 + 24 * zoom
	skald.draw_bezier(r, a, {a.x + dx, a.y}, {d.x - dx, d.y}, d, w * zoom, color, true)
}

// ---- view -----------------------------------------------------------------

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	cid := skald.hash_id("node-canvas")
	last := skald.widget_get(ctx, cid, .Canvas).last_rect

	// Refresh the painter snapshot (temp copy; see below).
	snap := new(State, context.temp_allocator)
	snap^ = s
	snap.cursor_screen = ctx.input.mouse_pos

	// Input: poll ctx.input, hit-test in graph space, post Msgs. Guarded on a
	// laid-out canvas (last_rect is zero on the very first frame).
	origin := [2]f32{last.x, last.y}
	vs := s // addressable copy for the ^State helpers (params aren't addressable)
	if last.w > 0 {
		if s.editing >= 0 {
			// Renaming: the field owns typing; commit/cancel on Enter/Escape.
			// Canvas gestures are suppressed so a click doesn't drag underneath.
			if .Enter  in ctx.input.keys_pressed { skald.send(ctx, CommitRename{}) }
			if .Escape in ctx.input.keys_pressed { skald.send(ctx, CancelRename{}) }
		} else {
			mouse := ctx.input.mouse_pos
			g := to_graph(mouse, origin, s.pan, s.zoom)
			inside := skald.rect_contains_point(last, mouse)

			if inside && ctx.input.mouse_pressed[.Left] {
				nid := node_at(&vs, g)
				if nid >= 0 && ctx.input.mouse_click_count[.Left] >= 2 {
					skald.send(ctx, StartRename{nid})
				} else if oid := port_at(&vs, g, true); oid >= 0 {
					skald.send(ctx, StartWire{oid})
				} else if nid >= 0 {
					n, _ := node_by_id(&vs, nid)
					skald.send(ctx, PickNode{nid, g - n.pos})
				} else if wid := wire_at(&vs, origin, mouse); wid >= 0 {
					skald.send(ctx, SelectWire{wid})
				} else {
					skald.send(ctx, StartPan{})
				}
			}
			if inside && ctx.input.mouse_pressed[.Right] {
				if nid := node_at(&vs, g); nid >= 0 { skald.send(ctx, DeleteNode{nid}) }
			}
			if ctx.input.mouse_buttons[.Left] {
				if s.drag_node >= 0 {
					skald.send(ctx, MoveNode{g})
				} else if s.panning {
					skald.send(ctx, PanBy{ctx.input.mouse_delta})
				}
			}
			if ctx.input.mouse_released[.Left] {
				if s.wire_from >= 0 {
					skald.send(ctx, EndWire{port_at(&vs, g, false)})
				} else if s.drag_node >= 0 {
					skald.send(ctx, EndDrag{})
				} else if s.panning {
					skald.send(ctx, EndPan{})
				}
			}
			if inside && ctx.input.scroll.y != 0 {
				skald.send(ctx, Zoom{1 + ctx.input.scroll.y * 0.1, mouse, origin})
			}
			if .Delete in ctx.input.keys_pressed {
				if s.selected >= 0 {
					skald.send(ctx, DeleteNode{s.selected})
				} else if s.sel_wire >= 0 {
					skald.send(ctx, DeleteWireAt{s.sel_wire})
				}
			}
		}
	}

	// Cursor per interaction mode (Cursor_Shape is exported, so we can store it).
	cursor := skald.Cursor_Shape.Default
	switch {
	case s.panning:        cursor = .Move
	case s.wire_from >= 0: cursor = .Crosshair
	}

	// Rename field: a real text_input pinned over the node via overlay(pin).
	// It floats at an exact computed spot rather than repositioning like a
	// popover. Layout-invisible (overlay size is zero), so it's just a sibling.
	edit_id := skald.hash_id("node-rename-field")
	edit_layer: skald.View = skald.spacer(0)
	if s.editing >= 0 {
		if fn, ok := node_by_id(&vs, s.editing); ok {
			tl := to_screen(fn.pos, origin, s.pan, s.zoom)
			fw := max(NODE_W * s.zoom - 12, 90)
			field := skald.text_input(ctx, s.edit_buf, on_rename, id = edit_id, width = fw)
			edit_layer = skald.overlay(
				skald.Rect{tl.x + 6, tl.y + 8, 0, 0}, field, pin = true)
			// Focus it the frame it appears (the double-click landed on the
			// canvas, not the field, so it won't auto-focus itself).
			if !skald.widget_has_focus(ctx, edit_id) { skald.widget_focus(ctx, edit_id) }
		}
	}

	return skald.col(
		skald.row(
			skald.text(
				"drag node • drag empty space to pan • scroll to zoom • drag output→input port to wire • click node/wire to select, Del deletes • double-click to rename • right-click deletes node",
				th.color.fg_muted, th.font.size_sm),
			padding = th.spacing.md,
		),
		skald.flex(1, skald.canvas(ctx, snap, paint, id = cid, cursor = cursor)),
		edit_layer,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Node graph",
		size   = {960, 640},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
