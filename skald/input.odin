package skald

// Input is a snapshot of user interaction during the current frame. It is
// regenerated each call to `window_pump` — the runtime preserves fields
// that describe current state (button held, mouse position, keys held)
// across frames and resets edge-triggered fields (pressed/released, scroll
// delta, text) at the start of each pump so a frame that sees
// `mouse_pressed[.Left]` will see it exactly once.
//
// Coordinate conventions:
//   * mouse_pos / mouse_delta are in *logical pixels*, matching the
//     coordinate space that layout and rendering use. On a 1× display
//     logical == physical; on HiDPI the renderer maps logical → physical
//     at the framebuffer boundary so app code never sees the pixel ratio.
//   * scroll is in SDL's wheel units (lines/ticks), not pixels. Callers
//     pick their own multiplier.
Input :: struct {
	mouse_pos:       [2]f32,
	mouse_delta:     [2]f32,

	// mouse_physical_moved is an edge flag set when a MOUSE_MOTION event
	// arrived this frame from a real mouse, not from SDL's pen/touch
	// synthesis. Default SDL settings route pen taps through the mouse
	// event stream (SDL_HINT_PEN_MOUSE_EVENTS = on) so that widgets
	// written for mouse just work with a stylus — but that means
	// `mouse_delta` alone can't tell you whether the user is driving
	// with the mouse or the pen. Apps that need that distinction (e.g.
	// a canvas deciding whether to hide the OS cursor) read this flag.
	// Set by checking the event's `which` field against
	// sdl3.PEN_MOUSEID / sdl3.TOUCH_MOUSEID before the rest of the
	// mouse-motion bookkeeping.
	mouse_physical_moved: bool,

	mouse_buttons:      [Mouse_Button]bool,
	mouse_pressed:      [Mouse_Button]bool,
	mouse_released:     [Mouse_Button]bool,
	// mouse_click_count carries the click streak reported by SDL for the
	// most recent press this frame: 1 single, 2 double, 3 triple, etc.
	// Defined only when the matching `mouse_pressed[btn]` is true — the
	// value is stale otherwise, and should not be read.
	mouse_click_count:  [Mouse_Button]u8,

	scroll:          [2]f32,

	// text is the concatenated UTF-8 text input produced this frame. It
	// lives in the frame arena and is cleared each pump.
	text:            string,

	// Keyboard state. `keys_down` tracks currently-held keys (level). The
	// other two are edge-triggered — they contain only keys whose state
	// *changed* during this frame, and are cleared at the start of every
	// pump. `keys_pressed` also includes OS auto-repeat events so that
	// holding Backspace deletes repeatedly without bespoke timer logic in
	// widget code.
	keys_down:       Keys,
	keys_pressed:    Keys,
	keys_released:   Keys,

	modifiers:       Modifiers,

	// OS drag-and-drop. `dropped_files` is populated when the user
	// releases one or more files over the window — the slice lives in
	// the frame arena and is cleared at the start of each pump, same
	// lifetime rules as `text`. `drop_pos` is in logical pixels.
	// `drag_active` + `drag_pos` track a drag *in progress*, before
	// release: window managers emit position updates while files hover
	// over the window so drop targets can paint highlights. Both go
	// back to their zero state on DROP_COMPLETE or if the user releases
	// outside the window.
	dropped_files: []string,
	drop_pos:      [2]f32,
	drag_active:   bool,
	drag_pos:      [2]f32,

	// Pressure-sensitive pen / stylus input. Fields here mirror the
	// mouse convention: *_down is level-triggered (held across frames),
	// *_pressed / *_released are edge-triggered (cleared each pump).
	//
	// `pen_in_proximity` latches between PROXIMITY_IN and PROXIMITY_OUT
	// so a canvas can render a cursor ring while the pen hovers.
	// `pen_down` latches between the pen tip touching the surface and
	// lifting off — the drawing-in-progress flag.
	//
	// `pen_pressure` is 0..1 (unidirectional). It's updated by PEN_AXIS
	// events and defaults to 1.0 on PEN_DOWN so pens without pressure
	// support still produce a visible stroke.
	// `pen_tilt` is degrees, both axes bidirectional (-90..90).
	// `pen_eraser` mirrors the eraser-tip flag — apps typically swap
	// tools when it flips to true.
	//
	// Barrel buttons (1..5 in SDL) are surfaced as flat arrays here —
	// indexed by button number minus one, so `pen_buttons_down[0]` is
	// button 1. Most styluses expose one or two.
	//
	// Pen coordinates are logical pixels, same space as `mouse_pos`. SDL
	// also synthesises mouse events from pen input by default; apps that
	// want to treat them separately should look at `pen_down` alongside
	// `mouse_buttons[.Left]` and prefer the pen path when active.
	pen_in_proximity:     bool,
	pen_down:             bool,
	pen_pressed:          bool,
	pen_released:         bool,
	pen_eraser:           bool,
	pen_pos:              [2]f32,
	pen_pressure:         f32,
	pen_tilt:             [2]f32,
	pen_buttons_down:     [5]bool,
	pen_buttons_pressed:  [5]bool,
	pen_buttons_released: [5]bool,

	// Per-event pen trajectory for the current frame, in SDL event order.
	// Stylus hardware reports at 200–1000 Hz; the UI typically runs at
	// 60. Without this buffer, apps only see the last-per-frame position
	// and fast pen motion produces long straight segments (the stroke
	// looks like it "picks up speed" when velocity is high). Canvas apps
	// iterate this list to emit a sample-per-event so the rendered
	// ribbon follows the real pen path.
	//
	// The buffer is cleared at the start of each pump and grown in place
	// — the backing allocation persists across frames so steady-state
	// pen traffic doesn't churn the heap. The last entry's position is
	// the same value that `pen_pos` holds; apps that only need a cursor
	// hover can keep reading `pen_pos` and ignore this list.
	pen_samples:          [dynamic]Pen_Sample,
}

