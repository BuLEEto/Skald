package example_file_viewer

import "core:fmt"
import "core:strings"
import "gui:skald"

// Async file viewer, built on top of Phase 9's `cmd_read_file`. The
// point is to demonstrate the Command/Effect plumbing end-to-end: a
// button click returns a Command, the runtime hands it to `core:nbio`,
// and the completion comes back as a regular Msg some number of frames
// later — exactly like a delayed msg or a batch.
//
// Flow:
//   type a path in the field → press Load (or Enter) → state flips
//   to .Loading → the nbio completion lands as File_Loaded or
//   File_Error → state flips to .Loaded / .Error and the body pane
//   renders either the contents or the error string.
//
// Memory contract: `cmd_read_file` hands us heap-allocated bytes on the
// persistent allocator. `update` takes ownership by cloning into
// `contents` (a persistent string) and `delete`-ing the old one, same
// pattern as the text_input examples. The bytes from nbio get freed
// after we clone — the handler is responsible for not leaking them.

Load_Status :: enum { Idle, Loading, Loaded, Error }

State :: struct {
	path:     string,
	contents: string,
	error:    string,
	status:   Load_Status,
}

Msg :: union {
	Path_Changed,
	Path_Segment_Clicked,
	Load_Clicked,
	File_Loaded,
	File_Failed,
}

Path_Changed         :: distinct string
Path_Segment_Clicked :: distinct int
Load_Clicked         :: struct{}
File_Loaded          :: distinct string  // full contents, owned by the msg
File_Failed          :: distinct string  // error description

init :: proc() -> State {
	return {
		path     = strings.clone("/etc/hostname"),
		contents = strings.clone(""),
		error    = strings.clone(""),
		status   = .Idle,
	}
}

// on_read translates a File_Read_Result into the app's Msg union. This
// is what gets handed to `cmd_read_file`. The bytes are owned by the
// handler (us) — we clone into persistent storage here and free the
// original buffer so the result doesn't leak.
on_read :: proc(r: skald.File_Read_Result) -> Msg {
	if r.err != .None {
		msg := fmt.aprintf("read failed: %v", r.err)
		return File_Failed(msg)
	}
	// Clone into a persistent, null-terminated-friendly string. The
	// nbio buffer is ours to release.
	s, _ := strings.clone_from_bytes(r.bytes)
	delete(r.bytes)
	return File_Loaded(s)
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Path_Changed:
		delete(out.path)
		out.path = strings.clone(string(v))
		return out, {}

	case Path_Segment_Clicked:
		// Truncate the path at segment `v`. The breadcrumb builder
		// indexes the segments it was handed; we re-derive them here
		// from the same source (the current path) to pick the cut.
		idx := int(v)
		segs := path_segments(out.path)
		defer delete(segs)
		if idx < len(segs) {
			joined := strings.join(segs[:idx+1], "/")
			defer delete(joined)
			prefix := "/" if strings.has_prefix(out.path, "/") else ""
			new_path := strings.concatenate({prefix, joined})
			delete(out.path)
			out.path = new_path
		}
		return out, {}

	case Load_Clicked:
		if len(out.path) == 0 { return out, {} }
		out.status = .Loading
		delete(out.error); out.error = strings.clone("")
		return out, skald.cmd_read_file(out.path, on_read)

	case File_Loaded:
		delete(out.contents)
		// The Msg payload was persistent-allocated in `on_read` and
		// now becomes owned by state — no re-clone.
		out.contents = string(v)
		out.status   = .Loaded
		return out, {}

	case File_Failed:
		delete(out.error)
		out.error  = string(v)
		out.status = .Error
		return out, {}
	}
	return out, {}
}

on_path       :: proc(s: string) -> Msg { return Path_Changed(s) }
on_path_click :: proc(i: int)    -> Msg { return Path_Segment_Clicked(i) }

path_crumbs :: proc(ctx: ^skald.Ctx(Msg), p: string) -> skald.View {
	segs := path_segments(p)
	if len(segs) == 0 {
		return skald.text("/", ctx.theme.color.fg_muted, ctx.theme.font.size_sm)
	}
	return skald.breadcrumb(ctx, segs, on_path_click, font_size = ctx.theme.font.size_sm)
}

// path_segments splits `p` on '/', dropping empty pieces. Caller owns
// the returned slice and should delete it.
path_segments :: proc(p: string) -> []string {
	parts := strings.split(p, "/")
	defer delete(parts)
	out := make([dynamic]string, 0, len(parts))
	for piece in parts {
		if len(piece) > 0 { append(&out, piece) }
	}
	return out[:]
}

status_line :: proc(s: State, th: ^skald.Theme) -> skald.View {
	switch s.status {
	case .Idle:    return skald.text("Enter a path and press Load.",
	                                  th.color.fg_muted, th.font.size_sm)
	case .Loading: return skald.text("Reading…",
	                                  th.color.fg_muted, th.font.size_sm)
	case .Loaded:
		label := fmt.tprintf("Loaded %d bytes.", len(s.contents))
		return skald.text(label, th.color.success, th.font.size_sm)
	case .Error:
		return skald.text(s.error, th.color.danger, th.font.size_sm)
	}
	return skald.spacer(0)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	body_wrap: f32 = 720 - 2 * th.spacing.xl

	body_view: skald.View
	if s.status == .Loaded && len(s.contents) > 0 {
		body_view = skald.scroll(ctx, {body_wrap, 360},
			skald.col(
				skald.text(s.contents, th.color.fg, th.font.size_sm,
					max_width = body_wrap - th.spacing.md),
				padding = th.spacing.md,
			),
		)
	} else {
		empty := skald.empty_state(ctx,
			"No file loaded",
			"Enter a path above and hit Load to read it asynchronously.",
			action = skald.button(ctx, "Load /etc/hostname", Load_Clicked{},
				color = th.color.primary, fg = th.color.on_primary),
		)
		body_view = skald.col(
			empty,
			width       = body_wrap,
			height      = 360,
			bg          = th.color.surface,
			radius      = th.radius.md,
			main_align  = .Center,
			cross_align = .Center,
		)
	}

	return skald.col(
		skald.text("Skald — File Viewer", th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Async file read via cmd_read_file + core:nbio.",
			th.color.fg_muted, th.font.size_md),

		skald.spacer(th.spacing.xl),

		skald.row(
			skald.tooltip(ctx,
				skald.text_input(ctx, s.path, on_path,
					placeholder = "/path/to/file",
					width       = 520),
				"Absolute or relative path to a text file"),
			skald.tooltip(ctx,
				skald.button(ctx, "Load", Load_Clicked{},
					color = th.color.primary, fg = th.color.fg, width = 140),
				"Read the file asynchronously via nbio"),
			spacing = th.spacing.md,
		),

		skald.spacer(th.spacing.xs),
		path_crumbs(ctx, s.path),

		skald.spacer(th.spacing.sm),
		status_line(s, th),

		skald.spacer(th.spacing.md),
		body_view,

		spacing     = 0,
		padding     = th.spacing.xl,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — File Viewer",
		size   = {760, 620},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
