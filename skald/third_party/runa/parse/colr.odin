package parse

// COLR — Color Glyph Layers Table.
//
// At v0.1 we read version 0: a base-glyph-record array mapping a
// "base" glyph ID to a slice of layer records. Each layer is one
// monochrome glyph filled with one CPAL palette colour, composited
// back-to-front to assemble the final colour glyph.
//
// COLR version 1 adds gradient brushes, glyph transforms, and
// compositing modes; it's deferred to v0.5
// Every version-1 font also ships a usable version-0 fallback, so a
// v0-only reader still renders all current emoji fonts (no gradients,
// but the layered fill is correct).
//
// References: OpenType spec, "COLR — Color Table".

COLR_VERSION_0 :: u16(0)
COLR_VERSION_1 :: u16(1)

// Palette-entry sentinel meaning "use the caller's foreground colour".
COLR_FOREGROUND_PALETTE_INDEX :: u16(0xFFFF)

Colr :: struct {
	data:                   []u8,
	version:                u16,
	num_base_glyph_records: u16,
	base_glyph_records_off: u32,
	layer_records_off:      u32,
	num_layer_records:      u16,

	// COLRv1 extras (zero on a v0 font).
	base_glyph_list_off:    u32,
	layer_list_off:         u32,
	clip_list_off:          u32,
	v1_paint_count:         u32,
	v1_layer_count:         u32,
}

new_colr :: proc(data: []u8) -> (c: Colr, err: Error) {
	r := Reader{data = data}
	version := read_u16(&r) or_return
	if version != COLR_VERSION_0 && version != COLR_VERSION_1 {
		err = .Unsupported_Format
		return
	}
	c.data                   = data
	c.version                = version
	c.num_base_glyph_records = read_u16(&r) or_return
	c.base_glyph_records_off = read_u32(&r) or_return
	c.layer_records_off      = read_u32(&r) or_return
	c.num_layer_records      = read_u16(&r) or_return

	if version >= 1 {
		// COLRv1 header extensions: BaseGlyphList, LayerList, ClipList
		// offsets (Offset32) + ItemVariationStore + VarIndexMap. We
		// only read the first three; variations are deferred.
		c.base_glyph_list_off = read_u32(&r) or_return
		c.layer_list_off      = read_u32(&r) or_return
		c.clip_list_off       = read_u32(&r) or_return
		// VarIndexMap + ItemVariationStore offsets follow — ignored.

		if c.base_glyph_list_off != 0 {
			off := c.base_glyph_list_off
			if u64(off) + 4 <= u64(len(data)) {
				c.v1_paint_count = u32(data[off])<<24 | u32(data[off + 1])<<16 |
				                   u32(data[off + 2])<<8 | u32(data[off + 3])
			}
		}
		if c.layer_list_off != 0 {
			off := c.layer_list_off
			if u64(off) + 4 <= u64(len(data)) {
				c.v1_layer_count = u32(data[off])<<24 | u32(data[off + 1])<<16 |
				                   u32(data[off + 2])<<8 | u32(data[off + 3])
			}
		}
	}
	return
}

// Colr_Layer is one composited layer: a monochrome glyph (its outline
// comes from `glyf` / `CFF`) tinted with a CPAL palette entry.
//
// If `palette_index` equals COLR_FOREGROUND_PALETTE_INDEX, the
// rasterizer substitutes the caller-supplied foreground colour rather
// than reading from CPAL.
Colr_Layer :: struct {
	glyph_id:      Glyph_ID,
	palette_index: u16,
}

// colr_layers returns a slice of layers for `gid`, or nil if `gid`
// isn't a colour-base glyph. The returned slice is a heap allocation;
// caller frees with `delete`.
//
// v1 paint trees are tried first; on miss, the v0 BaseGlyphRecord
// table is consulted (most COLRv1 fonts ship a v0 fallback for
// backwards compatibility).
colr_layers :: proc(c: ^Colr, gid: Glyph_ID, allocator := context.allocator) -> (layers: []Colr_Layer, err: Error) {
	// COLRv1 path.
	if c.version >= 1 && c.base_glyph_list_off != 0 {
		buf := make([dynamic]Colr_Layer, 0, 8, allocator)
		if colr_v1_layers(c, gid, &buf) {
			if len(buf) == 0 { delete(buf); return }
			layers = buf[:]
			return
		}
		delete(buf)
	}

	// COLRv0 path.
	first_layer, num_layers, ok := find_base_glyph_record(c, gid)
	if !ok { return }                            // gid not a colour base — return empty
	if num_layers == 0 { return }

	layers = make([]Colr_Layer, num_layers, allocator)
	if layers == nil { err = .Out_Of_Memory; return }

	for i in 0..<int(num_layers) {
		off := c.layer_records_off + u32(first_layer + u16(i)) * 4
		if u64(off) + 4 > u64(len(c.data)) {
			delete(layers, allocator)
			err = .Invalid_Table
			return
		}
		layers[i] = Colr_Layer{
			glyph_id      = Glyph_ID(u16(c.data[off])<<8     | u16(c.data[off + 1])),
			palette_index =          u16(c.data[off + 2])<<8 | u16(c.data[off + 3]),
		}
	}
	return
}

// colr_is_base reports whether `gid` is a colour base glyph — useful
// for the rasterizer's branching ("should I use the alpha pipeline or
// the colour pipeline?").
colr_is_base :: proc(c: ^Colr, gid: Glyph_ID) -> bool {
	_, _, ok := find_base_glyph_record(c, gid)
	return ok
}

// find_base_glyph_record binary-searches the sorted base-glyph-records
// array. Returns (first_layer_index, num_layers, true) on hit.
@(private)
find_base_glyph_record :: proc(c: ^Colr, gid: Glyph_ID) -> (first_layer: u16, num_layers: u16, ok: bool) {
	if c.num_base_glyph_records == 0 { return }
	base := c.base_glyph_records_off
	if u64(base) + u64(c.num_base_glyph_records) * 6 > u64(len(c.data)) { return }

	lo, hi := 0, int(c.num_base_glyph_records)
	for lo < hi {
		mid := (lo + hi) / 2
		p := base + u32(mid) * 6
		g := u16(c.data[p])<<8 | u16(c.data[p + 1])
		switch {
		case u16(gid) == g:
			first_layer = u16(c.data[p + 2])<<8 | u16(c.data[p + 3])
			num_layers  = u16(c.data[p + 4])<<8 | u16(c.data[p + 5])
			ok = true
			return
		case u16(gid) < g:
			hi = mid
		case:
			lo = mid + 1
		}
	}
	return
}
