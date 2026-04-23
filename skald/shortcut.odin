package skald

import "core:fmt"
import "core:strings"

// Shortcut is a keyboard chord: a non-modifier key plus any required
// modifiers. Zero-value (`Shortcut{}` → `.Backspace` + no mods) is
// reserved as the "no shortcut" sentinel for menu items that don't
// expose a hotkey — so a bare Backspace shortcut isn't expressible
// directly. Register Backspace via an explicit `{key=.Backspace, mods={.Shift}}`
// or similar combo if you genuinely need it.
Shortcut :: struct {
	key:  Key,
	mods: Modifiers,
}

@(private)
shortcut_is_empty :: proc(s: Shortcut) -> bool {
	return s.key == .Backspace && s.mods == {}
}

// shortcut registers a keyboard chord for the current frame. When the
// chord fires (matching modifiers + the non-modifier key in
// `keys_pressed`), `msg` is pushed onto the ctx's queue and the key is
// consumed — removed from `keys_pressed` so widgets built later in the
// view tree don't double-handle it. Call order matters: shortcuts only
// pre-empt widgets that come after them in the view, so place
// top-level shortcuts at the top of your `view` proc.
//
//     view :: proc(s: State, ctx: ^Ctx(Msg)) -> View {
//         skald.shortcut(ctx, {.S, {.Ctrl}}, Msg_Save)
//         skald.shortcut(ctx, {.O, {.Ctrl}}, Msg_Open)
//         return skald.col(...)
//     }
//
// Modifiers matching is exact: `{.Ctrl}` only fires when Ctrl alone is
// held — press Ctrl+Shift+S and it won't. This keeps accelerators
// unambiguous and matches every platform's menu shortcut convention.
shortcut :: proc(ctx: ^Ctx($Msg), chord: Shortcut, msg: Msg) {
	if shortcut_is_empty(chord) { return }
	if chord.key not_in ctx.input.keys_pressed { return }
	if ctx.input.modifiers != chord.mods         { return }

	send(ctx, msg)
	ctx.input.keys_pressed -= {chord.key}
}

// shortcut_format renders a chord as its conventional display string
// — "Ctrl+S", "Ctrl+Shift+Z", "Alt+F4", etc. Used by menu_bar to paint
// hints next to item labels; apps can call it directly when rolling
// their own menus or tooltips. Output lives in the frame temp arena.
shortcut_format :: proc(s: Shortcut) -> string {
	if shortcut_is_empty(s) { return "" }

	parts: [dynamic]string
	parts.allocator = context.temp_allocator
	if .Ctrl  in s.mods { append(&parts, "Ctrl")  }
	if .Shift in s.mods { append(&parts, "Shift") }
	if .Alt   in s.mods { append(&parts, "Alt")   }
	if .Super in s.mods { append(&parts, "Super") }
	append(&parts, key_display_name(s.key))

	return strings.join(parts[:], "+", context.temp_allocator)
}

@(private)
key_display_name :: proc(k: Key) -> string {
	switch k {
	case .Backspace: return "Backspace"
	case .Delete:    return "Del"
	case .Left:      return "Left"
	case .Right:     return "Right"
	case .Up:        return "Up"
	case .Down:      return "Down"
	case .Home:      return "Home"
	case .End:       return "End"
	case .Page_Up:   return "PageUp"
	case .Page_Down: return "PageDown"
	case .Enter:     return "Enter"
	case .Tab:       return "Tab"
	case .Escape:    return "Esc"
	case .Space:     return "Space"
	case .A: return "A"; case .B: return "B"; case .C: return "C"; case .D: return "D"
	case .E: return "E"; case .F: return "F"; case .G: return "G"; case .H: return "H"
	case .I: return "I"; case .J: return "J"; case .K: return "K"; case .L: return "L"
	case .M: return "M"; case .N: return "N"; case .O: return "O"; case .P: return "P"
	case .Q: return "Q"; case .R: return "R"; case .S: return "S"; case .T: return "T"
	case .U: return "U"; case .V: return "V"; case .W: return "W"; case .X: return "X"
	case .Y: return "Y"; case .Z: return "Z"
	case .N0: return "0"; case .N1: return "1"; case .N2: return "2"
	case .N3: return "3"; case .N4: return "4"; case .N5: return "5"
	case .N6: return "6"; case .N7: return "7"; case .N8: return "8"; case .N9: return "9"
	case .F1:  return "F1";  case .F2:  return "F2";  case .F3:  return "F3"
	case .F4:  return "F4";  case .F5:  return "F5";  case .F6:  return "F6"
	case .F7:  return "F7";  case .F8:  return "F8";  case .F9:  return "F9"
	case .F10: return "F10"; case .F11: return "F11"; case .F12: return "F12"
	}
	return fmt.tprintf("%v", k)
}
