#!/usr/bin/env bash
# Build one of the Skald examples.
#
# Usage:
#   ./build.sh                       # builds 01_hello (default)
#   ./build.sh 01_hello              # builds examples/01_hello
#   ./build.sh 01_hello run          # builds and runs
#   RELEASE=1 ./build.sh …           # strips the F12 debug inspector
#
# Examples build with -debug by default so the F12 inspector is
# available while exercising the gallery. Shipping apps should build
# without -debug (the whole inspector is `when ODIN_DEBUG`-gated, so
# release binaries don't contain the code or the F12 handler).
#
# The -collection:gui flag points at the project root so `import "gui:skald"`
# resolves the same way from any example.
set -euo pipefail

cd "$(dirname "$0")"

EXAMPLE="${1:-01_hello}"
ACTION="${2:-build}"

mkdir -p build

DEBUG_FLAG="-debug"
if [[ "${RELEASE:-0}" == "1" ]]; then
    DEBUG_FLAG="-o:speed"
fi

odin build "examples/${EXAMPLE}" \
    -collection:gui=. \
    ${DEBUG_FLAG} \
    -out:"build/${EXAMPLE}"

if [[ "$ACTION" == "run" ]]; then
    exec "./build/${EXAMPLE}"
fi
