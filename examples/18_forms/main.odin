package example_forms

import "core:fmt"
import "core:strings"
import "gui:skald"

// Phase 14 showcase: form controls. Starts with radios (this commit) and
// will grow to cover toggle, text area, image, dialog, and split pane as
// each lands. The demo is a mock "New Document" settings panel — the
// kind of dialog real apps ship and couldn't build with the Phase 5
// widget set alone.
//
// What's exercised today:
//   * Standalone `radio` with bool state + on_select Msg (the two-radio
//     "Orientation" row below). Use this when the options don't fit a
//     flat slice — e.g. when each option carries its own Msg variant.
//   * `radio_group` with a []string slice + index-based on_change (the
//     "Paper size" and "Theme" groups). Use this for the common case of
//     flat option lists; it adds arrow-key navigation between group
//     members for free.

Orientation :: enum { Portrait, Landscape }
Paper_Size  :: enum { A4, Letter, Legal, Tabloid }
Theme       :: enum { Dark, Light, High_Contrast }

State :: struct {
	orientation: Orientation,
	paper:       Paper_Size,
	theme:       Theme,
	wifi:        bool,
	bluetooth:   bool,
	airplane:    bool,
	notes:       string,
	locked:      bool,
}

Msg :: union {
	Orientation_Set,
	Paper_Set,
	Theme_Set,
	Wifi_Toggled,
	Bluetooth_Toggled,
	Airplane_Toggled,
	Notes_Changed,
	Lock_Toggled,
}

Orientation_Set   :: distinct Orientation
Paper_Set         :: distinct int
Theme_Set         :: distinct int
Wifi_Toggled      :: distinct bool
Bluetooth_Toggled :: distinct bool
Airplane_Toggled  :: distinct bool
Notes_Changed     :: distinct string
Lock_Toggled      :: distinct bool

init :: proc() -> State {
	return {
		orientation = .Portrait, paper = .A4, theme = .Dark,
		wifi = true, bluetooth = false, airplane = false,
		notes = strings.clone(
			"Print options for the first draft.\nEnter inserts newlines; Up/Down move between lines."),
		locked = false,
	}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Orientation_Set:   out.orientation = Orientation(v)
	case Paper_Set:         out.paper       = Paper_Size(int(v))
	case Theme_Set:         out.theme       = Theme(int(v))
	case Wifi_Toggled:      out.wifi        = bool(v)
	case Bluetooth_Toggled: out.bluetooth   = bool(v)
	case Airplane_Toggled:
		// Toggle semantics: airplane mode cuts wireless. Real apps
		// ripple an input change across dependent state in `update`
		// exactly like this, so the demo shows the pattern rather
		// than faking three independent toggles.
		out.airplane  = bool(v)
		if out.airplane {
			out.wifi      = false
			out.bluetooth = false
		}
	case Notes_Changed:
		// text_input strings live in the frame's temp arena, so clone
		// into a persistent allocator before the arena resets.
		delete(out.notes)
		out.notes = strings.clone(string(v))
	case Lock_Toggled:
		out.locked = bool(v)
	}
	return out, {}
}

on_portrait  :: proc() -> Msg { return Orientation_Set(.Portrait)  }
on_landscape :: proc() -> Msg { return Orientation_Set(.Landscape) }
on_paper     :: proc(i: int) -> Msg { return Paper_Set(i) }
on_theme     :: proc(i: int) -> Msg { return Theme_Set(i) }
on_wifi      :: proc(v: bool) -> Msg { return Wifi_Toggled(v)      }
on_bluetooth :: proc(v: bool) -> Msg { return Bluetooth_Toggled(v) }
on_airplane  :: proc(v: bool) -> Msg { return Airplane_Toggled(v)  }
on_notes     :: proc(s: string) -> Msg { return Notes_Changed(s)   }
on_lock      :: proc(v: bool) -> Msg { return Lock_Toggled(v)      }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	section_heading :: proc(text: string, ctx: ^skald.Ctx(Msg)) -> skald.View {
		th := ctx.theme
		return skald.text(text, th.color.fg, th.font.size_md)
	}

	return skald.col(
		skald.text("Skald — Forms",
			th.color.fg, th.font.size_xl),
		skald.spacer(th.spacing.xs),
		skald.text("Pick options the way a real Preferences panel would.",
			th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.lg),

		// Individual radios. Handy when the caller has a real enum and
		// wants the compiler to keep the Msg variants honest, instead
		// of indexing into a []string.
		section_heading("Orientation", ctx),
		skald.spacer(th.spacing.xs),
		skald.row(
			skald.radio(ctx, s.orientation == .Portrait,  "Portrait",  on_portrait),
			skald.spacer(th.spacing.lg),
			skald.radio(ctx, s.orientation == .Landscape, "Landscape", on_landscape),
			cross_align = .Center,
		),
		skald.spacer(th.spacing.lg),

		// radio_group convenience: string slice + index. Arrow keys
		// navigate inside the group (Up/Down because direction is
		// .Column by default).
		section_heading("Paper size", ctx),
		skald.spacer(th.spacing.xs),
		skald.radio_group(ctx,
			[]string{"A4", "Letter", "Legal", "Tabloid"},
			int(s.paper), on_paper),
		skald.spacer(th.spacing.lg),

		// Horizontal radio group uses Left/Right for nav.
		section_heading("Theme", ctx),
		skald.spacer(th.spacing.xs),
		skald.radio_group(ctx,
			[]string{"Dark", "Light", "High-Contrast"},
			int(s.theme), on_theme, direction = .Row,
			spacing = th.spacing.lg),
		skald.spacer(th.spacing.lg),

		// Toggles — same bool state as checkbox but drawn as a pill
		// switch. Real apps pick the affordance by semantics: toggle
		// when the change applies immediately, checkbox when it's
		// staged for OK/Apply. `read_only` flips every input in this
		// section into a muted, non-interactive state — the "Lock
		// preferences" toggle below drives it.
		section_heading("Connectivity", ctx),
		skald.spacer(th.spacing.xs),
		skald.toggle(ctx, s.wifi,      "Wi-Fi",         on_wifi,      read_only = s.locked),
		skald.spacer(th.spacing.xs),
		skald.toggle(ctx, s.bluetooth, "Bluetooth",     on_bluetooth, read_only = s.locked),
		skald.spacer(th.spacing.xs),
		skald.toggle(ctx, s.airplane,  "Airplane mode", on_airplane,  read_only = s.locked),
		skald.spacer(th.spacing.lg),

		// Multiline text field. Enter inserts a newline; Up/Down walk
		// between lines preserving visual column. `locked` flips it
		// read-only so the same widget serves the editable *and* the
		// review-only side of the same settings screen.
		section_heading("Notes", ctx),
		skald.spacer(th.spacing.xs),
		skald.text_input(ctx, s.notes, on_notes,
			placeholder = "Anything to tell the operator?",
			width       = 440,
			multiline   = true,
			wrap        = true,
			read_only   = s.locked),
		skald.spacer(th.spacing.lg),

		skald.toggle(ctx, s.locked, "Lock preferences (read-only)", on_lock),

		padding     = th.spacing.xl,
		spacing     = 0,
		cross_align = .Start,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Forms",
		size   = {520, 1040},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
