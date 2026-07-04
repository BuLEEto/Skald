# Changelog

Skald follows [semantic versioning](https://semver.org) on a best-effort
basis: breaking changes bump the major, new features bump the minor,
bug fixes bump the patch.

## Unreleased

### Added

- **`reveal_row` on `virtual_list`.** Pass a row index and the list scrolls the
  minimum amount to bring it into view — the same change-gated knob `table`
  already has, now for virtualized lists and grids (type-ahead / jump-to-item).
  A steady value never re-snaps, so it won't fight the user's manual scroll. For
  a grid, pass the focused item's grid row (`focus_index / columns`). Works in
  both fixed- and variable-height modes; `reveal_row = -1` (default) is a no-op.

- **Rounded corners (and optional border) on `image`.** `image(…, radius =
  th.radius.md)` rounds the drawn quad, antialiased through the same SDF that
  rounds `rect`/`col`; with `.Cover` the rounding hugs the box, so a photo
  matches its card's radius flush (no more sharp corners poking past a rounded
  card). `border`/`border_color` paint a concentric frame — a photo matte.
  `radius = 0` is the zero-cost, byte-identical default (no regression).

- **`scroll` reveals its keyboard-focused descendant.** When Tab or arrow
  navigation moves focus to a control scrolled out of view, the viewport now
  scrolls the minimum amount to bring it back (default-on `reveal_focus`). It
  fires only on focus *change*, so a steady focus never fights a manual
  wheel/drag — same discipline as the table's `reveal_row`. Fixes off-screen
  focus rings in any long, keyboard-navigable scrolled view. Set
  `reveal_focus = false` to opt a self-driven scroll out.

- **Zero-copy dmabuf textures (`image_import_dmabuf`, Linux).** Import an external
  dmabuf as a sampleable texture drawn by the normal `image(ctx, key, …)` path —
  the producer (e.g. a Wayland compositor sharing a downscaled window buffer for
  live thumbnails) keeps writing into the same buffer and the app just re-samples
  it: no readback, no upload. Single-plane packed RGBA (`ARGB`/`XRGB`/`ABGR`/`XBGR`
  8888), any single-plane DRM modifier (LINEAR or tiled; a multi-plane/DCC modifier
  is rejected with a clear message). Skald `dup()`s the fd and owns its copy.
  Returns `false` (no-op off Linux, or when the device lacks the extensions) so
  callers fall back to a pixel upload. Paired with **`image_release(r, key)`** to
  drop an image's GPU texture + memory (and the dup'd fd) on demand.

## 1.0.0-rc13 — 2026-06-27

### Added

- **Charts: `sparkline`, `sparkline_multi`, `gauge`.** The resource-monitor
  widgets. `sparkline(values, …)` draws one rolling time-series line; `_multi`
  overlays several traces on shared axes; `gauge(value, …)` draws a radial donut.
  Optional area `fill`, `grid`, fixed-or-auto value range, value-axis labels
  (`y_unit`, left by default / `y_right` for the cosmic-monitor side, with tick
  density adapting to height) and a `x_secs` time axis. The line/arc geometry is
  anti-aliased via a feathered alpha-0 fringe (no MSAA / shader change). All three
  are canvas-backed and take their data from the app — keep a rolling buffer per
  metric and hand over the slice. Example `54_charts`.

- **`draw_stroke` opt-in anti-aliasing (`aa`).** `draw_stroke(…, aa = true)`
  feathers the ribbon edges (1px alpha-0 fringe) so brush / vector strokes don't
  stair-step. Default `aa = false` is byte-identical to before, so a hard / pixel
  brush stays crisp; AA roughly triples the vertex count when on.

- **Auto-growing multiline `text_input` (`min_lines` / `max_lines`).** A multiline
  field can rest at `min_lines` rows and grow with the newline count up to
  `max_lines`, then scroll internally — `text_input(multiline = true,
  min_lines = 3, max_lines = 8, ...)`. This sizing used to live only inside
  `chat_input`; it now lives in `text_input`, so any multiline editor (notes,
  comments — where Enter inserts a newline) gets it too. `chat_input` delegates to
  it and adds the Enter=submit policy, plus `min_lines` for a composer that rests
  taller than one line. Default (no `max_lines`) is unchanged — the field keeps
  its existing fixed height.

- **In-window drag & drop.** `drag_source(child, payload, visual)` makes an item
  draggable — a press that moves past a threshold starts a drag carrying a
  `Drag_Payload{kind, id}`, with `visual` (any View) following the cursor as a
  ghost. `drop_target(child, on_drop, accepts)` fires a Msg when a matching drag
  is released over it, resolved at the release point (z-aware, like a click).
  `drag_target_hot` / `dragging_payload` drive hover tints. A drag owns the
  pointer, so it doesn't click-through or hover-bleed into content underneath;
  Esc or a release over nothing cancels. Selection and multi-item drag compose
  from the existing click queries — the framework just carries the gesture and
  paints the ghost. In-window only (no cross-app data-device yet). `table` grows
  an `on_row_drag` callback so list-view rows are drag sources too, composing
  with `on_row_click` / `on_row_activate`.

- **Drag *out* to other apps (Wayland).** `drag_source` gains optional
  `export_mime` + `export_data`: when the drag leaves the window on a Wayland
  session, Skald starts a real `wl_data_device` drag offering those bytes, so a
  file drags straight from a Skald app into a browser upload box / file manager /
  editor. The ghost View is rendered to the compositor's drag icon. No-op off
  Wayland (libwayland is loaded at runtime, never linked — X11 / non-Linux are
  unaffected); in-window DnD is unchanged. `table`'s `on_row_drag` carries the
  same export, so list-view rows drag out too — not just `drag_source` tiles.

