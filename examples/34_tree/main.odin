package example_tree

import "core:fmt"
import "core:strings"
import "gui:skald"

// Tree view over a mock file system. The app owns the shape; each
// frame it flattens visible nodes into a []Tree_Row that the widget
// renders. Clicks and keyboard nav report indices back — the app
// mutates its own state in `update`.

Node :: struct {
	name:     string,
	is_dir:   bool,
	children: []Node,
}

State :: struct {
	root:     Node,
	expanded: map[string]bool,
	selected: string,
}

Msg :: union {
	Toggled,
	Selected,
}

Toggled  :: distinct string // path that was toggled
Selected :: distinct string // path that was selected

// Flattened rows live in the frame arena — rebuilt every view pass.
Flat :: struct {
	rows:  []skald.Tree_Row,
	paths: []string,
}

path_join :: proc(parent, name: string) -> string {
	if parent == "" { return name }
	return fmt.tprintf("%s/%s", parent, name)
}

walk :: proc(
	out_rows:  ^[dynamic]skald.Tree_Row,
	out_paths: ^[dynamic]string,
	n:         Node,
	path:      string,
	depth:     int,
	s:         State,
) {
	expandable := n.is_dir && len(n.children) > 0
	expanded   := s.expanded[path]

	append(out_rows, skald.Tree_Row{
		depth      = depth,
		label      = n.name,
		expandable = expandable,
		expanded   = expanded,
		selected   = path == s.selected,
	})
	append(out_paths, path)

	if expandable && expanded {
		for c in n.children {
			walk(out_rows, out_paths, c, path_join(path, c.name), depth + 1, s)
		}
	}
}

flatten :: proc(s: State) -> Flat {
	rows:  [dynamic]skald.Tree_Row
	paths: [dynamic]string
	rows.allocator  = context.temp_allocator
	paths.allocator = context.temp_allocator
	walk(&rows, &paths, s.root, s.root.name, 0, s)
	return Flat{rows[:], paths[:]}
}

// Mock filesystem. Declared at package scope so the nested slice
// literals live in the binary's static data, not on init's stack.
src_children := []Node{
	{name = "main.odin"},
	{name = "view.odin"},
	{name = "state.odin"},
}
images_children := []Node{
	{name = "logo.png"},
	{name = "icon.ico"},
}
fonts_children := []Node{
	{name = "Inter.ttf"},
}
assets_children := []Node{
	{name = "images", is_dir = true},
	{name = "fonts",  is_dir = true},
}
root_children := []Node{
	{name = "src",    is_dir = true},
	{name = "assets", is_dir = true},
	{name = "README.md"},
	{name = "build.sh"},
}

init :: proc() -> State {
	// Wire up child slices (can't do at package scope — slice references
	// to other package-scope slices aren't a compile-time constant).
	root_children[0].children = src_children
	root_children[1].children = assets_children
	assets_children[0].children = images_children
	assets_children[1].children = fonts_children

	root := Node{name = "project", is_dir = true, children = root_children}
	expanded := make(map[string]bool)
	expanded["project"] = true
	return State{root = root, expanded = expanded}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	// Msg strings live in the frame temp arena (free_all wipes them at
	// end-of-frame), so any path we want to retain across frames has
	// to be cloned into a persistent allocator.
	switch v in m {
	case Toggled:
		p := strings.clone(string(v))
		out.expanded[p] = !out.expanded[p]
	case Selected:
		out.selected = strings.clone(string(v))
	}
	return out, {}
}

// Frame-scoped closures. We need to pass row-index callbacks that
// resolve to a path — captured from `flatten`'s output.
@(private)
_flat: Flat

on_toggle :: proc(i: int) -> Msg { return Toggled(_flat.paths[i])  }
on_select :: proc(i: int) -> Msg { return Selected(_flat.paths[i]) }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	_flat = flatten(s)

	detail: skald.View
	if s.selected == "" {
		detail = skald.text("Select a file or folder.", th.color.fg_muted, th.font.size_md)
	} else {
		detail = skald.col(
			skald.text("Selected", th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.xs),
			skald.text(s.selected, th.color.fg, th.font.size_lg),
			cross_align = .Start,
		)
	}

	return skald.row(
		skald.col(
			skald.text("Files", th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.sm),
			skald.tree(ctx, _flat.rows, on_toggle, on_select, width = 240),
			width       = 240,
			padding     = th.spacing.md,
			bg          = th.color.surface,
			cross_align = .Start,
		),
		skald.col(
			detail,
			padding     = th.spacing.lg,
			cross_align = .Start,
		),
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Tree",
		size   = {720, 480},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
