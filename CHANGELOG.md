# Changelog

Skald follows [semantic versioning](https://semver.org) on a best-effort
basis: breaking changes bump the major, new features bump the minor,
bug fixes bump the patch.

## 1.0.0-rc4 — 2026-05-12

Two new text widgets, a handful of correctness fixes uncovered by
external app integration, and a perf cliff smoothed out. `rich_text`
+ `rich_text_links` cover markdown-style inline emphasis (bold,
italic, inline-code chips, clickable links) in a single wrapped
paragraph — the missing piece for any chat or docs surface that
wants more than uniform text. `chat_input` provides the
Enter-submits / Shift-Enter-newlines composer pattern. Below the
widgets, several rough edges shipped in rc1-rc3 got polished:
combobox dropdowns now scroll past their default 8-row cap and
auto-grow to fit long labels, `text_input` normalises Windows
line endings on both paste and app-value boundaries, scrolling
through long chat content no longer flickers, and the wrap path
for long pasted strings is now O(1) for re-measurements within a
frame.

### Added

- **`rich_text` / `rich_text_links` widgets** — one paragraph of
  styled spans that wrap as a single block. Each `Text_Span` carries
  its own colour / weight / italic / inline-code background /
  underline / link, and the wrap path word-breaks *across span
  seams* so a long sentence with mixed bold + italic + inline-code
  flows into a normal multi-line paragraph instead of fragmenting
  into separate widgets. Bundled Inter Bold / Italic / Bold Italic
  faces are baked into the binary alongside the existing
  InterVariable; the renderer picks the right face per span
  automatically. `span_bold` / `span_italic` / `span_code` /
  `span_link` keep call sites readable. `rich_text_links` is the
  variant with click dispatch — `on_link_click: proc(link: string)
  -> Msg` fires on left-click release over a link span, and the OS
  cursor swaps to a pointer/hand on hover via the new
  `cursor_request` API. Split into two procs (not nilable callback)
  because of Odin's polymorphic-nil-default limit. Demo in
  `examples/44_rich_text` covers every shape: mixed weight/italic,
  mixed size+colour, multi-line wrap, inline-code chip, and two
  clickable links with a status line that shows the most recent
  target.
- **`cursor_request(ctx, shape)` API.** `Cursor_Shape` enum
  (`Default` / `Pointer` / `Text` / `Crosshair` / `Move` / four
  resize directions / `Not_Allowed`) backed by `SDL_CreateSystemCursor`
  with a per-shape lazy-allocated cache. Widgets call
  `cursor_request` from their view to claim a cursor shape while
  hovered; the run loop applies once per frame, last writer wins.
  First consumer is `rich_text_links`'s hover-pointer; future
  consumers will be text_input's I-beam and resize handles.
- **`Inter-Bold` / `Inter-Italic` / `Inter-BoldItalic` font assets**
  (~1.24 MB total, OFL-1.1, same licence as InterVariable). Loaded
  via `font_bold(r)` / `font_italic(r)` / `font_bold_italic(r)` for
  apps that want to use the static weights outside `rich_text`.
- **Tab handling in `text` and `wrap_text`.** Tabs in user-supplied
  strings now expand to 4 spaces of visible width instead of
  rendering as a missing-glyph tofu. Applies to both the wrap and
  no-wrap render paths. Simple model (no editor-grade column-aligned
  tab stops); apps that need true tab stops pre-process their input.
- **`chat_input` widget** — multi-line composer with the chat-app key
  contract: **Enter** submits, **Shift+Enter** inserts a newline,
  **Ctrl+Enter** also submits. Wraps `text_input(multiline = true,
  wrap = true)` and intercepts Enter before the underlying widget
  treats it as a newline insertion. Auto-grows from one line up to
  `max_lines` (default 8), then scrolls internally. Empty values
  short-circuit so submit is a no-op on a blank composer. See
  `examples/43_chat_input` for the contract in action.

- **`combobox` dropdown overhaul: `max_rows`, scrollable overflow,
  auto-grow width, open-with-current-selection.** The dropdown
  previously hard-capped at 8 visible rows and silently dropped
  anything past index 7 — visible only via filter-as-you-type, which
  most users wouldn't discover. Five changes:
  1. Cap is now a parameter (`max_rows: int = 8`, same visual default).
  2. Options beyond the cap are reachable via mouse wheel, scrollbar,
     or keyboard nav (Up/Down auto-scrolls the viewport to keep the
     highlighted row visible).
  3. Dropdown auto-grows wider than the trigger when an option's
     label exceeds the trigger width, so long labels no longer clip.
     Clamped to the framebuffer width so a pathologically long label
     can't paint off-screen.
  4. Opens with the currently-selected value highlighted (and the
     viewport scrolled to it), matching native combobox / popup-
     button behaviour — first-time / unmatched value still lands at
     row 0.
  5. Several interaction fixes that fell out: scrollbar grab works
     (mouse_pressed consume deferred until after the scroll widget
     builds), row hover/commit suppressed during scrollbar drag (so
     a drag-release-on-row doesn't pick the row), and the keyboard
     auto-scroll only fires on a real highlight change so wheel /
     drag scrolling isn't snapped back to the highlight.

  Reported via the cross-agent thread by an app with a 15-entry
  model picker; subsequent reports caught the scrollbar grab, text
  overlap, and drag side-effect issues during testing.

### Fixed

- **`virtual_list_variable` sticky-bottom no longer lags by one chunk.**
  When the app's view kept setting `scroll_y` to a sentinel each
  frame to pin the bottom (the standard "follow the streaming reply"
  pattern), `scroll_advance` clamped against `content_h_pre` — the
  sum of *cached* heights from the previous frame. If a visible row
  (e.g. the streaming assistant bubble) grew this frame, the
  post-measure `max_off` increased, but `scroll_y` had already been
  clamped to the stale value. Result: scroll_y was one chunk behind
  the true bottom, top-of-viewport rows snapped each chunk arrival.
  The existing re-anchor block only covered rows above
  `first_visible`; growth inside `[first_visible, last)` was
  invisible to it. Now: snapshot `was_at_bottom` from the
  pre-measure clamp, and after re-measure either re-anchor (as
  before, when not at bottom) *or* snap `scroll_y` to the new
  `max_off_post` (when at bottom). Sticky-bottom apps now hold the
  bottom edge exactly.
- **Scroll content no longer flickers on sub-pixel offsets.** `View_Scroll`
  applied its `offset_y` directly as a fractional render origin —
  `content_h` is a sum of float per-row heights, so any sticky-bottom
  or growing-content scenario produced sub-pixel scroll positions
  frame-to-frame. Anti-aliased glyphs rasterised to different pixels
  per frame on rows near the viewport's clip edges → visible jitter
  during streaming. Now snap `off` to physical-pixel boundaries
  (`floor(off * scale) / scale`) before it becomes the render origin
  *and* before being written back to widget state, so the snap
  persists across frames. Reported via the cross-agent thread —
  surfaced as "top 3 chat rows flicker while assistant streams reply."
- **`widget_get` no longer leaves the store holding freed pointers.**
  The cleanup branch (kind-mismatch or stale-frame) freed the prior
  occupant's heap state (`undo`, `virtual_heights`, `text_buffer`)
  and reset a *local copy* of `Widget_State`, but never wrote that
  reset state back to `ctx.widgets.states`. A caller that did
  `widget_get` and early-returned without `widget_set` — a normal
  pattern for read-only inspection paths — left the map entry
  pointing at the just-freed heap. The next `widget_get` on the same
  id read the same stale entry and re-entered the cleanup branch,
  double-freeing. Now `widget_get` persists the reset state to the
  map before returning so cleanup is idempotent regardless of
  caller discipline. Reported by an external app via the cross-agent
  thread (crash trace in `delete_dynamic_array` from a stale
  `virtual_heights` slice).
- **`wrap_text` is now memoised per frame.** `View_Text` gets walked
  twice every frame — once in `view_size` (layout measure) and once
  in `render_view` (paint) — and each walk previously re-ran the
  full word-wrap pass for every text widget. `virtual_list_variable`
  adds a third call per visible row when refreshing its height
  cache. For chat-style UIs displaying long pasted content (e.g.
  a 30 KB message body in the visible window) this dominated frame
  time. Reported via the cross-agent thread: boc-next saw avg frame
  time go from 8.5 ms (empty chat) to 208 ms (single 30 KB visible
  message) — almost entirely double-shape work. Fix: a per-frame
  cache lives in `Renderer.wrap_cache`, keyed by
  `(text_ptr, text_len, max_width, size, font)`. Allocated against
  the temp arena in `frame_begin` so it collects automatically at
  frame boundaries. View_size's call populates the cache; the
  subsequent render_view / virtual_list height-cache calls hit it
  in O(1).
- **Open/closed layout asymmetry on overlay-anchored widgets.**
  Affected `combobox`, `select`, `date_picker`, `time_picker`,
  `color_picker`, and `context_menu`. Pre-fix: when closed each
  widget returned its trigger directly so a stretching parent's
  offered width flowed through correctly; when open each returned
  `col(trigger, overlay(...))` *without* `cross_align`, so the
  trigger reverted to its intrinsic width (typically 220 px) and
  the popover — anchored to the now-shrunken `trigger_rect` —
  followed. The trigger visibly collapsed the moment the popover
  appeared. Fix: each open-state wrapper col now sets
  `cross_align = .Stretch` so layout-stretch flows through to the
  trigger and the overlay anchors to the correctly-sized rect.
  No-op for non-stretching parents.
- **`text_input(wrap = true)` now wraps correctly when no `width` is
  passed.** Pre-fix: `width = 0` (the implicit "stretch to fit parent"
  default) made `inner_w := width - 2*pad.x` negative, which silently
  disabled wrap inside `build_visual_lines`. Long logical lines clipped
  at the right edge instead of word-wrapping. Now: when `width <= 0`,
  the impl falls back to `st.last_rect.w` (the rect the widget was
  assigned last frame), and on the very first frame for a given id it
  schedules an immediate redraw so lazy-redraw doesn't lock in the
  bad-wrap frame. Stretchy multiline text_inputs (incl. `chat_input`
  with no explicit width) now wrap as soon as their parent layout
  resolves. The "always pass an explicit width" workaround in
  `project_inline_text_input_in_rows` is no longer required for
  multiline+wrap.
- **`text_input` normalises line endings on the app-supplied `value`.**
  Pre-fix: a value containing `\r\n` (loaded from disk / JSON / HTTP)
  passed `build_visual_lines` straight through; the wrap scanner
  treated `\r` as content and long logical lines clipped at the
  right edge instead of word-wrapping. Now: `\r\n` and bare `\r`
  collapse to `\n` at the top of the impl, before cursor clamping
  or the visual-line scan, so every downstream consumer (wrap,
  render, cursor, undo) operates on canonical bytes. The
  `changed = new_value != value` predicate fires `on_change` with
  the normalised string so the app stores the canonical form
  going forward — no app-side preprocessing needed. The
  `examples/43_chat_input` "Seed CRLF" button exercises the path.
- **`text_input` normalises pasted line endings.** Pasting Windows
  text (`\r\n`) or classic-Mac text (bare `\r`) into a multi-line
  text_input or `chat_input` now collapses to a single `\n` byte at
  insert time — no more stray `\r` tofu inside the editor, no more
  double-counted cursor advance. Single-line text_inputs strip
  newlines from paste entirely so a paste from a multi-line source
  flattens to one line instead of embedding a non-printable byte.
- **`text()` now honours embedded line breaks in the no-wrap path.**
  Before: `text("a\nb", color)` (without `max_width`) rendered the
  `\n` as a missing-glyph tofu on one row. After: it renders as two
  stacked rows. The `max_width` path already did this; this just
  closes the inconsistency. Cross-platform line endings (`\r\n`,
  `\r`, `\n`) all collapse to a single break, so pasted Windows
  text doesn't leave stray `\r` glyphs behind. `wrap_text` and a
  new `split_lines` helper share the same line-break logic.

## 1.0.0-rc3 — 2026-05-02

Transparent windows actually work now on Linux X11. The
`.TRANSPARENT` flag was advisory before — it requested a transparent
swapchain but three layers below that quietly defeated it.

### Fixed

- **Transparent X11 windows are now genuinely transparent.** Three
  Skald-side gaps had to close together for the flag to take effect:

  1. SDL3 ≥ 3.2 sets `_NET_WM_BYPASS_COMPOSITOR = 1` on every X11
     window by default (game-engine assumption). xfwm4 caches the
     bypass at map-time and refuses to composite the window
     thereafter. Skald now sets
     `SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR = "0"` pre-Init
     so the atom stays unset and the compositor decides.
  2. The run loop was clearing the swapchain to `th.color.bg`
     (opaque) every frame regardless of `.TRANSPARENT`. The card's
     view tree painted on top, but un-painted areas (rounded-card
     corners, gaps) stayed at the clear's alpha=1. The Window struct
     now tracks the `.TRANSPARENT` flag and the run loop zeros the
     clear's alpha when it's set.
  3. SDL3 creates the X11 window before Vulkan picks a swapchain
     format, so the visual chosen at creation time determines
     whether the framebuffer has an alpha channel. SDL3 handles this
     correctly for OpenGL but not Vulkan — the Vulkan path defaults
     to a 24-bit RGB visual, the X window has Depth: 24, and any
     framebuffer alpha is silently discarded at window-pixel level.
     Skald now enumerates X11 visuals via `XGetVisualInfo`, finds
     a 32-bit ARGB one, and feeds the ID to SDL3 via
     `SDL_HINT_VIDEO_X11_WINDOW_VISUALID` before window creation
     when `.TRANSPARENT` is requested.

  Diagnosed and verified building Orin Spotlight on xfwm4. After all
  three fixes: `xwininfo -id <wid>` reports Depth: 32 / Visual Class:
  TrueColor and translucent cards composite over the desktop as
  expected.

### Notes

- Wayland, Windows, and macOS need none of the above — transparent
  Vulkan windows work out of the box on those platforms. The
  `pick_argb_visual_for_x11` helper is a no-op outside X11; the
  bypass-compositor and clear-alpha fixes are harmless everywhere.

## 1.0.0-rc2 — 2026-05-01

Shake-down release after a week of cross-platform dogfood (Devuan,
Pop!_OS COSMIC, Ubuntu 24.04, Windows). Real-app testing on
ERSaveBackup, intralabels, and a Linux ER Trainer app surfaced a
handful of latent bugs and one usability footgun.

### Changed (small breaking)

- `text_input(search = true)` flag removed in favour of two
  orthogonal flags: `clear_button` and `escape_clears`. The old
  bundled flag conflated four behaviours (placeholder default,
  force single-line, clear-X, escape-to-clear) and overlapped with
  the dedicated `search_field` widget — both LLMs and humans editing
  app code grabbed `text_input(search=true)` when they meant
  `search_field` (which has the Enter-submit wiring). Apps that
  used the flag have a one-line swap: pass `clear_button = true,
  escape_clears = true` instead, or switch to `search_field` if you
  also want Enter-to-submit.

### Fixed

- **Table row / sort-header / resize-handle clicks** now pass
  through `rect_hovered` so they respect modal-rect and overlay
  gates. Previously a click on a dialog button positioned over a
  table also fired the row underneath.
- **`select` / `menu` / `context_menu` no longer flash open and
  close** when used inside a dialog. The popover's option-row
  buttons consumed parent auto-id slots, shifting the dialog's id
  on open frames; the dialog's `widget_get` returned a fresh state
  on each click and its open-transition sweep killed the just-
  toggled popover. Option rows now build inside a per-widget
  `widget_scope_push` so their auto-ids stay isolated.
- **`rect_hovered`** loosened: a widget whose rect spills past the
  modal card is still reachable when contained within a registered
  overlay (popover from inside the dialog). Without this, options
  below the dialog card were dead-clickable.
- **File dialogs default to `$HOME` on Linux / macOS** (and
  `%USERPROFILE%` on Windows) when the app doesn't pass
  `default_location`. Previously some Linux portals defaulted to
  filesystem root, which read as a confusing first-time UX.

### Added

- **Debug-only `row_key` collision warning**: `virtual_list`,
  `virtual_list_variable`, and `table` print a one-line stderr
  warning the first time a duplicate `row_key` is detected during
  iteration, naming both colliding row indices. Stripped from
  release builds.
- **`docs/distributing.md`**: end-user runtime requirements +
  bundling pattern (patchelf RPATH on Linux, app bundles on macOS).
- **`docs/widget_choice.md`**: short decision tree for "which
  widget should I reach for here?"
- **Layout-basics intro** at the top of `widgets.md`'s Layout
  section — the four knobs every container takes, why
  `cross_align = .Stretch` is often what new devs need.
- **Cross_align gotcha** in `gotchas.md` for the "my child sticks
  to the top-left" symptom.
- **File-dialog filter limitation** documented in `gotchas.md` —
  on bleeding-edge Linux desktops (Pop!_OS COSMIC verified) the
  filtered file-dialog code path can silently drop or crash; the
  workaround is to pass nil filters.

### Changed (UX)

- **F12 inspector** slimmed to the hover-readout panel only (id,
  kind, computed rect, focused widget). The previous FPS / RSS /
  widget-count metrics were misleading under lazy redraw ("0 fps"
  read as "frozen") and weren't load-bearing.

### Docs

- README: hero GIF of `00_gallery` for stop-the-scroll first
  impression.
- `getting_started.md`: explicit Ubuntu 24.04 LTS steps (build SDL3
  from source) and the one-time Odin `vendor:stb` step.
- `PLATFORMS.md`: full upstream SDL3 dep set (audio + IME) with
  the bare-minimum subset alongside.
- Several inline parameter explanations across `widgets.md`
  (`track_h`, `thumb_r`, `min_w`, `min_h`, `wheel_step`).

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

- F12 inspector overlay — names the widget under the cursor (id, kind,
  computed rect) and outlines it on screen; press P to pin so the
  readout doesn't follow the cursor. Entirely gated behind
  `when ODIN_DEBUG`; release builds strip it.
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
