# Gotchas

The handful of things that will trip you up. Skim this once; you'll
recognise them when they happen.

## Msg strings don't survive the frame

When a text input or file dialog hands you a string through a `Msg`,
that string lives in a per-frame arena that Skald drops at frame end.
If you want to keep the value, clone it:

```odin
case Draft_Changed:
    delete(out.draft)
    out.draft = strings.clone(string(v))
```

Forgetting this shows up as "my state has a garbage string next frame"
or, worse, an occasional use-after-free that crashes in a hot spot.

## Building inside `view`? Use the temp allocator

Slices, dynamic arrays, formatted strings built inside `view` should
all live in the frame arena:

```odin
rows: [dynamic]View
rows.allocator = context.temp_allocator

label := fmt.tprintf("Count: %d", s.count)   // tprintf already does this
```

`fmt.tprintf` is always safe; `fmt.aprintf` is a leak waiting to
happen. Same goes for `strings.clone` without a temp allocator — it
defaults to the persistent heap.

## `flex(1, ...)` collapses to zero in a content-sized parent

`flex` distributes *leftover* main-axis space. If the parent sizes
itself to fit children (the default for `col` / `row` without a
`width`/`height`), there is no leftover space, and flex children get
zero.

Fixes:

- Give the parent a concrete size.
- Put the parent inside another flex layout that gives it a share.
- Use `spacer(size)` with a real number instead of `flex`.

## My child sticks to the top/left of its container

Symptom: a single child inside a `col` (or `row`) with a defined
width renders at its intrinsic size, flushed to the start of the
cross axis instead of filling. A button looks like a small left-aligned
chip; an input doesn't span the form row.

Cause: `cross_align` defaults to `.Start`. A `col` doesn't stretch
children to its full width unless asked, and a `row` doesn't stretch
them to its full height either.

Fix: pass `cross_align = .Stretch` on the parent.

```odin
// Button stays at intrinsic width, flushed left:
skald.col(
    skald.button(ctx, "Save", On_Save{}),
    width = 320,
)

// Button fills the column's width:
skald.col(
    skald.button(ctx, "Save", On_Save{}),
    width = 320,
    cross_align = .Stretch,
)
```

Same trick stretches *every* child of a sidebar column to a uniform
width, regardless of how wide each child wants to be intrinsically.
For one-off children mixed in with content-sized siblings, wrap just
that child in `flex` (main axis) or `sized` (explicit cross-axis).

## Widget state in reshuffled rows

Skald keys widget state (focus, scroll, checked, open) off the
call-site hash. Inside `virtual_list` / `table` / `virtual_list_variable`
auto-IDs are scoped by the required `row_key` callback, so state
follows the *item* rather than the row position automatically —
sorts, filters, and deletions don't smear state across neighbors.
Most apps never hit this.

The only remaining footgun: returning an **unstable** key from
`row_key` (e.g. `u64(i)` on a list that sorts). If the key changes
for the same item between frames, widget state for that item is
lost on every sort. Return an id derived from the item's identity
(a database id, a filename hash, etc.), not from its current
position.

For hand-built lists (no virtual_list / table), use `hash_id` on
the item's stable identity:

```odin
for item in s.items {
    row_id := skald.hash_id(fmt.tprintf("row-%d", item.uid))
    skald.checkbox(ctx, item.done, on_toggle, id = row_id)
}
```

Same principle: the id has to come from the *item*, not the list
index.

## Persistent draft buffers and use-after-free

If you write a widget that keeps a draft string on the persistent
heap across frames, clone it into the temp allocator *first*, before
you slice or modify it:

```odin
draft := strings.clone(state.text_buffer, context.temp_allocator)
// now safe to slice, concatenate, index...
delete(state.text_buffer)
state.text_buffer = strings.clone(draft)
```

