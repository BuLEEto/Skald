# Choosing the right widget

Skald has 80+ widgets. This page is a short decision tree for the
choices that come up most. If you can answer the questions, you can
skip [`widgets.md`](widgets.md)'s full reference for the common cases.

## Text entry

| User intent | Widget |
|---|---|
| Single line of text (name, label, etc.) | `text_input` |
| Multi-line prose (notes, descriptions) | `text_input` with `multiline = true` |
| Password, masked input | `text_input` with `password = true` |
| Search box that filters incrementally on every keystroke | `text_input` with `clear_button = true, escape_clears = true` |
| Search box that fires on **Enter** (kick off a query / activate selection) | `search_field` |
| Pick from a fixed set of options by typing | `combobox` |
| Numeric value (qty, price, count) | `number_input` |

The big decision in text entry is **search box → does Enter need to
fire something?** If yes, use `search_field`. If no (you're
filtering in memory, no submit action), `text_input` with
`clear_button` and `escape_clears` gives you the same `×`-button-and-
Escape-clears affordances without forcing you to write an `on_submit`.

## Boolean and choice

| User intent | Widget |
|---|---|
| One on/off toggle | `checkbox` (compact) or `toggle` (visual switch) |
| One of N predefined options, list-style | `radio_group` |
| One of N predefined options, dropdown-style | `select` |
| One of N predefined options, segmented-button row | `segmented` |
| Type-to-filter from a long list | `combobox` |

`radio_group` vs `select` vs `segmented`: visual rather than
semantic. Three-or-fewer short options with constant visibility →
`segmented`. Five-or-more options or long labels → `select`. List
that benefits from showing all options at once and the user clicks
exactly one → `radio_group`.

## Range and numeric

| User intent | Widget |
|---|---|
| Pick a number on a continuous range (volume, opacity, …) | `slider` |
| Pick a precise number | `number_input` |
| Show progress of a known-length operation | `progress` (determinate) |
| Show "still working" without a known endpoint | `progress` (indeterminate) or `spinner` |
| Pick a 1–5 star rating | `rating` |

`slider` is for *picking*; `progress` is for *showing*. They look
similar, but slider is interactive and progress is not.

## Lists and tables

| User intent | Widget |
|---|---|
| < 100 items, simple text | `col(...children)` |
| 100s–100k items, fixed row height | `virtual_list` |
| Mixed row heights (collapsed vs expanded) | `virtual_list_variable` |
| Tabular data with sortable / resizable columns | `table` |
| Hierarchical / expandable rows | `tree` |

If your "list" is really a single column of a wider grid, use
`table` even with one column — the header, hairline divider, and
keyboard navigation come for free.

## Containers and layout

| User intent | Widget |
|---|---|
| Stack things vertically | `col` |
| Stack things horizontally | `row` |
| Same as `row` but flow onto new lines when narrow | `wrap_row` |
| 2D grid with aligned columns | `grid` |
| One pane stretches to fill remaining space | `flex(weight, child)` |
| Branch between two layouts based on slot width | `responsive` |
| Resizable two-pane split | `split` |
| Scrollable viewport for content larger than its container | `scroll` |
| Hard-clip drawing to a fixed rect | `clip` |
| Hand a child an explicit size | `sized` |

`flex` and `responsive` get confused for each other. `flex` is
"distribute leftover main-axis space"; `responsive` is "pick a
different layout shape based on how much space my parent assigned
me." They compose: `flex(1, responsive(...))` is a valid pattern.

## Overlays

| User intent | Widget |
|---|---|
| Modal blocker that the user must answer | `dialog` |
| "Are you sure?" yes/no prompt | `confirm_dialog` |
| Information-only OK prompt | `alert_dialog` |
| Auto-dismissing notification (toast) | `toast` |
| Hover hint | `tooltip` |
| Right-click options | `context_menu` |
| Searchable command list (Ctrl-K) | `command_palette` |
| App-wide menu bar with accelerators | `menu_bar` |

Skald's modals (`dialog`, `confirm_dialog`, `alert_dialog`) **never
dismiss on backdrop click** — the scrim blocks pointer events but is
not itself a "cancel" trigger. Escape and explicit Cancel/OK buttons
are the only ways out. This is intentional; see `gotchas.md`.

## Date, time, color

| User intent | Widget |
|---|---|
| Pick a date | `date_picker` |
| Pick a time of day | `time_picker` |
| Pick a colour (HSV + hex) | `color_picker` |

## When two widgets seem equally valid

Default to the simpler one. Skald's design is "fewer ways to do each
thing," and the more specialized widgets exist because the simpler
ones genuinely don't do the job, not because they're tidier. If you
can solve it with a `text_input` and don't need `search_field`'s
on_submit, use `text_input`. If you can solve it with `col` instead
of `grid`, use `col`. The cost of the more powerful widget is always
non-zero (extra params, extra concepts to read in `widgets.md`).
