package example_gallery

import "core:fmt"
import "core:strings"
import "gui:skald"

// Gallery: every Skald widget on one page, behind collapsible sections.
// Top bar has a theme toggle so you can flip between dark/light and
// scan the whole surface for regressions. Intended as (a) a playground
// for new users, (b) a QA target after framework refactors, (c) the
// README screenshot reel.

State :: struct {
	// chrome
	theme:        skald.Theme,
	dark:         bool,
	labels:       skald.Labels,
	spanish:      bool,
	open_section: [9]bool,

	// buttons
	counter:   int,

	// inputs
	name:      string,
	multiline: string,
	password:  string,
	search:    string,
	handle:    string, // capped at 12 chars
	quantity:  f64,
	on_flag:   bool,
	toggle_on: bool,
	volume:    f32,
	progress:  f32,
	tick:      int,

	// selection
	country:   string,
	language:  string,
	size_seg:  int,
	tab_idx:   int,
	stars:     int,
	pick_one:  int,

	// pickers
	date:      skald.Date,
	time:      skald.Time,
	color:     skald.Color,

	// data
	rows:          int,
	tree_expanded: map[string]bool,
	tree_selected: string,
	table_selected: int,  // -1 = none, else source row

	// overlays
	dialog:          bool,
	delete_confirm:  bool,
	toast:           bool,
	toast_msg:       string,   // what the next toast will say
	about:           bool,     // Help → About alert dialog
	palette_open:    bool,     // Ctrl+K command palette

	// decorations
	tags:          [dynamic]string,
	accordion_idx: int,    // -1 = all closed
}

Msg :: union {
	Theme_Toggled, Locale_Toggled, Section_Toggled,
	Counter_Inc, Counter_Reset,
	Name_Changed, Multiline_Changed, Password_Changed, Search_Changed, Search_Submitted,
	Handle_Changed,
	Quantity_Changed, On_Flag_Toggled, Toggle_Toggled, Volume_Changed,
	Tick,
	Country_Changed, Language_Changed, Size_Seg_Changed, Tab_Changed, Stars_Changed,
	Pick_One_Changed,
	Date_Changed, Time_Changed, Color_Changed,
	Tree_Toggled, Tree_Selected,
	Dialog_Open, Dialog_Close,
	Delete_Open, Delete_Confirm, Delete_Cancel,
	Toast_Show, Toast_Close,
	Tag_Removed,
	Accordion_Toggled,
	Menu_Action,          // rolling toast for menu-item clicks
	About_Open, About_Close,
	Palette_Open, Palette_Close,
	Table_Row_Clicked,
	Noop,   // inert — used by table callbacks we don't care about
}

Theme_Toggled     :: struct{}
Locale_Toggled    :: struct{}
Section_Toggled   :: distinct int
Counter_Inc       :: struct{}
Counter_Reset     :: struct{}
Name_Changed      :: distinct string
Multiline_Changed :: distinct string
Password_Changed  :: distinct string
Search_Changed    :: distinct string
Search_Submitted  :: struct {}
Handle_Changed    :: distinct string
Quantity_Changed  :: distinct f64
On_Flag_Toggled   :: distinct bool
Toggle_Toggled    :: distinct bool
Volume_Changed    :: distinct f32
Tick              :: struct{}
Country_Changed   :: distinct string
Language_Changed  :: distinct string
Size_Seg_Changed  :: distinct int
Tab_Changed       :: distinct int
Stars_Changed     :: distinct int
Pick_One_Changed  :: distinct int
Date_Changed      :: distinct skald.Date
Time_Changed      :: distinct skald.Time
Color_Changed     :: distinct skald.Color
// Tree_Toggled / Tree_Selected carry the clicked row's path, resolved
// from its flat index at the call site. The tree widget itself only
// knows indices — the app translates them.
Tree_Toggled      :: distinct string
Tree_Selected     :: distinct string
Dialog_Open       :: struct{}
Dialog_Close      :: struct{}
Delete_Open       :: struct{}
Delete_Confirm    :: struct{}
Delete_Cancel     :: struct{}
Toast_Show        :: struct{}
Toast_Close       :: struct{}
Tag_Removed       :: distinct string
Accordion_Toggled :: distinct int
Menu_Action       :: distinct string  // label of the action — e.g. "File → New"
About_Open        :: struct{}
About_Close       :: struct{}
Palette_Open      :: struct{}
Palette_Close     :: struct{}
Table_Row_Clicked :: distinct int
Noop              :: struct{}

SECTION_TITLES := [9]string{
	"Buttons & actions",
	"Inputs",
	"Selection",
	"Pickers",
	"Data",
	"Decorations",
	"Overlays",
	"Layout primitives",
	"Table",
}

// Static tree for the data-section demo. Using plain package-scope
// slices means the nested literals live in the binary's static data —
// no per-frame alloc, no per-item init dance in `init`.
Tree_Node :: struct {
	name:     string,
	children: []Tree_Node,
}

