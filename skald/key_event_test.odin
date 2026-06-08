package skald

// White-box tests for key_events_for — the edge→Key_Event mapping behind
// the App.on_key hook: press/release edges, modifier stamping, and the
// empty case. Bare modifiers can't appear here (they're not `Key`s), so a
// non-empty press set is always a real key.

import "core:testing"

@(test)
key_events_press_and_release :: proc(t: ^testing.T) {
	in_ := Input{
		keys_pressed  = {.A, .Enter},
		keys_released = {.Escape},
		modifiers     = {.Ctrl, .Shift},
	}
	evs := make([dynamic]Key_Event, 0, 8)
	defer delete(evs)
	key_events_for(in_, &evs)

	testing.expect_value(t, len(evs), 3)

	// Two presses + one release, all carrying the held modifiers.
	presses, releases := 0, 0
	saw_a, saw_enter, saw_escape := false, false, false
	for ev in evs {
		testing.expect(t, ev.mods == Modifiers{.Ctrl, .Shift},
			"modifiers should be stamped on every event")
		if ev.pressed {
			presses += 1
			if ev.key == .A     { saw_a = true }
			if ev.key == .Enter { saw_enter = true }
		} else {
			releases += 1
			if ev.key == .Escape { saw_escape = true }
		}
	}
	testing.expect_value(t, presses, 2)
	testing.expect_value(t, releases, 1)
	testing.expect(t, saw_a && saw_enter, "both pressed keys present")
	testing.expect(t, saw_escape, "released key present and marked !pressed")
}

@(test)
key_events_empty_input :: proc(t: ^testing.T) {
	evs := make([dynamic]Key_Event, 0, 4)
	defer delete(evs)
	key_events_for(Input{}, &evs)
	testing.expect_value(t, len(evs), 0)
}

@(test)
key_events_no_modifiers :: proc(t: ^testing.T) {
	evs := make([dynamic]Key_Event, 0, 4)
	defer delete(evs)
	key_events_for(Input{keys_pressed = {.F5}}, &evs)
	testing.expect_value(t, len(evs), 1)
	testing.expect_value(t, evs[0].key, Key.F5)
	testing.expect_value(t, evs[0].pressed, true)
	testing.expect(t, evs[0].mods == Modifiers{}, "no modifiers held")
}
