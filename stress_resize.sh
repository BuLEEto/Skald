#!/usr/bin/env bash
# Resize-fuzz the canonical example set.
#
# Drives each example's window through a sequence of small / odd
# sizes via xdotool — including the WM minimum (1x1) — and asserts
# the process is still alive after each resize. Catches the class
# of bug intralabels found in 2.0 rc.1: deferred fill-mode
# trampolines that re-defer at zero-size and recurse forever.
#
# Usage:
#   ./stress_resize.sh                 # all examples
#   ONLY=00_gallery ./stress_resize.sh # one example
#
# Requires xdotool and an X11 display. On Wayland sessions the
# WM may refuse external resize requests; run from an X11 login
# (or under XWayland) for accurate coverage.
set -euo pipefail

cd "$(dirname "$0")"

if [[ -z "${DISPLAY:-}" ]]; then
    echo "stress_resize.sh: \$DISPLAY not set; needs an X server." >&2
    exit 1
fi

if ! command -v xdotool >/dev/null 2>&1; then
    echo "stress_resize.sh: xdotool not installed." >&2
    exit 1
fi

ONLY="${ONLY:-}"

# Examples that open a normal resizable main window. Multi-window
# (38) and threads (40) are excluded because they spin up extra
# windows whose lifetimes confuse the squish-and-check loop.
EXAMPLES=(
    01_hello
    07_counter
    08_text_input
    09_widgets
    10_scroll
    16_virtual_list
    17_table
    18_forms
    23_editor
    24_chat
    37_canvas
    41_table_inputs
    42_wrap_row
    00_gallery
)

# Sequence of (w,h) to push the window through. Includes:
#   - 1x1: triggers Vulkan minImageExtent clamp + zero-size fill paths
#   - 60x60 / 120x80: layout breakpoints + small flex remainders
#   - 400x300: middle responsive breakpoint
#   - 1280x720: back to the App.size default; recovery check
SIZES=(
    "1 1"
    "60 60"
    "120 80"
    "400 300"
    "200 150"
    "1280 720"
)

run_one() {
    local ex="$1"
    printf "%-18s " "$ex"

    ./build.sh "$ex" >/dev/null 2>&1

    "./build/$ex" >/tmp/stress-$ex.log 2>&1 &
    local pid=$!
    sleep 1.5

    # Find the window. Examples don't all use the same title, so we
    # look up by PID's window via xdotool.
    local wid
    wid=$(xdotool search --pid "$pid" 2>/dev/null | tail -1 || true)
    if [[ -z "$wid" ]]; then
        echo "FAIL (no window — startup crash?)"
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 1
    fi

    for s in "${SIZES[@]}"; do
        # Drop both stderr and stdout — xdotool spams BadWindow when
        # the WM debounces an out-of-range request, which is fine.
        xdotool windowsize "$wid" $s >/dev/null 2>&1 || true
        sleep 0.3
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "CRASH at size $s — log: /tmp/stress-$ex.log"
            return 1
        fi
    done

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f /tmp/stress-$ex.log
    echo "OK"
    return 0
}

fails=0
if [[ -n "$ONLY" ]]; then
    run_one "$ONLY" || fails=$((fails+1))
else
    for ex in "${EXAMPLES[@]}"; do
        run_one "$ex" || fails=$((fails+1))
    done
fi

if [[ $fails -gt 0 ]]; then
    echo
    echo "$fails example(s) crashed during resize. Logs in /tmp/stress-*.log"
    exit 1
fi
echo
echo "All examples survived the resize sequence."