gallery_tree_skald_children := []Tree_Node{
	{name = "view.odin"},
	{name = "layout.odin"},
}
gallery_tree_examples_children := []Tree_Node{
	{name = "00_gallery"},
	{name = "09_widgets"},
	{name = "17_table"},
}
gallery_tree_src_children := []Tree_Node{
	{name = "skald",    children = gallery_tree_skald_children},
	{name = "examples", children = gallery_tree_examples_children},
}
gallery_tree_root := Tree_Node{
	name = "src", children = gallery_tree_src_children,
}

// Flatten the visible subset of the static tree into a Tree_Row slice
// plus a parallel path slice (so on_toggle / on_select can map the
// widget's index back to a stable key).
tree_walk :: proc(
	rows:  ^[dynamic]skald.Tree_Row,
	paths: ^[dynamic]string,
	n:     Tree_Node,
	path:  string,
	depth: int,
	s:     State,
) {
	expandable := len(n.children) > 0
	expanded   := s.tree_expanded[path]
	append(rows, skald.Tree_Row{
		depth      = depth,
		label      = n.name,
		expandable = expandable,
		expanded   = expanded,
		selected   = path == s.tree_selected,
	})
	append(paths, path)
	if expandable && expanded {
		for c in n.children {
			tree_walk(rows, paths, c,
				fmt.tprintf("%s/%s", path, c.name),
				depth + 1, s)
		}
	}
}

tree_flatten :: proc(s: State) -> (rows: []skald.Tree_Row, paths: []string) {
	rs:  [dynamic]skald.Tree_Row
	ps:  [dynamic]string
	rs.allocator = context.temp_allocator
	ps.allocator = context.temp_allocator
	tree_walk(&rs, &ps, gallery_tree_root, gallery_tree_root.name, 0, s)
	return rs[:], ps[:]
}

// Stashed paths slice for the tree's index→path callbacks. Re-populated
// by `data_section` every frame before the widget is built; the
// callbacks below read it back on click.
_gallery_tree_paths: []string

labels_es :: proc() -> skald.Labels {
	l := skald.labels_en()
	l.search_placeholder      = "Buscar"
	l.select_placeholder      = "Seleccionar…"
	l.date_picker_placeholder = "Elegir fecha"
	l.time_picker_placeholder = "Elegir hora"
	l.month_names = [12]string{
		"Enero",      "Febrero",   "Marzo",     "Abril",
		"Mayo",       "Junio",     "Julio",     "Agosto",
		"Septiembre", "Octubre",   "Noviembre", "Diciembre",
	}
	l.weekday_short = [7]string{"Do", "Lu", "Ma", "Mi", "Ju", "Vi", "Sá"}
	l.today = "Hoy"
	l.now   = "Ahora"
	l.clear = "Borrar"
	return l
}

