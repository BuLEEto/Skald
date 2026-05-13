# Benchmarks

Frame-time and memory numbers for Skald's example apps. Published so
that when a user asks *"is Skald fast enough?"* the answer is
**"here's the data."** Reproducible: every number below comes from
running one of the tree's example apps with two environment
variables set.

## Headline numbers

All examples fit inside a **1 ms** p99 frame at release build on the
Linux box, and sustain **120 fps with heaps of headroom** on the
Apple M4. Idle memory on Linux is ~77 MB for every app on the
default fontstash backend (atlas + Vulkan buffers dominate);
steady-state growth is flat after warmup. RSS on macOS is blank for
now — reader is Linux-only.

The pure-Odin runa backend (`SKALD_RUNA=1`) adds ~2.6 MB of one-time
overhead at startup (parsed font tables + shape cache) and lands
*faster* than fontstash on every workload — the 00_gallery ceiling
test runs at 1.22 ms / 821 fps vs 2.92 ms / 343 fps for fontstash,
2.4× faster. The shape cache (zero-alloc on hit) is doing the work.

### Linux (Ryzen 9 7900 + Radeon RX 7600)

| Example             | avg ms | p99 ms | Uncapped FPS | RSS (MB) | Notes                                 |
|---------------------|-------:|-------:|-------------:|---------:|---------------------------------------|
| `01_hello`          |  0.062 |  0.202 |       16,141 |     77.5 | minimal counter app                   |
| `99_todo`           |  0.074 |  0.226 |       13,440 |     77.7 | text input + dynamic list             |
| `23_editor`         |  0.081 |  0.235 |       12,383 |     77.9 | multiline text_input                  |
| `37_canvas`         |  0.093 |  0.222 |       10,755 |     77.8 | pen/canvas widget                     |
| `16_virtual_list`   |  0.239 |  0.308 |        4,193 |     78.0 | 5 000-row virtual_list                |
| `17_table`          |  0.333 |  0.414 |        3,005 |     78.1 | 5 000-row sortable table              |
| `00_gallery`        |  1.223 |  1.423 |          818 |     78.5 | every widget on one screen            |

### macOS (Apple Silicon M4, Mac mini, ProMotion 144 Hz)

| Example             | avg ms | p99 ms | "Uncapped" FPS | Notes                                            |
|---------------------|-------:|-------:|---------------:|--------------------------------------------------|
| `01_hello`          |  2.341 |  7.252 |          427.2 |                                                  |
| `99_todo`           |  2.287 |  7.298 |          437.3 |                                                  |
| `23_editor`         |  2.260 |  7.384 |          442.6 |                                                  |
| `37_canvas`         |  2.274 |  7.309 |          439.7 |                                                  |
| `16_virtual_list`   |  2.272 |  7.331 |          440.2 |                                                  |
| `17_table`          |  2.364 |  7.217 |          423.0 |                                                  |
| `00_gallery`        |  2.093 |  7.119 |          477.8 | every widget on one screen                       |

**The 144 Hz cap is real.** `SKALD_BENCH_UNCAP=1` requests
`VK_PRESENT_MODE_IMMEDIATE_KHR` but MoltenVK falls back to FIFO —
Apple Metal doesn't expose uncapped presentation, so p99 clamps to
one display frame (~7 ms for the Mac mini's ProMotion 144 Hz
display). The avg ms numbers are what Skald actually spends per
frame; the fps column is artificially ceiled. Bottom line: every
app sustains **120 fps with ~4× headroom** on this hardware.

Conclusions:

- Every app has **≥12× headroom** against a 16.6 ms (60 Hz) frame budget.
- The most content-dense app (the gallery, with every widget live) still
  finishes a frame in under 1.5 ms.
- Memory growth over **30 000 frames** on the gallery is **~1.15 MB**
  — essentially flat after the first few hundred frames. Breakdown:
  +852 KB over frames 1–600 (warmup), +200 KB over frames 600–3 000
  (~85 B/frame), +100 KB over frames 3 000–30 000 (~4 B/frame — OS
  page-churn noise). Not a per-frame leak; allocator/OS resident-set
  behaviour stabilising.

## Test machines

### Linux

- **CPU**: AMD Ryzen 9 7900 (12 cores, 24 threads)
- **GPU**: AMD Radeon RX 7600
- **OS**: Debian 13
- **Window**: 1680×980 logical px, 1× DPI

### macOS

- **CPU/GPU**: Apple Silicon M4 (Mac mini)
- **OS**: macOS 14+
- **Display**: ProMotion 144 Hz
- **Vulkan**: MoltenVK via LunarG SDK (portability subset)
- **Window**: app defaults, 2× DPI

Common to both: **Odin** nightly 2026-03, **Vulkan 1.3**, build with
`RELEASE=1` (`odin build -o:speed`).

## How to reproduce

The quickest way: `./bench.sh` from the repo root runs the full
suite above and prints a summary table. Variants:

```bash
./bench.sh                        # all 7 canonical examples
FRAMES=3000 ./bench.sh            # longer sample for stability
ONLY=00_gallery ./bench.sh        # just one
```

Use it to compare before/after a framework change. Pair the gallery
result (ceiling test — every widget live) with a focused one like
`17_table` or `16_virtual_list` when hunting a specific regression.

