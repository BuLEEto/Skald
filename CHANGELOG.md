# Changelog

Skald follows [semantic versioning](https://semver.org) on a best-effort
basis: breaking changes bump the major, new features bump the minor,
bug fixes bump the patch.

## 1.0.0-rc1 — 2026-04-29

First release candidate. The API surface here is what 1.0 will ship —
the rc window is for shaking out anything real apps surface that
weren't caught by the gallery and the in-house apps (Limn, Orin,
intralabels). Nothing is expected to change between rc1 and 1.0.0
unless the rc finds something that has to.

### Core

- Elm architecture: `init` / `update` / `view` + `Command(Msg)`. Pure
  functional state, rebuild-every-frame rendering. `view` and `update`
  always run single-threaded.
- Pure-Odin Vulkan 1.3 renderer (`vendor:vulkan`) — single SDF
  pipeline for rects, text, images, and shadows; glyph atlas via
  `vendor:fontstash`.
- Lazy redraw with frame-deadline wake-ups — a static window renders
  zero frames per second.
- Async via `core:nbio`: file I/O and native dialogs round-trip back
  as regular `Msg` values without blocking the UI.
- `cmd_thread(Msg, payload, work)` / `cmd_thread_simple(Msg, work)` —
  escape hatch for blocking libraries (postgres, sqlite, sync HTTP,
  large-file parsers, image codecs) that aren't nbio-shaped. Runs the
  work on a fresh OS thread; the return value lands as a Msg. Composes
  with library-managed connection pools — N concurrent workers + an
  N-sized pool = N queries in parallel.
- Multi-window. `cmd_open_window` / `cmd_close_window` spawn and tear
  down secondary OS windows; each gets its own swapchain, input,
  widget store, and per-frame plumbing. Device, pipeline, fonts, and
  image cache stay shared. `ctx.window` lets one `view` proc switch
  on which window it's drawing.
- Cross-platform: Linux (primary), Windows, macOS via MoltenVK.

### Widgets

- Layout: `col`, `row`, `wrap_row`, `grid`, `flex` (with `min_main`),
  `spacer`, `sized`, `clip`, `scroll`, `split`, `responsive`.
- Text + decorations: `text`, `button`, `link`, `divider`, `rect`,
  `image`, `badge`, `chip`, `avatar`, `kbd`, `stepper`, `alert`.
- Inputs: `text_input` (single + multi-line, with undo / clipboard /
  selection / `max_chars`), `number_input`, `search_field`.
- Booleans + choice: `checkbox`, `radio`, `radio_group`, `toggle`,
  `select`, `combobox`, `segmented`.
- Numeric + status: `slider`, `progress` (determinate +
  indeterminate), `spinner`, `rating`.
- Pickers: `date_picker`, `time_picker`, `color_picker`.
- Lists + tables: `virtual_list`, `virtual_list_variable`, `table`
  (sortable, resizable, keyboard-navigable, with optional hairline
  row separators), `tree`.
- Navigation: `tabs`, `breadcrumb`, `menu_bar` (with accelerators),
  `command_palette` (shares data with menu_bar).
- Containers: `list_frame`, `form_row`, `section_header`,
  `collapsible`, `accordion`, `empty_state`.
- Overlays: `overlay`, `tooltip`, `dialog`, `confirm_dialog`,
  `alert_dialog`, `toast`, `menu`, `context_menu`.
- Interaction: `right_click_zone`, `drop_zone`, `drag_over`, `canvas`
  (with pen / tablet support).

### Widget callback shape

Every value-emitting widget is a proc group of two variants. Pick
whichever fits the call site:

```odin
// Standalone — closes over the value implicitly via the surrounding Msg.
checkbox(ctx, s.is_admin, proc(v: bool) -> Msg { return Set_Admin{v} })

// Typed payload — threads row identity (or any other context) into the
// callback without a closure or a parent map_msg_for boundary.
checkbox(ctx, row.selected, row.id,
    proc(id: int, v: bool) -> Msg { return Row_Selected{id, v} })
```

### Layout

- `wrap_row(...children, line_spacing)` reflows children onto more
  lines when they don't fit. Same lay-out shape as `row` for everything
  that does fit.
- `responsive(min_w_threshold, narrow_view, wide_view)` switches between
  two layouts based on the slot's assigned width (not the window's),
  so a sidebar + content area can each pick their own breakpoint.
- `flex(weight, child, min_main = 0)` — child won't shrink below its
  intrinsic size unless `min_main` is set explicitly.
- `ctx.breakpoint` exposes the current slot's breakpoint enum
  (`.Compact` / `.Regular` / `.Wide`) for ad-hoc branching inside a
  view.

### Theming

- `theme_dark()` and `theme_light()` ship in-tree, tuned against
  GitHub Primer and Radix tokens.
