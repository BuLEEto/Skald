package example_table_inputs

import "core:fmt"
import "core:strings"
import "gui:skald"

// Comprehensive per-row editable cells via `map_msg_for`. Every common
// stateful Skald widget appears once per product row:
//
//     text_input    (name)
//     number_input  (qty)
//     checkbox      (in_stock?)
//     toggle        (featured?)
//     slider        (discount %)
//     select        (category)
//     combobox      (supplier — type-to-filter)
//     segmented     (size — S/M/L)
//     rating        (quality 1–5)
//     date_picker   (valid_until)
//     color_picker  (tag color)
//
// All eleven widgets fire callbacks → `Row_Msg` → `map_msg_for` wraps
// with the row index → parent `update` writes back to the row's
// fields. The `widget_scope_push` keyed on each product's stable id
// keeps focus + edit state pinned to the *item* across reshuffles.
// Because every widget routes through `widget_auto_id`, this also
// stress-tests the cross-row id-collision fix that was the bug behind
// "dropdowns won't open in row 1."
//
// The Click counter at the bottom keeps incrementing while you're
// editing — proves the UI stays responsive throughout.

Category :: enum {
	Hardware,
	Fastener,
	Sealing,
	Spring,
}
category_strings := [Category]string{
	.Hardware = "Hardware",
	.Fastener = "Fastener",
	.Sealing  = "Sealing",
	.Spring   = "Spring",
}
category_options := []string{"Hardware", "Fastener", "Sealing", "Spring"}
category_from_string :: proc(s: string) -> Category {
	switch s {
	case "Fastener": return .Fastener
	case "Sealing":  return .Sealing
	case "Spring":   return .Spring
	}
	return .Hardware
}

Size :: enum { S, M, L }
size_options := []string{"S", "M", "L"}

supplier_options := []string{
	"Acme Co.", "Bolts & Co.", "FastFix",
	"GearBin", "Norton Tools", "Wright & Sons",
}

Product :: struct {
	id:           int,                       // stable id used as scope key
	name:         string,                    // heap-owned
	qty:          f64,
	in_stock:     bool,
	featured:     bool,
	discount:     f32,                       // 0..1
	category:     Category,
	supplier:     string,                    // heap-owned
	size_idx:     int,                       // 0=S 1=M 2=L
	quality:      int,                       // 1..5
	valid_until:  skald.Date,
	tag_color:    skald.Color,
}

State :: struct {
	products:        [dynamic]Product,
	clicks:          int,
	last_event_log:  string,                  // heap-owned
}

// Row-local Msg union — only what one row can emit.
Row_Msg :: union {
	Row_Name_Changed,
	Row_Qty_Changed,
	Row_Stock_Toggled,
	Row_Featured_Toggled,
	Row_Discount_Changed,
	Row_Category_Changed,
	Row_Supplier_Changed,
	Row_Size_Changed,
	Row_Quality_Changed,
	Row_Date_Changed,
	Row_Color_Changed,
}
Row_Name_Changed     :: distinct string
Row_Qty_Changed      :: distinct f64
Row_Stock_Toggled    :: distinct bool
Row_Featured_Toggled :: distinct bool
Row_Discount_Changed :: distinct f32
Row_Category_Changed :: distinct string
Row_Supplier_Changed :: distinct string
Row_Size_Changed     :: distinct int
Row_Quality_Changed  :: distinct int
Row_Date_Changed     :: distinct skald.Date
Row_Color_Changed    :: distinct skald.Color

Msg :: union {
	Click_Bumped,
	Row_Op,
}
Click_Bumped :: struct{}
Row_Op :: struct {
	row: int,
	op:  Row_Msg,
}

