# Platforms

Skald targets Linux, macOS, and Windows. This file is the runbook for
bringing the two non-Linux platforms online: exact commands, what to watch
for, and a checklist to sign off a platform as "works on my machine."

All three platforms share the same Odin source. Rendering is pure-Odin
Vulkan 1.3 via `vendor:vulkan`; on macOS, MoltenVK translates Vulkan calls
to Metal. The only platform-specific shim in Skald is:

- `skald/platform_title_{linux,other}.odin` — Linux X11 `_NET_WM_NAME`
  workaround; a no-op stub on macOS/Windows (SDL3 handles titles natively
  there).

SDL3 handles the rest of the windowing/input differences; surface creation
runs through `sdl3.Vulkan_CreateSurface`, which picks the right
platform-specific `VkSurfaceKHR` extension under the hood.

---

## macOS (Intel + Apple Silicon)

### One-time setup

```bash
# 1. Install Odin (https://odin-lang.org/docs/install/) and put it on PATH.
# 2. Install the Vulkan SDK (includes MoltenVK) from
#    https://vulkan.lunarg.com/sdk/home — run the installer and source
#    its setup-env.sh so VK_ICD_FILENAMES points at MoltenVK.
# 3. Clone Skald. No download step — `vendor:vulkan` uses the loader
#    installed by the SDK; `vendor:sdl3` bundles its own runtime.
```

### Build + run

```bash
./build.sh 35_color_picker run
```

### What to verify

- [ ] `01_hello` opens a window and exits cleanly on close.
- [ ] `09_widgets` — buttons, sliders, toggles, text inputs all respond.
- [ ] `08_text_input` — typing works; Cmd+C / Cmd+V copy/paste via SDL3.
- [ ] `30_date_picker`, `31_time_picker`, `35_color_picker` — popovers open,
      dismiss on outside click, track the mouse on drag.
- [ ] `20_image` — PNG loads and renders.
- [ ] Window is crisp on a Retina display (HiDPI scaling works).
- [ ] Dark-mode toggle: change System Settings → Appearance → Dark while
      `32_theme_follow` is running; the app's theme should flip.

### Known risks

- `sdl3.Vulkan_CreateSurface` + MoltenVK require SDL3 ≥ 3.2.10 and a
  MoltenVK that advertises `VK_EXT_metal_surface`. The LunarG SDK ships
  a compatible build.
- MoltenVK's Vulkan 1.3 support is recent (≥ v1.2.9). If device creation
  fails with "unsupported API version" on an older SDK, upgrade.
- The Vulkan instance / device creation paths opt into
  `VK_KHR_portability_enumeration` + `VK_KHR_portability_subset`
  under `when ODIN_OS == .Darwin`. Without these, MoltenVK returns
  `ERROR_INCOMPATIBLE_DRIVER` — macOS has no fully-conformant
  Vulkan driver, so the app has to acknowledge portability-subset
  devices explicitly.

### Known limitations

- **Live-resize stretches the last frame.** While the user drags a
  window corner on macOS, Cocoa's resize-tracking loop blocks the
  main thread and SDL3's event pump stops firing. The compositor
  stretches the last-rendered framebuffer until mouse-up, at which
  point the app reflows normally. Every SDL-on-macOS app shares
  this — the proper fix is `SDL_AddEventWatch` + a re-entrant render
  pass, which is non-trivial. Deferred to post-1.0. Day-to-day use
  is unaffected; only interactive drag-to-resize looks stretchy.

- **`menu_bar` renders in-window, not in the top-of-screen bar.**
  SDL3 installs a minimal default Cocoa menu (App + Window) for
  every app; Skald layers its own `menu_bar` widget inside the
  window the same way it does on Linux/Windows. That's duplicated
  menu affordance and reads as non-native on Mac. Integrating with
  the top-of-screen bar (via AppKit foreign calls + routing clicks
  back into the Msg queue) is tracked for 1.1. 1.0 ships with the
  in-window bar; functional, just alien-looking on Mac.