- `theme_system()` probes the OS for light/dark preference and
  accent colour and returns a theme that matches.
  `App.on_system_theme_change` keeps it in sync if the user toggles.
- Colour helpers: `color_mix`, `color_tint`, `track_color_for`,
  `focus_ring_for`, `selected_inactive_bg_for`.
- `font_add_fallback` chains additional fonts onto the base for CJK,
  Cyrillic extensions, icon fonts, etc. Up to 20 fallbacks per base.
- `Labels` struct carries every framework-supplied string (picker
  placeholders, month / weekday names, AM/PM, "Today" / "Now"). Apps
  pass `App.labels = labels_en()` or a custom translation; one swap
  re-localizes every built-in widget.

### Window state

- `App.initial_window_state` seeds position / size / maximized at
  launch. `App.on_window_state_change` reports user resize / move /
  maximize so apps can persist geometry however they like (JSON,
  embedded settings DB, whatever).
- `App.window_flags: sdl3.WindowFlags` — caller-override of the SDL
  flags passed to `SDL_CreateWindow`. For dock windows, always-on-top
  panels, transparent HUDs.
- `App.on_window_open: proc(w: ^Window)` — post-create hook for
  platform-specific tweaks (X11 `_NET_WM_WINDOW_TYPE_DOCK` via Xlib,
  macOS `NSWindow` levels).
- `App.always_redraw` opts a window into per-frame rendering for
  apps that need it (canvases under heavy interaction, animation-heavy
  views). Default stays lazy.
- Swapchains negotiate the best `compositeAlpha` the driver advertises
  (`POST_MULTIPLIED` → `INHERIT` → `PRE_MULTIPLIED` → `OPAQUE`). Apps
  that set `.TRANSPARENT` in `window_flags` actually get a transparent
  swapchain.

### Images

- `image_load_pixels(r, name, w, h, rgba)` registers an in-memory
  RGBA8 buffer with the image cache; later `image(ctx, name, …)` calls
  draw it the same as a file-loaded image.
- `image_update_pixels(r, name, w, h, rgba)` refreshes a registered
  image in place at the same size — reuses the existing `VkImage` +
  view + descriptor set; one staged copy per call, no allocations,
  no `DeviceWaitIdle`. Cheap enough for 60 fps streaming.
- `draw_image(r, name, rect, fit, tint)` paints a registered image
  inside a `canvas` callback so app-drawn overlay primitives (lines,
  markers, text) can sit on top.

### Input + keyboard

- Full Tab ring with focus trap inside dialogs; focus restoration on
  dialog / command-palette close.
- `widget_tab_index` to steer ring order without restructuring the
  view tree.
- Global `shortcut` registration; `menu_bar` auto-registers its
  items' accelerators.
- F-key (`F1`–`F12`) support; `is_typing(ctx)` to gate
  shortcut handlers when the user is in a text input.
- Pen / tablet input via `canvas` (per-event sample buffering, mouse
  cursor auto-hides while a pen is active).

### Dev tools

- F12 inspector overlay (FPS, RSS, widget counts, hover readout) —
  entirely gated behind `when ODIN_DEBUG`; release builds strip it.
- `SKALD_BENCH_FRAMES=N` env triggers bench mode — runs N forced
  frames, prints a one-line stats summary, exits.
- `./bench.sh` convenience script running the canonical example suite.

### Docs

- Tutorial (`docs/guide.md`) builds a small app from scratch.
- Cookbook (`docs/cookbook.md`) with task-oriented recipes for the
  patterns apps reach for: forms, dialogs, shortcuts, theming,
  async, persistence, editable cells in tables, OS-theme follow.
- Widget reference (`docs/widgets.md`) covering every public widget.
- Architecture, gotchas, examples index, published benchmarks
  (Linux + macOS).
- Per-function reference: `odin doc ./skald` from the project root.

### Known limitations

- macOS live-resize stretches the last frame while dragging (Cocoa's
  resize loop blocks SDL3's event pump). Documented in
  `PLATFORMS.md`. Deferred to post-1.0.
- Complex-script shaping (Arabic, Devanagari, Thai, Hebrew) renders
  glyphs but without contextual reshaping — `stb_truetype` ships
  glyphs only, no HarfBuzz integration. Latin / Cyrillic / Greek /
  CJK all work cleanly.
- Color emoji (CBDT / sbix / COLR) doesn't render — `fontstash`
  decodes monochrome outlines only. Tracked as a post-1.0 item.
- `_bench_rss_kb` reads `/proc/self/statm` on Linux; macOS / Windows
  return -1 until a Mach-API / `GetProcessMemoryInfo` reader lands.

### Thanks

Skald stands on good shoulders. See the Acknowledgments section of
`README.md` for the full list.
