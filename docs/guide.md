# A Skald tour

Let's build a small to-do list. You type into a box, click Add, an
item appears. A little × next to each item removes it.

By the end you'll have seen text inputs, dynamic lists, message
unions, and enough layout to put things where you want them. The
finished code lives in `examples/99_todo`.

## Start with just a shell

Every Skald app needs four procs. Let's stub them out:

```odin
package example_todo

import "gui:skald"

State :: struct {}

Msg :: enum { /* nothing yet */ }

init :: proc() -> State { return {} }

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
    return s, {}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    th := ctx.theme
    return skald.text("Todo", th.color.fg, th.font.size_lg)
}

main :: proc() {
    skald.run(skald.App(State, Msg){
        title  = "Todo",
        size   = {480, 600},
        theme  = skald.theme_dark(),
        init   = init,
        update = update,
        view   = view,
    })
}
```

Run it. You get a window with the word "Todo" in it. Nothing to do
yet, but the loop is running — Skald is calling `view` sixty times a
second and drawing what comes back. `ctx.theme` is the colours,
fonts, and spacing for the active theme. You'll keep reaching for it.

> Following along in your own project rather than this repo? Compile
> with `odin build . -collection:gui=/path/to/skald-parent`, where
> `skald-parent` is the directory that *contains* the `skald/` folder
> (the root of a Skald clone, say). See
> [Building your own app](getting_started.md#building-your-own-app)
> for the full recipe plus a `build.sh` / `build.bat` template.

## Collect some text

Put a draft on state:

```odin
State :: struct {
    draft: string,
}
```

Enums can't carry data, and we need to know *what* the user typed.
Change the enum to a union:

```odin
Msg :: union {
    Draft_Changed,
}

Draft_Changed :: distinct string
```

`distinct string` is Odin's way of saying "yes it's a string, but
give it its own type so `switch v in m` can pattern-match on it."

Now handle the message in `update`:

```odin
import "core:strings"

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
    out := s
    switch v in m {
    case Draft_Changed:
        delete(out.draft)
        out.draft = strings.clone(string(v))
    }
    return out, {}
}
```

The `delete` + `clone` is because text-input messages carry temporary
strings — they live in a frame arena that Skald drops at the end of
every frame. If you want the value to survive, clone it onto the
persistent heap. `delete` frees what you had before.

And wire it into `view`:

```odin
on_draft :: proc(v: string) -> Msg { return Draft_Changed(v) }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    th := ctx.theme
    return skald.col(
        skald.text_input(ctx, s.draft, on_draft,
            placeholder = "What needs doing?"),
        padding = th.spacing.lg,
    )
}
```

`text_input` takes the current value and a proc that turns the new
value into a `Msg`. You can't hand it a `Msg` directly because one
gets built per keystroke — you pass a factory, Skald calls it.

Run it. You type, letters appear, `update` runs every keystroke,
state updates, the next frame renders with the new value. The fact
that you can't feel any of that happening is kind of the point.

## Add a button that does something

We want an Add button next to the input. Buttons emit a fixed `Msg`
(no payload), so a new variant:

```odin
Msg :: union {
    Draft_Changed,
    Add_Clicked,
}

Add_Clicked :: struct {}
```

Handle it — move the draft onto a list:

```odin
State :: struct {
    draft: string,
    items: [dynamic]string,
}

// in update, add a case:
case Add_Clicked:
    if len(out.draft) == 0 { return out, {} }
    append(&out.items, strings.clone(out.draft))
    delete(out.draft)
    out.draft = strings.clone("")
```

For the view, we want the input and the button side by side. That's
`row`:

```odin
return skald.col(
    skald.row(
        skald.flex(1, skald.text_input(ctx, s.draft, on_draft,
            placeholder = "What needs doing?")),
        skald.button(ctx, "Add", Add_Clicked{}, width = 80,
            color = th.color.primary, fg = th.color.on_primary),
        spacing = th.spacing.sm,
    ),
    padding = th.spacing.lg,
)
```

Two new pieces:

- `row` lays its children out horizontally. `col` does vertical.
- `flex(1, ...)` tells the row "this child takes all the leftover
  space." Without it the text input would shrink to fit its
  placeholder and there'd be a big gap before the button.

Run it, type something, click Add. It should add to `items`, but
we're not drawing the list yet.

## Render the list

Build a row per item. A `for` loop collecting views into a slice:

```odin
view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    th := ctx.theme

    rows: [dynamic]skald.View
    rows.allocator = context.temp_allocator

    for item in s.items {
        append(&rows, skald.text(item, th.color.fg, th.font.size_md))
    }

    return skald.col(
        skald.row(
            skald.flex(1, skald.text_input(ctx, s.draft, on_draft,
                placeholder = "What needs doing?")),
            skald.button(ctx, "Add", Add_Clicked{}, width = 80,
                color = th.color.primary, fg = th.color.on_primary),
            spacing = th.spacing.sm,
        ),
        skald.col(..rows[:], spacing = th.spacing.xs),
        padding = th.spacing.lg,
        spacing = th.spacing.md,
    )
}
```

Notice `rows.allocator = context.temp_allocator` — anything you
build inside `view` should live in the frame arena. Skald drops it
after the frame renders. Allocating on the persistent heap from
`view` is almost always a bug.

The `..rows[:]` syntax spreads the slice as variadic arguments.
`col` takes `..View` as its first parameter.

Type a few things, click Add, they pile up under the input. Good.

## Remove things

Each row needs an × button that says "remove *this* item." The Msg
carries the index:

```odin
Remove_Clicked :: distinct int

// in the Msg union:
Msg :: union {
    Draft_Changed,
    Add_Clicked,
    Remove_Clicked,
}

// in update:
case Remove_Clicked:
    i := int(v)
    if i < 0 || i >= len(out.items) { return out, {} }
    delete(out.items[i])
    ordered_remove(&out.items, i)
```

And in `view`, build the row with the × button carrying its index:

```odin
for item, i in s.items {
    remove_msg := Remove_Clicked(i)
    append(&rows, skald.row(
        skald.text(item, th.color.fg, th.font.size_md),
        skald.flex(1, skald.spacer(0)),
        skald.button(ctx, "×", remove_msg, width = 32,
            color = th.color.danger, fg = th.color.on_primary),
        spacing     = th.spacing.sm,
        cross_align = .Center,
    ))
}
```

`flex(1, skald.spacer(0))` pushes the × to the far end of the row.
The spacer is zero-size; flex makes it greedy.

`cross_align = .Center` vertically centers the text and the button
against each other.

Run it. Type, Add, ×, items come and go. Under 90 lines of code for
a real interactive app.

## What just happened

You wrote no window code, no event loop, no redraw trigger, no
widget reference cleanup. You described what should be on screen
for any given state, and what `update` should do in response to
each message. Skald handled everything else.

Worth noticing:

- You never "attached a handler" to the button. You said "this
  button carries this message." When it's clicked, the message
  shows up in `update`. Same for text inputs, dropdowns, every
  interactive widget.
- You rebuilt the whole view from scratch every frame. That sounds
  expensive but it isn't — allocations go through a frame arena
  that gets wiped in one shot at the end. Skald reconciles which
  widget is "the same widget as last frame" so focus, scroll
  position, undo history, and selection survive the rebuild.
- You never cared about threading or async. (File I/O, dialogs, and
  timers are coming in a later section; they all travel through
  `Command(Msg)` values returned from `update`, so they integrate
  with the same loop).

## Where to go next

- **[`cookbook.md`](cookbook.md)** — short recipes for the things
  you'll keep reaching for: forms, dialogs, shortcuts, theming,
  async work, persistence.
- **[`gotchas.md`](gotchas.md)** — the handful of things that will
  actually trip you up. Worth skimming once so you recognise them
  when they happen.
- **[`widgets.md`](widgets.md)** — signatures and behavior notes for
  every public widget.
- **`examples/`** — 35+ annotated demos, grouped in
  [`examples.md`](examples.md). When you want to see a pattern, look
  for the example that uses it.
- **[`architecture.md`](architecture.md)** — how the framework is
  put together inside. Read this if you're extending Skald, not if
  you're using it.