- **`tooltip` shadow control.** `tooltip(..., shadow := f32(-1))` — the default
  keeps the soft drop shadow; `>= 0` overrides it (`0` = no shadow), for
  rendering over a compositor backdrop-blur where a soft shadow halos into a
  frosted ring.

### Changed

- **`command_palette` follows the mouse and scrolls.** Hovering a row now moves
  the highlight (it only tracked the arrow keys before); the bar stays put while
  the cursor rests, so keyboard nav isn't yanked back to wherever the pointer
  happens to sit. When the matched rows are taller than the window the list
  scrolls inside a capped viewport — the highlight auto-scrolls into view — so
  no match is unreachable instead of running off-screen.

- **`scroll` thumb is much easier to grab.** Presses register in a wider
  invisible band flush to the viewport's right edge (no more dead gap at the
  window edge, no more 6px sliver target), the visible bar is 8px and expands
  to 12px on hover/drag, and grabbing or dragging the thumb no longer
  click-throughs or hover-bleeds into the content beneath it. No API change.

### Fixed

- **`scroll` keeps its stored offset in range.** `scroll_advance` wrote the
  wheel / page offset back to widget state unclamped, so overscrolling an edge
  accumulated past the bounds — the wheel went dead until you scrolled back
  through the overshoot — and an app that set `scroll_y` to a large value to jump
  to the end read it back permanently out of range. The persisted offset is now
  clamped to `[0, content_h - viewport]`, matching the rendered position.

- **`text_input` renders tabs as whitespace.** An editable field shaped its raw
  buffer, so a literal `\t` drew as a missing-glyph tofu at every indent level of
  a tab-indented file (read-only `text` already expanded tabs). Tabs now render
  as four spaces of visible width, the buffer keeping its single `\t` byte (saves
  unchanged) and the caret, selection, and `offset_at` / `offset_rect` measuring
  the expanded width.

- **Default to native Wayland on a Wayland session.** SDL3 with no
  `SDL_VIDEODRIVER` picks x11 on a Wayland desktop (where `DISPLAY` is also
  set, via XWayland), and XWayland mis-maps pointer input on outputs at
  negative layout coordinates — a window dragged to a monitor left of the
  primary got no hover or clicks (keyboard still worked, so it looked frozen).
  Skald now sets `SDL_VIDEODRIVER=wayland` in-process before `SDL_Init` when
  `WAYLAND_DISPLAY` is set and no driver was chosen. No-op on real X11
  sessions; respects a pre-set `SDL_VIDEODRIVER` / `SDL_VIDEO_DRIVER`.

## 1.0.0-rc12 — 2026-06-13

### Added

- **`text_input` gains `styles` — inline rich text.** `styles: []Text_Style`
  restyles byte ranges of the buffer (`{start, end, color, weight, italic,
  font, size}`) for syntax highlighting and headings. Caret, selection and
  click hit-testing measure per run, so bold / italic / mono advances — and
  per-run sizes, which make a line taller — stay exact. Supply fresh each
  frame; `nil` is a no-op, and offsets clamp + snap to rune boundaries.
  Composes with `marks`; unstyled fields are untouched.

- **Embedded backend — bring your own surface.** A second entry path
  alongside `skald.run` for hosts that own their surface, input, and frame
  loop (e.g. a Wayland compositor or shell). `window_init_embedded` builds a
  `Window` from a caller-supplied Vulkan surface, `input_feed_*` push the
  pointer/key/text snapshot the SDL pump would, and the host drives
  `frame_begin`/`frame_end` itself. Skald still owns the instance, device,
  and pipeline; the SDL path is untouched.

- **Multiple surfaces from one renderer.** `renderer_add_embedded_surface` /
  `renderer_remove_embedded_surface` attach extra caller-supplied surfaces to
  a single `Renderer`, so one process drives N swapchains — a panel per
  output, a lock surface per monitor — sharing one device, pipeline, and
  glyph atlas. `frame_begin` selects the target by window, so one view proc
  can paint every surface.

## 1.0.0-rc11 — 2026-06-04

### Added