init :: proc() -> State {
	s := State{
		theme     = skald.theme_dark(),
		dark      = true,
		labels    = skald.labels_en(),
		spanish   = false,
		name      = strings.clone("Ada Lovelace"),
		multiline = strings.clone("Notes go here.\nPress Enter for a new line."),
		password  = strings.clone(""),
		search    = strings.clone(""),
		handle    = strings.clone("skald"),
		quantity  = 3,
		on_flag   = true,
		toggle_on = true,
		volume    = 0.6,
		country   = "United Kingdom",
		language  = "English",
		size_seg  = 1,
		tab_idx   = 0,
		stars     = 4,
		pick_one  = 1,
		date      = {year = 2026, month = 4, day = 22},
		time      = {hour = 9, minute = 30},
		color     = skald.rgb(0x4c6ef5),
		rows          = 8,
		accordion_idx = 0,
		table_selected = -1,
	}
	for i in 0 ..< len(s.open_section) { s.open_section[i] = true }

	for t in ([]string{"urgent", "wip", "phase-1.0"}) {
		append(&s.tags, t)
	}

	// Seed the tree with the two top-most folders expanded so the data
	// section shows nested rows without requiring the user to click first.
	s.tree_expanded = make(map[string]bool)
	s.tree_expanded["src"]       = true
	s.tree_expanded["src/skald"] = true
	return s
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Theme_Toggled:
		out.dark = !out.dark
		out.theme = skald.theme_dark() if out.dark else skald.theme_light()
	case Locale_Toggled:
		out.spanish = !out.spanish
		out.labels = labels_es() if out.spanish else skald.labels_en()
	case Section_Toggled:
		idx := int(v)
		if idx >= 0 && idx < len(out.open_section) {
			out.open_section[idx] = !out.open_section[idx]
		}
	case Counter_Inc:       out.counter += 1
	case Counter_Reset:     out.counter = 0
	case Name_Changed:
		delete(out.name);      out.name      = strings.clone(string(v))
	case Multiline_Changed:
		delete(out.multiline); out.multiline = strings.clone(string(v))
	case Password_Changed:
		delete(out.password);  out.password  = strings.clone(string(v))
	case Search_Changed:
		delete(out.search);    out.search    = strings.clone(string(v))
	case Search_Submitted:
		// Demo no-op: in a real app this would kick off a query.
	case Handle_Changed:
		delete(out.handle);    out.handle    = strings.clone(string(v))
	case Quantity_Changed:  out.quantity  = f64(v)
	case On_Flag_Toggled:   out.on_flag   = bool(v)
	case Toggle_Toggled:    out.toggle_on = bool(v)
	case Volume_Changed:    out.volume    = f32(v)
	case Tick:
		out.tick += 1
		out.progress += 0.015
		if out.progress > 1 { out.progress = 0 }
	case Country_Changed:   out.country   = string(v)
	case Language_Changed:  out.language  = string(v)
	case Size_Seg_Changed:  out.size_seg  = int(v)
	case Tab_Changed:       out.tab_idx   = int(v)
	case Stars_Changed:     out.stars     = int(v)
	case Pick_One_Changed:  out.pick_one  = int(v)
	case Date_Changed:      out.date      = skald.Date(v)
	case Time_Changed:      out.time      = skald.Time(v)
	case Color_Changed:     out.color     = skald.Color(v)
	case Tree_Toggled:
		path := string(v)
		out.tree_expanded[path] = !out.tree_expanded[path]
	case Tree_Selected:
		out.tree_selected = string(v)
	case Dialog_Open:   out.dialog = true
	case Dialog_Close:  out.dialog = false
	case Delete_Open:    out.delete_confirm = true
	case Delete_Confirm:
		out.delete_confirm = false
		delete(out.toast_msg)
		out.toast_msg = strings.clone("File deleted.")
		out.toast     = true
	case Delete_Cancel:  out.delete_confirm = false
	case Toast_Show:
		delete(out.toast_msg)
		out.toast_msg = strings.clone("Toast raised.")
		out.toast     = true
	case Toast_Close:   out.toast  = false
	case Tag_Removed:
		target := string(v)
		for t, i in out.tags {
			if t == target { ordered_remove(&out.tags, i); break }
		}
	case Accordion_Toggled:
		out.accordion_idx = int(v)
	case Menu_Action:
		// Every menu item funnels through one Msg — the label is the
		// payload. Show it in a toast so you can see mouse clicks and
		// accelerator presses firing down the same path.
		delete(out.toast_msg)
		out.toast_msg = strings.clone(string(v))
		out.toast     = true
	case About_Open:    out.about = true
	case About_Close:   out.about = false
	case Palette_Open:  out.palette_open = true
	case Palette_Close: out.palette_open = false
	case Table_Row_Clicked:
		if int(v) == out.table_selected { out.table_selected = -1 }
		else                             { out.table_selected = int(v) }
	case Noop: // inert — table callbacks we don't want to react to
	}
	return out, {}
}

// ---------- per-widget callbacks (many widgets want a proc, not a Msg) ----------

on_name      :: proc(s: string) -> Msg { return Name_Changed(s) }
on_multi     :: proc(s: string) -> Msg { return Multiline_Changed(s) }
on_password  :: proc(s: string) -> Msg { return Password_Changed(s) }
on_search    :: proc(s: string) -> Msg { return Search_Changed(s) }
on_handle    :: proc(s: string) -> Msg { return Handle_Changed(s) }
on_quantity  :: proc(v: f64)    -> Msg { return Quantity_Changed(v) }
on_flag      :: proc(v: bool)   -> Msg { return On_Flag_Toggled(v) }
on_toggle    :: proc(v: bool)   -> Msg { return Toggle_Toggled(v) }
on_volume    :: proc(v: f32)    -> Msg { return Volume_Changed(v) }
on_country   :: proc(s: string) -> Msg { return Country_Changed(s) }
on_language  :: proc(s: string) -> Msg { return Language_Changed(s) }
on_size_seg  :: proc(i: int)    -> Msg { return Size_Seg_Changed(i) }
on_tab       :: proc(i: int)    -> Msg { return Tab_Changed(i) }
on_stars     :: proc(v: int)    -> Msg { return Stars_Changed(v) }
on_pick_one  :: proc(i: int)    -> Msg { return Pick_One_Changed(i) }
on_pick_zero :: proc() -> Msg { return Pick_One_Changed(0) }
on_pick_one_proc :: proc() -> Msg { return Pick_One_Changed(1) }
on_pick_two  :: proc() -> Msg { return Pick_One_Changed(2) }
on_date      :: proc(d: skald.Date)  -> Msg { return Date_Changed(d) }
on_time      :: proc(t: skald.Time)  -> Msg { return Time_Changed(t) }
on_color     :: proc(c: skald.Color) -> Msg { return Color_Changed(c) }
on_tree_tog  :: proc(i: int) -> Msg {
	if i < 0 || i >= len(_gallery_tree_paths) { return Tree_Toggled("") }
	return Tree_Toggled(_gallery_tree_paths[i])
}
on_tree_sel  :: proc(i: int) -> Msg {
	if i < 0 || i >= len(_gallery_tree_paths) { return Tree_Selected("") }
	return Tree_Selected(_gallery_tree_paths[i])
}
on_dialog_close  :: proc() -> Msg { return Dialog_Close{} }
on_delete_yes    :: proc() -> Msg { return Delete_Confirm{} }
on_delete_no     :: proc() -> Msg { return Delete_Cancel{} }
on_toast_close   :: proc() -> Msg { return Toast_Close{} }
on_about_close   :: proc() -> Msg { return About_Close{} }
on_palette_close :: proc() -> Msg { return Palette_Close{} }
on_section_toggled :: proc(open: bool) -> Msg { return Section_Toggled(-1) } // unused
on_tag_removed  :: proc(label: string) -> Msg { return Tag_Removed(label) }
on_accordion    :: proc(idx: int) -> Msg      { return Accordion_Toggled(idx) }

