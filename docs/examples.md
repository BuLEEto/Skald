# Examples

Every example is self-contained: a single `main.odin` under
`examples/NN_topic/`. Build and run with:

```bash
./build.sh NN_topic run
```

Each demo's source has a doc-comment at the top explaining what it's
meant to exercise — the one-liners below are a jumping-off point.

## By concept

### Start here

| Example | What it teaches |
|---------|-----------------|
| `00_gallery` | Every widget on one page with a live theme (Dark ↔ Light) and locale (English ↔ Español) toggle. The fastest way to see the whole widget surface; also the screenshot target for README / docs. |
| `01_hello`   | The minimum `App` record: empty state, empty view, opens a window. |
| `07_counter` | End-to-end elm round-trip: button Msgs, `update`, re-render from new state. |

### Layout and drawing primitives

| Example | What it teaches |
|---------|-----------------|
| `02_shapes`  | Low-level renderer API: rect, rounded-rect, stroke, direct frame loop. |
| `03_text`    | Fontstash text rendering, sizes and weights. |
| `04_clip`    | Clip regions and nested scissor rects. |
| `05_views`   | Declarative view tree (`col`, `row`, `rect`, `text`, `spacer`). |
| `06_flex`    | Flex layout in containers: fixed vs flex children, nested rows/cols. |

### Widgets

| Example | What it teaches |
|---------|-----------------|
| `08_text_input` | Single-line `text_input`, focus between fields, live derived text. |
| `09_widgets`    | `checkbox`, `slider`, `progress` driven by state. |
| `10_scroll`     | `scroll` container with a realistic list + detail split. |
| `12_select`     | Dropdown `select` with overlay rendering and outside-click dismiss. |
| `18_forms`      | Radio groups and form-control primitives. |
| `22_form_extras`| `divider`, `link`, `number_input`, `segmented`, toggle, plus misc. |
| `20_image`      | `image` widget: Cover / Contain / Fill / None fit modes, tints. |
| `21_split`      | Nested `split` panes (row + column), drag dividers resize. |

### Composition and identity

| Example | What it teaches |
|---------|-----------------|
| `11_composed` | `map_msg`: embed a sub-component's view, translate its Msg type. |
| `15_advanced` | `tabs`, `menu` + `right_click_zone`, explicit `hash_id` for list rows. |

### Scale

| Example | What it teaches |
|---------|-----------------|
| `16_virtual_list` | `virtual_list` rendering 10 000 fixed-height rows without building the whole tree. |
| `17_table`        | `table` with sorting, multi-select, column resize, keyboard nav over 5 000 rows. |
| `24_chat`         | `virtual_list` in variable-height mode: 10 000 wrapped chat messages, each measured to its own height. |

### Async and I/O

| Example | What it teaches |
|---------|-----------------|
| `13_stopwatch`  | `cmd_delay` as a recurring timer; wall-clock elapsed time. |
| `14_file_viewer`| `cmd_read_file` end-to-end: click → Command → handler → Msg. |
| `23_editor`     | Full persistence flow: file pickers, `cmd_read_file` / `cmd_write_file`, drag-and-drop, toasts. |

### Modals

| Example | What it teaches |
|---------|-----------------|
| `19_dialog` | Modal `dialog`: scrim blocks clicks, Escape routes to Cancel, focus trap. |

### Windows

| Example | What it teaches |
|---------|-----------------|
| `38_multi_window` | `cmd_open_window` + `cmd_close_window`, dispatching per window via `ctx.window`, the `on_close` callback that fires for both programmatic and X-button close. The pattern for dock popovers, notifications, floating palettes. |

## Suggested learning path

1. `01_hello` → `07_counter` — the mental model.
2. `05_views` → `06_flex` — how layout composes.
3. `08_text_input` → `09_widgets` → `12_select` — the everyday widgets.
4. `10_scroll` → `16_virtual_list` → `24_chat` → `17_table` — scaling from 80 to 10 000 rows, fixed to variable height.
5. `13_stopwatch` → `14_file_viewer` → `23_editor` — async commands.
6. `11_composed` + `15_advanced` — composition and explicit IDs once you
   have multi-screen apps or dynamic lists.

## Writing a new example

Copy the layout of `07_counter` — package name `example_<topic>`, a
`State`, a `Msg`, `init` / `update` / `view`, and a `main` that calls
`skald.run`. The top-of-file doc comment should say *why* the example
exists; the code itself shows *how*.
