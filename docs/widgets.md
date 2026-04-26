# Widget reference

Every public widget builder, grouped by what it's for. Signatures
here show the parameters you'll actually reach for — the full list is
in `odin doc ./skald`.

For usage patterns and finished apps, see the examples linked at the
end of each section.

## Contents

- [Layout](#layout) — col, row, grid, spacer, flex, sized, clip, scroll, split
- [Primitives](#primitives) — text, rect, divider, image
- [Buttons and links](#buttons-and-links) — button, link
- [Text entry](#text-entry) — text_input, search_field, number_input
- [Booleans and choice](#booleans-and-choice) — checkbox, radio, radio_group, toggle, select, combobox, segmented
- [Range and numeric](#range-and-numeric) — slider, progress, spinner, rating
- [Date, time, color](#date-time-color) — date_picker, time_picker, color_picker
- [Lists and tables](#lists-and-tables) — virtual_list, table, tree
- [Navigation](#navigation) — tabs, breadcrumb, menu_bar, command_palette
- [Containers and layout helpers](#containers-and-layout-helpers) — list_frame, form_row, section_header, collapsible, accordion, empty_state
- [Small decorations](#small-decorations) — badge, chip, avatar, kbd, stepper, alert
- [Floating and feedback](#floating-and-feedback) — overlay, tooltip, dialog, confirm_dialog, alert_dialog, toast, menu
- [Interaction helpers](#interaction-helpers) — right_click_zone, context_menu, drop_zone, drag_over
- [Framework helpers](#framework-helpers) — widget_tab_index, font_add_fallback, Window_State

---

## Layout

### col / row

```odin
col(..children, spacing = 0, padding = 0, width = 0, height = 0,
    main_align = .Start, cross_align = .Start, bg = {}, radius = 0)
```

Stack children along an axis. `col` is vertical, `row` is horizontal.
`spacing` is the gap between children; `padding` is the margin inside
the container. Zero on `width` / `height` means "size to fit content"
unless the parent is a flex layout, in which case you'll be stretched
to the assigned slot.

`main_align` controls how leftover main-axis space is distributed
(only relevant when there's no `flex` child eating it). `cross_align`
controls perpendicular alignment.

### grid

```odin
grid(ctx, columns: []f32, ..children: View,
     spacing_x = 0, spacing_y = 0, padding = 0,
     width = 0, bg = {}, radius = 0)
```

Two-dimensional table with aligned column widths. `columns` is a
per-column width array: a positive value fixes that column in pixels,
a zero makes it a flex column that splits the remaining width with
the other flex columns. Children fill row-major — the first
`len(columns)` children form the first row, the next `len(columns)`
the second, and so on.

```odin
skald.grid(ctx,
    {120, 0, 80},                  // label col fixed, middle flex, action col fixed
    row1_label, row1_content, row1_action,
    row2_label, row2_content, row2_action,
    spacing_x = 8,
    spacing_y = 4,
)
```

Pass a concrete `width` for a fixed-size grid; leave it at 0 to fill
the parent's cross axis (same contract as `scroll`, so the parent
must stretch the grid). The last row may have fewer children than
there are columns — extra cells render as empty spacers so the grid
stays rectangular.

### spacer

```odin
spacer(size: f32) -> View
```

A fixed-size gap. Use when you want a specific pixel distance between
two children instead of uniform `spacing`.

### flex

```odin
flex(weight: f32, child: View) -> View
```

Inside a `row` or `col`, takes a `weight`-proportional share of the
leftover main-axis space. `flex(1, a)` alongside `flex(2, b)` splits
1/3 : 2/3. Inside a content-sized parent there is no leftover space,
so flex children collapse to zero — see `gotchas.md`.

### sized

```odin
sized(ctx, data: ^T, build: proc(ctx, data: ^T, size: [2]f32) -> View,
      min_w = 0, min_h = 0)
```

Defers the `build` call until layout has assigned this node a rect,
then re-enters with the real size. Used internally by `scroll`,
`virtual_list`, `table` to implement "zero on an axis = fill the
assigned slot." Apps rarely call `sized` directly.

### clip

```odin
clip(size: [2]f32, child: View) -> View
```

Hard-clip drawing to a fixed rect. Anything the child would draw
outside gets scissored away.

### scroll

```odin
scroll(ctx, size: [2]f32, content: View, wheel_step = 40,
       focusable = false)
```

Clipped viewport with an autohiding scrollbar. Zero on an axis means
"fill what my flex parent gives me"; pass real numbers to fix the
viewport size. `focusable = true` lets the viewport take keyboard
focus for PageUp/PageDown/arrow-key scrolling.

### split

```odin
split(ctx, first: View, second: View, first_size: f32,
      on_resize: proc(new_first_size: f32) -> Msg,
      direction = .Row, min_first = 40, min_second = 40)
```

Two-pane resizable container. `first_size` is the current size of
the first pane along `direction` (logical pixels). The divider is
draggable; drags fire `on_resize` with the new `first_size`.

**Example: `examples/21_split`.**

---

## Primitives

### text

```odin
text(str: string, color: Color, size: f32 = 14, font = 0, max_width: f32 = 0)
```

Draws a text run. `size` defaults to 14 px. Pass `max_width` to enable
word-wrap at that pixel width. `font` is the handle from `add_font`;
`0` means the renderer's default (Inter).

### rect

```odin
rect(size: [2]f32, color: Color, radius: f32 = 0)
```

Flat coloured rectangle with optional corner radius.

### divider

```odin
divider(ctx, vertical = false, color = {}, thickness = 1)
```

A 1-pixel rule. Inside a `row`, use `vertical = true`; inside a `col`,
leave it off. Color falls back to theme border.

### image

```odin
image(ctx, path: string, width = 0, height = 0,
      fit = .Cover, tint = {1, 1, 1, 1})
```

Loads an image from `path` and draws it scaled to fit. `fit` is
`.Cover` (fill, crop), `.Contain` (fit, letterbox), `.Fill` (stretch),
or `.None` (pixel-exact). Images are cached by path — cheap to use
the same one in many places.

`path` can be a file path **or** a synthetic name registered through
`image_load_pixels` (see below) — the widget treats both the same.

**Example: `examples/20_image`.**

#### image_load_pixels

```odin
image_load_pixels(r: ^Renderer, name: string, w, h: u32, rgba: []u8) -> bool
```

Registers an in-memory RGBA8 buffer with the image cache under a
synthetic name, so any later `image(ctx, name, …)` draws it the same
way as a file-loaded image. Use it when the pixels come from anywhere
other than disk — a rasterized DXF / SVG / PDF page, a video frame, an
in-memory PNG fetched over the network, a procedurally generated
thumbnail, a golden-image test fixture.

`rgba` must be exactly `w * h * 4` bytes (RGBA8 sRGB, straight alpha).
Bytes are copied into a staging buffer synchronously — the caller's
slice does not need to outlive the call.

Pick a name unlikely to collide with any file path you might also
load (`"app://thumb/42"`, `"dxfwg.viewport"`). Calling with an
existing name replaces the entry (after a `DeviceWaitIdle`) so a
producer that re-renders on demand can keep the same name.

Returns `true` on success, `false` on size mismatch or allocation
failure. Pair with `image_unload(r, name)` when you're done.

**Not** intended for per-frame updates — replacement allocates a fresh
texture every call. For per-frame refresh of the same name + size,
seed once with `image_load_pixels` and refresh in-place via
`image_update_pixels` (below).

#### image_update_pixels

```odin
image_update_pixels(r: ^Renderer, name: string, w, h: u32, rgba: []u8) -> bool
```

Refreshes an already-registered image in place — reuses the existing
`VkImage` / memory / view / descriptor set. One staged copy + a queue
wait for that one upload, no fresh allocations, no `DeviceWaitIdle`.
Cheap enough for 60 fps streaming sources: software rasterizers (CAD
pan / zoom), video frame queues, paint canvases.

Preconditions: `name` already registered (call `image_load_pixels`
once first), and `w` × `h` matches the existing entry's extent. Mips
are regenerated CPU-side and re-uploaded each call so shrunken samples
don't read stale levels.

Returns false on miss (name not registered, or size mismatch) — caller
re-seeds via `image_load_pixels` if the dimensions changed.

#### draw_image

```odin
draw_image(r: ^Renderer, name: string, rect: Rect,
           fit = .Cover, tint = {1, 1, 1, 1}) -> bool
```

Paints a registered image inside a `canvas` callback at `rect` (logical
pixels). Use this when you want to composite an image *behind* app-drawn
overlay primitives (lines, markers, text) in the same canvas node — the
ordinary `image()` widget can't be interleaved with `draw_*` calls
because it lives in the view tree, not the immediate-mode canvas
pass. Same `Image_Fit` semantics as the widget.

---

## Buttons and links

### button

```odin
button(ctx, label: string, on_click: Msg,
       color = {}, fg = {}, radius = 0, padding = {0, 0},
       font_size = 0, width = 0, text_align = .Center)
```

Clickable rectangle. `on_click` is the Msg value (not a proc) that
Skald enqueues when the button is clicked. Color and fg fall back to
theme neutrals — pass `th.color.primary` / `th.color.on_primary` for
a call-to-action.

### link

```odin
link(ctx, label: string, on_click: Msg, color = {}, color_hover = {},
     font_size = 0, underline = true)
```

Text-only clickable, no background or padding. For inline references,
hyperlink-styled actions, etc.

---

## Text entry

### text_input

```odin
text_input(ctx, value: string, on_change: proc(new: string) -> Msg,
           placeholder = "", width = 0, height = 0,
           read_only = false, multiline = false, wrap = false,
           password = false, search = false,
           invalid = false, error = "")
```

Editable text field. Single-line by default; set `multiline = true`
for a text area (and `wrap = true` if you want soft-wrap). Built-in:
selection, clipboard (Ctrl+C/X/V), Ctrl-A select all, undo/redo
(Ctrl+Z/Y), cursor navigation, IME.

`password = true` masks input and suppresses copy/cut. `search = true`
adds a magnifier glyph and defaults the placeholder to "Search."
`invalid = true` + `error = "..."` renders the red-underline error
affordance.

`on_change` is called with the new value on every edit — you clone
the string onto state if you want to keep it (see `gotchas.md`).

**Examples: `examples/08_text_input`, `examples/18_forms`.**

### search_field

```odin
search_field(ctx, value, on_change, on_submit: proc() -> Msg,
             placeholder = "", ...)
```

`text_input` with `search = true` plus an `on_submit` callback that
fires on Enter. Use this when pressing Enter should kick off a search
rather than insert a newline.

### number_input

```odin
number_input(ctx, value: f64, on_change: proc(new: f64) -> Msg,
             step = 1, min_value = min(f64), max_value = max(f64),
             decimals = 0, width = 140)
```

Typeable numeric field with `+` / `−` stepper buttons on the side.
`decimals` controls the display precision. Out-of-range values are
clamped on commit.

**Example: `examples/22_form_extras`.**

---

## Booleans and choice

### checkbox

```odin
checkbox(ctx, checked: bool, label: string,
         on_change: proc(new: bool) -> Msg, read_only = false)
```

Classic boolean toggle with a label to the right. Pass
`label = ""` for a bare checkbox (in a table cell, say).

### radio / radio_group

```odin
radio(ctx, selected: bool, label: string,
      on_select: proc() -> Msg)

radio_group(ctx, options: []string, selected: int,
            on_change: proc(index: int) -> Msg,
            direction = .Column, spacing = -1)
```

`radio` is one circle. `radio_group` is the common case — a list of
string options, the runtime handles the "only one at a time"
semantics and arrow-key navigation.

### toggle

```odin
toggle(ctx, on: bool, label: string,
       on_change: proc(new: bool) -> Msg, read_only = false)
```

iOS-style pill switch. Same semantics as `checkbox`; picks when
you want the setting to feel less form-like and more affordance-y.

### select

```odin
select(ctx, value: string, options: []string,
       on_change: proc(new: string) -> Msg,
       placeholder = "", read_only = false, width = 0)
```

Dropdown. `value` is the currently chosen string (matched exactly
against `options`). Opens a popover of clickable rows. Use when the
option list is short enough that scanning is faster than typing.
Default placeholder comes from `ctx.labels.select_placeholder`
("Select…" in English).

**Example: `examples/12_select`.**

### combobox

```odin
combobox(ctx, value: string, options: []string,
         on_change: proc(new: string) -> Msg,
         placeholder = "", filter = true, free_form = false,
         read_only = false, max_chars = 0, width = 0)
```

Text-input trigger with a filtered dropdown. Typing narrows the list
(by default); arrow keys move the highlight; Enter or click commits.
Use instead of `select` when the option list is long enough that
scanning becomes slower than typing.

`filter = false` keeps the full list visible while typing — useful
for short lists where you want Windows-style "type a letter, jump to
first match" typeahead.

`free_form = true` lets Enter commit whatever the user typed even
when it isn't an option. Email entry with suggestions, tag inputs,
and similar "suggestions are helpers, not a constraint" flows fit
this shape.

Escape cancels (blurs without committing). Clicking outside the
trigger or popover also dismisses.

**Example: `examples/00_gallery` (Selection section).**

### segmented

```odin
segmented(ctx, options: []string, selected: int,
          on_change: proc(index: int) -> Msg, read_only = false)
```

Mutually-exclusive tabs styled as a connected pill. Good for small
option sets where you want everything visible at once.

---

## Range and numeric

### slider

```odin
slider(ctx, value: f32, on_change: proc(new: f32) -> Msg,
       min_value = 0, max_value = 1, step = 0,
       width = 0, track_h = 4, thumb_r = 8, read_only = false)
```

Horizontal draggable value control. `step = 0` gives continuous
values; any positive step quantizes.

### progress

```odin
progress(ctx, value: f32, width = 0, height = 6,
         color_bg = {}, color_fill = {},
         indeterminate = false, period = 1.2)
```

Non-interactive fill indicator, `value ∈ [0, 1]`. Set
`indeterminate = true` for the "working…" sliding bar animation;
`period` is its cycle time in seconds.

### spinner

```odin
spinner(ctx, size = 24, color = {}, phase = 0)
```

Circular indeterminate "working, no known ETA" indicator — eight
dots in a ring, alpha trailing around the circle. Schedules its own
next frame via `widget_request_frame_at`, so lazy redraw keeps the
animation running without the app managing a ticker.

### rating

```odin
rating(ctx, value: int, on_change: proc(v: int) -> Msg,
       max_value = 5, size = 20,
       filled = "★", empty = "☆")
```

Clickable row of stars. Click a star to set that rating; click the
currently-set star to clear.

---

## Date, time, color

### date_picker

```odin
date_picker(ctx, value: Date, on_change: proc(new: Date) -> Msg,
            placeholder = "", read_only = false,
            min_date = {}, max_date = {},
            format: proc(d: Date) -> string = nil,
            week_start = .Locale)
```

Form-row trigger that opens a calendar popover. Leaves the app owning
the `Date` value. `format` overrides the display formatter; default
is locale-aware (`date_format`, which reads `LC_TIME`/`LANG` or
Windows regional settings). Default placeholder and month/weekday
names come from `ctx.labels` — see the **Labels and i18n** section
in `architecture.md`.

The popover has a footer with **Today** (jumps to the current date
+ commits + closes) and **Clear** (zeroes the value so the trigger
reverts to its placeholder). `Date{}` = year 0 / month 0 / day 0 is
the canonical "no date" sentinel.

**Example: `examples/30_date_picker`.**

### time_picker

```odin
time_picker(ctx, value: Time, on_change: proc(new: Time) -> Msg,
            placeholder = "",
            minute_step = 15, second_step = 0,
            format: proc(t: Time) -> string = nil)
```

Trigger that opens an hour/minute/second popover. Default shows
only hours + minutes (minute step 15); set `second_step > 0` to
surface seconds. See `time_format_12h` / `time_format_24h` for
explicit 12- or 24-hour display.

The popover has a **Now** button that commits the current wall-clock
hour + minute (snapped to `minute_step`, seconds zeroed) and closes.
There is no Clear button — `Time{}` is a valid midnight, so "clear"
has no unset state to snap to. Apps that need a nullable time should
wrap it in a `Maybe(Time)` or similar and own their own clear button.

**Example: `examples/31_time_picker`.**

### color_picker

```odin
color_picker(ctx, value: Color, on_change: proc(new: Color) -> Msg,
             width = 0, read_only = false)
```

Swatch trigger that opens an HSV square + hue strip + hex input
popover. Emits `on_change` live while dragging and on hex commit.

**Example: `examples/35_color_picker`.**

---

## Lists and tables

### virtual_list

```odin
virtual_list(ctx, state: T, total_count: int, item_height: f32,
             viewport: [2]f32,
             row_builder: proc(ctx, state: T, index: int) -> View,
             row_key:     proc(state: T, index: int) -> u64,
             overscan = 4, variable_height = false,
             estimated_height = 0, focusable = false)
```

Renders only the rows currently visible in `viewport`. `state` is
passed through to `row_builder` untouched; the builder indexes into
it to produce the row view. Zero on an axis = fill (same as `scroll`).

**`row_key` is required** — it returns a stable `u64` identity for
the item at index `i`. Widget state inside cells (focus, text buffer,
checked, expanded) is scoped by this key, so state follows the
*item* through reorders / filters / sort changes rather than
following the row position. For synthetic lists that never reorder,
just `proc(s: ^State, i: int) -> u64 { return u64(i) }`. For a real
data set, return the item's database id or hash of a stable string.
A nil `row_key` safely falls back to index-keying — useful if you're
roughing something out, but unstable under reorder.

Set `variable_height = true` with `estimated_height` as a seed when
rows differ in height; the list measures each row on first render and
caches. Most apps don't need this.

**Examples: `examples/16_virtual_list`, `examples/27_fill_list`,
`examples/29_fill_scroll`, `examples/24_chat`.**

### table

```odin
table(ctx, state: T, columns: []Table_Column, row_count: int,
      item_height: f32, viewport: [2]f32,
      row_builder: proc(ctx, state: T, row: int) -> []View,
      row_key:     proc(state: T, row: int) -> u64,
      on_row_click: proc(row: int, mods: Modifiers) -> Msg,
      is_selected: proc(state: T, row: int) -> bool,
      on_sort_change: proc(col: int, ascending: bool) -> Msg,
      on_resize: proc(col: int, new_width: f32) -> Msg,
      on_row_activate: proc(row: int) -> Msg,
      sort_column = -1, sort_ascending = true,
      focus_row = -1, header_height = 32)
```

Virtualized, sortable, resizable, selectable data grid. `row_builder`
returns one `View` per column (must match `len(columns)`). Any
callback may be nil to disable that interaction. `row_key` is
required and works the same way as in `virtual_list`: it returns the
stable id for the item at `row`, so state scoped inside cells
follows the item when the user re-sorts the table. A typical
sorted-table pattern is `proc(s: ^State, visible: int) -> u64 {
return u64(s.sorted[visible]) }` where `s.sorted[visible]` maps the
visible row position to the underlying source row.

**Column sizing**: each `Table_Column` sets *either* `width` (fixed px)
*or* `flex` (share of leftover width), not both. A column that has
neither set gets zero width and disappears — designate at least one
column as flex so it expands to fill the viewport.

**Cell views**: `row_builder` should return raw views (`text`, `badge`,
`button`, …) one per column — exactly `len(columns)` of them, in the
same order. Wrapping each cell in a `col(…)` with its own padding
breaks column alignment; the col sizes to its text and drifts out of
the column slot. The table owns cell padding and the column-wide
width; let it. Debug builds assert on cell-count mismatch so a
miscounted slice surfaces at the row builder instead of mysteriously
showing a badge in the Owner column.

For shift-select / ctrl-toggle, read `mods` in `on_row_click`.
`on_row_activate` fires on double-click or Enter when a row has
keyboard focus.

Widget IDs inside `row_builder` are auto-scoped per `row_key(state,
row)` return value (same as `virtual_list`) — cells can contain any
stateful widget without extra ceremony, and state follows the item
through every sort / filter.

Column visibility: set `Table_Column.hidden = true` to collapse a
column entirely (header, body cells, and resize handles are skipped).
`row_builder` is still called with the full set of cells — it's
simpler to over-produce and let the table drop the hidden ones than
to thread a visible-column mask through the builder. Good for
letting users show/hide columns via a settings menu without
re-shaping the app's row logic.

**Examples: `examples/17_table`, `examples/28_fill_table`.**

### tree

```odin
tree(ctx, rows: []Tree_Row,
     on_toggle: proc(row_idx: int) -> Msg,
     on_select: proc(row_idx: int) -> Msg,
     row_height = 0, indent = 0, width = 0)
```

Flat-array collapsible outline. You build `[]Tree_Row` in your own
code (depth, label, expanded, selected fields); the widget handles
rendering, keyboard nav, and click/toggle events. Keeping tree shape
on app state means you can reorder and filter without fighting the
widget.

**Example: `examples/34_tree`.**

---

## Navigation

### tabs

```odin
tabs(ctx, labels: []string, active: int,
     on_change: proc(index: int) -> Msg)
```

Horizontal strip of tab labels, one marked active. The tabs widget
doesn't swap content for you — render the appropriate body based on
`active` in your `view`.

### breadcrumb

```odin
breadcrumb(ctx, segments: []string,
           on_select: proc(index: int) -> Msg,
           separator = "›", font_size = 0)
```

Clickable nav trail. `on_select` fires with the index of the clicked
segment.

### menu_bar

```odin
menu_bar(ctx, entries: []Menu_Entry(Msg))
```

Top-level menu bar with keyboard accelerators and hover-switch between
menus. Each `Menu_Item` carries a label, an optional `Shortcut`, the
`Msg` to dispatch, and three optional flags:

- `disabled = true` — grey the row out, drop the shortcut from the
  global accelerator registry.
- `separator = true` — render a horizontal divider; all other fields
  ignored.
- `checked = true` — prefix the row with a ✓ glyph for togglable
  state (View → Show Grid, View → Word Wrap, etc.). Set this from
  your state in `view`; dispatch a flip-msg on click. The leading
  column is only reserved when at least one item in the active menu
  is currently checked, so menus without checks lay out unchanged.

Need an icon next to a label? Use the same Font Awesome / Lucide /
Phosphor fallback trick from the Fonts cookbook section — embed the
PUA codepoint in `label`.

**Example: `examples/33_menu_bar`.**

### command_palette

```odin
command_palette(ctx, open: bool,
                entries: []Menu_Entry(Msg),
                on_dismiss: proc() -> Msg,
                width = 520, max_rows = 10,
                placeholder = "Type a command…")
```

Ctrl+K-style fuzzy-search overlay that reads from the same
`[]Menu_Entry` slice `menu_bar` consumes. Enter dispatches the
highlighted item, Esc calls `on_dismiss`, ↑/↓ walk the match list.
Only `menu_bar` registers shortcut accelerators — the palette is a
passive viewer, so hotkeys never double-fire. Apps without a visible
menu bar can pass entries with empty labels and the palette drops
the "Entry → " prefix from rows.

**Example: `examples/00_gallery`** (Ctrl+K).

---

## Containers and layout helpers

### list_frame

```odin
list_frame(ctx, first: View, rest: ..View,
           bordered = true, divided = true,
           bg = {}, border = {}, div_color = {},
           padding = -1, radius = -1, width = 0)
```

A surface card with hairline border and 1-px dividers between rows —
the Mac/iOS "grouped list" look. `first` is required so Odin's
polymorphic variadic can infer `$Msg`; any later rows go in `rest`.

### form_row

```odin
form_row(ctx, label: string, control: View,
        label_width = 0, spacing = 0)
```

Pairs a left-hand label with a right-hand control. Build forms by
stacking `form_row` inside a `col`.

**Examples: `examples/18_forms`, `examples/22_form_extras`.**

### section_header

```odin
section_header(ctx, title: string, color = {}, font_size = 0)
```

Horizontal rule with a centered title, for grouping settings or form
sections without full card borders.

### collapsible

```odin
collapsible(ctx, title: string, open: bool,
            on_toggle: proc(new_open: bool) -> Msg,
            content: View)
```

Disclosure triangle + content panel. You own the open/closed bool;
the widget fires `on_toggle` when clicked.

**Example: `examples/25_collapsible`.**

### accordion

```odin
accordion(ctx, sections: []Accordion_Section, open_index: int,
          on_toggle: proc(idx: int) -> Msg,
          spacing = 0, padding = -1, font_size = 0)
```

Group of `collapsible`-like panels where at most one is open at a
time. The app owns `open_index`: `-1` means "all closed," any valid
index means "that one is open." Clicking the open panel's header
closes it; clicking a different one swaps.

`on_toggle` fires with the index that should become the new
`open_index` — the caller just stores what it's given:

```odin
Panel_Toggled :: distinct int
// …
case Panel_Toggled: out.panel_idx = int(v)
```

Use for settings drawers, property inspectors, and other "look at
one thing at a time" groups. For the "any number open at once"
pattern, stack independent `collapsible` widgets in a `col`.

### empty_state

```odin
empty_state(ctx, title: string, description = "",
            action: View = View_Spacer{size = 0})
```

Centered placeholder for empty lists and no-search-match results.
Pass an optional `action` view (typically a button) to guide the user.

---

## Small decorations

### badge

```odin
badge(ctx, label: string, tone = .Primary,
      bg = {}, fg = {}, font_size = 0)
```

Small rounded pill for counts ("3"), status tags ("NEW"), labels.
`tone` is one of `.Primary`, `.Neutral`, `.Success`, `.Warning`,
`.Danger`.

### chip

```odin
chip(ctx, label: string,
     on_close: proc(label: string) -> Msg,
     tone = .Neutral)
```

Badge with an × close glyph. Use for filter tags, selected items in
a picker, and other "things that can be dismissed."

### avatar

```odin
avatar(ctx, initials: string, size = 32, bg = {}, fg = {})
```

Circular user chip. Colour is hashed stably from the initials, so the
same person always gets the same colour. For a "+N more" roster,
compose `row(avatar(...), avatar(...), spacing = -10)` — the negative
spacing produces the overlapping-bubble look without a dedicated widget.

### kbd

```odin
kbd(ctx, label: string, font_size = 0)
```

Keyboard shortcut hint, styled as a slightly-raised rounded rect.
`kbd("⌘K")` or `kbd("Ctrl+S")`.

### stepper

```odin
stepper(ctx, labels: []string, current: int, disc_size = 24)
```

Horizontal progress indicator for multi-step flows (wizards,
checkouts). Visual only — advance by updating `current` from your
Msgs.

### alert

```odin
alert(ctx, title: string, description = "", tone = .Primary)
```

Inline notice box with a coloured left stripe. Use for warnings and
info banners that should stay visible in-flow, not pop up as toasts.

---

## Floating and feedback

### overlay

```odin
overlay(anchor: Rect, child: View,
        placement = .Below, offset = {0, 0})
```

Low-level popover primitive — pins `child` to `anchor` on the overlay
layer. Used by `select`, `menu`, `date_picker`, etc. Apps usually
want the higher-level widgets rather than calling `overlay` directly.

### tooltip

```odin
tooltip(ctx, child: View, text: string)
```

Hover-triggered popover after a short delay. Wraps any existing view.

### dialog

```odin
dialog(ctx, open: bool, content: View,
       on_dismiss: proc() -> Msg,
       initial_focus: Widget_ID = 0,
       width = 0, max_width = 480, padding = 0,
       bg = {}, border = {}, scrim = {})
```

Modal dialog with a full-frame scrim. The scrim swallows clicks but
**does not dismiss** — Esc and explicit buttons are the only ways
out. `on_dismiss` fires on Esc.

On open the dialog snapshots whatever widget held focus; on close it
restores that focus. `initial_focus` (when non-zero) seeds focus to
a specific widget inside the card on open — typically the first
text input.

**Example: `examples/19_dialog`.**

### confirm_dialog

```odin
confirm_dialog(ctx, open: bool, title, body: string,
               on_confirm, on_cancel: proc() -> Msg,
               confirm_label = "OK", cancel_label = "Cancel",
               danger = false, width = 0)
```

Sugar over `dialog` for the "are you sure?" prompt. Title + wrapped
body + two buttons. `danger = true` tints the confirm button red
for destructive flows.

### alert_dialog

```odin
alert_dialog(ctx, open: bool, title, body: string,
             on_ok: proc() -> Msg,
             ok_label = "OK", width = 0)
```

Single-button variant of `confirm_dialog` for error / success /
"you've been signed out" acknowledgements.

### toast

```odin
toast(ctx, visible: bool, message: string,
      on_close: proc() -> Msg, kind = .Info,
      anchor = .Bottom_Center, max_width = 420,
      margin = 16, dismiss_after = 0)
```

Viewport-pinned notification ("snackbar"). `kind` is `.Info`,
`.Success`, `.Warning`, or `.Danger`. Set `dismiss_after = 3.0` for
auto-dismiss after 3 seconds (the runtime schedules an internal
`cmd_delay`).

**Example: `examples/23_editor`** (save/load success and error toasts).

### menu

```odin
menu(ctx, labels: []string,
     on_select: proc(index: int) -> Msg,
     on_dismiss: proc() -> Msg, width = 200)
```

Vertical popover of clickable rows — context menus, dropdown lists.
For menu-bar style top-level menus, use `menu_bar` instead.

---

## Interaction helpers

### right_click_zone

```odin
right_click_zone(ctx, child: View, on_right_click: Msg)
```

Wraps a child view as a right-click target. Emits `on_right_click`
when the user right-clicks inside the rect. Use when you want the
click to go to app state and you'll drive the popover yourself;
otherwise prefer `context_menu` which bundles both.

### context_menu

```odin
context_menu(ctx, child: View, items: []string,
             on_select: proc(index: int) -> Msg, width = 200)
```

Right-click-detecting wrapper that pops a menu of `items` at the
click point. Selecting an item fires `on_select(i)`; clicking outside
or pressing Escape dismisses. Open state lives inside the widget —
callers only see the on_select msg when the user commits.

```odin
skald.context_menu(ctx,
    layer_row_view,
    {"Rename", "Duplicate", "Delete"},
    proc(i: int) -> Msg { return Layer_Menu(i) },
)
```

Auto-flips above the cursor when a below-cursor placement would
overflow the framebuffer, same rule as date/time/color pickers.

### drop_zone

```odin
drop_zone(ctx, child: View,
          on_drop: proc(files: []string) -> Msg)
```

Passthrough wrapper that fires `on_drop` when files are dragged from
the OS onto the child's rect. File paths are frame-arena strings —
clone what you want to keep.

### drag_over

```odin
drag_over(ctx, id: Widget_ID) -> bool
```

Returns true while a drag is in progress **and** the cursor is inside
the matching `drop_zone`'s rect. Use this to tint the drop zone's
border during drag-over.

**Example: `examples/23_editor`** (drop a file to open it).

## Framework helpers

These aren't widgets — they're small procs exposed for app-level
coordination that doesn't fit inside a single builder's signature.

### widget_tab_index

```odin
widget_tab_index(ctx, id: Widget_ID, tab_index: int)
```

Override the Tab ring position of a focusable widget for the current
frame. Positive values come first in ascending order; `0` (the
default every widget registers with) means "natural order after
everyone with an explicit index." Call after the widget builder;
a no-op if `id` didn't register (read_only / disabled widget, or
wrong id). HTML `tabindex` semantics minus the negative case.

### font_add_fallback

```odin
font_add_fallback(r: ^Renderer, base, fallback: Font) -> bool
```

Chain `fallback` onto `base` so codepoints missing from the base
font fall through to the next font in the chain. Use
`font_default(r)` as `base` to extend the framework-wide glyph
coverage beyond Inter (Latin + Cyrillic). Up to 20 fallbacks per
base. Handles CJK / Cyrillic extensions / symbols cleanly; complex
scripts (Arabic, Devanagari, Thai) render glyphs but without
contextual shaping — HarfBuzz integration is post-1.0.

### Window_State, initial_window_state, on_window_state_change

```odin
Window_State :: struct {
    pos: [2]i32, size: Size, maximized: bool,
}
// On App:
initial_window_state:    Window_State
on_window_state_change:  proc(ws: Window_State) -> Msg
```

Round-trip window geometry through the app's own persistence so the
window remembers its size and position between launches. See the
cookbook recipe "Save and restore window size / position between
launches."
