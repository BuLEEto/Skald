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

## The "one frame lag" isn't a bug

Click → Msg queued → `update` runs → state changes → *next* frame
renders the new state. There's always one frame of lag between an
input event and the visible result. At 60 Hz that's 16 ms, invisible
to users, but worth knowing when you're debugging "why does my state
look one step behind the click?"

## `odin doc` and widget builder signatures

Widget builders like `button(ctx, label, msg, width = ..., color = ...)`
have lots of optional named parameters. `odin doc ./skald` is the
fastest way to see the full signature of any builder when you've
forgotten which parameter does what. `widgets.md` covers the common
ones in prose.
