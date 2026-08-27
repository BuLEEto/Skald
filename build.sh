#!/usr/bin/env bash
# Build one of the Skald examples.
#
# Usage:
#   ./build.sh                       # builds 01_hello (default)
#   ./build.sh 01_hello              # builds examples/01_hello
#   ./build.sh 01_hello run          # builds and runs
#   ./build.sh all                   # type-checks every example (pre-push guard)
#   RELEASE=1 ./build.sh …           # strips the F12 debug inspector
#
# Examples build with -debug by default so the F12 inspector is
# available while exercising the gallery. Shipping apps should build
# without -debug (the whole inspector is `when ODIN_DEBUG`-gated, so
# release binaries don't contain the code or the F12 handler).
#
# The -collection:gui flag points at the project root so `import "gui:skald"`
# resolves the same way from any example.
#
# Runa is the pure-Odin text engine that ships vendored at
# skald/third_party/runa/ — Skald imports it via a relative path so
# clones build standalone without any extra collection flag. Runa is
# the default backend; pass SKALD_RUNA=0 to force the legacy fontstash
# path instead (no colour emoji, no complex-script shaping).
set -euo pipefail

cd "$(dirname "$0")"

EXAMPLE="${1:-01_hello}"
ACTION="${2:-build}"

mkdir -p build

DEBUG_FLAG="-debug"
if [[ "${RELEASE:-0}" == "1" ]]; then
    DEBUG_FLAG="-o:speed"
fi

RUNA_DEFINE=""
if [[ "${SKALD_RUNA:-}" == "0" ]]; then
    RUNA_DEFINE="-define:SKALD_RUNA=false"
fi

# `all` type-checks every example — a fast (~15s) guard so a signature change
# that breaks an example's call can't slip past `odin test` (which only checks
# the skald package, not examples/). Run it before pushing.
if [[ "$EXAMPLE" == "all" ]]; then
    fail=0
    for dir in examples/*/; do
        ex="$(basename "$dir")"
        [[ -f "${dir}main.odin" ]] || continue
        if ! odin check "examples/${ex}" -collection:gui=. ${RUNA_DEFINE} >/dev/null 2>&1; then
            echo "FAIL  ${ex}"
            fail=1
        fi
    done
    if [[ "$fail" == "0" ]]; then
        echo "all examples check clean"
    else
        echo "some examples FAILED to check" >&2
        exit 1
    fi
    exit 0
fi

odin build "examples/${EXAMPLE}" \
    -collection:gui=. \
    ${DEBUG_FLAG} \
    ${RUNA_DEFINE} \
    -out:"build/${EXAMPLE}"

if [[ "$ACTION" == "run" ]]; then
    exec "./build/${EXAMPLE}"
fi