// ---------- section builders ----------

section :: proc(ctx: ^skald.Ctx(Msg), idx: int, body: skald.View, open: bool) -> skald.View {
	// Skald's collapsible takes a `proc(new_open: bool) -> Msg`, but we
	// need to know *which* section toggled. Rather than generating eight
	// separate closures, wrap the whole row in a button that dispatches
	// Section_Toggled(idx) — this dodges the "polymorphic proc default"
	// rules and keeps each section's toggle as a bare Msg.
	th := ctx.theme
	title := SECTION_TITLES[idx]
	arrow := "▼" if open else "▶"
	header := skald.button(
		ctx,
		fmt.tprintf("%s  %s", arrow, title),
		Section_Toggled(idx),
		color       = th.color.surface,
		fg          = th.color.fg,
		radius      = th.radius.sm,
		padding     = {th.spacing.md, th.spacing.sm},
		font_size   = th.font.size_md,
		text_align  = .Start,
	)
	// Card: section bg + 1-px hairline border for a visual edge, so
	// in light theme each section reads as a proper card on the body.
	// Border + radius match the theme to stay native-feeling.
	content: skald.View = header
	if open {
		content = skald.col(
			header,
			skald.spacer(th.spacing.xs),
			skald.col(
				body,
				padding     = th.spacing.md,
				spacing     = th.spacing.md,
				cross_align = .Stretch,
			),
			spacing     = 0,
			cross_align = .Stretch,
		)
	}
	// Border ring as an outer col; inner col carries the surface bg.
	// Two stacked rects give us a 1-px border without a dedicated
	// stroke primitive. Inner padding = 1 so the border shows.
	return skald.col(
		skald.col(
			content,
			padding     = 1,
			bg          = th.color.surface,
			radius      = th.radius.md,
			cross_align = .Stretch,
		),
		padding     = 0,
		bg          = th.color.border,
		radius      = th.radius.md,
		cross_align = .Stretch,
	)
}

buttons_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(fmt.tprintf("Counter: %d", s.counter), th.color.fg, th.font.size_md),
		skald.row(
			skald.button(ctx, "Increment", Counter_Inc{}),
			skald.button(ctx, "Reset",     Counter_Reset{},
				color = th.color.surface, fg = th.color.fg),
			skald.button(ctx, "Disabled",  Counter_Inc{}, disabled = true),
			spacing = th.spacing.sm,
		),
		skald.row(
			skald.link(ctx, "Enabled link",  Counter_Inc{}),
			skald.link(ctx, "Disabled link", Counter_Inc{}, disabled = true),
			skald.kbd(ctx, "Ctrl"),
			skald.text("+", th.color.fg_muted, th.font.size_md),
			skald.kbd(ctx, "S"),
			spacing     = th.spacing.md,
			cross_align = .Center,
		),
		spacing = th.spacing.md,
	)
}

