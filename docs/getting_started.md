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