Under the hood, bench mode is built into `skald.run`. Two env vars:

- `SKALD_BENCH_FRAMES=N` — render N frames then exit. Forces every
  frame to render (bypasses lazy redraw) and prints a one-line
  summary to stdout.
- `SKALD_BENCH_UNCAP=1` — switch the swapchain to `IMMEDIATE`
  presentation so the measured frame time reflects actual CPU + GPU
  cost instead of the display's vsync period. **macOS note**:
  MoltenVK may silently fall back to FIFO — Apple Metal doesn't
  expose uncapped presentation. The p99 column will clamp to the
  display's refresh period (≈ 6.94 ms on 144 Hz ProMotion).

```bash
# Build release (no -debug, no inspector, o:speed)
RELEASE=1 ./build.sh 00_gallery

# Run with bench instrumentation
SKALD_BENCH_FRAMES=600 SKALD_BENCH_UNCAP=1 ./build/00_gallery
```

Output format:

```
SKALD_BENCH_STATS frames=599 avg_ms=1.223 p50_ms=1.211 p95_ms=1.286
                  p99_ms=1.423 min_ms=1.167 max_ms=1.825 fps=817.9
                  rss_start_kb=77676 rss_end_kb=78528 rss_growth_kb=852
```

One line, key=value, so you can pipe into a CSV or grep into a results
file. RSS is Linux-only (`/proc/self/statm`); other platforms emit -1.

## Stress test: long-text word-wrap

The canonical examples above measure normal UI density — short labels,
short button text, dozens of small widgets per frame. They don't hit
the `wrap_text` path with a 30 KB paragraph in one bubble, which is
exactly what a chat / log / commit-message viewer does to it.

`examples/43_chat_input` ships a `-define:BENCH_BIG_MSG=true` flag
that seeds one ~28 KB synthetic message into the list. Message rows
have `max_width = 580` so word-wrap runs. Numbers on the Linux box
(RX 7600 XT, Inter at 14 px, lazy redraw bypassed):

| | avg ms | p99 ms | fps |
|---|---|---|---|
| pre-cache | 195.3 | 201.1 | 5.1 |
| current   |  65.4 |  67.0 | 15.3 |

The 3× cliff comes from a per-frame cache (`Renderer.wrap_cache`)
that short-circuits the second + third `wrap_text` calls layout
makes per visible text widget (`view_size`, `render_view`, plus
`virtual_list_variable` if used). Repro:

```bash
RELEASE=1 odin build examples/43_chat_input -collection:gui=. \
  -define:BENCH_BIG_MSG=true -o:speed -out:build/43_chat_input_bench
SKALD_BENCH_FRAMES=300 SKALD_BENCH_UNCAP=1 ./build/43_chat_input_bench
```

The cache eliminates duplicate measure work, not the underlying
per-line measure cost — a 14-px text widget at this width word-wraps
~28 KB to ~360 lines, and every visible line still costs a measure.

## Why these numbers are what they are

Skald is built for speed as a *consequence* of its design, not as a
goal. The shape of the framework produces these numbers:

- **No retained tree.** `view` returns a fresh view tree every frame,
  laid out into the per-frame arena. There is no diffing, no widget
  reference tracking, no virtual DOM comparison. Less code runs
  per frame.
- **One pipeline.** Rects, text, images, and shadows all flow through
  a single SDF fragment shader (`skald/shaders/ui.frag`). Draw-call
  batching is trivial because everything is a quad with a `kind`
  attribute.
- **Lazy redraw.** When nothing has changed, the loop parks on
  SDL's event queue for up to 100 ms. A static window draws 0 frames
  per second. These benchmarks disable lazy redraw to measure the
  worst case.
- **Pure Odin Vulkan backend.** No FFI thunking across a large
  renderer lib — one translation unit owns the swapchain, glyph
  atlas, and command buffers.
- **Frame arena.** Every `view`-side allocation is a bump pointer
  into `context.temp_allocator`, reset at `free_all` each frame.
  There is no per-frame `malloc`/`free` churn outside explicit
  `delete(...)` / `strings.clone(...)` that widgets deliberately do
  for state that has to survive the frame.

## Where the numbers will get worse

- A window that's **taller / wider** draws more triangles and
  drives up frame time roughly proportionally.
- Many simultaneous **overlays** (dropdowns + dialogs + tooltips)
  each queue their own render pass region; a screen with 5+ open
  popovers will ingest extra CPU work.
- A **heavy canvas** widget drawing per-pixel shapes via the stroke
  pipeline can dominate frame time if the caller submits millions
  of samples — but that's app code, not Skald's surface.
- **Vsync on** (the default — `SKALD_BENCH_UNCAP` off) caps frame
  time at the display period (8.3 ms on 120 Hz, 16.6 ms on 60 Hz).
  Real-world users see that number, not the uncapped one.
- **A single visible text widget with tens of KB of content** still
  costs ~65 ms / frame on the Linux box even with the wrap cache. The
  cache kills the double-shape; it doesn't shrink the underlying
  O(rune-count) per-line measure. Apps that surface logs / chat /
  large paste targets should consider a display cap with an explicit
  "show full" expand — see `examples/43_chat_input
  -define:BENCH_BIG_MSG=true` for the repro.
