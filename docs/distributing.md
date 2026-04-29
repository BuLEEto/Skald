# Distributing your Skald app

What end users need installed to run a Skald app you've built, and how
to package the binary so they don't have to install much. This is
runtime-side; for the developer build setup see
[`PLATFORMS.md`](../PLATFORMS.md).

## What every end user needs (no matter what you ship)

A **Vulkan loader** + **GPU driver**. Both come pre-installed on every
modern desktop system that ships with a working GPU:

- Linux: `libvulkan1` (loader) and a Vulkan ICD —
  `mesa-vulkan-drivers` for Intel/AMD, NVIDIA's proprietary driver,
  etc. Default on every desktop install since ~2020.
- Windows: `vulkan-1.dll` ships with every recent GPU driver
  (NVIDIA / AMD / Intel since ~2018).
- macOS: no native Vulkan; **MoltenVK** translates Vulkan calls to
  Metal. You ship MoltenVK with your app (see below).

Quick test on the user's machine: `vulkaninfo | head` (Linux/macOS) or
`vulkaninfo` (Windows, if they install the SDK). If it prints
device info, the Vulkan side is working.

Plus the standard session libraries — Wayland/X11, xkbcommon, DBus —
which are present on any normal desktop install. SDL3 dlopens
whichever's available at runtime, so users on either Wayland or X11
sessions are fine without you naming specific packages.

## Linux

Two distribution patterns, pick one.

### Pattern A — bundle `libSDL3.so.0` next to the binary (recommended)

The user just extracts the tarball and runs the binary. Works on every
distro that has a Vulkan loader, including ones that don't ship SDL3
in their repos (Ubuntu 24.04 LTS, Debian 12).

The pattern, as used by ERSaveBackup's release CI:

```bash
# In your build script after `odin build`:
patchelf --set-rpath '$ORIGIN' yourapp
sdl_lib=$(ldd yourapp | awk '/libSDL3\.so/ {print $3}' | head -n 1)
cp -L "$sdl_lib" libSDL3.so.0
tar -czf yourapp-linux-amd64.tar.gz yourapp libSDL3.so.0
```

`RPATH=$ORIGIN` tells the dynamic loader to look for libraries in the
binary's own directory before checking system paths. The user's
extracted directory has both files; the loader picks up the bundled
SDL3 automatically.

The bundle adds ~1.5 MB to your tarball. The benefit: end users on
Ubuntu LTS or any older distro can run your app without
`apt install libsdl3-0` first.

A complete working reference lives in
[`ERSaveBackup`'s release workflow](https://github.com/BuLEEto/ERSaveBackup/blob/main/.github/workflows/release.yml)
— Linux job + bundle step + GitHub Release upload, all in one file.
Copy and adapt.

### Pattern B — assume system-installed SDL3

You ship a bare binary; the user installs SDL3 through their package
manager. Works on Debian 13, Fedora 40+, Arch, and rolling distros.
**Doesn't work on Ubuntu 24.04 LTS** — that release shipped before
SDL3 was packaged.

When this is the right call:

- You're publishing through `apt` / `dnf` / `pacman` repositories or
  Flatpak/Snap, where the package manager declares the dep for you.
- Your audience is on rolling-release distros (Arch, Fedora rawhide).
- You're producing a build for a single distro that you know has SDL3.

Required runtime package: `libsdl3-0` (Debian-family),
`sdl3` (Arch), `SDL3` (Fedora).

## Windows

Skald's `build.bat` already does the right thing automatically:

```bat
build.bat my_app run
```

…copies `SDL3.dll` from Odin's `vendor\sdl3\` next to the produced
`.exe`. Ship the `.exe` and `SDL3.dll` together (zip them, drop into
an installer, whatever). The Vulkan loader (`vulkan-1.dll`) ships with
every modern Windows GPU driver, so the user doesn't install anything.

Common distribution shapes:

- **Plain zip** with `myapp.exe` + `SDL3.dll`. User extracts, runs.
- **MSI / InnoSetup installer** if you want Start Menu / uninstall.
  Bundle both files; declare nothing as a runtime requirement.
- **MSIX / Microsoft Store** has its own packaging rules; the .exe +
  .dll pair still goes in.

## macOS

A proper `.app` bundle with `libSDL3.dylib` + MoltenVK inside.
Skeleton:

```
MyApp.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── myapp                  # the binary
    ├── Frameworks/
    │   ├── libSDL3.dylib
    │   └── libMoltenVK.dylib      # from the LunarG Vulkan SDK
    └── Resources/
        └── MyApp.icns
```

Set the binary's rpath to look inside `@executable_path/../Frameworks`
so it finds the bundled libraries:

```bash
install_name_tool -add_rpath '@executable_path/../Frameworks' MyApp.app/Contents/MacOS/myapp
```

For wider distribution (outside the App Store), you'll want to **sign
and notarise** the bundle so Gatekeeper doesn't block it on first
launch. Apple's developer docs cover the process; the short version
is `codesign --deep --options runtime` + `xcrun notarytool submit`.

The user double-clicks the `.app`. macOS has no native Vulkan, but
MoltenVK inside your bundle handles that — they don't need to install
anything separately.

## Asset bundling

Anything you `#load(...)` at compile time (fonts, images, shaders) is
already embedded in the binary by Odin — nothing to ship separately.

Anything loaded at runtime via `image_load`, `font_load`, or
`os.read_entire_file` needs to be present at the path your code looks
in. For relative paths, that's relative to the *current working
directory*, which is wherever the user launched the binary from — so
either ship those assets next to the binary and resolve via
`os.args[0]`'s parent, or `#load` them at compile time so they live
inside the executable.

## Self-distribution summary table

| Target | What you ship | What user installs |
|---|---|---|
| Linux (any distro, bundled) | `app` + `libSDL3.so.0` in a tarball | nothing extra; `vulkaninfo` should work |
| Linux (system SDL3) | `app` binary alone | `libsdl3-0` (or distro equivalent) |
| Windows | `app.exe` + `SDL3.dll` | nothing |
| macOS | `MyApp.app` (incl. libSDL3 + MoltenVK) | nothing |

## Where to host the binaries

For most projects:

- **GitHub Releases** is the obvious choice. Auto-attaches CI build
  artefacts, gives you a stable URL per version, and `softprops/action-gh-release`
  in a workflow handles the upload. ERSaveBackup uses exactly this.
- **itch.io** for indie / hobby distribution — handles a lot of the
  user-facing presentation (changelogs, screenshots) for you.
- **Flathub / Snap Store** if you want auto-updates and tighter
  desktop integration on Linux. More work to set up; worth it once
  your user base outgrows manual download.

For commercial distribution: a signed installer (Windows MSI, macOS
.pkg, Linux .deb / .rpm) plus a small download page on your own
domain. CI generates the installers; the page links to them.
