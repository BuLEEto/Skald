/*
Package parse reads OpenType / TrueType font tables from a []u8 buffer.

The parser is lazy and read-only — it indexes into the caller's byte slice
without copying. The caller's `data` must outlive any parsed views.

Every fallible procedure returns `(T, Error)`. The parser never panics on
malformed input; mis-shaped tables surface as `Error.Invalid_Table`. This
hardness is a deliberate hedge against the OpenType attack surface
(decades of FreeType / FontConfig CVEs).

Tables implemented at v0.1 ship in priority order (head, maxp, cmap, hhea,
hmtx, loca, glyf, ...).1 list and
§14 for the table sequence.
*/
package parse

// Error is the parse-level error type. The public `runa.Error` enum is a
// superset that the facade maps these onto.
Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Table,         // malformed or out-of-bounds table data
	Unsupported_Format,    // table format not implemented
	Table_Not_Found,       // required table absent from SFNT directory
	Glyph_Not_Found,
}

// Glyph_ID is the OpenType glyph index. u16 is the on-disk size and the
// natural size for every public API surface.
Glyph_ID :: u16

// Tag is a 4-byte OpenType tag (table tag, feature tag, script tag, ...).
// Stored big-endian-packed as a u32 so equality compares are a single
// instruction. Construct with `tag("head")`.
Tag :: distinct u32
