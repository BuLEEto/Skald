#!/usr/bin/env bash
# Recompile Skald's GLSL shaders to SPIR-V. Run from anywhere.
# Requires `glslc` from the Vulkan SDK / shaderc.
set -euo pipefail
cd "$(dirname "$0")"
glslc ui.vert -o ui.vert.spv
glslc ui.frag -o ui.frag.spv
echo "shaders rebuilt: $(ls -la ui.*.spv | awk '{print $NF, $5}')"
