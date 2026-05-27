package skald

import "core:testing"

@(test)
outside_press_blurs_focused_widget :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)

	id := Widget_ID(1)
	ws.focused_id = id
	ws.states[id] = Widget_State {
		kind       = .Button,
		last_rect  = {x = 10, y = 10, w = 80, h = 24},
		last_frame = ws.frame,
	}

	input := Input{mouse_pos = {200, 200}}
	input.mouse_pressed[.Left] = true

	widget_store_frame_reset(&ws)
	widget_store_blur_on_outside_press(&ws, input)

	testing.expect_value(t, ws.focused_id, Widget_ID(0))
}

@(test)
press_inside_overlay_keeps_focus :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)

	id := Widget_ID(1)
	ws.focused_id = id
	ws.states[id] = Widget_State {
		kind       = .Select,
		last_rect  = {x = 10, y = 10, w = 120, h = 28},
		last_frame = ws.frame,
	}
	append(&ws.overlay_rects, Rect{x = 10, y = 42, w = 120, h = 90})

	input := Input{mouse_pos = {20, 60}}
	input.mouse_pressed[.Left] = true

	widget_store_frame_reset(&ws)
	widget_store_blur_on_outside_press(&ws, input)

	testing.expect_value(t, ws.focused_id, id)
}
