# Cookbook

Short recipes for common Skald tasks. Each one shows the minimum code
for a pattern you're likely to hit more than once. If you want a
gentler tour of the framework, read [`guide.md`](guide.md) first; if
you want a specific widget's signature, see [`widgets.md`](widgets.md).

The recipes assume you're inside the usual `view` / `update` shape:

```odin
State :: struct { /* ... */ }
Msg   :: union  { /* ... */ }
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) { /* ... */ }
view   :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View    { /* ... */ }
```

Code snippets show the new bits, not the whole file — copy them in where
they fit.

## Contents

- [Layouts](#layouts)
- [Input and forms](#input-and-forms)
- [Lists and tables](#lists-and-tables)
- [Overlays](#overlays)
- [Multi-window](#multi-window)
- [Fonts](#fonts)
- [Localization](#localization)
- [Theming](#theming)
- [Keyboard and shortcuts](#keyboard-and-shortcuts)
- [Commands and async work](#commands-and-async-work)
- [Persistence](#persistence)
- [Dev tools](#dev-tools)

---

## Layouts

### Fill the window with a centered card

```odin
return skald.col(
    skald.flex(1, skald.spacer(0)),
    skald.row(
        skald.flex(1, skald.spacer(0)),
        card(ctx, s),
        skald.flex(1, skald.spacer(0)),
    ),
    skald.flex(1, skald.spacer(0)),
)
```

`flex(1, spacer(0))` is greedy empty space. Two on a row push the
middle child to the center; a `col` of three columns does the same
vertically. Wrap the content in both to center on both axes.

### Three-column layout (sidebar | main | inspector)

```odin
return skald.row(
    skald.col(sidebar,   width = 240),
    skald.flex(1, main),
    skald.col(inspector, width = 320),
)
```

Fixed-width side panels, a flexed middle. Swap in `skald.split` instead
if the user should be able to drag the dividers.

### Reflow chips / tags / toolbars onto new lines

`wrap_row` flows children left-to-right and breaks onto a new line when
the next one wouldn't fit. Use it for tag inputs, filter pills,
toolbars whose item count varies — anything where a regular `row` would
clip or overflow.

```odin
chips := make([dynamic]skald.View, 0, len(s.tags), context.temp_allocator)
for t in s.tags {
    append(&chips, skald.badge(ctx, t.label, tone = t.tone))
}

skald.wrap_row(..chips[:],
    spacing      = th.spacing.sm,    // gap between chips on a line
    line_spacing = th.spacing.sm)    // gap between wrapped lines
```

Inside a column with `cross_align = .Stretch` it wraps at the column's
width. Pass `width = X` for a fixed-width panel that wraps tighter.
See `examples/42_wrap_row`.

### Pick a layout based on the slot's width

Two ways, depending on what you're branching on:

**Window-wide check** — read `ctx.breakpoint`:

```odin
if ctx.breakpoint == .Compact {
    return mobile_layout(ctx, s)
}
return desktop_layout(ctx, s)
```

`Breakpoint` is `Compact` (< 600 px) / `Regular` (< 1100 px) / `Wide`
(everything bigger). Computed each frame from the window's logical
size, so it follows the user's resizing.

**Per-container check** — use `responsive(...)`:

```odin
narrow_pane :: proc(ctx: ^skald.Ctx(Msg), s: ^State) -> skald.View {
    return skald.col(/* stacked layout for narrow */)
}

wide_pane :: proc(ctx: ^skald.Ctx(Msg), s: ^State) -> skald.View {
    return skald.row(/* side-by-side layout for wide */)
}

// In view:
state := s
skald.responsive(ctx, &state, 700, narrow_pane, wide_pane)
```

`responsive` picks based on the *slot's assigned width* — a 320 px
sidebar embedded in a 1600 px window stays narrow. The two builders
take a typed `data` parameter so they stay closure-free; the value
gets snapshotted into the frame arena.

---

## Input and forms

### Form with per-field validation

State holds drafts + per-field error strings. `update` validates after
every keystroke so errors surface without a submit roundtrip:

```odin
State :: struct {
    email, email_err: string,
    password, password_err: string,
}

Msg :: union { Email_Changed, Password_Changed, Submit_Clicked }
Email_Changed    :: distinct string
Password_Changed :: distinct string
Submit_Clicked   :: struct{}

validate_email :: proc(s: string) -> string {
    if len(s) == 0 { return "" }                       // empty is fine until submit
    if !strings.contains(s, "@") { return "Missing @" }
    return ""
}

// update:
case Email_Changed:
    delete(out.email); out.email = strings.clone(string(v))
    delete(out.email_err); out.email_err = strings.clone(validate_email(out.email))
```

In the view, surface the error under the field:

```odin
skald.col(
    skald.text_input(ctx, s.email, on_email, placeholder = "you@example.com"),
    skald.text(s.email_err, th.color.danger, th.font.size_sm),
    spacing = th.spacing.xs,
)
```

### Grouped validate-on-submit

Per-field validation catches obvious typos as you go, but some
fields only make sense together (password confirmation, one of N
required radios, etc.). Run a full-form sweep from a `Submit_Clicked`
Msg, dump errors onto state, and render a summary banner at the top
of the form.

```odin
State :: struct {
    email, password, confirm: string,
    errors: [dynamic]string,   // full list; rendered as a banner
}

Submit_Clicked :: struct{}

validate_all :: proc(s: ^State) -> bool {
    clear(&s.errors)
    if !strings.contains(s.email, "@") {
        append(&s.errors, strings.clone("Email must contain @"))
    }
    if len(s.password) < 8 {
        append(&s.errors, strings.clone("Password must be 8+ characters"))
    }
    if s.password != s.confirm {
        append(&s.errors, strings.clone("Passwords don't match"))
    }
    return len(s.errors) == 0
}

// update:
case Submit_Clicked:
    if validate_all(&out) {
        return out, skald.cmd_delay(Signed_Up{}, seconds = 0)  // or real action
    }
```

In the view, render the errors above the form when non-empty:

```odin
errors_view: skald.View = skald.spacer(0)
if len(s.errors) > 0 {
    lines := make([dynamic]skald.View, 0, len(s.errors),
        context.temp_allocator)
    for e in s.errors {
        append(&lines, skald.text(e, th.color.danger, th.font.size_sm))
    }
    errors_view = skald.alert(ctx, "Please fix these:",
        strings.join(s.errors[:], "\n", context.temp_allocator),
        tone = .Danger)
}
```

Pair this with per-field errors for the best UX: per-field highlights
bad input as the user types; submit validation catches anything they
didn't trip on the way.

### Max-length text field

```odin
skald.text_input(ctx, s.username, on_username, max_chars = 20)
```

`text_input` counts runes, not bytes — emoji and accented chars count
as one.

### Number field clamped to a range

```odin
skald.number_input(ctx, s.quantity, on_quantity,
    min_value = 1, max_value = 99, decimals = 0)
```

Type a value, click +/−, or focus and use arrow keys. Out-of-range
input is clamped on commit.

### Search box that fires on Enter

```odin
skald.search_field(ctx, s.query, on_query_changed,
    on_submit = proc() -> Msg { return Search_Submitted{} },
    width     = 360)
```

`search_field` is the dedicated search-input widget. It defaults the
placeholder to the localized "Search…" label, sits a `×` clear button
to the right whenever the field holds text, switches Escape from
"blur" to "clear-then-blur" (the GTK / macOS convention), and fires
`on_submit` whenever the user presses Enter while the field has focus.

Both callbacks are required:

- `on_change(new_value)` runs on every keystroke. Use this for
  incremental filtering (recompute the visible list based on the
  current query).
- `on_submit()` runs on Enter. Use this for committing the query to
  a server, kicking off a heavy search, or activating the highlighted
  result in a launcher-style picker.

If you don't need Enter-submit (you're filtering an in-memory list
on every keystroke), use `text_input` with `clear_button = true,
escape_clears = true` instead — same affordances, no submit callback
required.

```odin
skald.text_input(ctx, s.filter, on_filter_changed,
    placeholder   = "Filter…",
    clear_button  = true,
    escape_clears = true,
    width         = 240)
```

---

## Lists and tables

### Virtualized list — 100k rows

```odin
Row_Data :: struct { id: int, name: string }

row_builder :: proc(ctx: ^skald.Ctx(Msg), s: State, i: int) -> skald.View {
    r := s.items[i]
    return skald.text(fmt.tprintf("%d — %s", r.id, r.name),
        ctx.theme.color.fg, ctx.theme.font.size_md)
}

// Stable id per row. For data that never reorders, index is fine;
// for data with real item ids, return the id — that's how state
// inside cells follows the item through filters / reorders.
row_key :: proc(s: State, i: int) -> u64 { return u64(s.items[i].id) }

skald.virtual_list(ctx,
    s,                     // state threaded to the builder
    len(s.items),
    32,                    // item_height
    {0, 400},              // viewport: zero x = fill, 400 px tall
    row_builder,
    row_key,
)
```

Only the visible rows build, so memory and frame time stay flat even
with a million items. Stateful widgets inside a row (buttons,
checkboxes, text inputs) get per-row id scopes keyed off `row_key`
automatically — no `hash_id` ceremony needed. See
`examples/16_virtual_list`.

### A basic table

Minimum shape: a columns slice, a row count, a row builder that
returns one `View` per column, and callbacks the widget fires on
row interactions. Every callback is required — pass a no-op that
emits an inert Msg for the ones you don't need.

```odin
Row :: struct { task, owner, status: string }

rows := []Row{
    {"Ship 1.0",         "Lee", "In progress"},
    {"Write docs",       "Lee", "Done"},
    {"macOS smoke test", "Lee", "Blocked"},
}

columns := []skald.Table_Column{
    // flex + width rules: set `flex` OR `width`, not both. Flex
    // columns share the leftover space; fixed columns don't move.
    // A column with *neither* flex nor width set gets ZERO width
    // — a common gotcha. Give the "primary" column `flex = 1`.
    {label = "Task",   flex = 1},
    {label = "Owner",  width = 80},
    {label = "Status", width = 130},
}

row_builder :: proc(ctx: ^skald.Ctx(Msg), s: State, row: int) -> []skald.View {
    th := ctx.theme
    r := s.rows[row]
    cells := make([]skald.View, 3, context.temp_allocator)
    // Return raw cells. Wrapping each in its own `col(…)` breaks
    // column alignment because the col sizes to its content, not
    // the column slot — the table owns widths and cell padding.
    cells[0] = skald.text(r.task,  th.color.fg,       th.font.size_sm)
    cells[1] = skald.text(r.owner, th.color.fg_muted, th.font.size_sm)
    // Status gets a tone-appropriate badge.
    tone := skald.Badge_Tone.Neutral
    if r.status == "Done"    { tone = .Success }
    if r.status == "Blocked" { tone = .Danger }
    cells[2] = skald.badge(ctx, r.status, tone = tone)
    return cells
}

// Stable key per row — lets widget state inside cells follow the
// item through sorts / filters. Static list → index works. Real
// dataset → return the item's stable id.
row_key :: proc(s: State, row: int) -> u64 { return u64(row) }

on_click    :: proc(row: int, mods: skald.Modifiers) -> Msg { return Row_Clicked(row) }
is_selected :: proc(s: State, row: int) -> bool              { return s.selected == row }
no_sort     :: proc(col: int, asc: bool) -> Msg              { return Noop{} }
no_resize   :: proc(col: int, w: f32) -> Msg                 { return Noop{} }
no_activate :: proc(row: int) -> Msg                          { return Noop{} }

skald.table(ctx,
    state           = s,
    columns         = columns,
    row_count       = len(s.rows),
    item_height     = 32,
    viewport        = {0, 0},    // 0,0 = fill parent (needs a flex parent)
    row_builder     = row_builder,
    row_key         = row_key,
    on_row_click    = on_click,
    is_selected     = is_selected,
    on_sort_change  = no_sort,
    on_resize       = no_resize,
    on_row_activate = no_activate,
)
```

The full sort + resize + multi-select flow is in `examples/17_table`.
Note its `row_key` returns `u64(s.sorted[visible])` — visible row
position maps to the underlying source row id, so state stays glued
to the file when the user re-sorts.

### Table with sortable columns

Mark each column `sortable = true` and sort the underlying slice in
`update` on the `Sort_Changed` msg the table dispatches:

```odin
case Sort_Changed:
    out.sort_col = v.col
    out.sort_asc = v.asc
    slice.sort_by(out.rows[:], proc(a, b: Row) -> bool {
        return a.task < b.task // switch on v.col for real multi-col sort
    })
```

Pass `sort_column = s.sort_col, sort_ascending = s.sort_asc` to
`table` so it draws the ▲/▼ indicator. The widget doesn't sort
anything itself — it only dispatches the event.

### Selection that persists across data reloads

Don't store the index — store the row's stable ID:

```odin
State :: struct {
    items:       [dynamic]Row_Data,
    selected_id: int, // 0 = none
}
```

On reload, if the previously-selected ID still exists, the user's
selection naturally follows.

### Editable cells per row (qty, dropdown, checkbox)

The classic order-form pattern: every row has its own `number_input`
for quantity, a `select` for label type, maybe a `checkbox` for
"include." Without closures (Odin doesn't have them) a widget callback
can't capture which row it belongs to.

There are two ways to solve this; pick whichever fits your row.

**Quick: pass the payload to each widget directly.** Every value-
emitting widget accepts an optional payload argument that gets handed
back to the callback when the value changes:

```odin
on_qty :: proc(id: int, v: f64) -> Msg { return Qty_Changed{id, v} }

for p in s.products {
    skald.row(
        skald.text(p.name, th.color.fg, th.font.size_md),
        skald.number_input(ctx, p.qty, p.id, on_qty,
            min_value = 0, width = 120),
    )
}
```

The `p.id` slot in the call signals "this widget belongs to product
`p.id`"; the callback receives it back as its first argument. Best
when only a couple of widgets per row need identity.

**Tidy: thread the payload at the row boundary with `map_msg_for`.**
When a row has *many* widgets that all need the same identity, push
the row identity through once at the boundary instead of repeating
`p.id` on every widget call:

```odin
// 1. Row-local Msg union — only what one row can emit.
Row_Msg :: union {
    Row_Qty_Changed:   distinct f64,
    Row_Label_Changed: distinct string,
}

on_row_qty   :: proc(v: f64)    -> Row_Msg { return Row_Qty_Changed(v) }
on_row_label :: proc(v: string) -> Row_Msg { return Row_Label_Changed(v) }

// 2. Sub-view: takes the row's data + a Ctx parameterised on Row_Msg.
//    Inside, every widget fires Row_Msg variants. The proc is reused
//    for every row — no per-row closure, no codegen.
product_row :: proc(p: Product, ctx: ^skald.Ctx(Row_Msg)) -> skald.View {
    th := ctx.theme

    // Pin per-row widget state (focus, draft buffer, caret) to the
    // item's stable id rather than the row's position. Without this,
    // sorting or filtering smears state across neighbours.
    saved := skald.widget_scope_push(ctx, u64(p.id))
    defer skald.widget_scope_pop(ctx, saved)

    return skald.row(
        skald.flex(1, skald.text(p.name, th.color.fg, th.font.size_md)),
        skald.number_input(ctx, p.qty, on_row_qty, min_value = 0, width = 160),
        skald.select(ctx, label_strings[p.label], label_options, on_row_label,
            width = 140),
        cross_align = .Center, spacing = th.spacing.md,
    )
}

// 3. App-side Msg variant that carries the row identity + the
//    row-local Msg, plus a translator that builds it.
Msg :: union { ..., Row_Op }
Row_Op :: struct { row: int, op: Row_Msg }

wrap_row :: proc(row: int, m: Row_Msg) -> Msg {
    return Row_Op{row = row, op = m}
}

// 4. Parent view: iterate, wrap each row via map_msg_for.
//    The `i` is the payload — it threads through wrap_row when any
//    widget in the row fires.
for p, i in s.products {
    skald.map_msg_for(ctx, i, p, product_row, wrap_row)
}

// 5. update dispatches into the row.
case Row_Op:
    if v.row < 0 || v.row >= len(out.products) { return out, {} }
    switch op in v.op {
    case Row_Qty_Changed:
        out.products[v.row].qty = f64(op)
    case Row_Label_Changed:
        out.products[v.row].label = label_from_string(string(op))
    }
```

Adding a new editable column once the scaffold is in place is a
4-step mechanical change: variant on `Row_Msg`, handler proc, widget
in `product_row`, case in `update`.

A working version with five rows of editable products (qty number_input
+ label-type dropdown + responsive UI proof) lives at
[`examples/41_table_inputs`](../examples/41_table_inputs).

**Why `widget_scope_push(u64(p.id))`?** Without it, widget state
tracks call-site position, so a sort that moves row 3 to position 0
would carry row 3's draft buffer onto row 0's display. Scoping by the
item's stable id pins focus + edit state to the *item* across
reshuffles. Skald's `virtual_list` and `table` widgets do this
automatically; in a hand-rolled list you do it yourself.

---

## Overlays

### Confirm dialog for destructive action

```odin
delete_confirm := skald.confirm_dialog(ctx,
    s.confirm_delete,
    "Delete this file?",
    "The file will be moved to the Trash.",
    on_delete_yes, on_delete_no,
    confirm_label = "Delete",
    cancel_label  = "Keep",
    danger        = true,
)
```

`danger = true` tints the primary button red. The dialog handles
Escape, scrim clicks are swallowed (won't accidentally dismiss —
explicit Cancel or Escape only).

### Toast that auto-dismisses after 3 s

```odin
skald.toast(ctx, s.toast, "Saved.", on_toast_close,
    kind          = .Success,
    dismiss_after = 3)
```

### Right-click context menu

```odin
skald.context_menu(ctx,
    child     = file_row(ctx, file),
    items     = []string{"Rename", "Duplicate", "Delete"},
    on_select = on_file_action)
```

Wraps the child. Right-click inside the child's rect opens the menu at
the cursor.

### Command palette (Ctrl+K)

Reuse your menu_bar entries:

```odin
skald.shortcut(ctx, {.K, {.Ctrl}}, Palette_Open{})

palette := skald.command_palette(ctx,
    s.palette_open,
    menu_entries,    // same []Menu_Entry you pass to menu_bar
    on_palette_close)
```

The palette doesn't need a menu_bar — pass the entries directly. If
your app has no visible menu, use entries with empty labels and the
palette will drop the "Entry → " prefix automatically.

### Tooltip on hover

```odin
skald.tooltip(ctx, skald.button(ctx, "Save", Save_Clicked{}), "Ctrl+S")
```

400 ms hover delay. Multi-line tooltips: put `\n` in the text.

---

## Multi-window

### Open a popover window

One `view` proc renders every open window. Switch on `ctx.window` to
pick which tree belongs to which.

```odin
State :: struct {
    popover_id: skald.Window_Id,   // zero-value = not open
}

Msg :: union {
    Open_Popover,
    Popover_Opened,
    Popover_Closed,
    Close_Popover,
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
    out := s
    switch v in m {
    case Open_Popover:
        if out.popover_id != {} { return out, {} } // already open
        return out, skald.cmd_open_window(
            {title = "Calendar", size = {240, 200}},
            on_popover_opened,
            on_close = on_popover_closed,
        )

    case Popover_Opened: out.popover_id = v.id
    case Popover_Closed:
        // Fires for BOTH paths: cmd_close_window AND the user's X-click.
        // One handler covers both so state always tracks reality.
        if v.id == out.popover_id { out.popover_id = {} }

    case Close_Popover:
        if out.popover_id == {} { return out, {} }
        return out, skald.cmd_close_window(Msg, out.popover_id)
    }
    return out, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    if s.popover_id != {} && ctx.window == s.popover_id {
        return popover_view(s, ctx)
    }
    return main_view(s, ctx)
}

on_popover_opened :: proc(id: skald.Window_Id) -> Msg { return Popover_Opened{id = id} }
on_popover_closed :: proc(id: skald.Window_Id) -> Msg { return Popover_Closed{id = id} }
```

Each window gets its own `Widget_Store` — focus, modal rects, and
overlays are scoped per window. Input events only reach the window
they were targeted at. Device, pipeline, and fonts stay shared.

### Dock-style window (borderless, always on top)

Pass SDL flags at `App` construction time:

```odin
app.window_flags = {.BORDERLESS, .ALWAYS_ON_TOP}
```

`.VULKAN` and `.HIGH_PIXEL_DENSITY` are added by Skald automatically —
set `window_flags` to override everything else the OS would otherwise
enable (like `.RESIZABLE`, which the default includes).

For X11-specific hints — `_NET_WM_WINDOW_TYPE_DOCK`, struts, etc. —
use `App.on_window_open` to reach the native handle:

```odin
app.on_window_open = proc(w: ^skald.Window) {
    props := sdl3.GetWindowProperties(w.handle)
    display    := sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_X11_DISPLAY_POINTER, nil)
    x11_window := sdl3.GetNumberProperty(props, sdl3.PROP_WINDOW_X11_WINDOW_NUMBER, 0)
    // XChangeProperty(..., _NET_WM_WINDOW_TYPE, DOCK) etc.
}
```

Same hook exists per secondary window via `Window_Desc.on_open`.

### Auto-close a popover on click-away

```odin
app.on_window_focus_lost = on_focus_lost

on_focus_lost :: proc(window: skald.Window_Id) -> Msg {
    return Focus_Lost{id = window}
}

// in update:
case Focus_Lost:
    if out.popover_id == v.id {
        return out, skald.cmd_close_window(Msg, out.popover_id)
    }
```

Fires once when any window stops being foreground (user clicks
another app, Alt-Tabs, switches workspace). Works for both primary
and secondary windows.

---

## Fonts

### Add a fallback font for non-Latin glyphs

Skald ships with Inter (Latin + Cyrillic + extended). Codepoints
outside that — CJK, Arabic, Devanagari, etc. — render as tofu
boxes. Bundle the fonts your locale needs and chain them:

```odin
// Load once (first frame is fine; guard with a State flag so
// you don't re-register every frame).
CJK_TTF :: #load("assets/NotoSansJP.ttf", []byte)

State :: struct {
    fonts_loaded: bool,
    // ... rest of your state
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    if !s.fonts_loaded {
        cjk := skald.font_load(ctx.renderer, "noto-jp", CJK_TTF)
        skald.font_add_fallback(ctx.renderer,
            skald.font_default(ctx.renderer), cjk)
        skald.send(ctx, Fonts_Loaded{})  // flip s.fonts_loaded next frame
    }
    // ... rest of view
}
```

Glyphs are rasterised on demand, so there's no upfront cost —
fontstash fetches from the fallback only when Inter doesn't contain
the codepoint. Chain multiple fallbacks in priority order; first
match wins.

**What works well**: CJK (Chinese / Japanese / Korean), Cyrillic
extensions, symbol fonts, math. Anything whose layout is codepoint
in → glyph out with no contextual reshaping.

**What's limited**: Arabic, Hebrew, Devanagari, Thai — any script
that needs *contextual shaping* (initial/medial/final letter
forms, RTL reordering, conjuncts). Skald uses stb_truetype under
fontstash, which ships glyphs but not shaping. The codepoints will
render, but linguistically incorrectly. Correct shaping +
bidirectional layout is a planned post-1.0 feature — contributions
from native speakers of those scripts are welcome. See
[`CONTRIBUTING.md`](../CONTRIBUTING.md) for the concrete work items.

### Use an icon font (Font Awesome, Lucide, Phosphor, Material…)

Same mechanism as the fallback above — register the icon font as a
fallback to Inter, then drop the icon's PUA codepoint straight into
any string. The glyph renders inline alongside regular text; nothing
else in the framework needs to know it's an icon.

```odin
FA_SOLID_TTF :: #load("assets/fa-solid-900.ttf", []byte)

ICON_SAVE  :: ""  // floppy-disk
ICON_TRASH :: ""

// First-frame init (same pattern as the CJK example above).
fa := skald.font_load(ctx.renderer, "fa-solid", FA_SOLID_TTF)
skald.font_add_fallback(ctx.renderer, skald.font_default(ctx.renderer), fa)

// Then anywhere in your view:
skald.button(ctx, ICON_SAVE + "  Save", On_Save{})
skald.text(ICON_TRASH, th.color.fg, 24)
```

Pick the **TTF** distribution, not OTF/CFF — fontstash's stb_truetype
backend only renders TrueType outlines. Font Awesome 6 Free, Lucide,
Phosphor, and Material Symbols all ship a TTF. Codepoint catalogues
are on the icon set's website; copy `\uXXXX` into your string.

A working example lives in [`examples/39_icons`](../examples/39_icons).

**Color emoji** (😀 with the actual yellow face) is a separate
problem — the OS system emoji fonts ship glyphs in CBDT / sbix /
COLR formats that fontstash doesn't decode. Tracked as a post-1.0
item; for now Inter renders monochrome fallbacks for the few emoji
codepoints it carries, and unmapped ones tofu.

## Localization

Skald ships a `Labels` struct that carries every string the framework
itself produces (picker placeholders, month / weekday names, AM/PM,
"Today" / "Now" buttons). `labels_en()` is the default. Apps wanting
another language supply their own `Labels` value on `App.labels` — one
swap and every built-in widget renders in the new language.

Translating *your app's own* strings (button labels, form fields,
error messages) is the app's responsibility — Skald doesn't ship a
gettext-style translation framework. The pattern below shows how to
handle both sides with roughly 30 lines of app code.

### Add a second language to your app

```odin
Locale :: enum { English, Spanish }

State :: struct {
    locale: Locale,
    // ... rest of your state
}

Msg :: union { Locale_Switched /* ... */ }
Locale_Switched :: distinct Locale

// 1. Your app's own strings. Keyed however you like — here, a
//    struct with explicit fields so the compiler catches typos.
App_Labels :: struct {
    title:        string,
    save:         string,
    discard:      string,
    unsaved_msg:  string,
}

app_labels_for :: proc(loc: Locale) -> App_Labels {
    switch loc {
    case .Spanish: return {
        title       = "Bloc de notas",
        save        = "Guardar",
        discard     = "Descartar",
        unsaved_msg = "Hay cambios sin guardar.",
    }
    case .English: fallthrough
    case:          return {
        title       = "Notes",
        save        = "Save",
        discard     = "Discard",
        unsaved_msg = "You have unsaved changes.",
    }
    }
}

// 2. Framework strings — a matching proc that returns skald.Labels.
//    Seed from labels_en() and override the fields you translate.
framework_labels_for :: proc(loc: Locale) -> skald.Labels {
    switch loc {
    case .Spanish:
        l := skald.labels_en()
        l.month_names = [12]string{
            "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
            "Julio", "Agosto", "Septiembre", "Octubre",
            "Noviembre", "Diciembre",
        }
        l.weekday_short = [7]string{"Dom","Lun","Mar","Mié","Jue","Vie","Sáb"}
        l.am = "AM"; l.pm = "PM"
        l.today = "Hoy"; l.now = "Ahora"; l.clear = "Limpiar"
        return l
    case .English: fallthrough
    case:          return skald.labels_en()
    }
}

// 3. In update, handle the switch.
// case Locale_Switched:
//     out.locale = Locale(v)

// 4. In view, update the framework labels and use your app labels.
view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    ctx.labels^ = framework_labels_for(s.locale)
    L := app_labels_for(s.locale)

    return skald.col(
        skald.text(L.title, ctx.theme.color.fg, ctx.theme.font.size_lg),
        skald.button(ctx, L.save,    Save_Clicked{}),
        skald.button(ctx, L.discard, Discard_Clicked{}),
        // ...
    )
}
```

The pattern scales to any number of languages — just add enum cases
and branches. Working example in `examples/00_gallery` (toggle
between English and Spanish with the Locale button).

### Auto-pick language from OS locale on first launch

```odin
import "core:os"

guess_locale :: proc() -> Locale {
    // Look at LANG / LC_ALL / LC_MESSAGES in that order. Whatever
    // the OS reports first with a non-empty value wins.
    for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
        v := os.get_env(name, context.temp_allocator)
        if len(v) >= 2 {
            switch v[:2] {
            case "es": return .Spanish
            case "en": return .English
            // ... add cases for every locale you ship
            }
        }
    }
    return .English
}
```

Call from `init()` the first time your app launches (and persist the
user's chosen locale thereafter — see
"Save and restore window size / position between launches" above for
the persistence pattern).

### What Skald does *not* handle

- **Pluralization** (`"1 file" / "2 files"`) — do it in your
  `app_labels_for` with a proc that takes a count.
- **Number / currency formatting** — use `core:strconv` and format
  by hand; Skald has no locale-aware number formatter.
- **Right-to-left text flow** (Arabic, Hebrew) — tracked in
  [`CONTRIBUTING.md`](../CONTRIBUTING.md) as a 1.x item; the
  glyphs render via `font_add_fallback` but contextual shaping
  and bidi layout aren't in yet.

## Theming

### Follow the OS theme automatically

The one-liner: `skald.theme_system()` picks dark or light from the OS
preference and overlays the user's chosen accent colour where the
platform exposes one (GNOME's `accent-color` setting on Linux today;
macOS and Windows fall back to Skald's own primary).

```odin
skald.run(skald.App(State, Msg){
    theme = skald.theme_system(),
    on_system_theme_change = proc(t: skald.System_Theme) -> Msg {
        return Theme_Changed(t == .Light)
    },
    // ...
})
```

The callback fires when the user flips dark/light at runtime so you
can mirror it without a relaunch — re-read `theme_system()` and assign
to `ctx.theme^` next frame.

If you want the dark-or-light pick without the accent override (or
need a fixed theme regardless of the OS), use `theme_dark()` /
`theme_light()` directly.

### Custom theme based on the defaults

```odin
my_theme :: proc() -> skald.Theme {
    t := skald.theme_dark()
    t.color.primary    = skald.rgb(0xff6b35)   // brand orange
    t.color.on_primary = skald.rgb(0xffffff)
    t.radius           = {sm = 6, md = 10, lg = 14, xl = 20, pill = 9999}
    return t
}
```

Only override the slots you care about — everything else stays at the
professional defaults.

### Dark / light toggle in the app

```odin
case Theme_Toggled:
    out.dark  = !out.dark
    out.theme = skald.theme_dark() if out.dark else skald.theme_light()

// in view:
ctx.theme^ = s.theme
```

`ctx.theme^` assignment is how the app tells the framework which theme
to use on a given frame.

---

## Keyboard and shortcuts

### App-wide accelerator

```odin
skald.shortcut(ctx, {.S, {.Ctrl}}, Save_Clicked{})
```

Put it at the top of `view`. Fires regardless of focus, but is
suppressed while a text_input has focus (so typing "S" in a field
doesn't trigger save).

### Control Tab order explicitly

By default, Tab cycles focus in the order widgets were registered
(build order in `view`). When the visual layout doesn't match the
desired Tab flow — e.g. "email goes above phone visually but Tab
should visit them in reverse" — call `widget_tab_index` on the
widgets whose order you want to pin.

```odin
email_id := skald.hash_id("email")
phone_id := skald.hash_id("phone")

skald.col(
    skald.text_input(ctx, s.phone, on_phone, id = phone_id),
    skald.text_input(ctx, s.email, on_email, id = email_id),
)

// Tab email first, phone second, regardless of build order:
skald.widget_tab_index(ctx, email_id, 1)
skald.widget_tab_index(ctx, phone_id, 2)
```

Positive values Tab first in ascending order. Zero (the default)
means "natural order after everything with a positive index." Matches
HTML's `tabindex` semantics.

### Only when the app is focused (via menu_bar)

The `menu_bar` widget registers every non-disabled item's shortcut for
you — one place to define both the menu and the shortcut. No separate
`shortcut` call needed.

### Skip a key for a specific field

```odin
if skald.is_typing(ctx) { return view_with_no_shortcuts() }
```

`is_typing` returns true when any text-input widget holds focus. Wrap
your app-wide shortcuts in an `if !skald.is_typing(ctx)` to avoid
stealing keystrokes from forms.

---

## Commands and async work

### Send a Msg after N seconds

```odin
case Login_Clicked:
    return out, skald.cmd_delay(Show_Welcome{}, seconds = 2)
```

The framework wakes itself at the deadline — lazy redraw still works.

### Dispatch multiple Msgs in order

```odin
case Save_Clicked:
    return out, skald.cmd_now({Save_To_Disk{}, Show_Toast{}, Close_Dialog{}})
```

`cmd_now` batches — every Msg lands in the same frame, in order. Use
when you want several update branches to cascade without a render
between them.

### Kick off an async file read

Skald's run loop integrates `core:nbio`, so file I/O runs on the
same thread without blocking the view/update cycle. `cmd_read_file`
takes a path and a converter proc that turns the completion result
into a `Msg`; the handler runs in a future `update` once the bytes
are on the queue.

```odin
File_Loaded :: struct { bytes: []u8 }

to_msg :: proc(r: skald.File_Read_Result) -> Msg {
    if r.err != .None { return File_Error{err = r.err} }
    return File_Loaded{bytes = r.bytes}
}

case Open_Clicked:
    return out, skald.cmd_read_file("/etc/hostname", to_msg)

case File_Loaded:
    // r.bytes is heap-owned by nbio; clone into state or delete.
    delete(out.contents)
    out.contents = strings.clone(string(v.bytes))
    delete(v.bytes)
```

`cmd_write_file` is the mirror. For native open/save dialogs use
`cmd_open_file_dialog` / `cmd_save_file_dialog`. See
`examples/14_file_viewer` for a full read+display flow.

### Run a blocking library on a background thread

Skald's nbio integration covers file I/O. Anything else that blocks —
postgres, sqlite, sync HTTP, big-file parsers, image codecs — uses
`cmd_thread`. The work proc runs on a fresh OS thread and its return
value is delivered back as a Msg. The UI never freezes.

```odin
Search_Params :: struct {
    job_id: int,
    term:   string,                                // heap-owned
}

run_search :: proc(p: Search_Params) -> Root_Msg {
    conn := postgres.pool_acquire(g_pool)
    defer postgres.pool_release(g_pool, conn)
    rows := postgres.query(conn,
        "SELECT id, name FROM users WHERE name ILIKE $1",
        p.term)
    return Search_Done{job_id = p.job_id, rows = rows}
}

case Search_Submitted:
    out.job_seq += 1
    params := Search_Params{
        job_id = out.job_seq,
        term   = strings.clone(out.draft),         // snapshot
    }
    return out, skald.cmd_thread(Root_Msg, params, run_search)

case Search_Done:
    // Drop stale results — only keep the highest job_id we've seen.
    // Without this, a slow earlier search could overwrite a newer one.
    if v.job_id < out.job_seq { return out, {} }
    out.rows = v.rows
```

`cmd_thread_simple(Root_Msg, work)` is the no-payload form for jobs
that need no runtime parameters.

**Worker contract** — these aren't enforced by the compiler; violations
are data races:

1. Don't touch any Skald state from inside the work proc — no `ctx`,
   no renderer, no widget store, no `view`-tree procs. Treat the
   worker as a plain compute thread.
2. Strings + slices in your payload (in) and your returned Msg (out)
   must be heap-allocated, not temp-arena. The worker thread has no
   Skald frame arena and the main-thread temp allocator gets reset
   under the worker's feet.
3. The work proc returns when the operation completes — one call,
   one Msg out. Don't loop forever inside it.
4. Errors are part of your Msg union (`Search_Failed{err}`) — branch
   in `update`. Don't panic; an Odin assertion in a worker terminates
   the whole process.

**Composes cleanly with library-managed pools.** A postgres `Pool`
pre-allocates N connections; `cmd_thread`'s worker calls
`pool_acquire` (which blocks if all N are in use) and `pool_release`
on the same thread. N concurrent searches with `cmd_thread` plus a
pool of N → all N run in parallel, no thread fights the pool.

Cancellation, progress reporting, and a built-in worker pool are
deliberately out of scope for now. To cancel a stale request, give
each job an incrementing `job_id` and ignore late results in `update`
(shown above). To show progress while a job runs, render a `spinner`
or animate a `progress` bar based on `state.jobs_in_flight`.

See `examples/40_threads` for a runnable demo (sleep-simulated
queries, in-flight job counter, stale-result discipline).

### Force a render every frame (DAW / live video / animation)

By default Skald is lazy — frames render only when state changes,
events arrive, or a widget asks for one (tooltip delays, toast
auto-dismiss). Real-time apps that drive their own animation from
state — DAWs with a transport playhead, live-video preview windows,
custom canvas animations — want a predictable per-frame loop instead.
Set `App.always_redraw = true` and the run loop renders every frame:

```odin
skald.run(skald.App(State, Msg){
    always_redraw = true,
    // ...
})
```

Battery-sensitive apps should leave it off and use
`widget_request_frame_at` for one-shot deadline-driven redraws
instead. This flag is the escape hatch when the work isn't
schedulable.

---

## Persistence

### Save and restore window size / position between launches

Two hooks: `App.initial_window_state` seeds the window's geometry at
launch, `App.on_window_state_change` fires a Msg whenever the user
resizes or moves it. Mirror them through your state-persistence path
and the window remembers itself.

```odin
State :: struct {
    win: skald.Window_State,   // the bit we persist
    // ... the rest of your state
}

Msg :: union { Window_Moved /* ... */ }
Window_Moved :: distinct skald.Window_State

on_win :: proc(ws: skald.Window_State) -> Msg { return Window_Moved(ws) }

// update:
case Window_Moved:  out.win = skald.Window_State(v)
```

Persist `state.win` however you already persist state (JSON, binary,
etc.). On launch:

```odin
init :: proc() -> State {
    s := default_state()
    data, err := os.read_entire_file("state.json", context.allocator)
    if err == nil {
        json.unmarshal(data, &s)
    }
    return s
}

main :: proc() {
    s0 := init()
    skald.run(skald.App(State, Msg){
        size                    = {1280, 800}, // fallback for first launch
        initial_window_state    = s0.win,
        on_window_state_change  = on_win,
        init                    = init,
        update                  = update,
        view                    = view,
    })
}
```

`Window_State` fields are `pos: [2]i32`, `size: Size`, `maximized: bool`.
All zero means "first launch" — the framework falls back to `App.size`
and lets the window manager place the window.

### Store a draft in state, flush to disk on Ctrl+S

```odin
case Save_Clicked:
    os.write_entire_file("doc.txt", transmute([]u8)out.draft)
    out.dirty = false
```

The `dirty` bool is how you greys-out Save / changes the window title
to `* Untitled`.

---

## Dev tools

### Debug inspector (F12)

No setup needed. Build with `-debug` (`odin build -debug`) and press
F12 to toggle a floating panel showing the hovered widget's id, kind,
and computed rect, plus the currently-focused widget. The hovered
widget gets outlined on screen so you can match the readout to the
thing you're pointing at. Press P to pin the current hover so you
can move the cursor without losing the readout.

Release builds (`odin build -o:speed`) strip the inspector entirely
via `when ODIN_DEBUG` — users can't trip it.

### Trace every dispatched Msg

Log in `update` at the top:

```odin
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
    fmt.printfln("msg: %v", m)
    // ...
}
```

`%v` formats a union variant with its type name, so you see
`msg: Save_Clicked{}`, `msg: Draft_Changed("hi")`, etc.

### Assert an invariant every frame

```odin
assert(len(s.items) == len(s.selection))
```

The panic lands with your stack trace intact; no extra integration
needed.

---

## More

Look in `examples/` for bigger patterns
(chat, file viewer, notes, canvas). The examples are designed to be
copy-paste starting points.

If you can't find what you need, check:

- [`guide.md`](guide.md) — the hands-on tour
- [`widgets.md`](widgets.md) — every public widget, one paragraph each
- [`gotchas.md`](gotchas.md) — common mistakes
- [`architecture.md`](architecture.md) — how the framework works inside
- `examples/` — real code