- **`button` gains an `overflow` mode.** `overflow: Text_Overflow` — a label
  too wide for the button elides with `…` under `.Ellipsis`. The label is
  always clipped to the rect (it can't punch into the next button), so
  `.Visible`/`.Clip` are equivalent; only `.Ellipsis` changes anything.
  Mirrors `text`'s overflow — for a chat-list row title that should degrade
  gracefully when squeezed. Defaults to `.Visible`.

- **`combobox` shows a dropdown chevron.** A downward caret in the closed
  trigger's right padding so it reads as "pick from a list", not a free
  text field. Internal (`View_Text_Input.chevron`); combobox sets it. The
  caret is hand-drawn (stacked rects) like `select`'s — no glyph, so it
  can't tofu on a font missing `▾`. `color_picker`'s caret matches.

- **`chat_input` gains `line_spacing`.** Threads multiline leading into the
  composer; the auto-grow height counts the full per-line stride so loose
  spacing stays fully visible. Defaults to `0`.

- **`clickable` — make any view a button.** Wraps an arbitrary child (an
  image, a card, a row) so a left-click — or Space/Enter while focused —
  fires `on_click`; a second arg adds a right-click action:
  `clickable(ctx, child, Open{})` or `clickable(ctx, child, Open{}, Menu{})`.
  Auto-id, joins Tab order (`focusable`, default true), and `disabled`.
  Input-only by design — it draws nothing, so hover/pressed/focus visuals
  come from the query layer below.

- **`zone` + interaction queries — the engine under `clickable`.** Register
  a hit region with `zone(ctx, child, id)`, then read it during view:
  `widget_clicked` (release-based), `widget_pressed` (press edge),
  `widget_active` (held), `widget_click_count` (double/triple), plus the
  existing `widget_hovered`. Covers every button and gesture off one id —
  right-click menus, double-click, and hover/pressed restyling — the
  Skald-native way to build custom interactive widgets.

- **`image_is_resident(r, name)`.** Read-only check for whether an image
  is currently GPU-resident — without loading it or touching LRU order.
  Lets async-thumbnail apps detect LRU eviction and re-decode off-thread
  instead of tripping a blocking on-demand decode through `image()`.

- **`table` can reveal an app-driven focus row.** A new `reveal_row`
  parameter scrolls a row into view when its value *changes* — for
  typeahead, Backspace-to-parent, or "scroll to selection" where focus
  moves from outside the table. Change-detected, so a steady value won't
  fight the user's manual scrolling. In-table keyboard nav already
  self-reveals, so this is only for app-driven moves. Defaults to `-1`
  (no-op), so existing callers are unchanged.

- **`table` and `tree` activate on double-click.** Double-clicking a
  table row fires `on_row_activate`; double-clicking a tree row body
  fires `on_toggle` (expand/collapse). Matches keyboard activation and
  file-manager muscle memory; single-click still selects first.

- **`text_input` gains `line_spacing`.** Extra leading between visual
  lines (multiline only; `0` = font default). Feeds the per-line stride
  consistently, so content height, the scrollbar thumb, click
  hit-testing and caret-follow all stay in agreement when scrolled.
  Additive — defaults to `0`, so existing fields are unchanged.

- **`text` gains an overflow mode.** `overflow: Text_Overflow` —
  `.Visible` (default, today's behaviour), `.Clip` (hard-clip to the
  slot), or `.Ellipsis` (truncate and append `…`). Only bites when layout
  assigns the node less width than its content needs — so a `.Stretch`
  parent or fixed-width box elides while a `.Start`/`.End`/`.Center`
  parent is unaffected. Paired helper `text_fits(r, str, width, size,
  font)` reports whether a string fits, so apps can show a full-text
  tooltip only on truncated rows.

- **`tabs` can be closed by middle-click.** New `tabs_closable` builder
  takes `on_close(index)`, fired on a middle-click of a tab — the
  universal "close tab" gesture. Plain `tabs` is unchanged; the close
  callback rides a separate builder so the polymorphic-`Msg` signature
  stays sound.

- **`table` columns can elide overflowing text.** New
  `Table_Column.ellipsis` truncates over-long cell content to the column
  width with a trailing `…` instead of letting it spill into the next
  column. The table stretches the column's cells (so the text is actually
  width-constrained) and auto-sets `.Ellipsis` on a bare `text` cell, so
  marking the column is usually all that's needed — flex columns re-elide
  as they resize. Opt-in; other columns are unchanged. Ellipsis columns
  render left-aligned.

- **`opacity(factor, child)`.** Fades a whole subtree by multiplying the
  alpha of every draw it emits. Layout pass-through (measures and positions
  exactly as the child) and input-transparent (the faded region still
  hit-tests), so it's the way to dim an inactive pane, ghost a drag
  preview, or fade a disabled region. Nests multiplicatively and is
  theme-agnostic. Put it *inside* a flex, not around one, like the other
  wrappers.

- **`text` gains horizontal `align`.** `align: Cross_Align = .Start`
  places the (possibly-elided) single line within its assigned width,
  mirroring `button.text_align`. Lets a label be centred *and* ellipsised
  at once — previously mutually exclusive, since eliding needs a stretched
  width (left-drawn) and centring needs a content-sized slot. No-op unless
  the node is wider than its content; defaults to `.Start`.

### Fixed

- **Scroll wheel and scrollbar leaked through modals.** A `scroll` /
  `virtual_list` / `table` viewport (and a multiline `text_input`) behind an
  open dialog still claimed the wheel and let you drag its scrollbar — the
  wheel/thumb paths gated on raw rect-containment, not the z-aware
  `widget_hovered` that clicks already used. Now matched, so input behind a
  modal is fully inert.

- **Multiline `text_input` hit-testing ignored `line_spacing`.** Click-press
  resolved the cursor line by dividing mouse-y by the per-line stride
  (`line_h + line_spacing`), but click-drag — and the public
  `text_input_offset_at` / `text_input_offset_rect` accessors — divided by
  bare `line_h`. With spacing on, the held-button frame overshot and flung
  the selection several lines down, and the offset accessors mis-resolved
  the line (so spell-check / marks hit-tests landed on the wrong row). All
  paths now share the stride. Reported against a "Loose"-spaced markdown
  editor.

- **Fill-mode `table` / `virtual_list` with an empty `State`.** The state
  snapshot ran `new`/copy on a zero-size pointee (`State = struct{}`),
  which faulted under AddressSanitizer and snapshotted a degenerate
  pointer. Guarded with `size_of(Elem) > 0` — a zero-size state has
  nothing to copy.

- **`context_menu` no longer blanks a self-sizing child while open.**
  Wrapping a fill-mode `table`/`grid` (or anything via `sized()`) in
  `context_menu` collapsed the child to zero height the moment the menu
  opened: the open-state `col` offered it only its intrinsic min. The
  child now keeps the same layout role open or closed (`flex(1, …)` so it
  receives the full offered height), so the listing stays put under the
  menu.