Without the clone-to-temp, doing `draft = draft[:len(draft)-1]`
(backspace) followed by `delete(state.text_buffer)` reads the same
memory you just freed. The default allocator reuses it instantly,
so the clone back to the heap picks up corrupted bytes. Only bites
custom widgets — the built-in `text_input` already does this.

## File-dialog filters can be flaky on Linux

`cmd_open_file_dialog(filters, ...)` works reliably on Windows and on
mainstream Linux desktops with mature `xdg-desktop-portal` backends
(GNOME, KDE, XFCE on stable distros). On bleeding-edge desktops it
gets sketchy: Pop!_OS's COSMIC ships an early `xdg-desktop-portal-cosmic`
that silently drops filtered Open dialogs and crashes on rapid clicks,
and even forcing zenity (`SDL_FILE_DIALOG_DRIVER=zenity`) doesn't
always recover — the filter-handling path inside SDL3 itself appears
to have a NULL-pointer bug on some Linux setups.

Folder dialogs (`cmd_open_folder_dialog`) and unfiltered file dialogs
(`cmd_open_file_dialog(nil, ...)`) work everywhere we've tested — the
bug is specifically in the filtered-file-dialog code path.

If your users hit the silent drop or a `dbus_message_unref(NULL)`
crash, the safe fallback is to pass `nil` for filters and let the OS
show all files. Most apps work fine that way; folder layouts usually
already implicitly limit what the user picks. We track this as an
upstream SDL3 issue, not a Skald bug — re-test once SDL ships a
filter-path fix.

## The "one frame lag" isn't a bug

Click → Msg queued → `update` runs → state changes → *next* frame
renders the new state. There's always one frame of lag between an
input event and the visible result. At 60 Hz that's 16 ms, invisible
to users, but worth knowing when you're debugging "why does my state
look one step behind the click?"

## In multi-window apps, dispatch on `ctx.window`

Skald calls the app's `view` once per open window per frame. A naive
`view` that always returns the same tree will render the main UI into
every popover.

```odin
view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
    switch ctx.window {
    case s.popover_id: return popover_view(s, ctx)
    case:              return main_view(s, ctx)
    }
}
```

`ctx.window` is a `Window_Id` — pointer-valued, compared with `==`.
Single-window apps never need to look at it; `ctx.window` just always
equals the primary id there. Cookbook's Multi-window section has a
full example.

## `cmd_thread` workers must not touch Skald state

The work proc you hand to `cmd_thread` / `cmd_thread_simple` runs on a
**different OS thread**. Skald's runtime (renderer, widget store, frame
arena, msg queue, ctx) is single-threaded. Touching any of it from
inside the worker is a data race — undefined behaviour that may not
surface until production.

Inside the work proc:

- ❌ Don't read or mutate `state` or anything pointing into it. Snapshot
  what you need into the typed payload of `cmd_thread`; it's copied
  by value at dispatch.
- ❌ Don't call any `skald.*` proc that takes `^Ctx`, `^Renderer`, or
  `^Widget_Store`. The worker has none of those.
- ❌ Don't allocate strings or slices into `context.temp_allocator`.
  The temp allocator on the worker is its own thread-local one; the
  main thread's gets reset under the worker's feet.

Safe inside the worker:

- ✅ Plain compute — CPU-bound math, parsing, decoding.
- ✅ Calls into your own sync libraries — postgres pool, sqlite, sync
  HTTP, image codec.
- ✅ Allocating heap memory you'll hand back via the returned Msg.
  Use `strings.clone` (default allocator) for output strings — they
  need to outlive the trip from worker to main thread.

Errors come back as Msg variants — don't panic. An Odin assertion
inside a worker terminates the whole process, with no chance for
`update` to handle it.

## `odin doc` and widget builder signatures

Widget builders like `button(ctx, label, msg, width = ..., color = ...)`
have lots of optional named parameters. `odin doc ./skald` is the
fastest way to see the full signature of any builder when you've
forgotten which parameter does what. `widgets.md` covers the common
ones in prose.
