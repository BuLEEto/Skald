# Skald

**An Elm-architecture GUI framework for Odin with immediate-mode-level
performance.** Pure-functional state, rebuild-every-frame rendering, and
a modern dark/light aesthetic out of the box.

<p align="center">
  <img src="screenshots/Gallery_Dark.png"  alt="Skald gallery — dark theme"  width="49%"/>
  <img src="screenshots/Gallery_Light.png" alt="Skald gallery — light theme" width="49%"/>
</p>

<p align="center"><sub><code>examples/00_gallery</code> — the shipped widget set in both themes.</sub></p>

Skald reads like iced or Elm at the API level, and its rebuild-every-frame
model puts it in the immediate-mode performance tier rather than the
retained-tree one. See [`docs/benchmarks.md`](docs/benchmarks.md) for
actual numbers.

## Highlights

- **Elm architecture** — `init` / `update` / `view` with a pure `Msg` union.
  No imperative widget handles, no signal wiring; your app's `State`
  struct is the source of truth for app-level data.
- **Immediate-mode performance** — the view tree is rebuilt every frame
  from the app's state, so there's no retained widget graph to diff or
  keep in sync. Frame times under 1 ms on most apps on a modern desktop
  GPU (Linux); capped by display refresh on macOS.
- **GPU rendering** — pure-Odin Vulkan 1.3 backend (`vendor:vulkan`), glyphs
  via fontstash, one pipeline for rects + text + images.
- **Async** — the `Command(Msg)` effect system runs file I/O, native
  dialogs, and delays through `core:nbio` on the main thread; completions
  round-trip back as regular `Msg` values. For sync libraries that aren't
  nbio-shaped (postgres, sqlite, big-file parsers), `cmd_thread` runs the
  blocking call on a worker thread and delivers the return value as a Msg.
  The UI never freezes; `view` and `update` always run single-threaded.
- **Real widget set** — buttons, checkboxes, sliders, selects, text inputs
  (single + multi-line, with undo/clipboard/selection), tables, virtual
  lists, tabs, menus, dialogs, image, split panes, toasts, drag-and-drop,
  context menus, command palette, tree, date / time / color pickers.
- **Themable** — dark + light themes ship in-tree (GitHub Primer / Radix
  tuned); custom themes are a plain struct. Ships with i18n `Labels`,
  font-fallback chaining (`font_add_fallback`), and a
  `system_theme()` probe plus an `on_system_theme_change` callback so
  apps can follow the OS light/dark setting if they want.
- **Window state hooks** — `initial_window_state` to seed the window
  on launch, `on_window_state_change` to hear about user resize /
  move / maximize. Your app decides where/how to persist the state
  (JSON on disk, embedded in a `settings.db`, wherever) — Skald just
  reports the current geometry as a plain struct. Cookbook has the
  pattern.
- **Multi-window** — `cmd_open_window` / `cmd_close_window` spawn
  and tear down extra OS windows (popovers, notification bubbles,
  panels, HUDs). Each gets its own Vulkan swapchain, input, and
  widget store; the app's `view` is called per window with
  `ctx.window` set so one proc can render all of them. Device,
  pipeline, fonts, and images stay shared — only the swapchain and
  per-frame plumbing are per-window.
- **Keyboard-first** — Tab ring, shift-Tab, focus trap inside modals,
  focus restoration on dialog/palette close, `widget_tab_index` for
  explicit ordering, global `shortcut()` registration.
- **Cross-platform** — Linux (primary), Windows, macOS.

## Quick start

Prerequisites vary by platform. See [`PLATFORMS.md`](PLATFORMS.md) for
the exact commands; the short version:

- **Linux** — install SDL3 (`sudo apt install libsdl3-0` or equivalent)
  and a Vulkan loader (`libvulkan1` on most distros). On Ubuntu 24.04
  LTS, SDL3 isn't yet packaged — `PLATFORMS.md` has the build-from-
  source recipe. First-time Odin install also needs the stb static
  libs built once: `make -C $ODIN_ROOT/vendor/stb/src`.
- **Windows** — Odin's `vendor:sdl3` bundles `SDL3.dll` and `build.bat`
  copies it next to the exe automatically. Vulkan loader ships with
  recent GPU drivers or the LunarG Vulkan SDK.
- **macOS** — `brew install sdl3` plus the
  [LunarG Vulkan SDK](https://vulkan.lunarg.com/sdk/home#mac) (installs
  MoltenVK + loader). Source `~/VulkanSDK/*/setup-env.sh` in your
  shell, or run the SDK's system-install script.

```bash
git clone <your-fork> skald && cd skald
./build.sh 07_counter run  # build + run the counter example
```

On Windows:

```bat
build.bat 07_counter run
```

## Hello, Skald