- **`SKALD_BENCH_UNCAP=1` is effectively a no-op on macOS.**
  MoltenVK falls back to `FIFO` when asked for `IMMEDIATE`
  presentation — Apple Metal doesn't expose uncapped present. The
  bench numbers p99 at the display's refresh period instead of
  real CPU+GPU cost. Useful, just not the same meaning as Linux.

- **RSS isn't reported on macOS.** The bench mode reads
  `/proc/self/statm` on Linux; the macOS branch returns `-1`, so
  growth shows as 0. A Mach-API-based reader is planned for 1.1.

---

## Windows (x86_64, MSVC toolchain)

### One-time setup

```powershell
# 1. Install Odin and add it to PATH.
# 2. Install Visual Studio Build Tools (MSVC + Windows 10/11 SDK).
#    Open the "x64 Native Tools Command Prompt" or a Developer PowerShell
#    so `cl.exe` and friends are on PATH.
# 3. Vulkan loader: comes bundled with recent AMD/NVIDIA/Intel drivers;
#    if `vulkaninfo` fails, install the Vulkan SDK from
#    https://vulkan.lunarg.com/.
```

### Build + run

```powershell
.\build.bat 35_color_picker run
```

`build.bat` copies `SDL3.dll` (from Odin's `vendor\sdl3\`) next to the
produced `.exe` so the executable runs without PATH gymnastics. The
Vulkan loader (`vulkan-1.dll`) lives in `%SystemRoot%\System32\` and is
picked up automatically.

### What to verify

- [ ] `01_hello` opens a window.
- [ ] Window title renders with UTF-8 characters (SDL3 uses SetWindowTextW).
- [ ] `09_widgets` — mouse + keyboard work; focus rings draw; Tab cycles.
- [ ] `08_text_input` — Ctrl+C / Ctrl+V clipboard works.
- [ ] `35_color_picker` — SV square renders, drag updates the color.
- [ ] `20_image` — image loads.
- [ ] Per-monitor DPI: drag the window between a 100% and a 150% monitor.
      The contents should re-layout at the new scale.

### Known risks

- If device creation fails with "no suitable GPU," the system may only
  have a software Vulkan driver (e.g. `vulkan-1.dll` present but no ICD).
  Install vendor GPU drivers or the LunarG SDK.
- If linking complains about `gdi32` / `user32`, the MSVC SDK env vars
  aren't set — launch from the Developer command prompt.

---

## Linux (X11 + Wayland)

Linux is the primary dev platform and assumed to work. Quick sanity:

```bash
./build.sh 35_color_picker run
```

Prerequisites: `libvulkan1` (Vulkan loader) and a Mesa Vulkan driver
(`mesa-vulkan-drivers`) — both in every mainstream distro's package
repo.

### What to verify

- [ ] Works on both X11 and Wayland. Toggle `SDL_VIDEODRIVER=x11` or
      `=wayland` to force one. Window should open and render either way.
- [ ] Title shows UTF-8 correctly on X11 (the `_NET_WM_NAME` workaround in
      `platform_title_linux.odin` is what makes this work under Xlib).
- [ ] System theme auto-follow (`32_theme_follow`) reflects the GNOME/KDE
      color-scheme setting. "Unknown" is an acceptable result on desktop
      environments that don't publish a preference.

---

## Sign-off

A platform is considered "supported for 1.0" when:

1. Every example in `examples/` builds without warnings.
2. Every checkbox in the platform's section above passes.
3. No platform-specific panics or visual regressions appear in a 5-minute
   manual smoke run of `09_widgets`, `17_table`, `30_date_picker`,
   `35_color_picker`, and `23_editor`.

Record the outcome (Odin version, OS version, GPU, Vulkan driver version
from `vulkaninfo | head`) in the PR that lands the sign-off.