init :: proc() -> State {
	products := make([dynamic]Product, 0, 4)
	append(&products,
		Product{
			id = 1, name = strings.clone("M4×12 screw"), qty = 100,
			in_stock = true,  featured = false, discount = 0.10,
			category = .Fastener, supplier = strings.clone("Bolts & Co."),
			size_idx = 0, quality = 4,
			valid_until = skald.Date{year = 2026, month =  9, day = 30},
			tag_color   = {0.96, 0.74, 0.20, 1},  // amber
		},
		Product{
			id = 2, name = strings.clone("Brass washer 8 mm"), qty = 50,
			in_stock = true,  featured = true,  discount = 0.00,
			category = .Hardware, supplier = strings.clone("Acme Co."),
			size_idx = 1, quality = 5,
			valid_until = skald.Date{year = 2027, month =  3, day = 15},
			tag_color   = {0.30, 0.78, 0.45, 1},  // emerald
		},
		Product{
			id = 3, name = strings.clone("O-ring 10 mm"), qty = 200,
			in_stock = false, featured = false, discount = 0.25,
			category = .Sealing, supplier = strings.clone("Wright & Sons"),
			size_idx = 1, quality = 3,
			valid_until = skald.Date{year = 2026, month = 12, day = 31},
			tag_color   = {0.60, 0.45, 0.95, 1},  // violet
		},
		Product{
			id = 4, name = strings.clone("Spring 12×40"), qty = 20,
			in_stock = true,  featured = false, discount = 0.05,
			category = .Spring,  supplier = strings.clone("GearBin"),
			size_idx = 2, quality = 4,
			valid_until = skald.Date{year = 2026, month = 10, day = 12},
			tag_color   = {0.95, 0.30, 0.40, 1},  // rose
		},
	)
	return State{
		products       = products,
		last_event_log = strings.clone("(no edits yet)"),
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Click_Bumped:
		out.clicks += 1

	case Row_Op:
		if v.row < 0 || v.row >= len(out.products) { return out, {} }
		p := &out.products[v.row]
		log := ""
		switch op in v.op {
		case Row_Name_Changed:
			delete(p.name); p.name = strings.clone(string(op))
			log = fmt.tprintf("row %d → name = %s", v.row, p.name)

		case Row_Qty_Changed:
			p.qty = f64(op)
			log = fmt.tprintf("row %d → qty = %.0f", v.row, p.qty)

		case Row_Stock_Toggled:
			p.in_stock = bool(op)
			log = fmt.tprintf("row %d → in_stock = %v", v.row, p.in_stock)

		case Row_Featured_Toggled:
			p.featured = bool(op)
			log = fmt.tprintf("row %d → featured = %v", v.row, p.featured)

		case Row_Discount_Changed:
			p.discount = f32(op)
			log = fmt.tprintf("row %d → discount = %.0f%%", v.row, p.discount * 100)

		case Row_Category_Changed:
			p.category = category_from_string(string(op))
			log = fmt.tprintf("row %d → category = %s", v.row, string(op))

		case Row_Supplier_Changed:
			delete(p.supplier); p.supplier = strings.clone(string(op))
			log = fmt.tprintf("row %d → supplier = %s", v.row, p.supplier)

		case Row_Size_Changed:
			p.size_idx = int(op)
			log = fmt.tprintf("row %d → size = %s",
				v.row, size_options[clamp(int(op), 0, len(size_options)-1)])

		case Row_Quality_Changed:
			p.quality = int(op)
			log = fmt.tprintf("row %d → quality = %d", v.row, p.quality)

		case Row_Date_Changed:
			p.valid_until = skald.Date(op)
			log = fmt.tprintf("row %d → valid_until = %04d-%02d-%02d",
				v.row, p.valid_until.year, p.valid_until.month, p.valid_until.day)

		case Row_Color_Changed:
			p.tag_color = skald.Color(op)
			log = fmt.tprintf("row %d → tag_color updated", v.row)
		}
		delete(out.last_event_log)
		out.last_event_log = strings.clone(log)
	}
	return out, {}
}

on_click_bump :: proc() -> Msg { return Click_Bumped{} }

