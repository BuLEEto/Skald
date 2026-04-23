# Changelog

Skald follows [semantic versioning](https://semver.org) on a best-effort
basis: breaking changes bump the major, new features bump the minor,
bug fixes bump the patch.

## 1.0.0 — 2026-04-23

First public release. What the API looks like now is the contract going
forward; minor releases extend it, major releases would break it.

### Core

- Elm-architecture runtime (`init` / `update` / `view` + `Command(Msg)`).
- Pure-Odin Vulkan 1.3 renderer — single SDF pipeline for rects, text,
  images, and shadows; glyph atlas via `vendor:fontstash`.
- Lazy redraw with frame-deadline wake-ups — a static window renders
  zero frames per second.
- Async file I/O + native dialogs via `core:nbio`, integrated into the
  same run loop.
- Cross-platform: Linux (primary), Windows (smoke-tested), macOS
  (smoke-tested with MoltenVK).

### Widgets

- Layout primitives: `col`, `row`, `grid`, `flex`, `spacer`, `sized`,
  `clip`, `scroll`, `split`.
- Text and buttons: `text`, `button`, `link`, `divider`, `rect`,
  `image`.
- Inputs: `text_input` (single + multi-line with undo / clipboard /
  selection / max_chars), `number_input`, `search_field`.
- Booleans + choice: `checkbox`, `radio`, `radio_group`, `toggle`,
  `select`, `combobox`, `segmented`.
- Numeric: `slider`, `progress` (determinate + indeterminate),
  `spinner`, `rating`.
- Pickers: `date_picker`, `time_picker`, `color_picker`.
- Lists and tables: `virtual_list`, `virtual_list_variable`, `table`
  (sortable, resizable, keyboard-navigable), `tree`.
- Navigation: `tabs`, `breadcrumb`, `menu_bar` (with accelerators),
  `command_palette` (shares data with menu_bar).
- Containers: `list_frame`, `form_row`, `section_header`, `collapsible`,
  `accordion`, `empty_state`.
- Decorations: `badge`, `chip`, `avatar`, `kbd`, `stepper`, `alert`.
- Overlays: `overlay`, `tooltip`, `dialog`, `confirm_dialog`,
  `alert_dialog`, `toast`, `menu`.
- Interaction: `right_click_zone`, `context_menu`, `drop_zone`,
  `drag_over`, `canvas` (with pen/tablet support).

### Theming

- Dark + light default themes tuned against GitHub Primer and Radix
  token tables.
- Helpers: `color_mix`, `color_tint`, `track_color_for`,
  `focus_ring_for`, `selected_inactive_bg_for`.
- `font_add_fallback` for CJK / extended scripts.
- `Labels` struct for framework-supplied strings (i18n).
- OS-theme follow via `App.on_system_theme_change`.

### Input + keyboard

- Full Tab ring with focus trap inside dialogs; focus restoration on
  dialog / command-palette close.
- `widget_tab_index` to steer ring order without restructuring the
  view tree.
- Global `shortcut` registration; `menu_bar` auto-registers its items'
  accelerators.
- F-key (`F1`–`F12`) support.

### App-level

- `Window_State` (position, size, maximized) + `initial_window_state`
  + `on_window_state_change` for geometry persistence between launches.

### Dev tools

- F12 inspector overlay (FPS, RSS, widget counts, hover readout) —
  entirely gated behind `when ODIN_DEBUG`; release builds strip it.
- `SKALD_BENCH_FRAMES=N` env triggers bench mode — runs N forced
  frames, prints a one-line stats summary, exits.
- `./bench.sh` convenience script running the canonical example suite.

### Docs

- Tutorial (`docs/guide.md`) building a to-do app from scratch.
- Cookbook (`docs/cookbook.md`) with ~30 task-oriented recipes.
- Widget reference (`docs/widgets.md`) covering every public widget.
- Gotchas, architecture, examples index, published benchmarks
  (Linux + macOS).

### Known limitations (deferred to 1.1)

- macOS live-resize stretches the last frame while dragging (Cocoa
  blocks SDL3's event pump). Documented in `PLATFORMS.md`.
- macOS `menu_bar` renders in-window, not in the top-of-screen bar.
- Complex-script shaping (Arabic, Devanagari, Thai) renders glyphs
  but without contextual reshaping — `stb_truetype` ships glyphs only.
- `/proc/self/statm` RSS reader is Linux-only; macOS / Windows return -1.

### Thanks

Skald stands on good shoulders. See the Acknowledgments section of
`README.md` for the full list.
