package skald

// push_clip pushes a pixel-aligned clip rectangle onto the clip stack. All
// subsequent draw calls (draw_rect, draw_text, …) are scissored to the
// intersection of every rect currently on the stack. Pop the rect with
// `pop_clip` to restore the previous clip.
//
// Typical use is a two-sided bracket: push before a scrollable or bounded
// container renders its children, pop when it's done. Nested pushes are
// safe — each push intersects with the current top.
//
// The clip is expressed in pixel coordinates with origin top-left, matching
// the coordinate system used by `draw_rect` and `draw_text`.
push_clip :: proc(r: ^Renderer, rect: Rect) {
	new_rect: Rect
	if len(r.batch.clip_stack) == 0 {
		new_rect = rect
	} else {
		new_rect = rect_intersect(r.batch.clip_stack[len(r.batch.clip_stack) - 1], rect)
	}
	append(&r.batch.clip_stack, new_rect)
	clip_open_range(r, new_rect)
}

// pop_clip pops the most recent `push_clip`. If that empties the stack the
// scissor reverts to the full framebuffer.
pop_clip :: proc(r: ^Renderer) {
	if len(r.batch.clip_stack) == 0 { return }
	pop(&r.batch.clip_stack)

	new_rect: Rect
	if len(r.batch.clip_stack) == 0 {
		new_rect = Rect{0, 0, f32(r.fb_size.x), f32(r.fb_size.y)}
	} else {
		new_rect = r.batch.clip_stack[len(r.batch.clip_stack) - 1]
	}
	clip_open_range(r, new_rect)
}

// clip_open_range starts a new Batch_Range with the given clip rect. If the
// current range is still empty (no draws since it opened) the clip is
// updated in place — avoids a zero-length scissored draw when callers push
// clips around empty sections.
@(private)
clip_open_range :: proc(r: ^Renderer, rect: Rect) {
	scissor := rect_to_scissor(rect, r.fb_size_px, r.scale)
	n := len(r.batch.ranges)
	if n > 0 && r.batch.ranges[n - 1].index_start == u32(len(r.batch.indices)) {
		r.batch.ranges[n - 1].clip = scissor
		return
	}
	append(&r.batch.ranges, Batch_Range{
		clip        = scissor,
		index_start = u32(len(r.batch.indices)),
	})
}

@(private)
rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 {
		return Rect{0, 0, 0, 0}
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// rect_to_scissor converts a logical-pixel rect into physical-pixel scissor
// extents suitable for Vulkan's CmdSetScissor. `fb_px` is the backing
// framebuffer size in physical pixels (what the swapchain was configured
// with). `scale` is the display scale factor — on 1× displays it's 1.0 and
// the conversion is identity; on HiDPI it multiplies up so the scissor
// rect covers the same visible region as the logical rect. Clamping is
// done in physical pixels so oversized rects don't leak past the edge of
// the actual attachment.
@(private)
rect_to_scissor :: proc(rect: Rect, fb_px: [2]u32, scale: f32) -> [4]u32 {
	x0 := max(0, int(rect.x * scale))
	y0 := max(0, int(rect.y * scale))
	x1 := min(int(fb_px.x), int((rect.x + rect.w) * scale))
	y1 := min(int(fb_px.y), int((rect.y + rect.h) * scale))
	if x1 <= x0 || y1 <= y0 {
		return {0, 0, 0, 0}
	}
	return {u32(x0), u32(y0), u32(x1 - x0), u32(y1 - y0)}
}
