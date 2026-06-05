package skald

// White-box tests for the embedded backend's input feed: input_begin +
// input_feed_* must populate the same Input fields the SDL pump does, with
// the same once-per-frame edge / persistent-level convention.

import "core:testing"
import vk "vendor:vulkan"

@(test)
embedded_pointer_button_edges :: proc(t: ^testing.T) {
	w: Window

	// Frame 1: press.
	input_begin(&w)
	input_feed_pointer_motion(&w, {30, 25})
	input_feed_pointer_button(&w, .Left, true, 1)
	testing.expect(t, w.input.mouse_buttons[.Left],  "held after press")
	testing.expect(t, w.input.mouse_pressed[.Left],  "press edge set")
	testing.expect(t, !w.input.mouse_released[.Left], "no release yet")
	testing.expect_value(t, w.input.mouse_pos, [2]f32{30, 25})
	testing.expect_value(t, w.input.mouse_click_count[.Left], u8(1))

	// Frame 2: edges cleared, level state persists.
	input_begin(&w)
	testing.expect(t, w.input.mouse_buttons[.Left],  "still held across frames")
	testing.expect(t, !w.input.mouse_pressed[.Left], "press edge cleared next frame")

	// Frame 2: release.
	input_feed_pointer_button(&w, .Left, false)
	testing.expect(t, !w.input.mouse_buttons[.Left], "release clears held")
	testing.expect(t, w.input.mouse_released[.Left], "release edge set")
}

@(test)
embedded_motion_delta_resets :: proc(t: ^testing.T) {
	w: Window
	input_begin(&w)
	input_feed_pointer_motion(&w, {10, 10})
	input_begin(&w) // delta is an edge — clears each frame
	input_feed_pointer_motion(&w, {15, 13})
	testing.expect_value(t, w.input.mouse_pos,   [2]f32{15, 13})
	testing.expect_value(t, w.input.mouse_delta, [2]f32{5, 3})
}

@(test)
embedded_keys_press_repeat_release :: proc(t: ^testing.T) {
	w: Window
	input_begin(&w)
	input_feed_key(&w, .Enter, true, false)
	testing.expect(t, .Enter in w.input.keys_pressed, "press edge")
	testing.expect(t, .Enter in w.input.keys_down,    "held latched")

	input_begin(&w)
	testing.expect(t, .Enter not_in w.input.keys_pressed, "press edge cleared")
	testing.expect(t, .Enter in w.input.keys_down,        "still held")
	input_feed_key(&w, .Enter, true, true) // auto-repeat
	testing.expect(t, .Enter in w.input.keys_pressed, "repeat re-sets press edge")

	input_begin(&w)
	input_feed_key(&w, .Enter, false)
	testing.expect(t, .Enter in w.input.keys_released, "release edge")
	testing.expect(t, .Enter not_in w.input.keys_down, "held cleared")
}

@(test)
embedded_text_and_scroll_accumulate :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: Window
	input_begin(&w)
	input_feed_text(&w, "ab")
	input_feed_text(&w, "c")
	testing.expect_value(t, w.input.text, "abc")
	input_feed_scroll(&w, {0, 1})
	input_feed_scroll(&w, {0, 2})
	testing.expect_value(t, w.input.scroll, [2]f32{0, 3})

	input_begin(&w) // both are edges — cleared
	testing.expect_value(t, len(w.input.text), 0)
	testing.expect_value(t, w.input.scroll, [2]f32{0, 0})
}

@(test)
embedded_window_init :: proc(t: ^testing.T) {
	cfg := Embedded_Config{
		get_instance_proc_addr = rawptr(uintptr(1)), // non-nil stub
		create_surface = proc(instance: vk.Instance, user: rawptr) -> (vk.SurfaceKHR, bool) {
			return 0, true
		},
		size_px = {1920, 48},
		scale   = 2.0,
	}
	w, ok := window_init_embedded(cfg)
	testing.expect(t, ok, "init ok with required callbacks")
	testing.expect(t, w.embedded, "embedded flag set")
	testing.expect(t, w.handle == nil, "no SDL window")
	testing.expect_value(t, w.size_logical, [2]u32{960, 24}) // size_px / scale

	_, bad := window_init_embedded(Embedded_Config{size_px = {100, 100}})
	testing.expect(t, !bad, "missing get_proc / create_surface → not ok")
}
