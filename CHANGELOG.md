# Changelog

Skald follows [semantic versioning](https://semver.org) on a best-effort
basis: breaking changes bump the major, new features bump the minor,
bug fixes bump the patch.

## 1.2.0 — unreleased

### Added

- `image_load_pixels(r, name, w, h, rgba)` registers an in-memory
  RGBA8 buffer with the image cache under a synthetic name; any
  later `image(ctx, name, …)` draws it the same way as a file-loaded
  image. For rasterized DXF / SVG / PDF output, video frames,
  in-memory PNGs, procedural thumbnails, golden-image tests. Pair
  with `image_unload(r, name)` for explicit cleanup. Replacing under
  the same name is supported (DeviceWaitIdle + free + reload); not
  intended for per-frame updates — that wants its own primitive.
- `Menu_Item.checked: bool` — prefix a row with a ✓ glyph for
  togglable state (View → Show Grid, etc.). The check column is
  only reserved when at least one item in the active menu is
  currently checked, so unchecked menus lay out unchanged.
- `examples/39_icons` + cookbook recipe: registering an icon font
  (Font Awesome 6 Solid TTF bundled, SIL OFL 1.1) as a fallback to
  Inter, then using PUA codepoints inline in `text()` and
  `button()`. Same trick works for Lucide, Phosphor, Material —
  whatever ships TTF outlines.

## 1.1.0 — 2026-04-25

### Added

- **Multi-window.** `cmd_open_window` / `cmd_close_window` spawn and
  tear down secondary OS windows. Each gets its own Vulkan swapchain,
  per-frame command buffers + sync, `Input` snapshot, `Widget_Store`,
  vertex + index buffers, and descriptor set. Device, pipeline,
  fonts, and the image cache stay shared. `ctx.window` (type
  `Window_Id`) lets a single `view` proc switch on which window it's
  rendering. See `examples/38_multi_window` and the Multi-window
  section of the cookbook.
- `App.on_window_focus_lost` — fires when any window stops being
  foreground (click-away, Alt-Tab, workspace switch). Typical use:
  auto-dismiss popovers / notifications.
- `App.window_flags: sdl3.WindowFlags` — caller-override of the SDL
  flag set passed to `SDL_CreateWindow`. For dock windows, always-
  on-top panels, transparent HUDs, and the like.
- `App.on_window_open: proc(w: ^Window)` — post-create hook for
  platform-specific tweaks (X11 `_NET_WM_WINDOW_TYPE_DOCK` via Xlib,
  macOS `NSWindow` levels, and so on). No forking required.
- Swapchain picks the best `compositeAlpha` the driver advertises
  (`POST_MULTIPLIED` → `INHERIT` → `PRE_MULTIPLIED` → `OPAQUE`). Apps
  that set `.TRANSPARENT` in `window_flags` actually get a transparent
  swapchain instead of an opaque black backdrop.

### Changed

- `fb_size` moved from a uniform-buffer binding to a push constant.
  Descriptor set layout is now one binding (atlas). Shaders
  rebuilt.

### Fixed

- Dialog popover sweep no longer fires every frame — only on the
  closed→open transition. Popover-bearing widgets (`color_picker`,
  `select`, `combobox`, `date_picker`, `time_picker`) inside a
  dialog's content can now be opened and stay open.
- Modal-click filter whitelists clicks inside any open popover
  overlay. A picker anchored inside a dialog whose dropdown spills
  outside the dialog card now receives clicks on its slider, hex
  field, and other controls.

### Internal

- `Renderer` split into device-scoped (instance, device, queue,
  pipeline, text, images) and per-window `Window_Target` (surface,
  swapchain, cmd buffers, sync, vertex + index + dset, widget store,
  platform window). Single-window apps unaffected.
- `window_pump` split into `window_reset_frame` + `window_apply_event`;
  `windows_pump(slice)` dispatches SDL events by window id.

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
