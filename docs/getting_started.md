# Getting started

Skald is an Elm-architecture GUI framework for Odin with immediate-mode-level
performance. You write four procs — `init`, `update`, `view`, `main` — and
Skald turns them into a window that responds to clicks and keystrokes.
State lives in your app, messages flow through a pure `update`, the view
tree is rebuilt from scratch every frame. That's the whole deal.

## Get it running

You'll need Odin on your PATH, SDL3 installed through your OS package
manager (bundled with Odin on Windows), and a Vulkan loader (ships with
`libvulkan1` on Linux, recent GPU drivers on Windows, or the LunarG
Vulkan SDK — which includes MoltenVK — on macOS). Then:

```bash
git clone <repo> skald && cd skald
./build.sh 07_counter run
```

A window opens with a − / Reset / + counter. Click the buttons, the
number changes. If that works your toolchain is healthy and you can
stop reading this section.

On Windows, open "x64 Native Tools Command Prompt" before `build.bat`
— Odin links through `link.exe`.

## What you're looking at

Open `examples/07_counter/main.odin`. It's 72 lines and every Skald app
follows the same shape:

```odin
State :: struct { count: int }
Msg   :: enum   { Inc, Dec, Reset }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
    switch m {
    case .Inc:   return {count = s.count + 1}, {}
    case .Dec:   return {count = s.count - 1}, {}
    case .Reset: return {count = 0}, {}
    }
    return s, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    // ...build a tree of buttons and text out of `s`...
}
```

`State` is your data. `Msg` is every action the user can take. `update`
answers "given the old state and a message, what's the new state?"
`view` answers "given the state, what should be on screen right now?"

Skald calls `view` every frame and draws what it returns. When you
click a button, Skald takes whatever `Msg` that button carries, hands
it to `update`, and renders the new state on the next frame. That's
the whole loop.

No widget handles. No event listeners. No observable chains. You
describe the UI you want, Skald makes it be there.

## Building your own app

The `./build.sh 07_counter run` command above only works from inside
this repo. For your own project, Skald is an Odin package that you
reference via a *collection* — Odin's name for a named root from which
`import` paths resolve.

### 1. Put Skald somewhere your project can find

Three common patterns; pick whichever fits your workflow:

- **Sibling clone** — `git clone <skald-url>` next to your project
  folder. Simple, no submodule juggling. Good for solo work.
- **Git submodule** — `git submodule add <skald-url> vendor/skald`
  inside your repo. Pins a specific Skald commit; collaborators get
  the exact same version on clone.
- **Vendored copy** — drop the `skald/` folder straight into your
  repo. Works offline, no external dependency, but updates are
  manual.

Whichever you pick, the important thing is that the path to the
*directory that contains* `skald/` is stable. That directory is what
you'll hand to the compiler as a collection root.

### 2. Tell Odin where to find it

Odin resolves `import "foo:bar"` by looking up the collection named
`foo` and reading `bar/` beneath it. Skald's examples use `gui` as
the collection name, so `import "gui:skald"` means "find the
collection called `gui`, then look for the `skald/` package under
it."

Your `main.odin`:

```odin
package my_app

import "gui:skald"

main :: proc() {
    skald.run(skald.App(State, Msg){
        title  = "Hello",
        size   = {640, 480},
        theme  = skald.theme_dark(),
        init   = init,
        update = update,
        view   = view,
    })
}
```

Your build command tells Odin what `gui` points to:

```bash
odin build . -collection:gui=/path/to/skald-parent -out:build/my_app
```

`/path/to/skald-parent` is the directory that *contains* the `skald/`
folder — **not** the `skald/` folder itself. For the sibling-clone
layout where your project and the Skald clone are peers, that's
`../skald-repo-name`.

### 3. A minimal `build.sh`

Save this next to your `main.odin` and `chmod +x` it:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# Adjust this path so it points at the directory containing the
# `skald/` folder. For a sibling git clone called `skald`, it's `../skald`.
SKALD_ROOT="../skald"

odin build . \
    -collection:gui="${SKALD_ROOT}" \
    -debug \
    -out:build/my_app

if [[ "${1:-}" == "run" ]]; then
    exec ./build/my_app
fi
```

`./build.sh` compiles, `./build.sh run` compiles and runs. Drop `-debug`
(or replace with `-o:speed`) for release builds — the F12 debug
inspector is `when ODIN_DEBUG`-gated, so release binaries strip it
out automatically.

### 4. Windows equivalent

`build.bat`:

```bat
@echo off
cd /d "%~dp0"
if not exist build mkdir build

set SKALD_ROOT=..\skald

odin build . -collection:gui=%SKALD_ROOT% -debug -out:build\my_app.exe
if errorlevel 1 exit /b 1

if "%~1"=="run" build\my_app.exe
```

Run it from "x64 Native Tools Command Prompt" so `link.exe` is on
PATH. Odin's `vendor:sdl3` bundles `SDL3.dll` and the build copies
it next to your `.exe` automatically.

## What next

- **[`guide.md`](guide.md)** builds a small to-do app from scratch so
  you see where each piece comes in.
- **[`cookbook.md`](cookbook.md)** is the "how do I?" grab-bag —
  short recipes for forms, dialogs, shortcuts, theming, async, etc.
- **[`gotchas.md`](gotchas.md)** lists the handful of things that
  will trip you up if you haven't heard about them yet.
- **[`widgets.md`](widgets.md)** is the widget menu — signatures,
  what they do, when to reach for each one.
- **`odin doc ./skald`** dumps every public proc if you want the raw
  reference.
