# Skald Architecture

This document describes how Skald fits together: the frame loop, the view
tree, widget identity, theming, async I/O, and the rendering pipeline.
It's written for people reading the source or writing non-trivial apps —
if you just want a taste, start with `examples/07_counter`.

## The elm loop

A Skald app is four things — `State`, `Msg`, `update`, `view` — glued
together by `skald.run`.

```
skald.App(State, Msg) {
    init:   proc() -> State
    update: proc(State, Msg) -> (State, Command(Msg))
    view:   proc(State, ^Ctx(Msg)) -> View
}
```

`State` and `Msg` are compile-time type parameters, so `update` sees the
app's real message union — not a rawptr, not an interface. Widget builders
(`button`, `select`, `text_input`, …) are parameterized by `Ctx($Msg)`
the same way, which keeps `skald.button(ctx, "Save", Msg.Save)` type-safe
end to end.

### One frame

`skald.run` drives this loop (see `skald/app.odin`):

```
loop {
    window_pump(&w)              // SDL events → Input snapshot
    drain_due_delays(...)        // cmd_delay timers whose deadline passed
    nbio.tick(0); drain_io(...)  // completed async ops → Msg queue
    widget_advance_focus(...)    // Tab / Shift-Tab
    widget_store_frame_reset()
    modal_click_preprocess()     // scrim swallows backdrop clicks
    if frame_begin() {
        v := app.view(state, &ctx)   // build the tree, hit-test, push Msgs
        render_view(r, v, ...)       // draw the tree
        render_overlays(r)           // dropdowns/menus/tooltips on top
        frame_end(r)
    }
    window_set_text_input(...)   // IME on/off for focused field
    while msgs not empty {
        state, cmd = update(state, msg)
        process_command(cmd, ...) // Now msgs re-enter the loop; Delay/Async queue
    }
    free_all(temp_allocator)
}
```

Key properties:

- `view` and `update` never talk to the outside world directly. I/O goes
  through `Command(Msg)`; the runtime performs it.
- Strings built inside `view` (and Msg payloads built inside builders) live
  in `context.temp_allocator`, reset at the end of every frame. If a Msg
  payload must survive into `update` or beyond, clone it before returning
  from the builder or on first receipt.
- `cmd_now` msgs cascade within a single frame. `Delay`, `Batch`-of-delay,
  and `Async` commands land on later frames.
- One frame of lag between a *view-generated Msg* (a click) and its visible
  result: the click is pushed in frame N, consumed by `update` at the end
  of frame N, rendered from new state in frame N+1.

## The view tree

`View` is a recursive record built each frame (see `skald/view.odin`). The
top-level builders:

- Layout: `col`, `row`, `wrap_row`, `grid`, `flex`, `clip`, `scroll`,
  `split`, `responsive`
- Primitives: `text`, `rect`, `spacer`, `image`, `divider`
- Widgets: `button`, `checkbox`, `radio`, `toggle`, `slider`, `progress`,
  `select`, `text_input`, `number_input`, `segmented`, `tabs`, `menu`,
  `right_click_zone`, `drop_zone`, `tooltip`, `toast`, `dialog`, `link`,
  `table`, `virtual_list`

Widgets *push* Msgs onto `ctx.msgs` when the input frame says they were
clicked, dragged, typed into, or dropped on. The builder returns a `View`
describing what to draw; nothing executes synchronously inside the builder
other than hit-testing against the previous frame's rectangle.

Layout is a single top-down pass during `render_view`: containers measure
children, assign rects, and the draw pass emits commands in tree order.
That's why widgets hit-test against `last_rect` (the *previous* frame's
rect) — the current frame's rect isn't known yet at builder time.

## Widget identity

Widgets need to persist focus, hover, press, selection, scroll offsets, and
other bits across frames. The `Widget_Store` (`skald/widget.odin`) is a
map from `Widget_ID` to `Widget_State`.

Two IDs sources:

- **Positional** — `widget_auto_id` assigns the first widget id 1, the
  second id 2, and so on. Stable while the tree shape is stable.
- **Explicit** — `hash_id("my-key")` when the tree shape changes (list
  rows that can reorder or filter, dialogs opening and closing) and you
  need state continuity across the shuffle.

`virtual_list`, `virtual_list_variable`, and `table` push a per-row
scope around each `row_builder` call, so positional auto-IDs inside a
row are salted with the row index — widgets in a row keep their state
as the visible window slides, no `hash_id` boilerplate required. Reach
for explicit IDs when rows can reorder or be filtered underneath you
and you want state to follow the *item*, not the row position. See
`examples/15_advanced` for the reorder-with-explicit-ids pattern.

`Widget_Kind` is stored with the state so the runtime can zero out state
that belonged to a different widget in the same slot — a dropdown that
lost its slot to a button won't have its `open=true` leak into the button.

Hover detection uses `rect_hovered(ctx, rect)` instead of a raw
rect-contains-point check. The wrapped version consults the previous
frame's stamped popover rects and returns false when the mouse is over
an overlay that doesn't fully cover this widget — so hover tints on
buttons, inputs, etc. don't bleed through an open dropdown sitting on
top of them. Widgets inside the popover (options, date cells) stay
hoverable because their rect is fully contained by the overlay.

## Theming

`Theme` is plain data (`skald/theme.odin`) — four nested groups (`color`,
`radius`, `spacing`, `font`) passed through `ctx.theme`. Ship a new theme
by constructing a literal or copy-and-override from `theme_dark` /
`theme_light`.

