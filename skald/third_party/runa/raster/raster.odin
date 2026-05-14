/*
Package raster turns parsed glyph outlines (and COLR layer trees) into
8-bit alpha or 32-bit RGBA atlas slots.

The rasterizer is a scanline analytic-coverage algorithm — no signed
distance fields, no GPU-side compute. CPU rasterization keeps the
library portable; the consumer uploads the resulting bitmap to whatever
GPU API they use (Vulkan, Metal, D3D12, GL).

v0.1: TrueType (`glyf`) + CFF outlines, integer-pixel positioning, COLRv0
layered emoji.
v0.1 (followup pass): 4-bucket subpixel positioning.
v0.5: COLRv1 gradient brushes and compositing modes.


*/
package raster