inputs_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.form_row(ctx, "Name",
			skald.text_input(ctx, s.name, on_name, width = 260)),
		skald.form_row(ctx, "Notes",
			skald.text_input(ctx, s.multiline, on_multi,
				width = 260, height = 80, multiline = true)),
		skald.form_row(ctx, "Password",
			skald.text_input(ctx, s.password, on_password,
				width = 260, password = true, placeholder = "secret")),
		skald.form_row(ctx, "Search",
			skald.search_field(ctx, s.search, on_search,
				on_submit = proc() -> Msg { return Search_Submitted{} },
				width     = 260)),
		skald.form_row(ctx, "Handle",
			skald.text_input(ctx, s.handle, on_handle,
				width = 260, max_chars = 12,
				placeholder = "up to 12 chars")),
		skald.form_row(ctx, "Quantity",
			skald.number_input(ctx, s.quantity, on_quantity,
				step = 1, min_value = 0, max_value = 99)),
		skald.form_row(ctx, "Read-only",
			skald.number_input(ctx, s.quantity, on_quantity, disabled = true)),
		skald.form_row(ctx, "Remember me",
			skald.checkbox(ctx, s.on_flag, "Stay signed in", on_flag)),
		skald.form_row(ctx, "Notifications",
			skald.toggle(ctx, s.toggle_on, "On" if s.toggle_on else "Off", on_toggle)),
		skald.form_row(ctx, "Volume",
			skald.slider(ctx, s.volume, on_volume, width = 240)),
		skald.form_row(ctx, "Progress",
			skald.progress(ctx, s.progress, width = 240)),
		skald.form_row(ctx, "Spinner",
			skald.spinner(ctx, size = 24)),
		spacing = th.spacing.sm,
	)
}

selection_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	countries := []string{"United Kingdom", "United States", "Japan", "Germany", "Brazil"}
	// Latin / Cyrillic only — Inter ships Latin + extended + Cyrillic but
	// not CJK / Arabic / Devanagari, so those locales render as tofu here.
	// Adding a fallback-font pipeline is a POST-1.0 infrastructure task.
	languages := []string{
		"English", "Español", "Français", "Deutsch", "Italiano",
		"Português", "Nederlands", "Polski", "Türkçe", "Svenska",
		"Norsk", "Dansk", "Suomi", "Ελληνικά", "Русский",
	}
	sizes     := []string{"S", "M", "L", "XL"}
	tabs_opts := []string{"Overview", "Activity", "Settings"}
	return skald.col(
		skald.form_row(ctx, "Country",
			skald.select(ctx, s.country, countries, on_country, width = 260)),
		skald.form_row(ctx, "Language",
			skald.combobox(ctx, s.language, languages, on_language, width = 260)),
		skald.form_row(ctx, "Size",
			skald.segmented(ctx, sizes, s.size_seg, on_size_seg)),
		skald.form_row(ctx, "Rating",
			skald.rating(ctx, s.stars, on_stars)),
		skald.form_row(ctx, "Pick one",
			skald.row(
				skald.radio(ctx, s.pick_one == 0, "A", on_pick_zero),
				skald.radio(ctx, s.pick_one == 1, "B", on_pick_one_proc),
				skald.radio(ctx, s.pick_one == 2, "C", on_pick_two),
				spacing = th.spacing.md,
			)),
		skald.tabs(ctx, tabs_opts, s.tab_idx, on_tab),
		skald.col(
			skald.text(fmt.tprintf("You chose: %s", tabs_opts[s.tab_idx]),
				th.color.fg_muted, th.font.size_sm),
			padding = th.spacing.sm,
		),
		spacing = th.spacing.sm,
	)
}

pickers_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.form_row(ctx, "Date",
			skald.date_picker(ctx, s.date, on_date, width = 220)),
		skald.form_row(ctx, "Time",
			skald.time_picker(ctx, s.time, on_time,
				width       = 160,
				minute_step = 5,
				second_step = 15)),
		skald.form_row(ctx, "Colour",
			skald.color_picker(ctx, s.color, on_color, width = 220)),
		spacing = th.spacing.sm,
	)
}