- **Widgets scrolled out of view are no longer clickable.** Hit-testing
  ignored scroll clipping: a widget clipped away by its container's
  viewport (a table's overscan rows, a button scrolled past a scroll's
  edge) kept a live click target where it was no longer drawn — so
  clicking the empty strip just above a scrolled table could select an
  off-screen row. Every widget now records the clip rect it rendered
  under, and `widget_hovered` rejects a hover that falls outside it.
  `last_rect` is unchanged, so popover anchoring and other geometry are
  unaffected.

- **`text_input` clipping leaks closed too.** Its `×` clear button, the
  multiline scrollbar, and wheel-to-scroll hit-tested the field's full
  rect directly rather than through `widget_hovered`, so a field scrolled
  out of a container's viewport could be cleared or scrolled by clicking
  the empty space where it was no longer drawn. All three now gate on the
  field's clip rect.

## 1.0.0-rc10 — 2026-05-30

O(n) text wrapping across `text_input`, `text`, and `rich_text` (a 1200-word
field went from ~300 ms to ~5 ms per keystroke), `text_input` decorations +
screen↔byte mapping, and a batch of input/safety fixes — widget id namespace
hardening (#4), focus release on outside clicks (#3), modal/popover
click-through, runa fuzzing hardening, and long-token wrapping. No breaking
changes.

### Added

- **`text_input` decorations + screen↔byte mapping.** A new `marks: []Text_Mark`
  parameter draws decorations over caller-supplied byte ranges —
  `Squiggle` (spell-check), `Underline`, and `Highlight` — reusing the
  per-visual-line selection geometry, so wrapping / clipping / scroll come
  free. `nil` is byte-identical to before. Paired with two accessors,
  `text_input_offset_at(pos) -> offset` and `text_input_offset_rect(offset)
  -> rect`, for mapping clicks to bytes and anchoring popovers under a word.
  Drives spell-check squiggles + a fix menu today; the same primitive backs
  editor diagnostics, go-to, and annotations. `Mark_Style` is an enum, so new
  styles stay additive.

### Fixed

- **Multiline `text_input` wraps in O(n), not O(n²).** Editing a large
  document (~1000+ words) was laggy: the wrap pass re-measured a growing
  prefix once per rune per line, so cost scaled quadratically and thrashed
  the text-shape cache. Each logical line is now shaped once into a
  cumulative-advance table, and the wrapped result is memoized across frames
  (rebuilt only when the text, width, or font changes). A 1200-word field
  went from ~300 ms to ~5 ms per keystroke, and ~0.05 ms on an idle repaint.

- **Wrapped `text_input` no longer hangs on a too-narrow field.** A multiline
  field whose wrap width was smaller than a single multi-byte glyph (emoji /
  CJK / accented) at the line start spun emitting empty lines until it ran the
  process out of memory. The hard-break now always advances by at least that
  one rune. (Latent since the long-token wrap landed; surfaced by fuzzing.)

- **Static `text()` / `rich_text()` wrapping is O(n) too.** `wrap_text` was
  re-measuring a growing line prefix once per word, and `wrap_rich_text`
  shaped every word separately — both now shape each paragraph/span once
  into a cumulative-advance table and read break widths by subtraction
  (wrap behaviour, including the long-token rune hard-break, is unchanged).
  A large prose/markdown block wraps in a few ms instead of tens of ms; the
  per-frame wrap cache still dedupes the layout+render double-walk.

- **Widget id namespace hardening.** Every resolved widget id — auto,
  `hash_id`, sub-id, and raw `Widget_ID(n)` — now lives in one explicit
  namespace, so `widget_resolve_id` is idempotent. Wrapper widgets
  (`chat_input`, `search_field`, …) resolve an id and pass it to an inner
  builder that resolves it again; previously an auto-id picked up a stray
  high bit on the second pass and desynced the two, so `chat_input` without
  an explicit `id` never saw focus and `on_submit` never fired (#4, thanks
  @quonic). A raw small-int `id` also no longer aliases a positional auto-id.

- **Focusable widgets release focus on an outside click.** Clicking a button,
  checkbox, radio, toggle (or the table's keyboard row-nav) and then clicking
  away left it focused, so a later Space/Enter still activated it. A left-press
  outside the focused widget now clears focus — clicks inside an open popover or
  on a modal scrim are excepted. (#3, thanks @NANDquark)

- **Text-engine hardening (runa).** Fixed two issues found by fuzzing the
  bundled text engine under AddressSanitizer/MemorySanitizer: (1) a
  Devanagari cluster ending in RA + Virama (e.g. `र`+`्`) read out of bounds
  in the reph reorder and crashed — trivially triggerable from untrusted
  text; (2) glyph-bitmap allocation was unbounded, so a pathological size or
  a malicious font's absurd glyph bbox could force an enormous allocation.
  Both are now guarded. (Upstream runa 1.2.1.)

- **Long unbreakable tokens wrap instead of overflowing.** A single
  spaceless token (URL, hash, base64) wider than `max_width` used to
  overflow and push its container off-screen. `wrap_text` and
  `wrap_rich_text` now hard-break it at the widest fitting rune boundary
  (CSS `overflow-wrap: anywhere`) — automatic for any `max_width > 0`,
  no-wrap (`max_width = 0`) unchanged.

- **Modal & popover click-through.** Interactive widgets behind a modal
  dialog or under an open popover (select / picker / menu) could still
  receive clicks when their rect fell inside the card/popover footprint —
  the scrim didn't really block them. Every click/press gate now uses the
  z-aware `widget_hovered` (button, checkbox, radio, toggle, slider, link,
  the picker triggers incl. emoji, table rows, context_menu,
  right_click_zone, split divider, …), and `widget_hovered`'s popover-bleed
  guard is z-aware too.

## 1.0.0-rc9 — 2026-05-25

Two memory-leak fixes — the per-call `cmd_thread` arena leak and
runa's unbounded shape cache — plus a new audio capture/playback
module and widget fixes. No breaking changes.

### Added

- **Audio capture + playback (`skald/audio.odin`).** Microphone
  recording and PCM playback via SDL3 — no new C dependency.
  `audio_capture_open` / `_read` pull f32 PCM from a mic;
  `audio_play_open` / `_write` queue it to a speaker; device
  enumeration drives a `select`-based picker. Codec-neutral —
  encoding (Opus / AAC) is the app's job. macOS mic capture needs an
  `NSMicrophoneUsageDescription` Info.plist key (untested on real
  macOS hardware so far; Linux verified). New example
  `examples/48_audio`; cookbook recipe for the record→play flow.

- **`font` parameter on `text_input`.** Editable fields can now use a
  custom typeface (a `Font` handle from `font_load`) instead of only
  the renderer's global default — useful for code / prose editors
  wanting Iosevka etc. Threads through measurement, caret positioning,
  wrap, and hit-testing, so editing stays correct under the custom
  font's metrics. Defaults to `0` (Inter), so existing call sites are
  unchanged.

- **`cursor: Cursor_Shape` parameter on `canvas()`** — declarative
  cursor applied while the mouse hovers the canvas. Paint apps pick
  per-tool (`.Crosshair` for brush, `.Move` for pan, etc.); reads from
  app state every frame, no callback wiring. Zero-default (`.Default`)
  preserves the prior behaviour of leaving the cursor unchanged.

- **`widget_hovered(ctx, id)` — z-aware input-gating helper.** Sibling
  of `rect_hovered` for click / press handlers where modal-trap
  correctness matters. `rect_hovered`'s modal check is geometry-only,
  so a main-tree widget whose rect happens to overlap a dialog card
  still received clicks through the scrim (chat-bubble images behind a
  settings dialog were the smoking gun). `widget_hovered` instead
  checks the widget's actual render layer via a new `last_overlay_frame`
  stamp, so main-tree widgets are correctly z-blocked when a modal is
  open. `rect_hovered` is unchanged for visual hover effects; reach for
  `widget_hovered` in custom click handlers. Additive — no breaking
  changes.

- **`text_shape_cache_size(r)`** — diagnostic returning the count of
  shape-cache entries currently held by the runa backend. Returns 0 on
  the fontstash backend (no shape cache there).

### Changed

- **Vendored runa refreshed to 1.2.0 — shape cache now LRU-evicts at
  4096 entries.** Pre-1.2.0 the shape cache grew without bound for the
  renderer's lifetime; a stress test at 2000 unique strings/sec showed
  ~100 MB/min of heap growth. Runa 1.2.0 caps the cache at a soft
  default of 4096 entries (~4-8 MB at typical body sizes) with O(1)
  LRU eviction; same stress test now plateaus at +1 MB / 2 min.
  Real-world apps with high text churn (code editors, log viewers,
  animated counters, financial tickers) now have a fixed memory
  ceiling instead of accumulating forever. No app-side code change
  required.

- **`emoji_picker` search field now renders via `View_Text_Input`.** It
  was a plain `text` widget that captured keystrokes but drew no caret.
  It now constructs a `View_Text_Input` directly (the same path
  `command_palette` uses), so caret, placeholder fade, and
  scroll-on-overflow match every other input. Key handling is
  unchanged — purely a rendering refactor.

### Fixed

- **Worker thread temp_allocator leak fixed.** `cmd_thread` and
  `cmd_thread_simple` spawn a fresh OS thread per call whose
  `@thread_local` default temp_allocator orphaned its heap blocks on
  thread exit — multi-GB process growth over hours of polling.
  Runners now call `runtime.default_temp_allocator_destroy` before
  exit. The documented worker contract is unchanged: returned-Msg
  strings / slices must be heap-allocated, not temp-arena (the
  temp_allocator is destroyed the instant the worker returns).

- **Multiline `text_input` in fill mode scrolled prematurely.** A
  stretched editor (`flex(1, text_input(height = 0, multiline = true))`)
  scrolled once content passed ~6 lines even with room below — the
  scroll math used the fixed placeholder height, not the field's real
  stretched height. Now falls back to `last_rect.h` when `height == 0`.

- **`tabs` widget — focus ring could land on the wrong tab.** Each tab
  button used a positional auto-id, so any widget churn above the
  tabs strip in the same frame (e.g. a sidebar list growing as new
  messages arrived) shifted the auto-id counter and the previously-
  focused tab's id mapped to a different button — visible as a
  focus ring on a non-active tab. Tab buttons now use
  `widget_make_sub_id` for stable cross-frame identity. `tabs` also
  gains an optional `id: Widget_ID = 0` parameter for apps that want
  to pin the strip's id explicitly (`skald.hash_id("settings-tabs")`);
  default behaviour unchanged for existing callers.

- **`context_menu` rows passed the pre-rc6 `color` argument.** An
  internal `button` call still used the old `color =` name after rc6
  renamed it to `bg`; corrected to `bg`. Thanks @quonic (#2). No
  app-facing change.

## 1.0.0-rc8 — 2026-05-21

### Changed

- **Vendored runa refreshed to 1.1.0 — Latin autohinter enabled by
  default.** runa 1.1 ships a small Latin-script autohinter (~95 LOC)
  that snaps glyph outlines to the pixel grid before rasterization
  for clean stems and curve bottoms at body text sizes (12 – 30 px).
  Fixes the long-standing fluffiness artifact at the bottom of round
  letters (S, O, c, e, a, o) and along thin horizontal serifs that
  was most visible in chat-style UIs reading at default size. The
  upstream proc default flipped from opt-in to opt-out (`hint: bool
  = true`), so Skald picks up the new behaviour just by refreshing
  the vendor — no app-side code change required. Validated across
  Inter (bundled), Liberation Sans / Liberation Serif / DejaVu Sans
  Mono (system), at sizes 13 → 48 px, with descenders / punctuation /
  diacritics / colour emoji / rich-text spans / wrapped paragraphs,
  plus gallery sweep at body text sizes (13 / 14 px). Apps that
  prefer the historical un-hinted look can opt back in by setting
  `runa.raster_glyph`'s `hint` parameter to `false` from their own
  text wrappers, but Skald itself uses the new default everywhere.

### Added

- **Selectable text widgets — `text_selectable`, `rich_text_selectable`,
  `rich_text_selectable_links`.** Three new builders alongside the
  existing `text` / `rich_text` / `rich_text_links` static variants,
  giving the same rendered output but with full mouse + keyboard
  selection support. Click-drag selects a byte range; double-click
  selects a word (UAX #29 boundaries via runa, so non-Latin scripts
  segment correctly); triple-click selects everything; `Ctrl-A` /
  `Ctrl-C` work; clicking outside the widget transfers focus and
  clears the selection. `rich_text_selectable_links` adds clickable
  link spans on top via a required `on_link_click(target)` callback;
  a quick press-and-release fires the link after the multi-click
  resolution window (~350 ms) elapses, while a press-then-drag past
  a small threshold starts a drag-selection instead, and any
  double / triple click cancels the pending link fire so the
  word / select-all action wins cleanly. `Ctrl-C` on a selection
  spanning multiple `Text_Span`s strips the markup and copies plain
  text, so paste targets get the same characters the user saw on
  screen. Build out of the box on both runa (default) and fontstash
  backends. New example `examples/47_selectable_text` covers the
  three procs in a chat-bubble-style layout; the
  "Selectable chat-style message bubble" cookbook recipe walks
  through the messenger use case end-to-end.

- **`strike: bool` field on `Text_Span`.** Sibling to the existing
  `underline` — set `strike = true` on any span in a `rich_text` view
  to draw a strikethrough line through its glyphs. Strike position
  sits at ~38 % of ascent above the baseline so the line runs through
  the middle of capitals and the upper half of lowercase letters,
  scaling with the span's font size. Strictly additive; spans that
  leave `strike` at the zero default render identically to before.
  Useful for diff "before"-side text, completed todo items, sale
  prices, deprecation marks, and the like.

### Fixed

- **Button (and other single-line widget) centring with fallback fonts
  registered.** `measure_text` on the runa backend was returning the
  maximum line height across *every* font in the fallback chain, so
  apps that called `font_add_fallback` with a tall script font (Arabic,
  Hebrew, CJK have notoriously large vertical metrics for diacritic
  headroom) saw single-line widgets — buttons, checkboxes, radios,
  toggles, single-line `text` — inflate their intrinsic height by
  ~75 % even for Latin-only labels. Because `text_ascent` only uses
  the primary font, the centring math `ty = (size.y − lh) / 2`
  collapsed to `ty = pad.y` regardless of `lh`, leaving the text
  flushed against the top padding with all the leftover space at the
  bottom. `measure_text_runa` now reports the line height of the
  primary font only, matching the fontstash backend and
  `text_ascent_runa`. Apps that don't register fallbacks see no
  change (line height was already 14 for Inter at `size_md`); apps
  that do see button heights drop back to their pre-fallback values
  and text re-centres.

## 1.0.0-rc7 — 2026-05-17

### Changed

- **Vendored runa refreshed to 1.0.0.** Bumps from runa 0.9.2 to runa
  1.0.0 — UAX #9 bidi at 100 % (was 99.998 %), UAX #14 line break at
  99.91 % (was 99.4 %), all 28 COLR composite blend modes lit up,
  new UAX #29 word + sentence boundary iterators (100 %
  conformance), and a new `normalize` package shipping NFC / NFD /
  NFKC / NFKD Unicode normalisation. Facade re-exports the
  segmentation iterators directly from the runa package root, so
  `runa.grapheme_iter_make` etc work without reaching into
  `runa/itemize`. No API breaks for Skald callers.
- **Colour emoji works with zero setup.** `text_init` now auto-registers
  Twemoji-Mozilla as a fallback to Inter, so `skald.text("hi 😀")`
  renders colour emoji without any app-side wiring. The existing
  `font_use_default_emoji(r)` helper is now redundant for most apps —
  it stays in the public API as an idempotent way to grab the Font
  handle (for chaining further fallbacks, replacing the emoji font,
  or querying metrics). Apps still on the legacy fontstash backend
  (`-define:SKALD_RUNA=false`) see identical behaviour to before:
  emoji cells render blank because fontstash doesn't decode COLR.
  Existing explicit calls in `examples/45_colour_emoji` and
  `examples/46_emoji_picker` have been removed since they're no-ops.

### Removed

- **Thai word-break dictionary deliberately not vendored.** Upstream
  runa 1.0.0 embeds the PyThaiNLP `words_th.txt` corpus (CC-BY-SA)
  to drive longest-match Thai word segmentation. Skald replaces
  `linebreak/thai_dict.odin` with a stubbed no-op so every Skald
  binary stays permissively licensed by default — apps shipping
  commercial products don't have to add a CC-BY-SA attribution line
  for a feature most apps don't need. Thai paragraphs fall back to
  UAX #14's default SA-class behaviour (one unbreakable run), the
  same behaviour Skald shipped on runa 0.9.2. Apps that genuinely
  need Thai word-break can replace the stubbed file with the
  upstream version (plus the corpus) and add the corresponding
  attribution line.

## 1.0.0-rc6 — 2026-05-15

### Changed

- **Runa is now the default text backend.** `RUNA_BACKEND_DEFAULT`
  flips from `false` to `true`, so a plain `./build.sh …` routes text
  through runa: OpenType shaping, COLRv0 + COLRv1 colour emoji
  (including skin-tone modifier sequences via ccmp ligatures), Indic
  + SEA + RTL bidi shaping, and faster text on every benched
  workload. The fontstash path is retained as a fallback (build with
  `-define:SKALD_RUNA=false` or `SKALD_RUNA=0 ./build.sh …` to opt
  back in). `text_init` keeps the existing safety net: a runa init
  failure logs a warning and falls back to fontstash automatically,
  so apps keep running. The `emoji_picker` warning, the
  `font_use_default_emoji` "no-op on fontstash" caveat, and every
  doc/example that previously instructed users to set `SKALD_RUNA=1`
  have been inverted.
- **API consistency sweep (1.0 prep).** `button` renames its
  background colour param from `color` to `bg`, matching every other
  filled widget (`badge`, `chip`, `text_input`, `list_frame`, …);
  callers using `button(color = …)` need to switch to
  `button(bg = …)`. `split` moves its `id` param from position 9 to
  position 6 (right after the `on_resize` callback), so positional
  callers — there are none in the tree — would need to reorder.
  Keyword callers are unaffected. View.odin's public-API conventions
  comment is rewritten to match what the framework actually does
  (flag toggles last, `width = 0` is intrinsic not fill,
  `padding = -1` is "widget default" on styled wrappers).

### Added

- **Vendored runa refreshed to 0.9.2.** The bundled
  `skald/third_party/runa/` is now the 0.9.2 release: 13 complex
  scripts shape on canonical syllables — 9 Brahmic (Devanagari,
  Bengali, Gujarati, Kannada, Odia, Tamil, Telugu, Malayalam,
  Gurmukhi) + 4 SEA (Thai, Lao, Khmer, Myanmar), all verified
  byte-for-byte against HarfBuzz. Bidi conformance corrected to
  99.998 % (the earlier 100 % claim missed two deep-nested empty
  RLE/PDF cases). Picks up the BD16 stack-overflow ICU-parity fix
  and the pre-base matra reorder for multi-consonant clusters.
- **`emoji_picker` widget.** 😀 trigger that opens a popover with a
  substring-match search bar, optional recents row, 9 Unicode CLDR
  category tabs, a paginated 8 × 6 grid of ~1150 single-codepoint
  emojis, and a Fitzpatrick skin-tone toolbar. Picked emojis fire
  `on_pick(emoji_string)`; people / hand emojis with a non-default
  tone selected get the modifier codepoint appended. Recents are
  app-owned (pass a `[]string`). Renders properly under runa (the
  new default backend); if you've opted into fontstash the cells
  render blank because Twemoji's `glyf` outlines are empty (only
  COLR layers ship), so the widget prints a one-shot stderr warning
  the first time it runs under fontstash. See `examples/46_emoji_picker`
  + the cookbook recipe.

### Fixed

- **Grapheme-cluster cursor stepping in `text_input`.** Backspace,
  Delete, and the Left/Right arrows now step by one UAX #29 grapheme
  cluster instead of one codepoint, via runa's grapheme iterator. The
  user-visible change: skin-tone-modified emoji (👋🏽 = base + Fitzpatrick
  modifier, 2 codepoints / 1 cluster), regional-indicator flag pairs,
  and emoji ZWJ sequences now delete in a single keystroke. Pre-rc6,
  one backspace on 👋🏽 removed only the modifier and left the default
  yellow 👋 behind, requiring a second keystroke.
- **Colour-emoji glyphs no longer overlap.** Twemoji-Mozilla emojis
  have zero side-bearing inside their advance and the COLR raster
  bitmap rounds up to the nearest pixel — at non-integer font sizes
  the bitmap was one pixel wider than the advance, so adjacent
  emojis overlapped by ~1 px. Skald now pads colour-glyph advances
  by 15 % in both `draw_text` and `measure_text` (so cursor placement
  stays accurate), which eliminates the rounding overlap and gives
  the eye a faint gap between emojis — the breathing room every
  other UI emoji renderer (Slack, Discord, iOS) applies.

## 1.0.0-rc5 — 2026-05-14

The headline of rc5 is a second text backend: Skald now vendors
`runa`, a pure-Odin text engine, as an **opt-in** preview alongside
`vendor:fontstash`. Set `SKALD_RUNA=1` at build time and every text
call routes through it — OpenType shaping, COLR colour emoji
(v0 + v1 with gradients), and subpixel-x positioning land for free,
and frame times improve on
every benched workload. Fontstash stays the default for rc5; the
plan is to flip runa on by default before 1.0 final if the rc soak
turns up no surprises.

Outside of runa, rc5 picks up `cmd_set_theme` for live theme reloads
from `update`, eleven new `Key` enum variants for punctuation
shortcuts, and a `menu_bar` overlay fix.

### Added

- **Pure-Odin text backend (preview, opt-in).** Skald now vendors
  `runa` — a pure-Odin text engine that does parsing, shaping, layout,
  rasterization, and atlas management with zero C dependencies — at
  `skald/third_party/runa/`. Build with `SKALD_RUNA=1 ./build.sh …` (or
  `-define:SKALD_RUNA=true` directly) to route every `draw_text` /
  `measure_text` / `wrap_text` call through it instead of fontstash.
  Default stays on fontstash for rc5; the plan is to flip runa on by
  default before 1.0 final if the rc soak turns up no surprises.

  What runa unlocks today:
  - **Real OpenType shaping** — ligatures (`fi`, `→`, `==`), GPOS pair
    kerning, contextual alternates. fontstash only has basic kern-pair
    lookup.
  - **Colour emoji** — COLRv0 layered glyphs and COLRv1 with linear /
    radial / sweep gradients, from fonts like Twemoji-Mozilla or
    Noto Color Emoji. Register a colour-emoji font through the
    existing `font_add_fallback` API and 🦊 renders properly in any
    text widget (label, button, `text_input`, `rich_text`, chat bubbles).
  - **Subpixel-x positioning** — glyphs land on the correct fractional
    pixel via a 4-bucket bitmap variant per cache key. fontstash
    quantises to integer pixels.

  Performance: in `bench.sh`, runa is faster than fontstash on every
  workload — 01_hello +39 % fps, virtual_list +27 %, table matches,
  gallery 2.2× faster. The shape cache (zero-alloc on hit) is doing
  the heavy lifting. Memory is +2.6 MB one-time overhead at startup
  (parsed font tables + cache structures), then zero per-frame growth.

  See `examples/45_colour_emoji/` for the canonical mixed-text +
  Twemoji demo. The runa source is zlib-licensed; full notice at
  `skald/third_party/runa/LICENSE`. Two Unicode UCD data files
  (`Scripts.txt` / `LineBreak.txt`) ship under the Unicode-DFS-2016
  licence at `skald/third_party/runa/tools/ucd/`.

  Two follow-ups already on `main` past the initial vendor:
  - **runa glyph size matches fontstash visually.** The two backends
    disagreed on what `size = N` means (fontstash: ascent − descent
    = N px; runa: em-square = N px), so flipping `SKALD_RUNA=1` made
    text render ~33 % larger. Skald now rescales per-font at the
    boundary so the visual size is identical across backends. Apps
    can flip the flag with no layout surprises.
  - **`font_use_default_emoji(r)` — one-line colour emoji opt-in.**
    Skald now bundles Twemoji-Mozilla (COLRv0, ~1.4 MB) at
    `skald/assets/Twemoji-Mozilla.ttf`. The helper loads it and
    chains as a fallback to Inter — under runa the emoji render in
    full colour, under fontstash they still tofu (until the runa
    default flip). Idempotent. Bundled artwork is CC-BY-4.0; apps
    shipping Skald binaries add an attribution line per the notice
    at `skald/assets/Twemoji-Mozilla-CCBY.txt`.

- **`cmd_set_theme(Msg, theme)` — swap the active theme from
  `update`.** The runtime owns one `Theme` value across frames;
  this command writes the new theme into that slot between frames
  so the next `view` paints with the new palette. Cleaner than the
  previous "mutate `ctx.theme^` from inside `view`" pattern, which
  worked but broke the convention that state changes flow through
  `update`. `examples/32_theme_follow` rebuilt around this: six
  palettes (Follow-OS / Dark / Light / Ocean / Forest / Rosewood),
  picker swatches, sample widgets so every surface slot is visible
  during the swap. Cookbook "Theming" section rewritten to match.
- **Keyboard `Key` enum: punctuation variants.** Added `Minus`,
  `Equals`, `Left_Bracket`, `Right_Bracket`, `Semicolon`,
  `Apostrophe`, `Comma`, `Period`, `Slash`, `Backslash`, `Grave`
  with their SDL3 scancode mappings. Apps wiring shortcuts like
  `Ctrl+=` / `Ctrl+-` (zoom) or `Ctrl+,` (preferences) no longer
  need to fall back to text-event sniffing.

### Fixed

- **`menu_bar` dropdowns no longer leak hover tints to widgets
  underneath.** The open dropdown now claims the overlay rect via
  `widget_stamp_overlay_rect`, matching `select` / `context_menu`
  / popovers. Widgets rendered later in the tree that use
  `rect_hovered` (almost everything) correctly gate out hover when
  the cursor sits inside an open menu. Visible on dense desktop
  UIs — without the fix, gliding down a File / View / Help menu
  painted hover halos on buttons + list rows behind it.

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

  Reported by a consumer app with a 15-entry model picker;
  subsequent reports caught the scrollbar grab, text overlap, and
  drag side-effect issues during testing.

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
  persists across frames. Surfaced by a consumer app as
  "top 3 chat rows flicker while assistant streams reply."
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
  caller discipline. Reported by a consumer app (crash trace in
  `delete_dynamic_array` from a stale `virtual_heights` slice).
- **`wrap_text` is now memoised per frame.** `View_Text` gets walked
  twice every frame — once in `view_size` (layout measure) and once
  in `render_view` (paint) — and each walk previously re-ran the
  full word-wrap pass for every text widget. `virtual_list_variable`
  adds a third call per visible row when refreshing its height
  cache. For chat-style UIs displaying long pasted content (e.g.
  a 30 KB message body in the visible window) this dominated frame
  time. A chat-style app saw avg frame
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

  Diagnosed and verified with a transparent-window app on xfwm4. After all
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
Pop!_OS COSMIC, Ubuntu 24.04, Windows). Real-app testing across
several in-house desktop apps surfaced a handful of latent bugs and
one usability footgun.

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
weren't caught by the gallery and the in-house apps. Nothing is
expected to change between rc1 and 1.0.0
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