```odin
package hello

import "core:fmt"
import "gui:skald"

State :: struct { count: int }

Msg :: enum { Inc, Dec }

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
    switch m {
    case .Inc: return {count = s.count + 1}, {}
    case .Dec: return {count = s.count - 1}, {}
    }
    return s, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    th := ctx.theme
    return skald.col(
        skald.text(fmt.tprintf("Count: %d", s.count),
            th.color.fg, th.font.size_display),
        skald.spacer(th.spacing.xl),
        skald.row(
            skald.button(ctx, "−", Msg.Dec, width = 64),
            skald.button(ctx, "+", Msg.Inc, width = 64,
                color = th.color.primary, fg = th.color.on_primary),
            spacing = th.spacing.md,
        ),
        padding     = th.spacing.xl,
        main_align  = .Center,
        cross_align = .Center,
    )
}

main :: proc() {
    skald.run(skald.App(State, Msg){
        title  = "Hello",
        size   = {640, 400},
        theme  = skald.theme_dark(),
        init   = init,
        update = update,
        view   = view,
    })
}
```

See `examples/07_counter` for the annotated version.

## Documentation

- [`docs/getting_started.md`](docs/getting_started.md) — install,
  run an example, understand what the code is doing.
- [`docs/guide.md`](docs/guide.md) — build a small app from scratch,
  picking up widgets and patterns as you go.
- [`docs/cookbook.md`](docs/cookbook.md) — short recipes for the
  things you'll keep reaching for: forms, dialogs, shortcuts,
  theming, async, persistence.
- [`docs/gotchas.md`](docs/gotchas.md) — the foot-guns worth knowing
  about before you hit them.
- [`docs/widgets.md`](docs/widgets.md) — per-widget reference.
- [`docs/examples.md`](docs/examples.md) — annotated index of every
  example, grouped by concept.
- [`docs/architecture.md`](docs/architecture.md) — how the framework
  fits together (for people extending Skald, not using it).
- [`docs/benchmarks.md`](docs/benchmarks.md) — frame-time and memory
  numbers with the env vars to reproduce them.
- Per-function reference — run `odin doc ./skald` from the project root.

## Repository layout

```
skald/          the framework package (pure Odin; imports vendor:vulkan/sdl3)
examples/       NN_topic/main.odin — runnable demos (44 of them)
docs/           tutorial, cookbook, widget reference, benchmarks
build.sh/.bat   build one example into ./build/ (use RELEASE=1 to strip -debug)
bench.sh        run the canonical bench suite
CHANGELOG.md    per-release notes
LICENSE         zlib
PLATFORMS.md    per-platform setup + known quirks
```

## Platforms

| Platform | Status                                  |
|----------|-----------------------------------------|
| Linux    | Primary target (X11 + Wayland via SDL3) |
| Windows  | Supported, SDL3 DLL auto-copied by build|
| macOS    | Supported via MoltenVK                  |

## The name

A *skáld* (Old Norse) was a court poet — composer and reciter of
ornate stanzaic verse in intricate alliterative meters, built up
from individual stanzas into longer praise poems called *drápur*.
The metaphor fits: a Skald app is one view composed from small
widgets, each shaped with care. It's also a thematic nod to Odin
itself, which the framework is built on.

## License

Skald is licensed under the **zlib license** — see [`LICENSE`](LICENSE).
Permissive: commercial use, modification, and redistribution are all
fine, with three light restrictions (don't misrepresent origin, mark
altered versions, keep the notice). Matches Odin's own license for
zero ecosystem friction.

The bundled Inter Variable font ships under the SIL Open Font License
1.1; its full text travels alongside the font at
[`skald/assets/InterVariable-OFL.txt`](skald/assets/InterVariable-OFL.txt).

## Acknowledgments

Skald stands on good shoulders. Credit and thanks to:

- **[Odin](https://odin-lang.org)** (Ginger Bill) — the amazing language itself.
- **[SDL3](https://libsdl.org)** (Sam Lantinga and the SDL contributors) —
  windowing, input, clipboard, file dialogs, drag-and-drop.
- **[Inter Variable](https://rsms.me/inter/)** (The Inter Project
  Authors) — the bundled default UI font.
- **[fontstash](https://github.com/memononen/fontstash)**
  (Mikko Mononen) — glyph atlas management, shipped via
  `vendor:fontstash`.
- **[stb](https://github.com/nothings/stb)** (Sean T. Barrett) —
  `stb_truetype` (used inside fontstash) and `stb_image` (PNG loading).
- **Vulkan** — specification by the Khronos Group; on macOS, Vulkan
  calls are translated to Metal by **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)**
  (originally by Brenwill Workshop Ltd., now maintained under
  Khronos).

If you build something nice with Skald, no obligation — but I'd love
to see it.

## Contributing

Small fixes: send a PR. Larger changes: open an issue first. The
open work areas the project would most benefit from — particularly
complex-script shaping (Arabic / Hebrew / Devanagari / Thai),
where the right contributor is a native speaker of the target
language — are written up in [`CONTRIBUTING.md`](CONTRIBUTING.md).