data_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	// Virtual widgets (tree, virtual_list) don't ship with an intrinsic
	// frame — wrap them in a `col` with `bg` + `radius` to present them
	// as distinct cards. (For hand-rolled row lists you can reach for
	// `list_frame`, which also draws dividers.)
	tree_rows, tree_paths := tree_flatten(s)
	_gallery_tree_paths = tree_paths
	tree_view := skald.col(
		skald.tree(ctx, tree_rows, on_tree_tog, on_tree_sel,
			row_height = 24, width = 260),
		padding = th.spacing.sm,
		bg      = th.color.surface,
		radius  = th.radius.sm,
	)
	virtual_view := skald.col(
		skald.virtual_list(ctx, s, s.rows * 100, 28, {0, 180},
			gallery_row_builder,
			gallery_row_key,
			wheel_step = 40),
		padding     = th.spacing.sm,
		bg          = th.color.surface,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)
	return skald.col(
		skald.section_header(ctx, "Tree"),
		tree_view,
		skald.section_header(ctx, "Virtual list"),
		skald.text(
			fmt.tprintf("(%d rows, rendered on demand)", s.rows * 100),
			th.color.fg_muted, th.font.size_sm),
		virtual_view,
		spacing     = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// Synthetic list, no reorder — index is the stable key.
gallery_row_key :: proc(state: State, index: int) -> u64 { return u64(index) }

gallery_row_builder :: proc(ctx: ^skald.Ctx(Msg), state: State, index: int) -> skald.View {
	th := ctx.theme
	label := fmt.tprintf("Row #%d", index + 1)
	return skald.row(
		skald.text(label, th.color.fg, th.font.size_sm),
		skald.flex(1, skald.spacer(0)),
		skald.badge(ctx, fmt.tprintf("%d", index % 10),
			tone = .Neutral),
		padding = th.spacing.xs,
		spacing = th.spacing.md,
		cross_align = .Center,
	)
}

decorations_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	segments := []string{"Home", "Projects", "Skald", "Gallery"}
	chips := make([dynamic]skald.View, 0, len(s.tags), context.temp_allocator)
	for t in s.tags {
		append(&chips, skald.chip(ctx, t, on_tag_removed))
	}
	return skald.col(
		skald.row(
			skald.badge(ctx, "Default"),
			skald.badge(ctx, "Neutral", tone = .Neutral),
			skald.badge(ctx, "Success", tone = .Success),
			skald.badge(ctx, "Warning", tone = .Warning),
			skald.badge(ctx, "Danger",  tone = .Danger),
			spacing = th.spacing.sm,
		),
		skald.row(
			skald.avatar(ctx, "AL"),
			skald.avatar(ctx, "JS"),
			skald.avatar(ctx, "MK"),
			spacing = th.spacing.sm,
		),
		skald.row(..chips[:], spacing = th.spacing.sm),
		skald.alert(ctx, "Heads up",
			description = "This is an informational callout."),
		skald.alert(ctx, "Something went wrong",
			description = "Changes not saved.", tone = .Danger),
		skald.stepper(ctx, {"Details", "Address", "Payment", "Review"}, current = 1),
		skald.breadcrumb(ctx, segments, on_tab),
		skald.accordion(ctx,
			{
				{title = "General",
				 content = skald.col(
				     skald.text("Name, brand, and short description.",
				         th.color.fg_muted, th.font.size_sm),
				     padding = th.spacing.sm)},
				{title = "Notifications",
				 content = skald.col(
				     skald.text("Email, push, and in-app toggles.",
				         th.color.fg_muted, th.font.size_sm),
				     padding = th.spacing.sm)},
				{title = "Advanced",
				 content = skald.col(
				     skald.text("Developer options, analytics, privacy.",
				         th.color.fg_muted, th.font.size_sm),
				     padding = th.spacing.sm)},
			},
			s.accordion_idx, on_accordion),
		skald.empty_state(ctx, "Nothing here yet",
			description = "When you add items they'll show up in this list."),
		spacing     = th.spacing.md,
		cross_align = .Stretch,
	)
}

overlays_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.row(
			skald.button(ctx, "Open dialog", Dialog_Open{}),
			skald.button(ctx, "Show toast",  Toast_Show{},
				color = th.color.surface, fg = th.color.fg),
			skald.button(ctx, "Delete file", Delete_Open{},
				color = th.color.danger, fg = th.color.on_primary),
			spacing = th.spacing.sm,
		),
		skald.tooltip(ctx,
			skald.button(ctx, "Hover me", Counter_Inc{},
				color = th.color.surface, fg = th.color.fg),
			"A tooltip appears after a short hover delay."),
		spacing = th.spacing.md,
	)
}

layout_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.section_header(ctx, "row + flex"),
		skald.row(
			skald.rect({60, 24}, th.color.primary, th.radius.sm),
			skald.flex(1, skald.rect({0, 24}, th.color.surface, th.radius.sm)),
			skald.rect({60, 24}, th.color.success, th.radius.sm),
			spacing = th.spacing.sm,
		),
		skald.section_header(ctx, "divider"),
		skald.divider(ctx),
		skald.section_header(ctx, "spacer (fixed 16px)"),
		skald.row(
			skald.rect({40, 20}, th.color.primary, th.radius.sm),
			skald.spacer(16),
			skald.rect({40, 20}, th.color.primary, th.radius.sm),
		),
		spacing     = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// Sample data for the Table section — a short task list. Kept static
// so the gallery doesn't need a synthetic-data generator and the
// selection index stays stable across sort/resize (which we don't
// enable in the demo — they'd demand more state than a gallery card
// should carry).
gallery_table_rows := []struct{ task, owner, status: string }{
	{"Ship 1.0",                "Lee",   "In progress"},
	{"Write cookbook recipes",  "Lee",   "Done"},
	{"Light theme sweep",       "Lee",   "Done"},
	{"macOS smoke test",        "Lee",   "Blocked"},
	{"Perf benchmarks",         "Lee",   "Queued"},
	{"Tutorial video",          "-",     "Queued"},
}

// Gallery's static task list has no reorder path — index is the key.
gallery_table_row_key :: proc(state: State, row: int) -> u64 { return u64(row) }