Themes are passed down explicitly. There's no global "current theme" —
multiple apps in the same process can use different themes, and unit
tests can construct a `Ctx` with any theme without global state.

Colors are stored in **linear space**. Construct from sRGB hex via `rgb`
/ `rgba`; `color_lighten` / `color_darken` mix in linear space. For
hover / press tints that need to stay visible across theme swaps, use
`color_tint(c, t)` — it picks lighten-or-darken by luminance so white
and near-white surfaces still produce visible feedback (one-directional
lighten is a no-op on white).

## Labels and i18n

`Labels` is a sibling of `Theme` — a struct of framework-supplied
user-visible strings (picker placeholders, date/time helpers, the
Today/Now/Clear buttons in the picker footers). Threaded through
`ctx.labels` the same way `Theme` is threaded through `ctx.theme`.

```odin
labels := skald.labels_en()
labels.select_placeholder       = "Seleccionar…"
labels.date_picker_placeholder  = "Elegir fecha"
labels.month_names              = [12]string{"Enero", "Febrero", …}
skald.run(skald.App(State, Msg){
    theme  = skald.theme_dark(),
    labels = labels,
    …
})
```

Zero-value `App.labels` falls back to `labels_en()` at startup, so
existing apps behave identically to pre-i18n builds. Apps shipping
other locales call `labels_en()` as a seed and override fields.

`Labels` covers the strings Skald itself produces; everything else
(button labels, dialog titles, form headings) is app-supplied and
lives in the app's own translation flow. RTL layout mirroring, CJK /
Arabic / Devanagari font coverage, and pluralisation are all out of
scope for Skald — they're separate infrastructure items that apps
can layer if they need them.

## Async I/O and commands

`Command(Msg)` describes a side effect (`skald/command.odin` +
`command_io.odin`). The runtime performs it and feeds the result back as a
`Msg`. No threads are exposed to app code — completions arrive on the main
loop some number of frames after the command was returned.

Kinds:

- `cmd_now(msg)` — re-enter `update` with `msg` on the *same* frame.
- `cmd_delay(seconds, msg)` — deliver `msg` after a wall-clock delay.
- `cmd_batch(cmds...)` — bundle several commands.
- `cmd_read_file(path, on_result)` — async read via `core:nbio`.
- `cmd_write_file(path, bytes, on_result)` — async write via `core:nbio`.
- `cmd_open_file_dialog(filters, on_result)` — native Open picker (SDL3).
- `cmd_save_file_dialog(filters, on_result)` — native Save picker (SDL3).
- `cmd_thread(payload, work)` / `cmd_thread_simple(work)` — run a sync
  proc on a dedicated worker thread, deliver its return value as a
  Msg. The escape hatch for *any* blocking library (postgres, sqlite,
  sync HTTP, large-file parsers) that isn't nbio-shaped — most aren't.
  Worker contract: don't touch Skald state, return one Msg per call,
  surface errors as Msg variants. Strings in the in/out payload must
  be heap-allocated, not temp-arena.

All I/O is non-blocking. `nbio.tick(0)` runs at the top of each frame and
any completions land on the Msg queue via `drain_io`. Handler procs (the
`on_result` parameters) run on the main loop before `update`, not on a
worker thread — think of them as translators from the I/O completion
record into the app's `Msg` union. `cmd_thread` is the exception: its
worker proc runs on a fresh OS thread; its return value crosses back
through a per-app mpsc mailbox drained at the top of each frame.

Lifetime rules: result buffers (`File_Read_Result.bytes`, the dialog path
string) are handed to the handler on the persistent heap. The handler is
responsible for cloning into app-owned storage and freeing the original
buffer if it took ownership. See `examples/23_editor` for the pattern.

## Input and drag-and-drop

`Input` (`skald/input.odin`) is a per-frame snapshot: mouse position and
delta, button edges, scroll delta, UTF-8 text, held/pressed/released key
bit-sets, modifiers, and OS drag-and-drop state.

Coordinates are in **framebuffer pixels** — `window_pump` scales SDL's
window-logical coords up by the HiDPI ratio so hit tests match the draw
pass on any display.

Edge-triggered fields (`mouse_pressed`, `scroll`, `text`, `keys_pressed`,
`dropped_files`) are cleared at the start of each pump. State fields
(`mouse_buttons`, `keys_down`, `drag_active`) carry across frames.

Drag-and-drop surfaces via `drop_zone(child, on_drop)` and `drag_over(id)`
for hover feedback. `dropped_files` paths live in the frame arena; if the
handler needs them later it must clone onto the persistent heap.

## Rendering pipeline

One Vulkan rendering scope per frame (`CmdBeginRendering` / `CmdEndRendering`
using dynamic rendering — no render-pass objects). Rects, text, and images
share a single pipeline (`skald/pipeline.odin`, `shaders/ui.vert`+`ui.frag`
compiled to SPIR-V and `#load`-embedded) keyed off a per-quad `kind`
attribute. That keeps draw-call count low and sidesteps a sort — the view
tree already emits commands in the correct order.

Text runs through fontstash, glyphs atlased to a GPU texture on demand.
`measure_text` on the renderer is exposed to widget builders so
text-input's caret-from-click hit-testing doesn't wait for the draw pass.

Images are uploaded lazily on first reference and cached by path.

## Further reading

- `skald/app.odin` — `run`, the main loop.
- `skald/view.odin` — every widget builder and its state hookup.
- `skald/layout.odin` — measure + place + draw.
- `skald/command_io.odin` — async command plumbing.
- `examples/` — runnable demos for each concept. See `docs/examples.md`.
