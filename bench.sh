#!/usr/bin/env bash
# Run Skald's canonical bench suite and print a summary table.
#
# Usage:
#   ./bench.sh                # all examples, 600 frames, uncapped
#   FRAMES=3000 ./bench.sh    # override frame count
#   ONLY=00_gallery ./bench.sh   # bench a single example
#
# Used to sanity-check perf before merging a framework change: run
# once before, once after, eyeball the table. For reference numbers
# you can paste in a PR, see docs/benchmarks.md.
set -euo pipefail

cd "$(dirname "$0")"

FRAMES="${FRAMES:-600}"
ONLY="${ONLY:-}"

# Canonical bench targets. The gallery is the ceiling test (every
# widget live), the others isolate specific widget code paths so
# regressions in one area don't hide behind noise from another.
EXAMPLES=(
    01_hello         # minimal: counter app
    99_todo          # text input + dynamic list
    23_editor        # multiline text_input
    37_canvas        # canvas widget
    16_virtual_list  # 5 000-row virtual_list
    17_table         # 5 000-row sortable table
    00_gallery       # every widget on one screen (ceiling)
)

# Header for the results table. Widths tuned to match the longest
# example name and the metric column widths from `_bench_emit_summary`.
printf "%-18s %8s %8s %8s %8s %8s %10s %10s\n" \
    "Example" "avg_ms" "p50_ms" "p95_ms" "p99_ms" "fps" "RSS_MB" "growth_KB"
printf -- "--------------------------------------------------------------------------------\n"

run_one() {
    local ex="$1"
    RELEASE=1 ./build.sh "$ex" > /dev/null 2>&1

    local stats
    stats=$(SKALD_BENCH_FRAMES="$FRAMES" SKALD_BENCH_UNCAP=1 \
        "./build/$ex" 2>/dev/null | grep "SKALD_BENCH_STATS" || true)

    if [[ -z "$stats" ]]; then
        printf "%-18s %8s\n" "$ex" "FAIL"
        return
    fi

    # Pull each key=value out of the stats line.
    local avg p50 p95 p99 fps rss_end growth
    avg=$(    echo "$stats" | sed -n 's/.*avg_ms=\([0-9.]*\).*/\1/p')
    p50=$(    echo "$stats" | sed -n 's/.*p50_ms=\([0-9.]*\).*/\1/p')
    p95=$(    echo "$stats" | sed -n 's/.*p95_ms=\([0-9.]*\).*/\1/p')
    p99=$(    echo "$stats" | sed -n 's/.*p99_ms=\([0-9.]*\).*/\1/p')
    fps=$(    echo "$stats" | sed -n 's/.*fps=\([0-9.]*\).*/\1/p')
    rss_end=$(echo "$stats" | sed -n 's/.*rss_end_kb=\([0-9-]*\).*/\1/p')
    growth=$( echo "$stats" | sed -n 's/.*rss_growth_kb=\([0-9-]*\).*/\1/p')

    # RSS in MB for readability; rss_end_kb may be -1 on non-Linux.
    local rss_mb="-"
    if [[ "$rss_end" != "-1" && -n "$rss_end" ]]; then
        rss_mb=$(awk -v k="$rss_end" 'BEGIN{printf "%.1f", k/1024}')
    fi

    printf "%-18s %8s %8s %8s %8s %8s %10s %10s\n" \
        "$ex" "$avg" "$p50" "$p95" "$p99" "$fps" "$rss_mb" "$growth"
}

if [[ -n "$ONLY" ]]; then
    run_one "$ONLY"
else
    for ex in "${EXAMPLES[@]}"; do
        run_one "$ex"
    done
fi