gallery_table_row_builder :: proc(ctx: ^skald.Ctx(Msg), state: State, row: int) -> []skald.View {
	th := ctx.theme
	r := gallery_table_rows[row]
	// Return raw cell views — the table widget owns column widths +
	// cell padding. Wrapping each cell in its own padded `col` breaks
	// the column alignment because the col sizes to its content
	// rather than filling the column slot.
	cells := make([]skald.View, 3, context.temp_allocator)
	cells[0] = skald.text(r.task,  th.color.fg,       th.font.size_sm)
	cells[1] = skald.text(r.owner, th.color.fg_muted, th.font.size_sm)

	// Status gets a tone-appropriate badge.
	tone: skald.Badge_Tone = .Neutral
	if r.status == "Done"    { tone = .Success }
	if r.status == "Blocked" { tone = .Danger  }
	cells[2] = skald.badge(ctx, r.status, tone = tone)
	return cells
}

gallery_table_row_clicked :: proc(row: int, mods: skald.Modifiers) -> Msg {
	return Table_Row_Clicked(row)
}
gallery_table_is_selected :: proc(s: State, row: int) -> bool {
	return s.table_selected == row
}
gallery_table_noop_sort     :: proc(col: int, ascending: bool) -> Msg { return Noop{} }
gallery_table_noop_resize   :: proc(col: int, new_width: f32)  -> Msg { return Noop{} }
gallery_table_noop_activate :: proc(row: int) -> Msg                  { return Noop{} }

