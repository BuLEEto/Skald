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

### Prerequisites

- **SDL3** — `libsdl3-0` (runtime) and the headers your distro packages
  it under. SDL3 is in Debian Trixie / Devuan Excalibur, Fedora 40+,
  Arch, and most rolling distros. **Ubuntu 24.04 LTS does not ship
  SDL3** in any official repo as of writing — see "Building SDL3 from
  source" below.
- **Vulkan loader + driver** — `libvulkan1` and `mesa-vulkan-drivers`
  (or vendor proprietary drivers). In every mainstream distro's repo.
- **Odin's stb static libs** — Odin ships `vendor:stb/` as C source;
  the static archives that `vendor:fontstash` (which Skald uses) links
  against have to be built once per machine:

  ```bash
  make -C $ODIN_ROOT/vendor/stb/src
  ```

  If you skip this you'll get a link-time "cannot find `stb_truetype`"
  error at the end of an otherwise-successful Odin compile.

### Building SDL3 from source (Ubuntu 24.04 LTS or any distro
without a packaged SDL3)

This is the upstream-recommended dep set (matches SDL's own
`docs/README-linux.md`). Skald doesn't use SDL audio, but enabling the
audio backends here means the same `libSDL3.so` build is reusable for
other projects, and the IME packages (`libibus-1.0-dev`,
`fcitx-libs-dev`) are what makes Chinese / Japanese / Korean input
work in Skald apps:

```bash
sudo apt install \
    build-essential git make pkg-config cmake ninja-build \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev \
    libxi-dev libxss-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libwayland-dev wayland-protocols libdecor-0-dev \
    libdrm-dev libgbm-dev libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev \
    libdbus-1-dev libudev-dev \
    libasound2-dev libpulse-dev libpipewire-0.3-dev libsndio-dev libjack-dev \
    libibus-1.0-dev fcitx-libs-dev

git clone --branch release-3.2.10 https://github.com/libsdl-org/SDL.git
cd SDL
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
sudo cmake --install build
sudo ldconfig
```

If you only need windowing / input (no IME, no audio — fine for
Skald-only use, single-locale apps), the bare-minimum dep set is:

```bash
sudo apt install \
    build-essential cmake pkg-config \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev \
    libxi-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libwayland-dev wayland-protocols libdecor-0-dev libdbus-1-dev
```

The two packages most commonly missing on a fresh Ubuntu box (and
the usual cause of "could not find X11 or Wayland") are
**`wayland-protocols`** (separate from `libwayland-dev`) and
**`libxkbcommon-x11-dev`** (different package from
`libxkbcommon-dev`).

`release-3.2.10` mirrors what's in current stable distros; bump to
`release-3.4.2` if you want to match Odin's `vendor:sdl3` bindings
exactly.

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