// Pen_Sample is one entry in the per-frame pen trajectory. `pos` is in
// logical pixels (same space as `pen_pos`), `pressure` is 0..1 to match
// the `pen_pressure` scalar, `tilt` is degrees on each axis (-90..90),
// and `eraser` is true when the sample was produced by the eraser tip
// of the stylus. `down` latches whether the pen tip was touching the
// surface at the moment the event fired — apps use it to distinguish
// hover-path samples from drawing samples without re-checking edge
// flags. Shape mirrors the corresponding scalar fields on `Input` so
// callers can copy samples around without a conversion layer.
Pen_Sample :: struct {
	pos:      [2]f32,
	pressure: f32,
	tilt:     [2]f32,
	eraser:   bool,
	down:     bool,
}

// Mouse_Button identifies which physical mouse button produced an
// event. The three-button minimum matches every supported platform;
// extended buttons (back/forward) aren't surfaced yet.
Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
}

// Modifier is one of the chord keys Skald tracks. Ctrl/Shift/Alt are
// physical keys; Super is the platform "meta" key (Command on macOS,
// Windows/Super/Win on Linux + Windows) so shortcut code can stay
// platform-agnostic.
Modifier :: enum {
	Shift,
	Ctrl,
	Alt,
	Super,
}

// Modifiers is the set of chord keys currently held. Most widgets test
// for membership like `.Ctrl in ctx.input.modifiers`.
Modifiers :: bit_set[Modifier]

// Key is the subset of keyboard keys Skald surfaces to application and
// widget code. Text entry itself flows through `Input.text` (UTF-8); this
// enum is for the editing controls that aren't characters — cursor motion,
// deletion, confirmation — plus the full alphabet + digits so apps can
// register `Ctrl-S` / `Cmd-N` / `Ctrl-1` style shortcuts through
// `skald.shortcut`.
//
// The bit_set storage stays a single 64-bit word — 14 editing keys + 26
// letters + 10 digits = 50 variants, which fits in u64 with room to
// spare for future additions (function keys, etc.).
Key :: enum u8 {
	Backspace,
	Delete,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
	Enter,
	Tab,
	Escape,
	Space,

	// Full alphabet and digit row for shortcut wiring. Typed characters
	// still arrive as UTF-8 via `Input.text`; these enum values are for
	// discrete-event checks like "Ctrl-S pressed this frame."
	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	N0, N1, N2, N3, N4, N5, N6, N7, N8, N9,

	// Function keys — F11 is the fullscreen convention on Linux/Windows,
	// F12 is the in-app debug inspector. Apps can bind any of these via
	// `shortcut` for their own actions.
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

// Keys is the set-valued companion to `Key`. `ctx.input.keys_pressed`
// holds keys that transitioned to pressed this frame (edge-triggered);
// `ctx.input.keys_down` holds keys currently held (level-triggered).
Keys :: bit_set[Key]

// input_reset_edges clears the edge-triggered fields. Called from
// `window_pump` before polling new events so each frame observes clean
// pressed/released/scroll/text values.
@(private)
input_reset_edges :: proc(in_: ^Input) {
	in_.mouse_delta          = {0, 0}
	in_.mouse_physical_moved = false
	in_.mouse_pressed        = {}
	in_.mouse_released       = {}
	in_.mouse_click_count    = {}
	in_.scroll         = {0, 0}
	in_.text           = ""
	in_.keys_pressed   = {}
	in_.keys_released  = {}
	// `dropped_files` is edge-triggered (each frame sees a fresh batch or
	// none); `drag_active` / `drag_pos` are *state* and persist across
	// pumps, so they are not cleared here.
	in_.dropped_files = nil

	// Pen edges. Level fields (pen_down, pen_in_proximity, pen_eraser,
	// pen_pos, pen_pressure, pen_tilt, pen_buttons_down) persist across
	// frames until the hardware changes them.
	in_.pen_pressed          = false
	in_.pen_released         = false
	in_.pen_buttons_pressed  = {}
	in_.pen_buttons_released = {}
	// Per-event pen trajectory is a fresh batch each frame — truncate
	// length but keep the backing allocation so steady-state stylus
	// traffic doesn't reallocate every pump.
	clear(&in_.pen_samples)
}