table_section :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme
	columns := []skald.Table_Column{
		// Task flexes to fill remaining width. Owner + Status are
		// fixed so badges/names sit in a stable place.
		{label = "Task",   flex = 1,    sortable = false, resizable = false},
		{label = "Owner",  width = 80,  sortable = false, resizable = false},
		{label = "Status", width = 130, sortable = false, resizable = false},
	}
	return skald.col(
		skald.text(
			"Click a row to select. Click again to deselect.",
			th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.table(ctx,
			state           = s,
			columns         = columns,
			row_count       = len(gallery_table_rows),
			item_height     = 32,
			viewport        = {0, f32(len(gallery_table_rows)) * 32 + 32 + 4},
			row_builder     = gallery_table_row_builder,
			row_key         = gallery_table_row_key,
			on_row_click    = gallery_table_row_clicked,
			is_selected     = gallery_table_is_selected,
			on_sort_change  = gallery_table_noop_sort,
			on_resize       = gallery_table_noop_resize,
			on_row_activate = gallery_table_noop_activate,
		),
		spacing     = 0,
		cross_align = .Stretch,
	)
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	ctx.theme^  = s.theme
	ctx.labels^ = s.labels
	th := ctx.theme

	// One action table drives both the menu bar and the Ctrl+K
	// command palette. Only `menu_bar` registers accelerators, so
	// shortcuts never double-fire even though the palette reads from
	// the same slice.
	menu_entries := []skald.Menu_Entry(Msg){
		{
			label = "File",
			items = []skald.Menu_Item(Msg){
				{label = "New",      shortcut = {.N, {.Ctrl}},         msg = Menu_Action("File → New")},
				{label = "Open…",    shortcut = {.O, {.Ctrl}},         msg = Menu_Action("File → Open")},
				{label = "Save",     shortcut = {.S, {.Ctrl}},         msg = Menu_Action("File → Save")},
				{label = "Save As…", shortcut = {.S, {.Ctrl, .Shift}}, msg = Menu_Action("File → Save As")},
				{separator = true},
				{label = "Quit",     shortcut = {.Q, {.Ctrl}},         msg = Menu_Action("File → Quit")},
			},
		},
		{
			label = "Edit",
			items = []skald.Menu_Item(Msg){
				{label = "Undo",  shortcut = {.Z, {.Ctrl}},         msg = Menu_Action("Edit → Undo")},
				{label = "Redo",  shortcut = {.Y, {.Ctrl}},         msg = Menu_Action("Edit → Redo")},
				{separator = true},
				{label = "Cut",   shortcut = {.X, {.Ctrl}},         msg = Menu_Action("Edit → Cut")},
				{label = "Copy",  shortcut = {.C, {.Ctrl}},         msg = Menu_Action("Edit → Copy")},
				// Paste greys out with no clipboard history — a tiny
				// demo of per-item `disabled`.
				{label = "Paste", shortcut = {.V, {.Ctrl}},         msg = Menu_Action("Edit → Paste"),
				 disabled = true},
			},
		},
		{
			label = "View",
			items = []skald.Menu_Item(Msg){
				{label = "Toggle theme",   shortcut = {.T, {.Ctrl}}, msg = Theme_Toggled{}},
				{label = "Toggle locale",                             msg = Locale_Toggled{}},
				{label = "Command palette", shortcut = {.K, {.Ctrl}}, msg = Palette_Open{}},
			},
		},
		{
			label = "Help",
			items = []skald.Menu_Item(Msg){
				{label = "About Skald…", msg = About_Open{}},
			},
		},
	}
	menu := skald.menu_bar(ctx, menu_entries)

	header := skald.row(
		skald.text("Skald — Widget gallery", th.color.fg, th.font.size_xl),
		skald.flex(1, skald.spacer(0)),
		skald.button(ctx,
			fmt.tprintf("Locale: %s", "Español" if s.spanish else "English"),
			Locale_Toggled{},
			color = th.color.surface, fg = th.color.fg),
		skald.spacer(th.spacing.sm),
		skald.button(ctx,
			fmt.tprintf("Theme: %s", "Dark" if s.dark else "Light"),
			Theme_Toggled{},
			color = th.color.surface, fg = th.color.fg),
		padding     = th.spacing.md,
		cross_align = .Center,
	)

	bodies := [9]skald.View{
		buttons_section(ctx, s),
		inputs_section(ctx, s),
		selection_section(ctx, s),
		pickers_section(ctx, s),
		data_section(ctx, s),
		decorations_section(ctx, s),
		overlays_section(ctx, s),
		layout_section(ctx, s),
		table_section(ctx, s),
	}

	// Three-column layout, balanced so everything fits on one wide-screen
	// monitor without scrolling. Columns: [0,1,8] / [2,3,4] / [5,6,7]
	// — Inputs (tall) + Table (compact) stack on the left, mid column
	// holds the form-heavy sections, right column holds the decorations.
	col_a := make([dynamic]skald.View, 0, 5, context.temp_allocator)
	col_b := make([dynamic]skald.View, 0, 6, context.temp_allocator)
	col_c := make([dynamic]skald.View, 0, 6, context.temp_allocator)
	for i in 0 ..< len(SECTION_TITLES) {
		dest: ^[dynamic]skald.View
		switch {
		case i < 2:  dest = &col_a
		case i < 5:  dest = &col_b
		case i < 8:  dest = &col_c
		case:        dest = &col_a  // Table goes bottom-left
		}
		append(dest, section(ctx, i, bodies[i], s.open_section[i]))
		append(dest, skald.spacer(th.spacing.md))
	}

	two_col := skald.row(
		skald.flex(1, skald.col(..col_a[:], spacing = 0, cross_align = .Stretch)),
		skald.flex(1, skald.col(..col_b[:], spacing = 0, cross_align = .Stretch)),
		skald.flex(1, skald.col(..col_c[:], spacing = 0, cross_align = .Stretch)),
		spacing     = th.spacing.xl,
		cross_align = .Start,
	)

	// Explicit id so the scroll's widget slot stays stable even when a
	// section's content changes widget count (e.g. opening the Country
	// select adds option-button ids that would otherwise shift the
	// scroll's auto-id and reset scroll_y to 0).
	scroll_id := skald.hash_id("gallery-scroll")
	body := skald.scroll(ctx, {0, 0},
		skald.col(two_col,
			padding     = th.spacing.lg,
			spacing     = 0,
			cross_align = .Stretch),
		id         = scroll_id,
		wheel_step = 40)

	dialog := skald.dialog(ctx,
		s.dialog,
		skald.col(
			skald.text("Confirm", th.color.fg, th.font.size_lg),
			skald.spacer(th.spacing.sm),
			skald.text("This is a modal dialog.", th.color.fg_muted, th.font.size_md),
			skald.spacer(th.spacing.md),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Close", Dialog_Close{}),
				spacing = th.spacing.sm,
			),
			padding = th.spacing.lg,
			spacing = 0,
		),
		on_dialog_close,
		width = 360,
	)

	toast_text := s.toast_msg if len(s.toast_msg) > 0 else "File deleted."
	toast := skald.toast(ctx, s.toast, toast_text, on_toast_close)

	delete_confirm := skald.confirm_dialog(ctx,
		s.delete_confirm,
		"Delete this file?",
		"The file will be moved to the Trash. You can restore it from there.",
		on_delete_yes, on_delete_no,
		confirm_label = "Delete",
		cancel_label  = "Keep",
		danger        = true,
		width         = 380,
	)

	about := skald.alert_dialog(ctx,
		s.about,
		"Skald",
		"A small Elm-style GUI framework for Odin. This gallery exercises every widget in the library.",
		on_about_close,
		width = 420,
	)

	palette := skald.command_palette(ctx,
		s.palette_open,
		menu_entries,
		on_palette_close,
	)

	// Animate progress and advance toast timers.
	skald.send(ctx, Tick{})

	return skald.col(
		menu,
		skald.divider(ctx),
		header,
		skald.divider(ctx),
		skald.flex(1, body),
		dialog,
		delete_confirm,
		about,
		palette,
		toast,
		spacing     = 0,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Widget Gallery",
		size   = {1680, 980},
		theme  = skald.theme_dark(),
		labels = skald.labels_en(),
		init   = init,
		update = update,
		view   = view,
	})
}