// Row-local handlers. None are aware of which row they belong to —
// that gets attached at the parent boundary by `wrap_row`.
on_row_name      :: proc(v: string)      -> Row_Msg { return Row_Name_Changed(v) }
on_row_qty       :: proc(v: f64)         -> Row_Msg { return Row_Qty_Changed(v) }
on_row_stock     :: proc(v: bool)        -> Row_Msg { return Row_Stock_Toggled(v) }
on_row_featured  :: proc(v: bool)        -> Row_Msg { return Row_Featured_Toggled(v) }
on_row_discount  :: proc(v: f32)         -> Row_Msg { return Row_Discount_Changed(v) }
on_row_category  :: proc(v: string)      -> Row_Msg { return Row_Category_Changed(v) }
on_row_supplier  :: proc(v: string)      -> Row_Msg { return Row_Supplier_Changed(v) }
on_row_size      :: proc(v: int)         -> Row_Msg { return Row_Size_Changed(v) }
on_row_quality   :: proc(v: int)         -> Row_Msg { return Row_Quality_Changed(v) }
on_row_date      :: proc(v: skald.Date)  -> Row_Msg { return Row_Date_Changed(v) }
on_row_color     :: proc(v: skald.Color) -> Row_Msg { return Row_Color_Changed(v) }

// Sub-view: takes the row's data + a Ctx parameterised on Row_Msg.
// Same proc reused for every row; identity threads through `wrap_row`.
product_row :: proc(p: Product, ctx: ^skald.Ctx(Row_Msg)) -> skald.View {
	th := ctx.theme

	// Pin per-row widget state to the product's stable id so each
	// widget's draft buffer / focus / open-state follows the *item*
	// across reshuffles.
	saved := skald.widget_scope_push(ctx, u64(p.id))
	defer skald.widget_scope_pop(ctx, saved)

	return skald.row(
		skald.text_input(ctx, p.name, on_row_name, width = 170),
		skald.number_input(ctx, p.qty, on_row_qty,
			min_value = 0, max_value = 9999, step = 1,
			width = 130),
		skald.checkbox(ctx, p.in_stock, "stock", on_row_stock),
		skald.toggle(ctx, p.featured, "featured", on_row_featured),
		skald.slider(ctx, p.discount, on_row_discount,
			min_value = 0, max_value = 1, step = 0.05, width = 120),
		skald.select(ctx, category_strings[p.category],
			category_options, on_row_category, width = 110),
		skald.combobox(ctx, p.supplier, supplier_options, on_row_supplier,
			width = 140),
		skald.segmented(ctx, size_options, p.size_idx, on_row_size),
		skald.rating(ctx, p.quality, on_row_quality),
		skald.date_picker(ctx, p.valid_until, on_row_date, width = 140),
		skald.color_picker(ctx, p.tag_color, on_row_color, width = 130),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	)
}

// Parent translator: receives the row index (passed as `payload` to
// `map_msg_for`) plus the row's emitted Sub_Msg and wraps both into
// the App's Msg union.
wrap_row :: proc(row: int, m: Row_Msg) -> Msg {
	return Row_Op{row = row, op = m}
}

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Body: one row per product, each wrapped via `map_msg_for`. The
	// SAME `product_row` proc serves every row — `map_msg_for`'s
	// `payload` is what makes each row's emits route correctly.
	row_views := make([dynamic]skald.View, 0, len(s.products),
		context.temp_allocator)
	for p, i in s.products {
		append(&row_views, skald.map_msg_for(ctx, i, p, product_row, wrap_row))
	}
	rows_col := skald.col(..row_views[:],
		spacing     = th.spacing.md,
		cross_align = .Stretch,
	)

	return skald.col(
		skald.text("Skald — comprehensive per-row editable cells",
			th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text(
			"Eleven widgets per row, all routed through map_msg_for. Edit any cell on any row; the action lands on the right product.",
			th.color.fg_muted, th.font.size_md, max_width = 1100),
		skald.spacer(th.spacing.lg),

		rows_col,
		skald.spacer(th.spacing.lg),

		// Stay-responsive proof.
		skald.row(
			skald.button(ctx, "Click me", on_click_bump()),
			skald.text(fmt.tprintf("Clicks: %d", s.clicks),
				th.color.fg, th.font.size_md),
			cross_align = .Center,
			spacing     = th.spacing.md,
		),
		skald.spacer(th.spacing.sm),
		skald.text(fmt.tprintf("Last edit: %s", s.last_event_log),
			th.color.fg_muted, th.font.size_sm),

		padding     = th.spacing.xl,
		cross_align = .Stretch,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — table inputs",
		size   = {1500, 700},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
