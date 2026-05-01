package skald

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// Public widget builder API conventions — locked in for 1.0 semver:
//
//   Parameter order:
//     1. `ctx: ^Ctx($Msg)`                — always first on stateful widgets.
//     2. state inputs (value, checked,
//        selected, on, options, rows, …)   — the thing the widget displays.
//     3. `on_<event>` callback(s)         — user-triggered event handlers.
//     4. `id: Widget_ID = 0`              — identity override; 0 = positional.
//     5. feature/behavior params          — step, min_value, disabled, etc.
//     6. sizing + style params            — width, padding, font_size, colors.
//
//   Naming:
//     - `value` for the primary state (text, number, time, date, color).
//       Domain exceptions: `checked` (checkbox), `selected` (radio),
//       `on` (toggle), `open` (dialog/collapsible).
//     - `on_change(new_value)` for widgets that emit a new value; the
//       callback is a `proc(...) -> Msg`. Exceptions: `on_click: Msg` /
//       `on_select: proc() -> Msg` for fire-and-forget events where the
//       widget has no payload to report.
//     - `disabled: bool` (not `disabled`). Read-only widgets still render
//       and may still be focused; the difference is that inputs are
//       ignored. No separate `disabled` flag — use the app's own
//       conditional-render if a field shouldn't appear at all.
//     - Range bounds: `min_value`/`max_value` (matches number_input and
//       slider). HTML-style `min`/`max` was rejected to avoid shadowing
//       Odin's builtin identifiers inside the widget body.
//     - Sentinel `width = 0` (and `height = 0` where applicable) means
//       "fill the parent's cross-axis allocation." Same convention on
//       View_Rect, View_Image, containers, and every form control.
//     - Sentinel `font_size = 0` / `padding = 0` / bare `Color{}` means
//       "inherit from theme." Widgets resolve these at build time against
//       `ctx.theme`.
//
//   Siblings vs flags:
//     - Prefer flags on the canonical widget over near-duplicates. e.g.
//       `text_input(multiline = true)` instead of a separate `text_area`;
//       `button(color = ...)` instead of `primary_button` / `danger_button`.
//     - Separate builders only when the model differs materially
//       (tree vs table vs virtual_list all have different state shapes).
//
// View is a declarative description of what to render this frame. It is a
// tagged union of concrete node types. An application's `view` proc returns
// a single View (usually a Stack at the root) built fresh every frame from
// the current state — the framework walks the tree, lays it out, and emits
// draw calls.
//
// The tree is cheap: all nodes are plain data, allocated from the frame
// arena (context.temp_allocator is rebound to a frame-scoped arena by
// `run`). There is no reconciliation yet — every frame rebuilds from
// scratch. Stable identity will arrive with stateful widgets in Phase 5.
View :: union {
	View_Rect,
	View_Gradient_Rect,
	View_Text,
	View_Stack,
	View_Wrap_Row,
	View_Clip,
	View_Spacer,
	View_Flex,
	View_Button,
	View_Text_Input,
	View_Checkbox,
	View_Radio,
	View_Toggle,
	View_Slider,
	View_Progress,
	View_Scroll,
	View_Overlay,
	View_Select,
	View_Tooltip,
	View_Zone,
	View_Dialog,
	View_Image,
	View_Split,
	View_Link,
	View_Toast,
	View_Deferred,
	View_Canvas,
	View_Spinner,
}

// Stack_Direction picks which axis a Stack lays its children along. Row
// flows left-to-right and treats width as the main axis; Column flows
// top-to-bottom and treats height as the main axis. The cross axis gets
// the perpendicular alignment rules from Cross_Align.
Stack_Direction :: enum {
	Row,
	Column,
}

// Main_Align distributes leftover main-axis space in a Stack that has no
// flex children. With flex children the remaining space is consumed by the
// flex distribution, so this enum has no visible effect.
Main_Align :: enum {
	Start,          // children packed at the start; leftover trails at the end
	Center,         // children packed in the middle
	End,            // children packed at the end
	Space_Between,  // first/last at the edges, remaining gaps equal
	Space_Around,   // equal space around each child (half at the ends)
}

// Cross_Align positions children on the Stack's cross axis. Stretch is the
// only variant that *changes* a child's size — it expands the child to the
// stack's inner cross extent, which is what enables, e.g., a sidebar column
// to match the height of its parent row.
Cross_Align :: enum {
	Start,
	Center,
	End,
	Stretch,
}

// View_Rect is a filled rounded rectangle with an explicit pixel size.
View_Rect :: struct {
	size:   [2]f32,
	color:  Color,
	radius: f32,
}

// View_Gradient_Rect is a rectangle whose four corners hold independent
// colors; the renderer's fragment interpolation produces a bilinear
// gradient across the rect. Used by the color picker for its SV square and
// hue strip. Zero on an axis fills the assigned size on that axis (same
// sentinel convention as View_Rect).
View_Gradient_Rect :: struct {
	size:                   [2]f32,
	c_tl, c_tr, c_br, c_bl: Color,
	radius:                 f32,
}

// View_Text is a run of text. Size is a cap-height-ish pixel size (same
// convention as `draw_text`). font=0 means the renderer's default font
// (Inter Variable).
//
// `max_width` turns word-wrapping on. When zero, the node is a single
// line sized to its content; when >0, the renderer breaks the string at
// word boundaries so no line exceeds that width, and `view_size` reports
// the wrapped height. Embedded `\n` also forces line breaks regardless.
View_Text :: struct {
	str:       string,
	color:     Color,
	size:      f32,
	font:      Font,
	max_width: f32,
}

// View_Stack lays children out in a row or column. Children contribute
// intrinsic sizes (text measurement, explicit rect size, or aggregated
// child sizes for nested stacks); `View_Flex` children claim a share of
// any remaining main-axis space according to their weight.
//
// `width` and `height` let a stack declare an explicit outer size — zero
// falls back to content-based intrinsic measurement. This is the
// equivalent of Flutter's SizedBox: when a container needs to be a fixed
// pixel width regardless of its children (a 220-px sidebar, a 56-px top
// bar), set it directly rather than padding the children.
//
// `bg` and `radius` render a filled rounded rect at the stack's assigned
// size behind the children. Leave `bg` at its zero value to skip the
// background entirely — the stack remains a pure layout container.
View_Stack :: struct {
	direction:   Stack_Direction,
	spacing:     f32,
	padding:     f32,
	width:       f32,
	height:      f32,
	main_align:  Main_Align,
	cross_align: Cross_Align,
	bg:          Color,
	radius:      f32,
	children:    []View,
}

// View_Wrap_Row flows children left-to-right and breaks to a new line
// when the next child wouldn't fit in the assigned width. Heights per
// line track the tallest child in the line; line_spacing inserts a fixed
// vertical gap between wrapped lines (independent of `spacing` on the
// main axis).
//
// Sizing: when `width > 0` the wrap_row computes its height by laying
// out children at that width. When `width == 0` it reports the natural
// single-line size from `view_size`. Inside a column with
// `cross_align = .Stretch` the parent's stack_render re-measures at
// the assigned cross extent, so wrap_row reserves the right vertical
// space without an explicit `width`.
View_Wrap_Row :: struct {
	spacing:      f32,
	line_spacing: f32,
	padding:      f32,
	width:        f32,
	bg:           Color,
	radius:       f32,
	children:     []View,
}

// View_Clip wraps a child in a pixel-bounded scissor rectangle. The child
// is rendered at the clip's origin; anything outside the clip is discarded.
View_Clip :: struct {
	size:  [2]f32,
	child: ^View,
}

// View_Spacer takes up `size` pixels in the parent stack's main axis (the
// cross axis contribution is zero). Useful for pushing subsequent children
// away from a preceding block.
View_Spacer :: struct {
	size: f32,
}

// View_Flex wraps a child to claim a proportional share of its parent
// stack's remaining main-axis space. Outside a Stack the wrapper is a
// no-op — the child simply renders at its intrinsic size.
//
// `min_main` is a floor on the assigned main-axis size. Without it a
// flex child can be squeezed below readability when the parent runs out
// of space (a `flex(1, text_input(...))` next to a fixed-width sidebar
// becomes a 4-px stub). Set `min_main` to the smallest size at which
// the child still works as a UI element; the parent still distributes
// remaining space proportionally, but no flex child shrinks below its
// floor. When the totalled floors exceed the parent's main extent the
// flex children overflow at their floors rather than collapsing.
View_Flex :: struct {
	weight:   f32,
	min_main: f32,
	child:    ^View,
}

// View_Text_Input is a single-line editable text field. The builder
// (`text_input`) does the editing work: it consumes keyboard events from
// the current frame, computes the new string value, and enqueues an
// on-change Msg. What the renderer sees is the post-edit string plus the
// cursor byte-index into it.
//
// `focused` decides whether to draw a caret and the focused border tint.
// `cursor_pos` is a byte index (not a rune index) so we don't need a UTF-8
// walk just to position the caret — the builder guarantees it always
// lands on a rune boundary.
View_Text_Input :: struct {
	id:                Widget_ID,
	text:              string,
	placeholder:       string,
	color_bg:          Color,
	color_fg:          Color,
	color_placeholder: Color,
	// color_border is the focused / invalid accent — typically the theme
	// primary. Drawn as a 1-px inline frame when `focused` or `invalid`.
	color_border:      Color,
	// color_border_idle is the resting 1-px hairline drawn when the field
	// is NOT focused and NOT invalid. Makes the input visible against a
	// low-contrast page background (light theme's surface is close to bg).
	color_border_idle: Color,
	color_caret:       Color,
	color_selection:   Color,
	color_track:       Color, // multiline scrollbar track
	color_thumb:       Color, // multiline scrollbar thumb
	radius:            f32,
	padding:           [2]f32,
	font_size:         f32,
	width:             f32,
	height:            f32,
	focused:           bool,
	cursor_pos:        int,
	// selection_anchor pins the other end of an active selection. When
	// it equals `cursor_pos` there is no selection, so the renderer
	// skips the highlight rect and draws only the caret.
	selection_anchor:  int,
	// multiline switches the renderer to per-line layout (top-aligned,
	// one glyph run per \n-separated chunk) and tells the caret / selection
	// drawer to walk line-by-line.
	multiline:         bool,
	// scroll_y and content_h drive the multiline vertical scroll and its
	// on-right scrollbar thumb. 0 / 0 on single-line fields.
	scroll_y:          f32,
	content_h:         f32,
	// visual_lines is the pre-computed display-line table; one entry per
	// logical line when wrap is off, possibly more when wrap is on. Lives
	// in the frame arena (context.temp_allocator), so it's only valid for
	// the render pass immediately following the view build. Nil / empty on
	// single-line fields.
	visual_lines:      []Visual_Line,
	// invalid flips the field into error state: a persistent border in
	// `color_border` (which the builder has already set to the danger
	// accent) regardless of focus. The builder may also pair this with
	// an `error` helper line rendered below the input as a sibling view.
	invalid:           bool,
	// Scrollbar tint hints for the multiline reader — same model as
	// View_Scroll so both readers feel native together. `sb_hover` is
	// true when the cursor sits over the thumb rect; `sb_dragging` is
	// true while the thumb is grabbed. Ignored on single-line.
	sb_hover:          bool,
	sb_dragging:       bool,
	// Search-affordance: when `show_clear` is true the renderer reserves
	// a glyph-width column in the right padding and paints a `×` there,
	// brightened on hover. The hit-zone itself is consumed by the builder
	// before the renderer sees the frame, so the renderer only needs the
	// hover hint to drive the tint.
	show_clear:        bool,
	clear_hovered:     bool,
}

// View_Checkbox is a boolean toggle with an optional label. The builder
// emits an on_change Msg with the new state when clicked. The tick mark
// is drawn as a Unicode "✓" rendered in the font — no dedicated vector
// path, which keeps the renderer free of primitive-drawing cruft and
// makes the checkmark automatically theme-scale with `font_size`.
View_Checkbox :: struct {
	id:           Widget_ID,
	checked:      bool,
	label:        string,
	color_box:    Color, // unchecked body
	color_fill:   Color, // checked body
	color_check:  Color, // tick color
	color_border: Color,
	color_focus:  Color, // focus-ring color
	color_fg:     Color, // label color
	font_size:    f32,
	box_size:     f32,
	gap:          f32,   // space between box and label
	hover:        bool,
	pressed:      bool,
	focused:      bool,
}

// View_Radio is a mutually-exclusive-selection marker: a circular
// outline with a filled inner dot when selected. Geometry mirrors
// View_Checkbox so both controls line up visually in the same form
// — the only substantive difference at render time is the circular
// corner radius (box_size / 2) and the dot instead of a ✓ glyph.
View_Radio :: struct {
	id:           Widget_ID,
	selected:     bool,
	label:        string,
	color_bg:     Color, // outer disc bg
	color_dot:    Color, // inner filled dot when selected
	color_border: Color,
	color_focus:  Color,
	color_fg:     Color,
	font_size:    f32,
	box_size:     f32,
	gap:          f32,
	hover:        bool,
	pressed:      bool,
	focused:      bool,
}

// View_Toggle is an iOS-style pill switch: a rounded track with a
// circular knob pinned to one side. Functionally equivalent to a
// checkbox (same on/off Msg, same focus + keyboard behavior) — the
// visual is the only thing that differs, and it matters, because
// users read toggles as "applies immediately" and checkboxes as
// "applies when you press OK/Apply". Skald has no opinion on that
// distinction; it just offers both so apps can pick the affordance
// that matches their semantics.
View_Toggle :: struct {
	id:         Widget_ID,
	on:         bool,
	label:      string,
	color_off:  Color, // track bg when off
	color_on:   Color, // track bg when on
	color_knob: Color, // circular knob
	color_focus: Color,
	color_fg:   Color, // label color
	font_size:  f32,
	track_w:    f32,
	track_h:    f32,
	knob_pad:   f32,   // gap between knob edge and track edge
	gap:        f32,   // space between track and label
	hover:      bool,
	pressed:    bool,
	focused:    bool,
}

// View_Slider is a draggable continuous-value control. The thumb tracks
// the mouse while the user holds the left button, even outside the widget
// bounds — a click on the track jumps the thumb to that position as a
// one-shot. `value` is in [`min_value`, `max_value`]; `step` (>0) quantizes it.
View_Slider :: struct {
	id:          Widget_ID,
	value:       f32,
	min_value:   f32,
	max_value:   f32,
	color_track: Color, // unfilled portion + full track bed
	color_fill:  Color, // filled portion (value side)
	color_thumb: Color,
	color_focus: Color, // focus-ring color
	track_h:     f32,   // track thickness
	thumb_r:     f32,   // thumb radius
	width:       f32,
	height:      f32,
	dragging:    bool,
	focused:     bool,
}

// View_Scroll is a fixed-size viewport that displays a potentially
// taller child, with a vertical offset the user controls via the mouse
// wheel. Horizontal scrolling is deliberately omitted until a consuming
// widget needs it — vertical-only scroll is what 95% of desktop UIs
// actually do, and wiring both axes doubles the state surface.
//
// The child lays out at its intrinsic height against the viewport's
// width, so flex / cross-stretch rules behave the same as they would in
// a plain column. Content overflow is clipped by the renderer.
View_Scroll :: struct {
	id:       Widget_ID,
	size:     [2]f32,
	content:  ^View,
	offset_y: f32, // current (pre-clamp) scroll position; renderer clamps.
	wheel_step: f32,
	track_color: Color,
	thumb_color: Color,
	hover_thumb: bool, // cursor is over the thumb (pre-drag tint)
	dragging:    bool, // thumb is grabbed (active-state tint)
}

// Overlay_Placement controls where an overlay positions itself relative
// to its anchor rect. `Below` is the natural default for dropdown menus
// and autocomplete popups; `Above` is used as an automatic fallback when
// the overlay would overflow the bottom of the framebuffer.
Overlay_Placement :: enum {
	Below,
	Above,
}

// View_Overlay defers rendering of `child` to a post-pass so it draws
// on top of the rest of the frame. The renderer measures the child at
// its intrinsic size, then positions it at `anchor`'s edge according
// to `placement`, flipping `Below` → `Above` if the natural placement
// overflows the screen.
//
// The overlay itself contributes zero size to its parent stack — it
// floats — so dropping an overlay between two sibling views doesn't
// push them around. The intrinsic dimensions belong to the overlay
// content, not the layout node that hosts it.
//
// Widgets built inside an overlay participate in the shared Widget_Store
// exactly like any other widget. Their recorded last_rect is in
// framebuffer coordinates after the overlay's placement, so mouse
// hit-testing on the next frame works without special casing.
View_Overlay :: struct {
	anchor:    Rect,
	placement: Overlay_Placement,
	offset:    [2]f32, // nudge from the natural placement (e.g. {0, 4} for a 4-px gap)
	child:     ^View,
	// opacity fades the overlay subtree during open / close
	// transitions. 0 suppresses rendering entirely; 1 is fully visible.
	// Widget builders drive this from an animated `anim_t`; zero-value
	// = fully visible for backwards compatibility with existing call
	// sites that don't animate.
	opacity:   f32,
}

// View_Tooltip wraps a `child` view and conditionally queues a small
// popover near the child's rect when the user has hovered for long
// enough. Layout-wise it's a passthrough — the child owns the space,
// and the tooltip bubble is rendered via the Phase 8 overlay queue so
// it sits on top of everything without interfering with flex/stack
// math. `show` is resolved by the builder against the previous frame's
// `last_rect` + the hover start timestamp on Widget_State, so the
// renderer doesn't have to track time or hit-test.
View_Tooltip :: struct {
	id:        Widget_ID,
	child:     ^View,
	text:      string,
	show:      bool,
	color_bg:  Color,
	color_fg:  Color,
	radius:    f32,
	padding:   [2]f32,
	font_size: f32,
}

// View_Zone is a pure passthrough that records its child's rect into a
// Widget_State. Builders use it to hit-test against areas that aren't
// themselves widgets — a column that should open a context menu on
// right-click, or the body of a popover that needs to detect
// outside-clicks for dismissal.
View_Zone :: struct {
	id:    Widget_ID,
	child: ^View,
}

// View_Dialog is a modal popover: a full-frame scrim plus a centered
// card wrapping `child`. Like View_Overlay it contributes zero size to
// its parent stack (it floats), but unlike View_Overlay it spans the
// entire framebuffer and intercepts input against everything behind it.
// When `open` is false the renderer skips it entirely — and the builder
// returns a zero-size passthrough so the dialog lives inline in the view
// tree without pushing siblings around.
//
// The card's rect is stamped onto Widget_Store.modal_rect by the
// renderer so the *next* frame's run-loop preprocessor can filter Tab
// traversal to focusables inside the card (focus trap) and consume
// backdrop clicks (outside-click dismiss without cascading to widgets
// underneath the scrim).
View_Dialog :: struct {
	id:           Widget_ID,
	open:         bool,
	child:        ^View,
	color_scrim:  Color,
	color_bg:     Color,
	color_border: Color,
	radius:       f32,
	padding:      f32, // uniform inner padding around `child`
	max_width:    f32, // cap on intrinsic width; 0 = no cap
	width:        f32, // forced width; 0 = intrinsic
}

// Image_Fit controls how an image's native aspect ratio is reconciled
// with the layout slot it's given. See `image` for the builder contract.
Image_Fit :: enum {
	Fill,    // stretch to fill, aspect ignored (fastest path)
	Contain, // scale to fit *inside* the slot, letterbox gaps
	Cover,   // scale to *fill* the slot, crop overflow via UV trim
	None,    // native size, centered in the slot (common for icons)
}

// View_Image is a textured quad backed by an on-disk image. `path` is
// the cache key — the renderer decodes the file via stb_image on first
// encounter and reuses the GPU texture thereafter. `size` is the layout
// slot; the renderer uses `fit` + the texture's natural dimensions to
// compute the actual quad rect and UV window.
//
// `tint` modulates the sampled RGBA — pass `{1, 1, 1, 1}` (the default
// the builder supplies) for no tint. Handy for fade-in animations
// (scale the alpha) or theming monochrome assets.
View_Image :: struct {
	path:  string,
	size:  [2]f32,
	fit:   Image_Fit,
	tint:  Color,
}

// View_Split is a two-pane container with a draggable divider between
// the children. The app owns `first_size` (the main-axis extent of the
// first pane) and feeds it back each frame — dragging the divider
// emits `on_resize(new_first_size)` to be applied next frame, matching
// the event-only contract used by sliders and table resize handles.
//
// The divider is the only interactive surface; everything else is
// layout. Children can be any View (including another `split`, giving
// you nested IDE-style panes for free).
View_Split :: struct {
	id:                    Widget_ID,
	direction:             Stack_Direction, // .Row = side-by-side panes, vertical divider; .Column = stacked, horizontal divider
	first:                 ^View,
	second:                ^View,
	first_size:            f32,
	divider_thickness:     f32,
	color_divider:         Color,
	color_divider_hover:   Color,
	color_divider_pressed: Color,
	hover:                 bool,
	pressed:               bool,
}

// Toast_Anchor places a transient notification at one of six screen
// corners / edges. Bottom_Center is the classic "snackbar" position,
// Top_Right is the notification-pane convention. Users with multiple
// concurrent toasts should drive a single anchor from app state to
// avoid visual collisions.
Toast_Anchor :: enum {
	Top_Left,
	Top_Center,
	Top_Right,
	Bottom_Left,
	Bottom_Center,
	Bottom_Right,
}

// Toast_Kind tags a toast with a semantic flavor; the builder uses it to
// pick an accent color and (optional) icon. Info is the neutral default.
Toast_Kind :: enum {
	Info,
	Success,
	Warning,
	Danger,
}

// View_Toast is a viewport-relative card — it ignores its parent's
// layout and positions itself against the framebuffer corners via the
// overlay queue, same mechanism the dialog scrim uses. The outer layout
// sees it as zero-size, so dropping a toast in a view doesn't shove
// adjacent widgets around.
//
// The card content is a pre-built `child` view the `toast` builder
// composes from standard widgets (row + rect + text + optional button).
// Keeping the positioning separate from the card lets apps swap in a
// custom card (say, a progress toast with a cancel button) by building
// their own child and wrapping it in a View_Toast directly.
View_Toast :: struct {
	visible: bool,
	child:   ^View,
	anchor:  Toast_Anchor,
	margin:  f32, // distance from the framebuffer edge(s)
}

// View_Deferred is a layout node whose content is built *after* its
// assigned rect is known. Intrinsically it reports `min` only; once a
// parent stack has given it a final size via flex / stretch, the layout
// walker invokes `trampoline(ctx, data, build_raw, assigned_size)` to
// materialise the actual subtree and recurses into it.
//
// This is the SwiftUI `GeometryReader` / Flutter `LayoutBuilder` pattern.
// It lets size-aware widgets (tables, virtualized lists, any "I need to
// know my viewport to decide what to render" widget) work with a simple
// `flex(1, sized(...))` wrapper, with no one-frame lag and no zero-size
// sentinel mixing with real zero values.
//
// `trampoline` is a per-monomorphization shim generated by the public
// `sized` builder that casts the three rawptrs back to their typed
// originals before calling the caller's builder. View itself has to
// stay non-polymorphic, so the Ctx(Msg) pointer and the user's typed
// state pointer and build proc all go through rawptr here.
View_Deferred :: struct {
	ctx:        rawptr,
	data:       rawptr,
	build_raw:  rawptr,
	trampoline: proc(ctx, data, build: rawptr, size: [2]f32) -> View,
	min:        [2]f32,
}

// View_Canvas is a framework escape hatch: the app claims a rectangular
// slot in the layout and, at render time, is handed a painter it can use
// to emit arbitrary primitives (rects, textured quads, triangle strips)
// via the public `draw_*` procs. Skald opens a clip to the canvas bounds
// before invoking the callback, so draws outside the rect are scissored
// away and won't bleed into neighbouring widgets.
//
// `size` is the declared outer size: zero on either axis means "fill the
// assigned extent" (same sentinel convention as `View_Rect`). `min` is
// the intrinsic contribution to a parent stack when the parent hasn't
// reserved explicit space — the layout will never give the canvas less
// than this on either axis, so a canvas inside a content-sized column
// still shows up instead of collapsing.
//
// `user` is an opaque pointer the builder stashes for the callback to
// cast back. `draw` runs inside the render pass, after all other layout
// has been resolved, with the final `bounds` in framebuffer pixels.
View_Canvas :: struct {
	id:     Widget_ID,
	user:   rawptr,
	draw:   proc(user: rawptr, painter: Canvas_Painter),
	size:   [2]f32,
	min:    [2]f32,
}

// Canvas_Painter is the handle `View_Canvas` draw callbacks receive.
// `r` is the live Renderer, suitable for any of the public `draw_*`
// procs (`draw_rect`, `draw_text`, `draw_triangle_strip`, etc.).
// `bounds` is the canvas's placement in framebuffer pixels, given so
// the callback can transform its own model-space coordinates into
// screen space (panning, zooming, centering — app-defined).
Canvas_Painter :: struct {
	r:      ^Renderer,
	bounds: Rect,
}

// View_Link is a text-styled clickable — no background, no border, just
// a label that changes color on hover/focus and (optionally) carries an
// underline. It's the hyperlink analogue: for inline "learn more",
// "cancel" stand-ins, and any navigational affordance where a full
// button would be too heavy.
//
// State flags (hover/focused) are resolved by the builder from the
// previous frame's rect + the current input snapshot, same pattern as
// View_Button. The renderer records this frame's rect so next frame's
// hit-test has something to measure against.
View_Link :: struct {
	id:          Widget_ID,
	label:       string,
	color:       Color,
	color_hover: Color,
	color_focus: Color,
	font_size:   f32,
	underline:   bool,
	hover:       bool,
	focused:     bool,
}

// View_Select is the trigger node for a dropdown — a button-shaped
// widget that shows the current value (or a placeholder) and a caret
// glyph on the right edge. The actual option list is an `overlay` the
// builder attaches when the select is open; the trigger and overlay
// are separate views so the trigger can record its own rect for hit-
// testing and screen-placement.
View_Select :: struct {
	id:                Widget_ID,
	value:             string,
	placeholder:       string,
	color_bg:          Color,
	color_fg:          Color,
	color_placeholder: Color,
	color_border:      Color,
	color_focus:       Color,
	color_caret:       Color,
	radius:            f32,
	padding:           [2]f32,
	font_size:         f32,
	width:             f32,
	open:              bool,
	hover:             bool,
	focused:           bool,
}

// View_Progress is a non-interactive fill indicator. `value` is in
// [0, 1]; values outside that range are clamped by the renderer. No
// widget state and no Widget_ID — it's a pure display node.
//
// Indeterminate mode: when `chip > 0` the renderer ignores the normal
// 0..value fill and instead draws a moving chip of fractional width
// `chip`, left edge at `chip_pos`, clipped to the bar. The builder
// computes `chip_pos` from wall-clock time, so the animation advances
// with the frame loop.
View_Progress :: struct {
	value:      f32,
	color_bg:   Color,
	color_fill: Color,
	radius:     f32,
	width:      f32,
	height:     f32,
	chip:       f32,
	chip_pos:   f32,
}

// View_Spinner is the circular indeterminate progress affordance. Eight
// dots arranged in a ring with an alpha falloff rotating around them at
// `phase` ∈ [0, 1). The builder re-computes phase from wall-clock each
// frame and calls `widget_request_frame_at` so lazy redraw keeps
// driving the animation.
View_Spinner :: struct {
	size:  f32,
	color: Color,
	phase: f32,
}

// View_Button is an interactive clickable widget. The builder computes
// its visual state (hover/pressed) from the previous frame's rect + the
// current input snapshot and stashes those flags here so the renderer
// can pick the right background tint without re-doing hit testing.
//
// `width == 0` means content-sized (label + horizontal padding). Height
// is always content-sized — overriding it caused weird off-center text
// in the early prototype, so it's not exposed.
View_Button :: struct {
	id:          Widget_ID,
	label:       string,
	color:       Color,
	fg:          Color,
	color_focus: Color, // focus-ring color
	radius:      f32,
	padding:     [2]f32, // x = horizontal, y = vertical
	font_size:   f32,
	width:       f32,
	text_align:  Cross_Align, // .Start | .Center | .End — horizontal text placement inside the button rect
	hover:       bool,
	pressed:     bool,
	focused:     bool,
}

// ---- builders ----

// rect returns a View_Rect wrapped as a View. `radius` defaults to 0 (sharp
// corners); the renderer anti-aliases the outer edge either way.
rect :: proc(size: [2]f32, color: Color, radius: f32 = 0) -> View {
	return View_Rect{size = size, color = color, radius = radius}
}

// text returns a View_Text. Default behavior is single-line; pass
// `max_width > 0` to enable word-wrap at that pixel width (the node's
// measured height grows to fit the wrapped content).
text :: proc(
	str:       string,
	color:     Color,
	size:      f32  = 14,
	font:      Font = 0,
	max_width: f32  = 0,
) -> View {
	return View_Text{
		str       = str,
		color     = color,
		size      = size,
		font      = font,
		max_width = max_width,
	}
}

// col stacks children vertically. All layout knobs are named arguments so
// the common case stays terse:
//
//     skald.col(header, body, footer)
//     skald.col(a, b, c, spacing = 8, padding = 16, cross_align = .Stretch)
//     skald.col(content, width = 220, bg = th.color.elevated)
col :: proc(
	children:    ..View,
	spacing:     f32 = 0,
	padding:     f32 = 0,
	width:       f32 = 0,
	height:      f32 = 0,
	main_align:  Main_Align  = .Start,
	cross_align: Cross_Align = .Start,
	bg:          Color       = {},
	radius:      f32         = 0,
) -> View {
	slice := make([]View, len(children), context.temp_allocator)
	copy(slice, children)
	return View_Stack{
		direction   = .Column,
		spacing     = spacing,
		padding     = padding,
		width       = width,
		height      = height,
		main_align  = main_align,
		cross_align = cross_align,
		bg          = bg,
		radius      = radius,
		children    = slice,
	}
}

// row stacks children horizontally. Same semantics as `col` with the axes
// swapped.
row :: proc(
	children:    ..View,
	spacing:     f32 = 0,
	padding:     f32 = 0,
	width:       f32 = 0,
	height:      f32 = 0,
	main_align:  Main_Align  = .Start,
	cross_align: Cross_Align = .Start,
	bg:          Color       = {},
	radius:      f32         = 0,
) -> View {
	slice := make([]View, len(children), context.temp_allocator)
	copy(slice, children)
	return View_Stack{
		direction   = .Row,
		spacing     = spacing,
		padding     = padding,
		width       = width,
		height      = height,
		main_align  = main_align,
		cross_align = cross_align,
		bg          = bg,
		radius      = radius,
		children    = slice,
	}
}

// wrap_row stacks children left-to-right and breaks to a new line when
// the next child wouldn't fit the assigned width. Useful for tag/chip
// strips, toolbars, filter pills, anything whose item count varies.
//
// `spacing` is the gap between children on the same line; `line_spacing`
// is the gap between wrapped lines. Per-line height tracks the tallest
// child in that line. The widget reports a single-line natural width
// from `view_size` when no `width` is set; inside a column with
// `cross_align = .Stretch`, the parent column re-measures at its inner
// cross extent so vertical reservation is correct without a manual
// `width`.
wrap_row :: proc(
	children:     ..View,
	spacing:      f32   = 0,
	line_spacing: f32   = 0,
	padding:      f32   = 0,
	width:        f32   = 0,
	bg:           Color = {},
	radius:       f32   = 0,
) -> View {
	slice := make([]View, len(children), context.temp_allocator)
	copy(slice, children)
	return View_Wrap_Row{
		spacing      = spacing,
		line_spacing = line_spacing,
		padding      = padding,
		width        = width,
		bg           = bg,
		radius       = radius,
		children     = slice,
	}
}

// grid arranges `children` into a 2-D table of aligned columns. Column
// widths are driven by `columns`: a positive value is a fixed-pixel
// column, a zero is a flex column that splits the remaining space with
// any other flex columns. Children fill the grid row-major — child 0 is
// at column 0 of row 0, child `len(columns)` is at column 0 of row 1,
// and so on. Partial final rows pad with empty spacers so the last row
// stays aligned.
//
//     skald.grid(ctx,
//         columns = {120, 0, 80},   // label col 120 px, content flex, action 80 px
//         row1_label, row1_content, row1_action,
//         row2_label, row2_content, row2_action,
//         spacing_x = 8,
//         spacing_y = 4,
//     )
//
// Sizing: pass a concrete `width` for a fixed grid; leave it at 0 to
// fill the parent's cross axis (must be inside a stretching container,
// same contract as `scroll` / `virtual_list`). Height always fits the
// content — explicit `height` is ignored for v1 and reserved.
grid :: proc(
	ctx:       ^Ctx($Msg),
	columns:   []f32,
	children:  ..View,
	spacing_x: f32 = 0,
	spacing_y: f32 = 0,
	padding:   f32 = 0,
	width:     f32 = 0,
	bg:        Color = {},
	radius:    f32 = 0,
) -> View {
	if len(columns) == 0 { return View_Spacer{size = 0} }

	// Fill path: defer through sized so we know the assigned width this
	// frame. Matches the virtual_list / scroll convention.
	if width <= 0 {
		P :: Grid_Params(Msg)
		p := new(P, context.temp_allocator)
		kids := make([]View, len(children), context.temp_allocator)
		copy(kids, children)
		cols_copy := make([]f32, len(columns), context.temp_allocator)
		copy(cols_copy, columns)
		p^ = P{
			columns   = cols_copy,
			children  = kids,
			spacing_x = spacing_x,
			spacing_y = spacing_y,
			padding   = padding,
			bg        = bg,
			radius    = radius,
		}
		fill_builder :: proc(ctx: ^Ctx(Msg), data: ^P, size: [2]f32) -> View {
			// Tight-window guard — see scroll()'s identical comment.
			// A zero assigned width re-enters fill mode and stack-
			// overflows, so render an empty placeholder instead.
			if size.x <= 0 { return View_Spacer{size = 0} }
			return grid(
				ctx,
				data.columns,
				..data.children,
				spacing_x = data.spacing_x,
				spacing_y = data.spacing_y,
				padding   = data.padding,
				width     = size.x,
				bg        = data.bg,
				radius    = data.radius,
			)
		}
		return sized(ctx, p, fill_builder, min_w = 0, min_h = 0)
	}

	num_cols := len(columns)
	num_rows := (len(children) + num_cols - 1) / num_cols

	// Resolve column widths. Fixed columns keep their declared pixels;
	// flex columns split the remainder equally. A grid with no flex
	// columns may be narrower than `width` — that's fine, extra space
	// stays blank on the right.
	fixed_sum: f32 = 0
	flex_count := 0
	for w in columns {
		if w > 0 { fixed_sum += w } else { flex_count += 1 }
	}
	gaps_sum := f32(max(0, num_cols - 1)) * spacing_x
	avail    := width - 2 * padding - fixed_sum - gaps_sum
	if avail < 0 { avail = 0 }
	flex_w: f32 = 0
	if flex_count > 0 { flex_w = avail / f32(flex_count) }

	resolved_widths := make([]f32, num_cols, context.temp_allocator)
	for w, i in columns {
		if w > 0 { resolved_widths[i] = w } else { resolved_widths[i] = flex_w }
	}

	rows := make([dynamic]View, 0, num_rows, context.temp_allocator)
	for r in 0 ..< num_rows {
		row_children := make([dynamic]View, 0, 2 * num_cols, context.temp_allocator)
		for c in 0 ..< num_cols {
			idx := r * num_cols + c
			cell: View
			if idx < len(children) {
				cell = children[idx]
			} else {
				cell = View_Spacer{size = 0}
			}
			cw := resolved_widths[c]
			// Wrap each cell in a col so we can pin the width — children
			// may be raw text / rects that don't own a width of their own.
			append(&row_children, col(
				cell,
				width       = cw,
				cross_align = .Stretch,
			))
			if c < num_cols - 1 { append(&row_children, View_Spacer{size = spacing_x}) }
		}
		row_view := row(..row_children[:], cross_align = .Start)
		append(&rows, row_view)
		if r < num_rows - 1 { append(&rows, View_Spacer{size = spacing_y}) }
	}

	return col(..rows[:],
		width       = width,
		padding     = padding,
		bg          = bg,
		radius      = radius,
		cross_align = .Start,
	)
}

// Grid_Params carries grid's variadic state across the sized() boundary
// when the caller leaves width at 0 (fill-parent). Public name kept off
// the API surface — callers never construct this directly.
@(private)
Grid_Params :: struct($Msg: typeid) {
	columns:   []f32,
	children:  []View,
	spacing_x: f32,
	spacing_y: f32,
	padding:   f32,
	bg:        Color,
	radius:    f32,
}

// spacer inserts a fixed gap in the parent stack's main axis.
spacer :: proc(size: f32) -> View {
	return View_Spacer{size = size}
}

// divider draws a 1-px hairline in `th.color.border` that stretches
// along the parent stack's cross axis. `vertical = false` (the default)
// is for use inside a Column — the line runs horizontally, filling the
// column's width. Pass `vertical = true` inside a Row to get a vertical
// separator that fills the row's height.
//
//   skald.col(
//       header,
//       skald.divider(ctx),
//       body,
//   )
//
// Override `color` or `thickness` for a bolder rule; the default pulls
// from the theme so dark/light mode swap it automatically.
divider :: proc(
	ctx:       ^Ctx($Msg),
	vertical:  bool  = false,
	color:     Color = {},
	thickness: f32   = 1,
) -> View {
	col := color
	if col.a == 0 { col = ctx.theme.color.border }
	// Zero on one axis means "fill the parent's cross axis" — the same
	// sentinel `rect` uses. So a horizontal divider is `{0, thickness}`
	// (fill width, fixed height) and a vertical divider is
	// `{thickness, 0}` (fixed width, fill height).
	if vertical {
		return View_Rect{size = {thickness, 0}, color = col}
	}
	return View_Rect{size = {0, thickness}, color = col}
}

// Badge_Tone is the semantic color ramp a badge pulls from the active
// theme. Primary uses the brand accent; Neutral is a muted chip for
// counts and labels; Success/Warning/Danger map to the standard status
// colors shared with toasts and dialogs.
Badge_Tone :: enum u8 {
	Primary,
	Neutral,
	Success,
	Warning,
	Danger,
}

// badge builds a small rounded pill for counts (unread, notifications),
// status tags ("New", "Beta"), and the like. Purely visual — no hit
// testing, no widget state. `tone` selects the color pair from the theme;
// passing `bg` or `fg` overrides the tone-derived values when you need a
// shade the palette doesn't offer.
//
// The capsule is content-sized: the builder measures `label` at `font_size`
// through the renderer and wraps it in a centered stack with a pill radius,
// so two badges of different text lengths line up cleanly in a row. Font
// size defaults to `size_xs` — on the built-in themes that renders ~11 px,
// which keeps a badge visually subordinate to adjacent body text.
badge :: proc(
	ctx:       ^Ctx($Msg),
	label:     string,
	tone:      Badge_Tone = .Primary,
	bg:        Color      = {},
	fg:        Color      = {},
	font_size: f32        = 0,
) -> View {
	th := ctx.theme
	fs := font_size; if fs == 0 { fs = th.font.size_xs }

	bgc, fgc: Color
	switch tone {
	case .Primary: bgc, fgc = th.color.primary,  th.color.on_primary
	case .Neutral:
		// Subtly tinted grey: mix fg toward surface so the badge
		// always has a visible fill even in the light theme where
		// `elevated == surface == white`. `fg` text reads on it
		// without a saturated accent.
		bgc = color_mix(th.color.fg, th.color.surface, 0.88)
		fgc = th.color.fg
	case .Success: bgc, fgc = th.color.success,  th.color.on_primary
	case .Warning: bgc, fgc = th.color.warning,  th.color.on_primary
	case .Danger:  bgc, fgc = th.color.danger,   th.color.on_primary
	}
	if bg[3] != 0 { bgc = bg }
	if fg[3] != 0 { fgc = fg }

	h_pad := th.spacing.sm
	v_pad := th.spacing.xs

	tw, lh: f32
	if ctx.renderer != nil {
		tw, lh = measure_text(ctx.renderer, label, fs)
	} else {
		// Unit-test fallback: coarse estimate based on font size. Keeps
		// the builder callable without a live GPU context.
		tw = f32(len(label)) * fs * 0.55
		lh = fs * 1.2
	}

	width  := tw + 2 * h_pad
	height := lh + 2 * v_pad

	children := make([]View, 1, context.temp_allocator)
	children[0] = View_Text{str = label, color = fgc, size = fs}
	return View_Stack{
		direction   = .Row,
		width       = width,
		height      = height,
		bg          = bgc,
		radius      = height / 2,
		main_align  = .Center,
		cross_align = .Center,
		children    = children,
	}
}

// chip builds a dismissable badge — same visual shape as `badge` but
// with a small close glyph after the label that fires `on_close(label)`
// when clicked. The shape for email recipient lists ("jane@acme.com ✕"),
// active filters, and tag inputs.
//
// The label itself is passed straight through to `on_close` so the app
// can identify which chip fired without a surrounding id. For chips that
// carry richer payloads (e.g. a row in a filter set), build the
// identifying string into `label` or sidestep via a second on_close
// that closes over an index.
chip :: proc(
	ctx:       ^Ctx($Msg),
	label:     string,
	on_close:  proc(label: string) -> Msg,
	id:        Widget_ID  = 0,
	tone:      Badge_Tone = .Neutral,
	font_size: f32        = 0,
) -> View {
	th := ctx.theme
	fs := font_size; if fs == 0 { fs = th.font.size_xs }

	bgc, fgc: Color
	switch tone {
	case .Primary: bgc, fgc = th.color.primary,  th.color.on_primary
	case .Neutral:
		bgc = color_mix(th.color.fg, th.color.surface, 0.88)
		fgc = th.color.fg
	case .Success: bgc, fgc = th.color.success,  th.color.on_primary
	case .Warning: bgc, fgc = th.color.warning,  th.color.on_primary
	case .Danger:  bgc, fgc = th.color.danger,   th.color.on_primary
	}

	h_pad := th.spacing.sm
	v_pad := th.spacing.xs

	lw, lh: f32
	x_glyph :: "\u00D7"  // ×
	if ctx.renderer != nil {
		lw, lh = measure_text(ctx.renderer, label, fs)
	} else {
		lw = f32(len(label)) * fs * 0.55
		lh = fs * 1.2
	}

	// Close-glyph hit zone. Clicking anywhere on the × fires on_close;
	// body clicks are inert so tag rows stay clickable (or not) at the
	// caller's discretion — chips don't assume an open/activate gesture.
	//
	// The × glyph itself is tiny (xs font), so the zone wraps it in a
	// hit-target-sized container so users don't need pixel-accurate
	// aim. 18 px matches the Fitts-sized tap target we use elsewhere
	// for small affordances (hence wider than the glyph but no taller
	// than a chip row).
	close_id := widget_resolve_id(ctx, id)
	close_st := widget_get(ctx, close_id, .Click_Zone)
	close_hot := rect_contains_point(close_st.last_rect, ctx.input.mouse_pos)
	if ctx.input.mouse_released[.Left] && close_hot {
		send(ctx, on_close(label))
	}
	widget_set(ctx, close_id, close_st)

	x_color := fgc
	if close_hot { x_color = color_tint(fgc, 0.25) }

	CLOSE_TARGET :: f32(18)
	close_inner := make([]View, 1, context.temp_allocator)
	close_inner[0] = View_Text{str = x_glyph, color = x_color, size = fs}
	close_stack := View_Stack{
		direction   = .Row,
		width       = CLOSE_TARGET,
		height      = CLOSE_TARGET,
		main_align  = .Center,
		cross_align = .Center,
		children    = close_inner,
	}
	c := new(View, context.temp_allocator)
	c^ = close_stack
	close_zone := View_Zone{id = close_id, child = c}

	gap := f32(2)
	width  := lw + gap + CLOSE_TARGET + 2 * h_pad
	height := max(CLOSE_TARGET, lh) + 2 * v_pad

	children := make([]View, 5, context.temp_allocator)
	children[0] = View_Spacer{size = h_pad - v_pad}
	children[1] = View_Text{str = label, color = fgc, size = fs}
	children[2] = View_Spacer{size = gap}
	children[3] = close_zone
	children[4] = View_Spacer{size = h_pad - v_pad}

	return View_Stack{
		direction   = .Row,
		width       = width,
		height      = height,
		bg          = bgc,
		radius      = height / 2,
		padding     = v_pad,
		main_align  = .Center,
		cross_align = .Center,
		children    = children,
	}
}

// avatar draws a circular user chip with centered initials. Use it in
// chat lists, user menus, member rosters. When `bg` is zero, the builder
// hashes `initials` into one of the theme's accent colors so every user
// gets a stable-but-varied bubble — two avatars with the same initials
// always look identical across frames, across launches. Explicit `bg`
// overrides the hash.
//
// Font size is 42% of the circle diameter — standard in native toolkits
// and preserves the two-letter baseline look at sizes from 20 px up.
avatar :: proc(
	ctx:      ^Ctx($Msg),
	initials: string,
	size:     f32   = 32,
	bg:       Color = {},
	fg:       Color = {},
) -> View {
	th := ctx.theme

	bgc := bg
	if bgc[3] == 0 {
		palette := [4]Color{
			th.color.primary,
			th.color.success,
			th.color.warning,
			th.color.danger,
		}
		// djb2 hash — tiny, fast, and gives good variety across short
		// strings. Modulo into the palette for a stable color per user.
		h: u32 = 5381
		for c in transmute([]u8)initials {
			h = ((h << 5) + h) ~ u32(c)
		}
		bgc = palette[h % u32(len(palette))]
	}
	fgc := fg; if fgc[3] == 0 { fgc = th.color.on_primary }

	fs := size * 0.42
	children := make([]View, 1, context.temp_allocator)
	children[0] = View_Text{str = initials, color = fgc, size = fs}
	return View_Stack{
		direction   = .Row,
		width       = size,
		height      = size,
		bg          = bgc,
		radius      = size / 2,
		main_align  = .Center,
		cross_align = .Center,
		children    = children,
	}
}

// rating renders an interactive row of stars (1..`max`). Clicking the
// i-th star sends `on_change(i + 1)`; clicking the currently-selected
// star again sends `on_change(0)` so the user can clear the rating.
// Pass `disabled = true` to render as a static badge with no hit-testing.
//
// Visuals use ★ / ☆ glyphs at the requested `size` — no iconography
// dependency. `color_on` defaults to theme.color.warning (gold-ish),
// `color_off` to theme.color.fg_muted. To swap the glyphs (e.g. hearts)
// pass `filled` and `empty` explicitly.
rating :: proc{rating_simple, rating_payload}

@(private)
_rating_impl :: proc(
	ctx:       ^Ctx($Msg),
	value:     int,
	id:        Widget_ID = 0,
	max_value: int   = 5,
	size:      f32   = 20,
	color_on:  Color = {},
	color_off: Color = {},
	filled:    string = "★",
	empty:     string = "☆",
	disabled: bool  = false,
) -> (view: View, new_value: int, changed: bool) {
	new_value = value
	th := ctx.theme
	max_value := max_value
	if max_value < 1 { max_value = 1 }

	on_c  := color_on;  if on_c[3]  == 0 { on_c  = th.color.warning }
	off_c := color_off; if off_c[3] == 0 { off_c = th.color.fg_muted }

	base := widget_resolve_id(ctx, id)

	// 24 px hit box per star at the default size of 20 — slightly
	// larger than the glyph so adjacent stars don't fight for clicks.
	slot := size + 4

	stars := make([dynamic]View, 0, max_value, context.temp_allocator)
	for i in 0..<max_value {
		glyph := filled if i < value else empty
		col   := on_c   if i < value else off_c

		inner := make([]View, 1, context.temp_allocator)
		inner[0] = View_Text{str = glyph, color = col, size = size}
		cell := View_Stack{
			direction   = .Row,
			width       = slot,
			height      = slot,
			main_align  = .Center,
			cross_align = .Center,
			children    = inner,
		}

		if disabled {
			append(&stars, cell)
			continue
		}

		// Per-slot id so hover rects track each star. Multiply the
		// Per-star sub-id via the framework helper — see
		// `widget_make_sub_id`. Plain XOR would alias stars across rows
		// when row scope keys differ only in the bits `i+1` flips
		// (4 rows × 5 stars = 20 ids collapsing to 8).
		slot_id := widget_make_sub_id(base, u64(i + 1))
		st := widget_get(ctx, slot_id, .Click_Zone)
		if ctx.input.mouse_pressed[.Left] &&
		   rect_hovered(ctx, st.last_rect) {
			// Clicking the currently-filled last star clears; any
			// other click sets to that slot (1-based).
			next := i + 1
			if i + 1 == value { next = 0 }
			new_value, changed = next, true
		}
		widget_set(ctx, slot_id, st)

		c := new(View, context.temp_allocator)
		c^ = cell
		append(&stars, View_Zone{id = slot_id, child = c})
	}

	view = View_Stack{
		direction   = .Row,
		width       = slot * f32(max_value),
		height      = slot,
		cross_align = .Center,
		children    = stars[:],
	}
	return
}

rating_simple :: proc(
	ctx:       ^Ctx($Msg),
	value:     int,
	on_change: proc(v: int) -> Msg,
	id:        Widget_ID = 0,
	max_value: int   = 5,
	size:      f32   = 20,
	color_on:  Color = {},
	color_off: Color = {},
	filled:    string = "★",
	empty:     string = "☆",
	disabled: bool  = false,
) -> View {
	view, new_value, changed := _rating_impl(
		ctx, value,
		id = id, max_value = max_value, size = size,
		color_on = color_on, color_off = color_off,
		filled = filled, empty = empty, disabled = disabled,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

rating_payload :: proc(
	ctx:       ^Ctx($Msg),
	value:     int,
	payload:   $Payload,
	on_change: proc(payload: Payload, v: int) -> Msg,
	id:        Widget_ID = 0,
	max_value: int   = 5,
	size:      f32   = 20,
	color_on:  Color = {},
	color_off: Color = {},
	filled:    string = "★",
	empty:     string = "☆",
	disabled: bool  = false,
) -> View {
	view, new_value, changed := _rating_impl(
		ctx, value,
		id = id, max_value = max_value, size = size,
		color_on = color_on, color_off = color_off,
		filled = filled, empty = empty, disabled = disabled,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// stepper renders a horizontal progress indicator for multi-step flows
// (wizards, checkouts, account setup). Every step is a numbered disc
// with a label beneath; steps are connected by a thin segment whose
// color reports whether the leg is done. `current` is the 0-based index
// of the step the user is on — past steps are filled primary, current
// is ringed primary, future steps are muted.
//
// Visual only: no hit-testing, no Msg. Apps drive state changes through
// their own Next/Back buttons and feed the updated `current` back in.
//
// Sizing: the connectors between discs are flex children, so they only
// fill when a parent stretches the stepper to a known width. Wrap it
// in a `col(..., width = W, cross_align = .Stretch)` (or any other
// container that hands it a horizontal extent) — otherwise the row
// collapses to content width and the discs clump on the left.
//
//     skald.col(
//         skald.stepper(ctx,
//             {"Details", "Address", "Payment", "Review"},
//             current = state.step),
//         width       = 480,
//         cross_align = .Stretch,
//     )
stepper :: proc(
	ctx:      ^Ctx($Msg),
	labels:   []string,
	current:  int,
	disc_size: f32 = 24,
) -> View {
	th := ctx.theme
	if len(labels) == 0 { return View_Spacer{size = 0} }

	// Structure: one row of cells (col(disc, label)) with connectors
	// flexed between them. Each connector sits at disc-center height
	// via a padded col, so the line lines up with disc rims even though
	// labels below push the cell height down. Building disc + label
	// as a single cell guarantees the label stays centered under its
	// disc — the bug with two independent rows was that the label row
	// divided space into N equal flex cells while the disc row placed
	// N discs at fixed offsets with connectors between, so the two
	// axes drifted apart on any non-trivial label width.
	row_kids := make([dynamic]View, 0, 2 * len(labels) - 1,
		context.temp_allocator)

	for lbl, i in labels {
		is_done    := i <  current
		is_current := i == current

		// Todo discs need a visible outline on cards whose bg *is*
		// `surface`. Current disc keeps plain surface because it's
		// already framed by the primary-colored ring below.
		todo_bg := track_color_for(th^)

		disc_bg: Color
		disc_fg: Color
		switch {
		case is_done:
			disc_bg = th.color.primary
			disc_fg = th.color.on_primary
		case is_current:
			disc_bg = th.color.surface
			disc_fg = th.color.primary
		case:
			disc_bg = todo_bg
			disc_fg = th.color.fg_muted
		}

		number := fmt.tprintf("%d", i + 1)
		disc_children := make([]View, 1, context.temp_allocator)
		disc_children[0] = View_Text{
			str = number, color = disc_fg, size = th.font.size_sm,
		}
		disc_inner := View_Stack{
			direction   = .Row,
			width       = disc_size - (is_current ? 2 : 0),
			height      = disc_size - (is_current ? 2 : 0),
			bg          = disc_bg,
			radius      = disc_size / 2,
			main_align  = .Center,
			cross_align = .Center,
			children    = disc_children,
		}

		disc: View
		if is_current {
			wrap_children := make([]View, 1, context.temp_allocator)
			wrap_children[0] = disc_inner
			disc = View_Stack{
				direction   = .Row,
				width       = disc_size,
				height      = disc_size,
				bg          = th.color.primary,
				radius      = disc_size / 2,
				main_align  = .Center,
				cross_align = .Center,
				children    = wrap_children,
			}
		} else {
			disc = disc_inner
		}

		lbl_color := th.color.fg_muted
		if is_current || is_done { lbl_color = th.color.fg }

		cell := col(
			disc,
			spacer(th.spacing.xs),
			View_Text{str = lbl, color = lbl_color, size = th.font.size_sm},
			cross_align = .Center,
		)
		append(&row_kids, cell)

		if i < len(labels) - 1 {
			conn_color := th.color.primary if i < current else th.color.border
			// Pin the connector to the disc's vertical center. The
			// enclosing col pads half the disc on top so the line
			// lands flush with the disc midline, regardless of how
			// tall the sibling cells become when a label wraps.
			append(&row_kids, flex(1, col(
				spacer(disc_size / 2 - 1),
				View_Rect{size = {0, 2}, color = conn_color},
				cross_align = .Stretch,
			)))
		}
	}

	return row(..row_kids[:], cross_align = .Start)
}

// empty_state builds a centered placeholder card for the "nothing here
// yet" case — empty lists, no search matches, first-run screens. A big
// title, a muted description, and an optional primary button the user
// can hit to fill the void (create item, change filter, open settings).
//
// The returned view fills its parent's cross-axis so the content reads
// as "the whole panel is empty," not a widget floating in a corner. Wrap
// in `flex(1, empty_state(...))` inside a col to make it claim the
// remaining vertical space.
//
// Pass an empty description to omit the subtitle. `action` is any View
// the caller wants to place beneath the copy — typically a button built
// by the caller so they can wire it to their own Msg. Omit (or pass a
// zero View_Spacer) to skip.
//
// This shape dodges the polymorphic-Msg default limitation: the builder
// never touches Msg itself, so callers can pass a button pre-bound to
// their message without us having to default a polymorphic Msg argument.
empty_state :: proc(
	ctx:         ^Ctx($Msg),
	title:       string,
	description: string = "",
	action:      View   = View_Spacer{size = 0},
) -> View {
	th := ctx.theme

	children := make([dynamic]View, 0, 5, context.temp_allocator)
	append(&children, View_Text{
		str = title, color = th.color.fg, size = th.font.size_lg,
	})
	if len(description) > 0 {
		append(&children, View_Spacer{size = th.spacing.sm})
		append(&children, View_Text{
			str = description, color = th.color.fg_muted, size = th.font.size_md,
		})
	}
	// Treat the default (zero-size spacer) as "no action". Any other
	// view — including an intentional sized spacer — renders normally.
	skip: bool
	if sp, ok := action.(View_Spacer); ok && sp.size == 0 { skip = true }
	if !skip {
		append(&children, View_Spacer{size = th.spacing.lg})
		append(&children, action)
	}

	return col(..children[:],
		padding     = th.spacing.xl,
		main_align  = .Center,
		cross_align = .Center,
	)
}

// breadcrumb builds a horizontal nav trail: every segment except the
// last is a clickable link, the last is a non-interactive label in the
// primary fg color that reads as "you are here". Separators between
// segments are drawn in `fg_muted`.
//
// `on_select(index)` fires with the 0-based index of the clicked
// segment. Apps typically truncate their location path to `path[:index+1]`
// in response. The last segment's index is never emitted — clicks on
// "you are here" are a no-op, matching native file-manager behavior.
//
//     skald.breadcrumb(ctx,
//         {"Home", "Projects", "Skald", "examples"},
//         on_nav)
breadcrumb :: proc(
	ctx:       ^Ctx($Msg),
	segments:  []string,
	on_select: proc(index: int) -> Msg,
	separator: string = "›",
	font_size: f32    = 0,
) -> View {
	th := ctx.theme
	fs := font_size; if fs == 0 { fs = th.font.size_md }

	if len(segments) == 0 {
		return View_Spacer{size = 0}
	}

	// Two children per segment (link + separator) minus the trailing
	// separator the last segment doesn't need.
	children := make([dynamic]View, 0, 2 * len(segments) - 1,
		context.temp_allocator)

	for seg, i in segments {
		if i == len(segments) - 1 {
			// Trailing segment: plain text, not a focusable link.
			append(&children, View_Text{
				str = seg, color = th.color.fg, size = fs,
			})
		} else {
			append(&children, link(ctx, seg, on_select(i),
				font_size = fs, underline = false))
			append(&children, View_Text{
				str   = fmt.tprintf(" %s ", separator),
				color = th.color.fg_muted,
				size  = fs,
			})
		}
	}

	return row(..children[:], cross_align = .Center)
}

// kbd renders a keyboard-shortcut hint in a slightly raised rounded rect,
// the way <kbd> does in web UIs. Useful in empty states ("Press Ctrl-R to
// refresh"), inline help, and tooltip bodies. Pure display — no focus,
// no Widget_State, same lifetime rules as `badge`.
//
// The bg is `elevated` with a hairline border in `border`, drawn as a
// two-layer outer/inner stack so the border reads as a 1-px rim rather
// than a solid fill at the seam.
kbd :: proc(
	ctx:       ^Ctx($Msg),
	label:     string,
	font_size: f32 = 0,
) -> View {
	th := ctx.theme
	fs := font_size; if fs == 0 { fs = th.font.size_xs }

	h_pad := th.spacing.sm
	v_pad := f32(2)  // tighter than badge — keeps the cap looking crisp

	tw, lh: f32
	if ctx.renderer != nil {
		tw, lh = measure_text(ctx.renderer, label, fs)
	} else {
		tw = f32(len(label)) * fs * 0.55
		lh = fs * 1.2
	}

	outer_w := tw + 2 * h_pad
	outer_h := lh + 2 * v_pad

	// Two-layer card trick: outer rect in border color, inner inset by 1 px
	// in the elevated fill. The result is a true hairline rim at any DPI.
	inner_children := make([]View, 1, context.temp_allocator)
	inner_children[0] = View_Text{str = label, color = th.color.fg_muted, size = fs}
	inner := View_Stack{
		direction   = .Row,
		width       = outer_w - 2,
		height      = outer_h - 2,
		bg          = th.color.elevated,
		radius      = th.radius.sm - 1 if th.radius.sm >= 1 else 0,
		main_align  = .Center,
		cross_align = .Center,
		children    = inner_children,
	}
	outer_children := make([]View, 1, context.temp_allocator)
	outer_children[0] = inner
	return View_Stack{
		direction   = .Row,
		width       = outer_w,
		height      = outer_h,
		bg          = th.color.border,
		radius      = th.radius.sm,
		main_align  = .Center,
		cross_align = .Center,
		children    = outer_children,
	}
}

// section_header renders a horizontal rule with a centered title —
// `─── Title ───`. Common in settings panels for grouping controls
// without the heavier `list_frame` card treatment. Meant to be used
// inside a parent that stretches the row (col with `cross_align =
// .Stretch`) — otherwise the flex dividers collapse and you get a bare
// label in the middle of an undersized row.
section_header :: proc(
	ctx:       ^Ctx($Msg),
	title:     string,
	color:     Color = {},
	font_size: f32   = 0,
) -> View {
	th := ctx.theme
	fs := font_size; if fs   == 0 { fs = th.font.size_sm  }
	tc := color;     if tc.a == 0 { tc = th.color.fg_muted }
	rule_color := th.color.border

	return row(
		flex(1, View_Rect{size = {0, 1}, color = rule_color}),
		spacer(th.spacing.md),
		View_Text{str = title, color = tc, size = fs},
		spacer(th.spacing.md),
		flex(1, View_Rect{size = {0, 1}, color = rule_color}),
		cross_align = .Center,
	)
}

// form_row pairs a left-hand label with a right-hand control, pinning the
// label into a fixed-width cell so stacking many rows keeps every control
// flush at the same x. Without the pin, a short label ("Mind") leaves its
// control closer to the left margin than a long label ("Spirit Ash Level")
// does — the drift is what turns a tidy settings panel into a ransom note.
//
// The control is whatever view you pass — a `text_input`, a `toggle`, a
// `row` of (value, input, Set-button) cells if you want a multi-column
// form. `cross_align = .Center` vertically centers the control against
// the label baseline so buttons and inputs stop floating above or below
// the text.
//
// Pick `label_width` once for the panel and pass it everywhere — that's
// the knob the "scale the whole form by one number" idiom pivots on. The
// default (140 px) is a reasonable starting point for short English labels.
form_row :: proc(
	ctx:         ^Ctx($Msg),
	label:       string,
	control:     View,
	label_width: f32   = 0,
	spacing:     f32   = 0,
	label_color: Color = {},
	label_size:  f32   = 0,
) -> View {
	th := ctx.theme
	lw := label_width; if lw == 0 { lw = 140 }
	sp := spacing;     if sp == 0 { sp = th.spacing.md }
	lc := label_color; if lc.a == 0 { lc = th.color.fg }
	ls := label_size;  if ls == 0 { ls = th.font.size_md }

	return row(
		col(text(label, lc, ls), width = lw),
		control,
		spacing     = sp,
		cross_align = .Center,
	)
}

// list_frame wraps a sequence of rows in a single surface card with a
// 1-px hairline border and hairline dividers between rows. The shape
// for an in-content list — search results, settings, files — where the
// whole group should read as one object rather than a stack of
// individually-boxed items.
//
// The frame owns the background and outline; the rows inside should
// leave their background transparent so dividers sit flush. A row is
// typically a `row(text(label), flex(1, spacer(0)), button(...))` with
// modest padding.
//
//     skald.flex(1, skald.list_frame(ctx,
//         item_row(ctx, "Boiled Crab"),
//         item_row(ctx, "Crab Eggs"),
//         item_row(ctx, "…"),
//     ))
//
// Put it inside a `flex` + `scroll` pair for a long list: the flex
// hands the list the remaining window height, and `scroll({0, 0}, …)`
// clips/scrolls the rows inside the frame.
//
// Defaults read from the theme. Pass `divided = false` for a list
// with hover-highlight separation only (no lines). `radius` and
// `padding` default to the theme's sm values; override for a borderless
// look (`radius = 0`, `bordered = false`).
list_frame :: proc(
	ctx:      ^Ctx($Msg),
	first:    View,
	rest:     ..View,
	bg:       Color = {},
	border:   Color = {},
	div_color:Color = {},
	padding:  f32   = -1,
	radius:   f32   = -1,
	width:    f32   = 0,
	bordered: bool  = true,
	divided:  bool  = true,
) -> View {
	th := ctx.theme

	bg_c   := bg;        if bg_c.a   == 0 { bg_c   = th.color.surface }
	brd_c  := border;    if brd_c.a  == 0 { brd_c  = th.color.border  }
	div_c  := div_color; if div_c.a  == 0 { div_c  = th.color.border  }
	pad    := padding;   if pad   < 0     { pad    = 0                }
	rad    := radius;    if rad   < 0     { rad    = th.radius.sm     }

	// Interleave dividers between rows. `divided = false` short-circuits
	// to rows-only so the col stays dense and dependencies on divider
	// thickness vanish.
	total := 1 + len(rest)
	children_count := total
	if divided && total > 1 { children_count = total * 2 - 1 }

	children := make([dynamic]View, 0, children_count, context.temp_allocator)
	append(&children, first)
	for v in rest {
		if divided {
			append(&children, View_Rect{size = {0, 1}, color = div_c})
		}
		append(&children, v)
	}

	BORDER_W :: f32(1)
	if !bordered {
		return col(..children[:],
			spacing     = 0,
			padding     = pad,
			width       = width,
			bg          = bg_c,
			radius      = rad,
			cross_align = .Stretch,
		)
	}

	// Two-layer card: outer border color + inner surface leaves a
	// 1-px hairline around the edge. Same pattern as `menu` and the
	// select popover.
	inner_w := width
	if inner_w > 0 { inner_w -= 2 * BORDER_W }
	inner := col(..children[:],
		spacing     = 0,
		padding     = pad,
		width       = inner_w,
		bg          = bg_c,
		radius      = rad,
		cross_align = .Stretch,
	)
	return col(
		inner,
		padding     = BORDER_W,
		width       = width,
		bg          = brd_c,
		radius      = rad,
		cross_align = .Stretch,
	)
}

// alert builds an inline notice — a surface-tinted card with a colored
// left stripe, a title, and an optional description. Stretches to fill
// the parent's cross axis, same as `list_frame`. Pure display; wire
// dismiss buttons yourself by wrapping in a `row`.
//
// Tones reuse `Badge_Tone` — `.Primary` is the informational default,
// `.Warning` / `.Danger` for escalations. The stripe is the only
// colored surface: the background stays neutral so body text reads
// without glare.
alert :: proc(
	ctx:         ^Ctx($Msg),
	title:       string,
	description: string     = "",
	tone:        Badge_Tone = .Primary,
) -> View {
	th := ctx.theme

	stripe: Color
	switch tone {
	case .Primary: stripe = th.color.primary
	case .Neutral: stripe = th.color.border
	case .Success: stripe = th.color.success
	case .Warning: stripe = th.color.warning
	case .Danger:  stripe = th.color.danger
	}

	// Soft-tinted backdrop: mix the accent toward `surface` so the
	// fill reads as a whisper of the tone rather than a flat surface.
	// Primer / Radix alerts do this — users read "warning" / "danger"
	// from the colour, not just the 3-px stripe. Neutral keeps the
	// plain surface because its "stripe" is just the border color.
	bg := th.color.surface
	if tone != .Neutral {
		bg = color_mix(stripe, th.color.surface, 0.88)
	}

	body_children := make([dynamic]View, 0, 2, context.temp_allocator)
	append(&body_children, View_Text{
		str = title, color = th.color.fg, size = th.font.size_md,
	})
	if len(description) > 0 {
		append(&body_children, View_Spacer{size = th.spacing.xs})
		append(&body_children, View_Text{
			str = description, color = th.color.fg_muted, size = th.font.size_sm,
		})
	}

	body := col(..body_children[:],
		padding     = th.spacing.md,
		cross_align = .Start,
	)

	return row(
		View_Rect{size = {3, 0}, color = stripe},
		flex(1, body),
		bg          = bg,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)
}

// collapsible builds a disclosure section: a clickable header with a
// rotating chevron and a title, and `content` that appears directly
// beneath when `open` is true. Event-only contract — the app owns the
// open/closed flag and feeds it back next frame. Click on the header,
// Space, or Enter while focused all fire `on_toggle(!open)`.
//
//     skald.collapsible(ctx,
//         title     = "Advanced",
//         open      = s.advanced_open,
//         on_toggle = proc(v: bool) -> Msg { return Advanced_Toggled(v) },
//         content   = advanced_form(ctx, s),
//     )
//
// No background / border by default — the widget composes cleanly
// inside a surface card (`list_frame`, panel col, etc.) without
// double-stacking chrome. Hover lightens the header fg to signal
// interactivity; focus adds a 2-px accent ring around the whole header.
collapsible :: proc(
	ctx:       ^Ctx($Msg),
	title:     string,
	open:      bool,
	on_toggle: proc(new_open: bool) -> Msg,
	content:   View,
	id:        Widget_ID = 0,
	padding:   f32       = -1,
	font_size: f32       = 0,
) -> View {
	th := ctx.theme

	pad := padding;   if pad < 0   { pad = th.spacing.sm    }
	fs  := font_size; if fs  == 0  { fs  = th.font.size_md  }

	id := widget_resolve_id(ctx, id)
	widget_make_focusable(ctx, id)
	st := widget_get(ctx, id, .Click_Zone)
	focused := widget_has_focus(ctx, id)
	hovered := rect_hovered(ctx, st.last_rect)

	toggled := false
	if ctx.input.mouse_pressed[.Left] && hovered {
		widget_focus(ctx, id)
		focused = true
		toggled = true
	}
	if focused {
		keys := ctx.input.keys_pressed
		if .Space in keys || .Enter in keys { toggled = true }
	}
	if toggled {
		send(ctx, on_toggle(!open))
	}

	widget_set(ctx, id, st)

	chevron := "\u25B6" // ▶ closed
	if open { chevron = "\u25BC" } // ▼ open

	// Zone wraps the header for hit-tracking — it has no visual of its
	// own, so hover/focus cues are painted via the header col's bg.
	// Selection tint is reused for the focus ring so the collapsible
	// matches the rest of the framework's focus language.
	header_row := row(
		text(chevron, th.color.fg_muted, fs),
		spacer(th.spacing.sm),
		text(title, th.color.fg, fs),
		flex(1, spacer(0)),
		cross_align = .Center,
	)

	header_bg: Color = {}
	switch {
	case focused: header_bg = th.color.selection
	case hovered: header_bg = track_color_for(th^)
	}
	header := col(
		header_row,
		padding     = pad,
		bg          = header_bg,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)

	c := new(View, context.temp_allocator)
	c^ = header
	zoned := View_Zone{id = id, child = c}

	if !open { return View(zoned) }

	return col(
		View(zoned),
		content,
		cross_align = .Stretch,
	)
}

// Accordion_Section is one panel in an `accordion`: a title and a body
// View. The body is shown only when the section's index is the
// currently-open one.
Accordion_Section :: struct {
	title:   string,
	content: View,
}

// accordion stacks a group of `collapsible`-like sections where AT MOST
// one is open at a time. Clicking a closed section's header opens it
// and closes whichever was previously open; clicking the currently-open
// one closes it (all closed).
//
// The app owns `open_index`: pass `-1` for "all closed," any valid
// index 0..len(sections)-1 for "that one is open." The widget emits
// `on_toggle(idx)` where `idx` is what the caller's update handler
// should assign to its state, so a plain store-what-I-give-you
// pattern works:
//
//     case Panel_Toggled:
//         out.panel_idx = int(v)
//
// Want multiple panels open at once? Use N standalone `collapsible`s
// in a `col`; that shape lets each panel own its own bool. Accordion
// is specifically the one-open-at-a-time contract.
accordion :: proc(
	ctx:        ^Ctx($Msg),
	sections:   []Accordion_Section,
	open_index: int,
	on_toggle:  proc(idx: int) -> Msg,
	id:         Widget_ID = 0,
	spacing:    f32       = 0,
	padding:    f32       = -1,
	font_size:  f32       = 0,
) -> View {
	th := ctx.theme
	pad := padding;   if pad < 0  { pad = th.spacing.sm   }
	fs  := font_size; if fs  == 0 { fs  = th.font.size_md }

	base_id := widget_resolve_id(ctx, id)

	rows := make([dynamic]View, 0, len(sections) * 2, context.temp_allocator)
	for sec, i in sections {
		is_open := i == open_index

		// Per-header zone id via the framework helper — see
		// `widget_make_sub_id`. Plain XOR aliases across rows when
		// scope keys differ only in low bits.
		zone_id := widget_make_sub_id(base_id, u64(i + 1))
		widget_make_focusable(ctx, zone_id)
		st := widget_get(ctx, zone_id, .Click_Zone)
		focused := widget_has_focus(ctx, zone_id)
		hovered := rect_hovered(ctx, st.last_rect)

		toggled := false
		if ctx.input.mouse_pressed[.Left] && hovered {
			widget_focus(ctx, zone_id)
			focused = true
			toggled = true
		}
		if focused {
			keys := ctx.input.keys_pressed
			if .Space in keys || .Enter in keys { toggled = true }
		}
		if toggled {
			// Re-click the open section to close the whole group; anything
			// else opens the clicked one. The caller stores whatever we
			// emit directly into its state.
			next_idx := -1 if is_open else i
			send(ctx, on_toggle(next_idx))
		}
		widget_set(ctx, zone_id, st)

		chevron := "▶"
		if is_open { chevron = "▼" }
		header_row := row(
			text(chevron, th.color.fg_muted, fs),
			spacer(th.spacing.sm),
			text(sec.title, th.color.fg, fs),
			flex(1, spacer(0)),
			cross_align = .Center,
		)
		header_bg: Color = {}
		switch {
		case focused: header_bg = th.color.selection
		case hovered: header_bg = track_color_for(th^)
		}
		header := col(
			header_row,
			padding     = pad,
			bg          = header_bg,
			radius      = th.radius.sm,
			cross_align = .Stretch,
		)
		zc := new(View, context.temp_allocator)
		zc^ = header
		append(&rows, View(View_Zone{id = zone_id, child = zc}))
		if is_open { append(&rows, sec.content) }
	}

	return col(..rows[:], spacing = spacing, cross_align = .Stretch)
}

// clip wraps `child` in a scissor rectangle of the given pixel size. Used
// to bound overflowing subtrees (e.g. a scroll container).
clip :: proc(size: [2]f32, child: View) -> View {
	c := new(View, context.temp_allocator)
	c^ = child
	return View_Clip{size = size, child = c}
}

// flex wraps `child` so it claims a `weight`-proportional share of its
// parent stack's remaining main-axis space. `weight = 1` is the usual
// default; `flex(2, ...)` takes twice the share of a sibling `flex(1, ...)`.
//
// `min_main` clamps the assigned main-axis size from below so the child
// can't be squeezed past usability when the parent runs short. Defaults
// to 0 (no floor — preserves v1 behaviour).
flex :: proc(weight: f32, child: View, min_main: f32 = 0) -> View {
	c := new(View, context.temp_allocator)
	c^ = child
	return View_Flex{weight = weight, min_main = min_main, child = c}
}

// sized defers `build` until the framework knows the rect this node was
// assigned, then calls `build(ctx, data, size)` inside the layout walk to
// materialise the real subtree. It's the framework primitive behind "I
// need to know my viewport to decide what to render" widgets — tables,
// virtualised lists, canvases that paint relative to their box.
//
// Typical use: wrap in a flex child of its parent stack, and (for the
// cross axis) make the parent stretch its children.
//
//     skald.col(
//         header,
//         skald.flex(1, skald.sized(ctx, &state, build_table)),
//         cross_align = .Stretch,
//     )
//
// `data` must be a pointer (`^State`). It's stored as a rawptr in the
// View and cast back before `build` runs, so ownership stays with the
// caller — don't pass a temp-allocated copy.
//
// `min_w` / `min_h` contribute to the node's intrinsic size so a parent
// Start-aligned stack still reserves at least that much room even if no
// flex is in play. They default to zero (pure "take what I'm given").
sized :: proc(
	ctx:   ^Ctx($Msg),
	data:  ^$T,
	build: proc(ctx: ^Ctx(Msg), data: ^T, size: [2]f32) -> View,
	min_w: f32 = 0,
	min_h: f32 = 0,
) -> View {
	// Per-monomorphization trampoline. The nested proc can reference the
	// enclosing polymorphic type parameters (Msg, T) because they're
	// specialised at compile time together — the trampoline ends up as a
	// concrete proc address per (Msg, T) pair, and we can store that
	// address in a non-polymorphic View node.
	tramp :: proc(ctx_raw, data_raw, build_raw: rawptr, size: [2]f32) -> View {
		b := transmute(proc(ctx: ^Ctx(Msg), data: ^T, size: [2]f32) -> View) build_raw
		return b(cast(^Ctx(Msg))ctx_raw, cast(^T)data_raw, size)
	}

	// Snapshot `data` into the frame arena. The user typically hands us
	// a pointer to a stack local inside `view`, which disappears the
	// moment `view` returns — but the trampoline runs later, during the
	// render pass. A fresh temp-arena copy survives until frame_end,
	// which matches render's lifetime exactly.
	snap := new(T, context.temp_allocator)
	snap^ = data^

	return View_Deferred{
		ctx        = rawptr(ctx),
		data       = rawptr(snap),
		build_raw  = rawptr(build),
		trampoline = tramp,
		min        = {min_w, min_h},
	}
}

// responsive picks between two sub-views based on the *assigned* width
// of its slot, deferred until layout knows the rect. Below `threshold`
// the `narrow` builder runs; at or above it the `wide` builder runs. A
// single 320 px sidebar embedded in a 1600 px window stays Compact —
// only the slot's width matters, not the window's.
//
// `data` is a pointer to caller state that both builders receive; copied
// by value into the frame arena so the deferred builder reads a stable
// snapshot regardless of when render walks it.
//
//     responsive(ctx, &state, threshold = 600,
//         narrow = build_stacked,   // single column
//         wide   = build_two_pane,  // sidebar + content
//     )
//
// Pair with `flex(1, responsive(...))` or a stretching column so the
// responsive node receives a useful assigned width — outside a flex
// it just gets its `min` (zero) and would always pick `narrow`. For
// app-level "is the window narrow" decisions, read `ctx.breakpoint`
// instead — that's the cheaper inline check.
responsive :: proc(
	ctx:       ^Ctx($Msg),
	data:      ^$T,
	threshold: f32,
	narrow:    proc(ctx: ^Ctx(Msg), data: ^T) -> View,
	wide:      proc(ctx: ^Ctx(Msg), data: ^T) -> View,
) -> View {
	// Bundle of the two builders + the threshold + a snapshot of the
	// caller's data, allocated from the frame arena. The View_Deferred
	// stores one rawptr "data" slot; we hide the whole pack behind it
	// so the trampoline can read both procs.
	Pack :: struct {
		narrow:    proc(ctx: ^Ctx(Msg), data: ^T) -> View,
		wide:      proc(ctx: ^Ctx(Msg), data: ^T) -> View,
		threshold: f32,
		data:      ^T,
	}

	snap := new(T, context.temp_allocator)
	snap^ = data^

	pack := new(Pack, context.temp_allocator)
	pack.narrow    = narrow
	pack.wide      = wide
	pack.threshold = threshold
	pack.data      = snap

	tramp :: proc(ctx_raw, data_raw, build_raw: rawptr, size: [2]f32) -> View {
		p := cast(^Pack)data_raw
		if size.x < p.threshold {
			return p.narrow(cast(^Ctx(Msg))ctx_raw, p.data)
		}
		return p.wide(cast(^Ctx(Msg))ctx_raw, p.data)
	}

	return View_Deferred{
		ctx        = rawptr(ctx),
		data       = rawptr(pack),
		build_raw  = nil,
		trampoline = tramp,
		min        = {0, 0},
	}
}

// canvas is the framework's escape hatch: a rectangular slot the app
// paints with arbitrary primitives via the public `draw_*` API. Use it
// when a widget set ("declarative tree of views") is the wrong shape
// for the problem — custom plots, drawing surfaces, game-style scenes,
// pixel art, node-graph editors. Everything else should reach for a
// higher-level widget first.
//
// `user` is an opaque pointer the builder stashes into the View node;
// the framework casts it back to a typed pointer for you inside `draw`
// via the trampoline. Typical usage is `canvas(ctx, &app_state, paint)`
// where `paint :: proc(s: ^App_State, p: skald.Canvas_Painter)`.
//
// Sizing follows the sentinel convention used everywhere else: `width`
// or `height = 0` means "fill the parent's assigned extent on that
// axis." Most apps flex-wrap the canvas (`flex(1, canvas(...))`) so it
// expands to fill the remaining main-axis space in its row or column.
// `min_w` / `min_h` are the intrinsic size contribution for parents
// that have nothing else to hand out — if omitted (zero) the canvas
// collapses to nothing in a Start-aligned stack with no flex children.
//
// Inside `draw`, Skald has already opened a clip to the canvas bounds,
// so primitives falling outside `painter.bounds` are scissored. The
// app pulls input via the normal `ctx.input` snapshot — pen / mouse
// coordinates are in the same logical-pixel space as `painter.bounds`,
// so canvas-local coords are just `pos - painter.bounds.xy`.
canvas :: proc(
	ctx:    ^Ctx($Msg),
	user:   ^$T,
	draw:   proc(user: ^T, painter: Canvas_Painter),
	id:     Widget_ID = 0,
	width:  f32 = 0,
	height: f32 = 0,
	min_w:  f32 = 0,
	min_h:  f32 = 0,
) -> View {
	rid := widget_resolve_id(ctx, id)
	// Stamp kind so next frame can retrieve last_rect via widget_last_rect.
	st := widget_get(ctx, rid, .Canvas)
	widget_set(ctx, rid, st)

	// Per-monomorphization pack: the non-polymorphic View node needs a
	// rawptr + rawptr-taking dispatcher, but the callback is typed
	// `proc(^T, Canvas_Painter)`. Pack `(user, cb)` into a temp-arena
	// record and cast back inside `dispatch`. Same trampoline idea as
	// `sized`, but here we need both the user pointer *and* the proc
	// pointer to survive across the erasure boundary.
	Pack :: struct {
		user: ^T,
		cb:   proc(user: ^T, painter: Canvas_Painter),
	}
	pack := new(Pack, context.temp_allocator)
	pack^ = Pack{user = user, cb = draw}

	dispatch :: proc(raw: rawptr, painter: Canvas_Painter) {
		p := cast(^Pack)raw
		if p == nil || p.cb == nil { return }
		p.cb(p.user, painter)
	}

	return View_Canvas{
		id   = rid,
		user = rawptr(pack),
		draw = dispatch,
		size = {width, height},
		min  = {min_w, min_h},
	}
}

// overlay wraps `child` in a floating popover anchored to `anchor`. The
// overlay renders in a post-pass after the main tree, so it reliably
// draws on top of everything else without needing depth buffering. The
// caller typically sources `anchor` from a widget's previous-frame
// `last_rect` (e.g. a dropdown anchoring under its trigger button).
//
// `placement = .Below` puts the overlay directly under the anchor; the
// renderer auto-flips to `.Above` if there's no room. `offset` is a
// pixel nudge applied after placement — handy for a small gap between
// the trigger and the popover.
overlay :: proc(
	anchor:    Rect,
	child:     View,
	placement: Overlay_Placement = .Below,
	offset:    [2]f32            = {0, 0},
	opacity:   f32               = 1,
) -> View {
	c := new(View, context.temp_allocator)
	c^ = child
	return View_Overlay{
		anchor    = anchor,
		placement = placement,
		offset    = offset,
		child     = c,
		opacity   = opacity,
	}
}

// overlay_placement_rect returns the on-screen rect an `overlay()` node
// will render to given an anchor rect and child size, *mirroring* the
// auto-flip logic in layout.odin's View_Overlay renderer. Popover
// builders use this to produce a mouse_over_overlay hit-test rect that
// stays aligned with the rendered overlay when the trigger sits near the
// bottom of the window and the overlay flips above. Needs a live
// renderer in `ctx` — returns the naive below-rect when ctx.renderer is
// nil (unit-test path).
overlay_placement_rect :: proc(
	ctx:        ^Ctx($Msg),
	anchor:     Rect,
	child_size: [2]f32,
	placement:  Overlay_Placement = .Below,
	offset:     [2]f32            = {0, 0},
) -> Rect {
	x := anchor.x + offset.x
	y: f32
	switch placement {
	case .Below:
		y = anchor.y + anchor.h + offset.y
		if ctx.renderer != nil {
			fb_h := f32(ctx.renderer.fb_size.y)
			if y + child_size.y > fb_h && anchor.y - child_size.y >= 0 {
				y = anchor.y - child_size.y - offset.y
			}
		}
	case .Above:
		y = anchor.y - child_size.y - offset.y
		if ctx.renderer != nil {
			if y < 0 && anchor.y + anchor.h + child_size.y <= f32(ctx.renderer.fb_size.y) {
				y = anchor.y + anchor.h + offset.y
			}
		}
	}
	if ctx.renderer != nil {
		fb_w := f32(ctx.renderer.fb_size.x)
		if x + child_size.x > fb_w { x = fb_w - child_size.x }
		if x < 0 { x = 0 }
	}
	return Rect{x, y, child_size.x, child_size.y}
}

// TOOLTIP_DELAY_MS is how long the pointer must rest over a tooltip
// host before the bubble appears. 500 ms is the classic Win32 / GTK
// default — long enough to avoid flashing tooltips during casual
// pointer movement, short enough that a user who parked the cursor
// on a control actually sees one.
TOOLTIP_DELAY_MS :: 500

// tooltip wraps `child` in a hover-triggered popover carrying `text`.
// Layout is a passthrough: the child takes the space it would have
// taken on its own; the bubble is rendered through the Phase 8 overlay
// queue so it floats on top without affecting the surrounding flex
// math. Hover duration is tracked via a Widget_ID so the tooltip shows
// only after `TOOLTIP_DELAY_MS` of sustained hover — classic desktop
// feel, nothing flashes as the pointer skims across a toolbar.
//
//     skald.tooltip(ctx,
//         skald.button(ctx, "Load", Msg.Load),
//         "Read the file at the path above",
//     )
//
// Builds using the previous frame's laid-out rect for hit-testing,
// same as every other stateful widget — one-frame lag is invisible
// under normal pointer speeds.
tooltip :: proc(
	ctx:   ^Ctx($Msg),
	child: View,
	text:  string,
	id:    Widget_ID = 0,
) -> View {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Tooltip)

	hovered := rect_hovered(ctx, st.last_rect)

	// Latch the hover-start timestamp on the rising edge; clear it on
	// exit so the delay restarts fresh on the next hover. Using the
	// wall clock means the delay survives frame-rate variation.
	now_ns := time.now()._nsec
	if hovered {
		if st.hover_start_ns == 0 { st.hover_start_ns = now_ns }
	} else {
		st.hover_start_ns = 0
	}
	widget_set(ctx, id, st)

	threshold_ns := i64(TOOLTIP_DELAY_MS) * 1_000_000
	show := hovered && st.hover_start_ns != 0 &&
		(now_ns - st.hover_start_ns) >= threshold_ns

	// Hovering but delay not yet elapsed — ask the run loop to wake at
	// the exact moment the tooltip becomes visible under lazy redraw.
	if hovered && !show {
		widget_request_frame_at(ctx, st.hover_start_ns + threshold_ns)
	}

	c := new(View, context.temp_allocator)
	c^ = child
	// Classic inverted-tooltip colors: fg ↔ bg swap so the bubble
	// always reads as a high-contrast dark chip in light mode and a
	// light chip in dark mode. Matches macOS / most desktop toolkits.
	return View_Tooltip{
		id        = id,
		child     = c,
		text      = text,
		show      = show,
		color_bg  = th.color.fg,
		color_fg  = th.color.bg,
		radius    = th.radius.sm,
		padding   = {th.spacing.sm, th.spacing.xs},
		font_size = th.font.size_sm,
	}
}

// button builds an interactive button. Clicking it enqueues `on_click`
// onto the current frame's message queue; the app's `update` sees the
// message on the following frame and advances state.
//
// All visual knobs fall back to theme tokens when left at their zero
// value, so the common case is a single line:
//
//     skald.button(ctx, "Save", Msg{kind = .Save_Clicked})
//
// Hit-testing uses the previous frame's laid-out rect — see the note on
// `Widget_State.last_rect` for why that's fine in practice.
button :: proc(
	ctx:        ^Ctx($Msg),
	label:      string,
	on_click:   Msg,
	id:         Widget_ID   = 0,
	color:      Color       = {},
	fg:         Color       = {},
	radius:     f32         = 0,
	padding:    [2]f32      = {0, 0},
	font_size:  f32         = 0,
	width:      f32         = 0,
	text_align: Cross_Align = .Center,
	disabled:   bool        = false,
) -> View {
	th := ctx.theme

	c   := color;     if c[3]  == 0 { c  = th.color.primary    }
	fc  := fg;        if fc[3] == 0 { fc = th.color.on_primary }
	rr  := radius;    if rr    == 0 { rr = th.radius.md         }
	fs  := font_size; if fs    == 0 { fs = th.font.size_md      }
	pad := padding
	if pad.x == 0 { pad.x = th.spacing.md }
	if pad.y == 0 { pad.y = th.spacing.sm }

	// Disabled buttons render muted, skip focus registration and click
	// handling entirely. The rect still lays out at the same size so form
	// toggling the flag doesn't reflow surrounding widgets. `track_color_for`
	// gives a subtle bg that's visible even when the button sits on a
	// surface-bg card (light theme case).
	if disabled {
		c  = track_color_for(th^)
		fc = th.color.fg_muted
	}

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Button)
	focused := !disabled && widget_has_focus(ctx, id)

	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	if !disabled {
		// Press/release state machine:
		//   1. Mouse-down *inside* the rect → latch `pressed`.
		//   2. Mouse-up while `pressed && hovered` → emit the click Msg.
		//   3. Any mouse-up, plus the "mouse wandered off while held" case,
		//      clear `pressed` so the button doesn't get stuck on subsequent
		//      frames.
		if ctx.input.mouse_pressed[.Left] && hovered {
			st.pressed = true
			widget_focus(ctx, id)
			focused = true
		}
		if ctx.input.mouse_released[.Left] {
			if st.pressed && hovered {
				send(ctx, on_click)
			}
			st.pressed = false
		}
		if !ctx.input.mouse_buttons[.Left] {
			st.pressed = false
		}

		// Keyboard activation: Space or Enter when focused fires the click
		// Msg. Matches native-toolkit convention; Space on button has been
		// standard since the Windows/Xt days.
		if focused {
			keys := ctx.input.keys_pressed
			if .Space in keys || .Enter in keys {
				send(ctx, on_click)
			}
		}
	} else {
		st.pressed = false
	}

	widget_set(ctx, id, st)

	return View_Button{
		id          = id,
		label       = label,
		color       = c,
		fg          = fc,
		color_focus = focus_ring_for(th^, c),
		radius      = rr,
		padding     = pad,
		font_size   = fs,
		width       = width,
		text_align  = text_align,
		hover       = hovered,
		pressed     = st.pressed,
		focused     = focused,
	}
}

// text_input builds a single-line editable text field. It applies all
// keyboard edits that landed in this frame's `Input` snapshot, then emits
// an `on_change` Msg carrying the new full string whenever the value
// actually changed — this is the elm/iced convention: the view doesn't
// own the text, the app's `State` does, and every keystroke round-trips
// through `update`.
//
//     Msg :: union {
//         Name_Changed: string,
//         ...
//     }
//     make_name_msg :: proc(s: string) -> Msg { return Name_Changed(s) }
//     skald.text_input(ctx, state.name, make_name_msg, placeholder = "Your name")
//
// The new string is allocated into `context.temp_allocator`; the run loop
// drains the message queue before resetting the frame arena, so the app's
// `update` sees live memory. Apps that want to persist the value into
// `State` must `strings.clone` into a persistent allocator — the text_input
// example shows the idiom.
//
// Focus model: clicking inside gives this input keyboard focus; clicking
// elsewhere releases it. Escape also clears focus. When focused, the
// widget sets `ctx.widgets.wants_text_input` so the run loop enables SDL3
// text entry (IME-friendly) and forwards typed characters via
// `Input.text`.
//
// `disabled`: display-only mode. No caret, no selection, no keypress
// handling, not Tab-reachable — the app's state is shown but can't be
// edited. Useful for config summaries or log viewers.
//
// `multiline`: Enter inserts a newline instead of being ignored, Up/Down
// arrows move the caret between lines preserving visual column, and
// clicks choose the target line by y-offset before picking the byte
// under the cursor. Default height grows to fit ~6 lines when the caller
// doesn't pass one explicitly. Single-line (the default) still swallows
// Enter so Enter-on-a-form-field keeps firing the parent's primary
// button.
//
// `wrap` (soft-wrap long lines at widget width) is still deferred — the
// real layout work lives in a future pass; the flag is accepted but
// currently unused so callers can already write `wrap = true` and get
// the right behavior once it ships.
//
// `password`: renders a `•` per rune instead of the buffer glyphs. Hit-
// testing runs against the mask so a click's x position reveals no
// glyph-width information about the real value. Copy + cut are
// suppressed so the cleartext never reaches the clipboard; paste and
// undo still work. Double-click word-select collapses to single-click
// (every char is identical). Forces `multiline = false` and `wrap =
// false` — passwords are always one line.
//
// `clear_button`: appends a small `✕` button at the right edge whose
// click sends `on_change("")`. Useful on search-style inputs and any
// other field where "wipe in one click" is a valid operation.
//
// `escape_clears`: pressing Escape on a populated field empties it
// instead of defocusing — a subsequent Escape (now with empty value)
// blurs as usual. Matches the GTK/macOS search-field convention. If
// you want `clear_button` to feel right, you almost always want this
// too. Both default off; `search_field` flips them on.
//
// Sizing: `width = 0` (the default) means "take the cross axis the
// parent stack assigns you." Put the input inside a `col(..., cross_align
// = .Stretch)` or wrap it in `flex(1, ...)` inside a row to fill; pass an
// explicit `width = 320` for a fixed pixel size. This matches the
// convention shared with `virtual_list`, `table`, `scroll`, `select`,
// and `slider`.
// _text_input_impl runs the full text-edit machinery and returns the
// rendered view alongside the post-edit value and a `changed` flag.
// Public dispatch — turning `changed` into a Msg via the caller's
// on_change — happens in the proc-group wrappers (`text_input_simple`
// and `text_input_payload`). Splitting the body lets one impl serve
// both callback shapes without duplication, and keeps Msg-construction
// at the wrapper boundary instead of threaded through ~700 lines of
// edit logic.
@(private)
_text_input_impl :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	id:          Widget_ID = 0,
	placeholder: string = "",
	width:       f32    = 0,
	height:      f32    = 0,
	font_size:   f32    = 0,
	padding:     [2]f32 = {0, 0},
	bg:          Color  = {},
	fg:          Color  = {},
	border:      Color  = {},
	disabled:    bool   = false,
	multiline:    bool   = false,
	wrap:         bool   = false,
	password:     bool   = false,
	clear_button: bool   = false,
	escape_clears:bool   = false,
	invalid:      bool   = false,
	error:        string = "",
	// max_chars caps the post-edit buffer length in runes (UTF-8 safe).
	// 0 disables the limit. Typing or pasting past the cap silently
	// drops the overflow at the caret; editing existing suffix text is
	// unaffected. Apps use this instead of re-implementing the cap in
	// their on_change handler.
	max_chars:    int    = 0,
) -> (view: View, new_value: string, changed: bool) {
	th := ctx.theme

	// Password fields are always single-line: a password can't contain a
	// newline a user could actually type. Shadow the incoming params so
	// downstream code doesn't have to special-case.
	multiline := multiline && !password
	wrap      := wrap      && !password

	fs := font_size; if fs == 0 { fs = th.font.size_md }

	pad := padding
	if pad.x == 0 { pad.x = th.spacing.md }
	if pad.y == 0 { pad.y = th.spacing.sm }

	bg_c := bg;     if bg_c[3]     == 0 { bg_c     = th.color.surface  }
	fg_c := fg;     if fg_c[3]     == 0 { fg_c     = th.color.fg       }
	br_c := border; if br_c[3]     == 0 { br_c     = th.color.primary  }
	// Read-only fields read as "informational, not interactive" — mute
	// the glyph color so the eye skips over them in a dense form.
	if disabled { fg_c = th.color.fg_muted }

	// Error state paints the border in the danger accent and makes it
	// persistent (see View_Text_Input.invalid for the renderer side). The
	// builder still passes `color_border` through so callers that already
	// supplied a custom border can override the danger swap if they
	// really want to — a small escape hatch for themed edge cases.
	if invalid && border.a == 0 { br_c = th.color.danger }

	h := height
	if h == 0 {
		if multiline {
			// ~6 visible lines by default — enough for notes / log-style
			// input without consuming the whole view. Apps that want a
			// different size pass `height` explicitly.
			h = fs * 6 + 2 * pad.y + 6
		} else {
			h = fs + 2 * pad.y + 6
		}
	}

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Text_Input)
	focused := !disabled && widget_has_focus(ctx, id)

	// Start with the state-held value and apply any edits this frame.
	// The caret can drift past the end if the app shortened `value`
	// underneath us, so clamp first. `new_value` is a named return —
	// the wrappers read it on exit to dispatch on_change.
	new_value = value
	cursor    := clamp(st.cursor_pos, 0, len(new_value))
	anchor    := clamp(st.selection_anchor, 0, len(new_value))

	// Pre-edit snapshot for the undo stack. `value_before` is the app's
	// persistent string so the clone inside undo_push is safe to hold
	// across frames. `cursor_before`/`anchor_before` mirror the just-
	// clamped values — they're what the caret looked like when the frame
	// started, before mouse or key events reshuffled it.
	value_before  := value
	cursor_before := cursor
	anchor_before := anchor

	// edit_kind tracks what kind of mutation happened this frame so the
	// undo stack can decide whether to coalesce with the previous
	// frame's entry. Stays .None when no mutation occurs, in which case
	// we either record a coalesce break (caret moved) or do nothing.
	edit_kind     := Edit_Kind.None
	handled_history := false // true when Ctrl-Z/Y handled the frame

	has_selection :: proc(a, c: int) -> bool { return a != c }
	sel_range :: proc(a, c: int) -> (lo, hi: int) {
		if a < c { return a, c }
		return c, a
	}

	// --- Mouse: focus + caret positioning + drag-to-select ---
	// Everything past the trigger press happens against `st.last_rect`,
	// so a field that mounted this frame still takes its first click —
	// the rect is zero, hit-test fails, we fall through.
	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	// Search-mode embedded clear: reserve a column in the right padding
	// for a `×` glyph. A press landing there empties the value outright
	// and suppresses the caret-placement path so the field doesn't also
	// move the cursor on the same click.
	show_clear    := clear_button && !disabled && len(new_value) > 0
	clear_captured := false
	clear_hovered  := false
	clear_w: f32   = 0
	if show_clear && st.last_rect.w > 0 && st.last_rect.h > 0 {
		clear_w = fs + th.spacing.sm
		cz := Rect{
			st.last_rect.x + st.last_rect.w - clear_w - pad.x * 0.5,
			st.last_rect.y,
			clear_w + pad.x * 0.5,
			st.last_rect.h,
		}
		clear_hovered = rect_contains_point(cz, ctx.input.mouse_pos)
		if clear_hovered && ctx.input.mouse_pressed[.Left] {
			new_value      = ""
			cursor         = 0
			anchor         = 0
			edit_kind      = .Other
			clear_captured = true
		}
	}

	// `content_x0` is the x where the glyphs actually start, inside the
	// padding. click_rel_x converts a window-space mouse x into a
	// prefix-width, which is what byte_index_at_x consumes.
	content_x0 := st.last_rect.x + pad.x
	click_rel_x := ctx.input.mouse_pos.x - content_x0

	// Multiline clicks pick the target visual line by y-offset first, then
	// run byte_index_at_x against that line's text. Soft-wrap splits one
	// logical line into multiple visual lines — the hit-test walks the
	// visual-line table so clicks land where the glyph actually is.
	resolve_click_idx :: proc(
		renderer: ^Renderer,
		text: string,
		vls: []Visual_Line,
		fs: f32,
		rel_x: f32,
		mouse_y, content_y0, line_h: f32,
		multiline: bool,
	) -> int {
		if renderer == nil { return 0 }
		if !multiline {
			return byte_index_at_x(renderer, text, fs, 0, rel_x)
		}
		ry := mouse_y - content_y0
		line := int(ry / line_h)
		if line < 0 { line = 0 }
		last := len(vls) - 1
		if last < 0 { return 0 }
		if line > last { line = last }
		vl := vls[line]
		col_in_line := byte_index_at_x(renderer, text[vl.start:vl.end], fs, 0, rel_x)
		return vl.start + col_in_line
	}

	// Line height: measure once per frame so multiline clicks and caret
	// motion agree. An empty string still returns the font's line height.
	line_h: f32 = fs
	if ctx.renderer != nil {
		_, line_h = measure_text(ctx.renderer, "Ag", fs)
	}
	// Multiline scrolls vertically against st.scroll_y. content_y0 is
	// the y where the first line's glyphs land *after* scrolling — click
	// hit-testing and caret positioning both go through it.
	content_y0 := st.last_rect.y + pad.y - st.scroll_y

	// Build the visual-line table once up front so the mouse hit-test can
	// use it. Rebuilt after any text mutation below — wrap is a function
	// of the current buffer, so it must follow edits. `inner_w` is the
	// text column inside the padding; the scrollbar sits in the right-pad
	// column past that.
	inner_w := width - 2 * pad.x
	do_wrap := multiline && wrap
	visual_lines := build_visual_lines(ctx.renderer, new_value, fs, inner_w, do_wrap)

	// Password: compute a `•`-per-rune mask used for hit-testing and
	// (later) rendering. The edit path stays on `new_value` (real bytes);
	// only the geometry that the user sees on screen runs through the
	// mask, so character widths don't leak the real string. Single-line
	// is forced above, so visual_lines is always a one-entry slice.
	disp_text := new_value
	if password {
		n := utf8.rune_count_in_string(new_value)
		disp_text = strings.repeat("•", n, context.temp_allocator)
		visual_lines = []Visual_Line{
			Visual_Line{start = 0, end = len(disp_text), consume_space = false},
		}
	}

	// --- Scrollbar thumb drag (multiline only) ---
	// Runs *before* the text-click handler so a press that lands on the
	// thumb doesn't also reposition the caret. Uses last-frame geometry
	// (st.content_h, st.scroll_y, st.last_rect) — same approach as
	// View_Scroll, which means the bar is draggable from frame 2 onward.
	// `st.pressed` latches the drag; `st.drag_anchor` holds the grab
	// offset within the thumb so it doesn't jump on the first move.
	sb_captured := false
	sb_hover    := false
	if multiline && !disabled && st.last_rect.w > 0 && st.last_rect.h > 0 {
		vp_h_prior := st.last_rect.h - 2 * pad.y
		if st.content_h > vp_h_prior && vp_h_prior > 0 {
			bar_w: f32 = 4
			bar_x := st.last_rect.x + st.last_rect.w - bar_w - 3
			bar_y := st.last_rect.y + pad.y + 1
			bar_h := vp_h_prior - 2
			max_off := st.content_h - vp_h_prior
			ratio   := vp_h_prior / st.content_h
			thumb_h := bar_h * ratio
			if thumb_h < 16    { thumb_h = 16 }
			if thumb_h > bar_h { thumb_h = bar_h }
			t: f32 = 0
			if max_off > 0 { t = st.scroll_y / max_off }
			thumb_y := bar_y + (bar_h - thumb_h) * t
			thumb := Rect{bar_x, thumb_y, bar_w, thumb_h}
			bar   := Rect{bar_x, bar_y, bar_w, bar_h}
			mp := ctx.input.mouse_pos

			sb_hover = rect_contains_point(thumb, mp)

			if ctx.input.mouse_pressed[.Left] {
				if rect_contains_point(thumb, mp) {
					st.pressed = true
					st.drag_anchor = mp.y - thumb_y
					sb_captured = true
				} else if rect_contains_point(bar, mp) {
					// Track click pages toward the cursor — same
					// convention as View_Scroll.
					if mp.y < thumb_y { st.scroll_y -= vp_h_prior }
					else              { st.scroll_y += vp_h_prior }
					sb_captured = true
				}
			}
			if !ctx.input.mouse_buttons[.Left] { st.pressed = false }

			if st.pressed {
				travel := bar_h - thumb_h
				if travel > 0 {
					want_thumb_y := mp.y - st.drag_anchor
					rel := (want_thumb_y - bar_y) / travel
					if rel < 0 { rel = 0 }
					if rel > 1 { rel = 1 }
					st.scroll_y = rel * max_off
				}
				// Suppress text selection updates while the thumb is
				// held. The sentinel covers both press and drag frames.
				sb_captured = true
			}
		} else {
			st.pressed = false
		}
	}

	if !disabled && !sb_captured && !clear_captured && ctx.input.mouse_pressed[.Left] {
		if hovered {
			widget_focus(ctx, id)
			focused = true
			idx := resolve_click_idx(ctx.renderer, disp_text, visual_lines,
				fs, click_rel_x,
				ctx.input.mouse_pos.y, content_y0, line_h, multiline)
			if password { idx = mask_byte_to_real_byte(new_value, idx) }
			clicks := ctx.input.mouse_click_count[.Left]
			// Password mode: double-click would collapse to select-all
			// (every char is identical, so word bounds == whole string),
			// which is redundant with triple-click. Treat double as a
			// plain caret-placement click instead.
			if password && clicks == 2 { clicks = 1 }
			switch {
			case clicks >= 3:
				// Triple-click: single-line selects everything; multiline
				// selects just the clicked line (the native convention for
				// a multi-line editor).
				if multiline {
					ls := multiline_line_nth_start(new_value, multiline_line_of(new_value, idx))
					le := multiline_line_end(new_value, ls)
					anchor = ls
					cursor = le
				} else {
					anchor = 0
					cursor = len(new_value)
				}
				st.mouse_selecting = false
			case clicks == 2:
				// Double-click selects the word under the cursor. If the
				// click landed on a separator, select that separator run
				// instead (matches most editors' "selects whitespace" feel).
				anchor, cursor = word_bounds_at(new_value, idx)
				st.mouse_selecting = false
			case:
				cursor = idx
				// Shift-click extends the existing selection rather than
				// collapsing it, matching the platform-wide convention.
				if .Shift not_in ctx.input.modifiers {
					anchor = idx
				}
				st.mouse_selecting = true
			}
		} else if focused {
			widget_focus(ctx, 0)
			focused = false
			st.mouse_selecting = false
		}
	}

	// Drag extends selection while the press is still held. Tracking
	// via `mouse_selecting` rather than `mouse_buttons[.Left]` means a
	// press that started outside the field and dragged in won't hijack
	// our caret. `sb_captured` blocks drag-to-select when the thumb
	// owns the drag.
	if st.mouse_selecting && !sb_captured && ctx.input.mouse_buttons[.Left] && ctx.renderer != nil {
		cursor = resolve_click_idx(ctx.renderer, disp_text, visual_lines,
			fs, click_rel_x,
			ctx.input.mouse_pos.y, content_y0, line_h, multiline)
		if password { cursor = mask_byte_to_real_byte(new_value, cursor) }
	}
	if ctx.input.mouse_released[.Left] {
		st.mouse_selecting = false
	}

	if focused {
		ctx.widgets.wants_text_input = true

		// Lazy-allocate the undo stack the first time a focused
		// text_input sees the builder. Unfocused fields never grow
		// history — opening a read-only dialog of 200 fields costs
		// nothing in undo memory.
		if st.undo == nil {
			st.undo = undo_stack_new()
		}

		keys := ctx.input.keys_pressed
		ctrl := .Ctrl in ctx.input.modifiers
		shift := .Shift in ctx.input.modifiers

		// Selection-replacing helper: if a selection exists, drop it from
		// the buffer and collapse the caret to the range start. Callers
		// use this before inserting text, hitting Backspace/Delete, or
		// pasting — the shared behavior across all three.
		drop_selection :: proc(buf: string, a, c: int) -> (out: string, caret: int) {
			if a == c { return buf, c }
			lo, hi := sel_range(a, c)
			return string_remove_range(buf, lo, hi), lo
		}

		// Undo / redo come first and short-circuit the rest of the
		// frame's edits. A Ctrl-Z that lands in the same frame as
		// typed characters replaces the buffer wholesale; the typed
		// chars are discarded rather than applied on top of the
		// restored snapshot, which matches every other editor.
		if ctrl && .Z in keys {
			if t, c, a, ok := undo_undo(st.undo, new_value, cursor, anchor); ok {
				cloned, _ := strings.clone(t, context.temp_allocator)
				new_value = cloned
				cursor    = c
				anchor    = a
				handled_history = true
			}
		} else if ctrl && .Y in keys {
			if t, c, a, ok := undo_redo(st.undo, new_value, cursor, anchor); ok {
				cloned, _ := strings.clone(t, context.temp_allocator)
				new_value = cloned
				cursor    = c
				anchor    = a
				handled_history = true
			}
		}

		if !handled_history {

		// Ctrl shortcuts come first so they pre-empt the matching letter
		// being typed (no risk of Ctrl-V pasting *and* inserting 'v').
		if ctrl && .A in keys {
			anchor = 0
			cursor = len(new_value)
		}

		// Password mode: suppress copy + cut so the cleartext never
		// reaches the clipboard. Paste + undo still work on the real
		// buffer. Matches browser `input[type=password]` behavior.
		if ctrl && (.C in keys || .X in keys) && has_selection(anchor, cursor) && !password {
			lo, hi := sel_range(anchor, cursor)
			clipboard_set(new_value[lo:hi])
			if .X in keys {
				new_value, cursor = drop_selection(new_value, anchor, cursor)
				anchor = cursor
				edit_kind = .Other
			}
		}

		if ctrl && .V in keys {
			paste := clipboard_get()
			if len(paste) > 0 {
				new_value, cursor = drop_selection(new_value, anchor, cursor)
				if max_chars > 0 {
					budget := max_chars - utf8.rune_count_in_string(new_value)
					paste = truncate_runes(paste, budget)
				}
				if len(paste) > 0 {
					new_value = string_insert_at(new_value, cursor, paste)
					cursor += len(paste)
					anchor = cursor
					edit_kind = .Other
				}
			}
		}

		// 1) Text insertion (typed characters arrive here as UTF-8). If a
		// selection is active the typed text replaces it. Typed characters
		// under Ctrl are the platform hotkeys we just handled — skip them
		// so e.g. Ctrl-A doesn't insert "a".
		if len(ctx.input.text) > 0 && !ctrl {
			had_selection := has_selection(anchor, cursor)
			new_value, cursor = drop_selection(new_value, anchor, cursor)
			ins := ctx.input.text
			if max_chars > 0 {
				budget := max_chars - utf8.rune_count_in_string(new_value)
				ins = truncate_runes(ins, budget)
			}
			if len(ins) > 0 {
				new_value = string_insert_at(new_value, cursor, ins)
				cursor += len(ins)
				anchor = cursor
				// Selection-replacing typing breaks the coalesce group so
				// Ctrl-Z lands cleanly on the "before typing started" state
				// rather than the middle of the typing run.
				if had_selection { edit_kind = .Other } else { edit_kind = .Type }
			} else if had_selection {
				edit_kind = .Other
			}
		}

		// Enter inserts a newline when multiline. Single-line fields fire
		// `on_submit` if the caller opted in; otherwise Enter is left
		// untouched so a form's primary button can still act on it.
		if multiline && .Enter in keys && !ctrl {
			had_selection := has_selection(anchor, cursor)
			new_value, cursor = drop_selection(new_value, anchor, cursor)
			over_cap := max_chars > 0 &&
				utf8.rune_count_in_string(new_value) >= max_chars
			if !over_cap {
				new_value = string_insert_at(new_value, cursor, "\n")
				cursor += 1
				anchor = cursor
				if had_selection { edit_kind = .Other } else { edit_kind = .Type }
			} else if had_selection {
				edit_kind = .Other
			}
		}

		// 2) Editing keys. `keys_pressed` includes auto-repeats so holding
		// Backspace / arrows behaves naturally without us running our own
		// timer.
		if .Backspace in keys {
			if has_selection(anchor, cursor) {
				new_value, cursor = drop_selection(new_value, anchor, cursor)
				anchor = cursor
				edit_kind = .Other
			} else if cursor > 0 {
				_, step := decode_last_rune_in_prefix(new_value, cursor)
				new_value = string_remove_range(new_value, cursor - step, cursor)
				cursor -= step
				anchor = cursor
				edit_kind = .Back
			}
		}
		if .Delete in keys {
			if has_selection(anchor, cursor) {
				new_value, cursor = drop_selection(new_value, anchor, cursor)
				anchor = cursor
				edit_kind = .Other
			} else if cursor < len(new_value) {
				_, step := decode_first_rune_in_suffix(new_value, cursor)
				new_value = string_remove_range(new_value, cursor, cursor + step)
				edit_kind = .Del
			}
		}

		// Caret motion. Shift-held extends selection (anchor stays put);
		// plain arrows collapse any selection to the appropriate end
		// before moving, so Right from a selection lands at the right
		// edge even when the caret was on the left.
		if .Left in keys {
			if !shift && has_selection(anchor, cursor) {
				lo, _ := sel_range(anchor, cursor)
				cursor = lo
			} else if cursor > 0 {
				_, step := decode_last_rune_in_prefix(new_value, cursor)
				cursor -= step
			}
			if !shift { anchor = cursor }
		}
		if .Right in keys {
			if !shift && has_selection(anchor, cursor) {
				_, hi := sel_range(anchor, cursor)
				cursor = hi
			} else if cursor < len(new_value) {
				_, step := decode_first_rune_in_suffix(new_value, cursor)
				cursor += step
			}
			if !shift { anchor = cursor }
		}
		// Text edits above may have changed new_value; refresh the
		// visual-line table before any nav key consults it. Cheap to
		// rebuild — O(runes) with a measure_text per rune — and keeping
		// one source of truth for lines is worth it.
		if multiline && new_value != value {
			visual_lines = build_visual_lines(ctx.renderer, new_value, fs, inner_w, do_wrap)
		}

		// Home/End: multiline scopes to the current *visual* line (the
		// native "Home goes to line start, not buffer start" behavior).
		// Single-line Home/End still jump to the whole buffer's ends.
		// Ctrl-Home / Ctrl-End escape to the whole buffer in multiline mode.
		if .Home in keys {
			if multiline && !ctrl {
				vl := visual_lines[visual_line_of_byte(visual_lines, cursor)]
				cursor = vl.start
			} else {
				cursor = 0
			}
			if !shift { anchor = cursor }
		}
		if .End in keys {
			if multiline && !ctrl {
				vl := visual_lines[visual_line_of_byte(visual_lines, cursor)]
				cursor = vl.end
			} else {
				cursor = len(new_value)
			}
			if !shift { anchor = cursor }
		}

		// Up / Down: only meaningful in multiline mode. Translate the
		// caret by one *visual* line while preserving visual column —
		// measure the prefix width on the current visual line, then
		// place the caret on the adjacent visual line at the byte whose
		// prefix width matches (or clamp to end-of-line if shorter).
		if multiline && (.Up in keys || .Down in keys) && ctx.renderer != nil {
			cur_line := visual_line_of_byte(visual_lines, cursor)
			cur_vl   := visual_lines[cur_line]
			col_x, _ := measure_text(ctx.renderer,
				new_value[cur_vl.start:cursor], fs)

			target := cur_line
			if .Up   in keys { target -= 1 }
			if .Down in keys { target += 1 }
			last_line := len(visual_lines) - 1
			if target < 0 { target = 0 }
			if target > last_line { target = last_line }

			if target != cur_line {
				vl := visual_lines[target]
				col := byte_index_at_x(ctx.renderer,
					new_value[vl.start:vl.end], fs, 0, col_x)
				cursor = vl.start + col
			} else if .Up in keys {
				// At the first line with Up: match the native "snap to
				// start-of-buffer" behavior so the caret still moves.
				cursor = 0
			} else if .Down in keys {
				cursor = len(new_value)
			}
			if !shift { anchor = cursor }
		}

		if .Escape in keys {
			if escape_clears && len(new_value) > 0 {
				// GTK/macOS search convention: first Escape empties the
				// field, a subsequent Escape (now with value == "") blurs
				// as usual. The wipe is marked `.Other` so undo records
				// one pre-wipe snapshot instead of coalescing into an
				// adjacent typing group.
				new_value = ""
				cursor = 0
				anchor = 0
				edit_kind = .Other
			} else {
				widget_focus(ctx, 0)
				focused = false
				anchor = cursor
			}
		}

		} // end if !handled_history
	}

	// Record the frame's activity on the undo stack. Three cases:
	// a buffer mutation pushes a pre-edit snapshot (with coalesce based
	// on edit_kind); a pure caret move breaks any active coalesce group
	// so the next typed character starts a fresh undo step; undo / redo
	// themselves (handled_history) already updated the stack and don't
	// need another push.
	if !handled_history && st.undo != nil {
		if new_value != value_before {
			undo_push(st.undo, value_before, cursor_before, anchor_before, edit_kind)
		} else if cursor != cursor_before || anchor != anchor_before {
			undo_mark_break(st.undo)
		}
	}

	// Vertical scroll for multiline. Content height = visual line count ×
	// line height; the viewport is the padded-inner region. Wheel scrolls
	// when the mouse is over the widget (even if a different input owns
	// focus); caret motion auto-scrolls to keep the caret onscreen so
	// typing past the bottom edge follows the cursor down.
	viewport_h := h - 2 * pad.y
	content_h  := f32(len(visual_lines)) * line_h
	if multiline {
		max_off := content_h - viewport_h
		if max_off < 0 { max_off = 0 }

		// Pointer-over-widget wheel. Matches View_Scroll's feel — one
		// notch ≈ 40 px, SDL wheel units multiplied in. Read from the
		// current-frame input; caret-driven scroll below runs after so
		// auto-follow beats an accidental simultaneous wheel.
		wheeling := rect_contains_point(st.last_rect, ctx.input.mouse_pos)
		if wheeling && ctx.input.scroll.y != 0 {
			st.scroll_y -= ctx.input.scroll.y * 40
		}

		// Auto-follow the caret when it moved this frame (keypress,
		// click, drag, or selection extension) or when a buffer edit
		// changed line count. Skip when the caret sits on its prior
		// position and the buffer shape is unchanged — avoids fighting
		// the user's wheel scroll.
		if cursor != cursor_before || new_value != value_before {
			cur_line := visual_line_of_byte(visual_lines, cursor)
			caret_top := f32(cur_line) * line_h
			caret_bot := caret_top + line_h
			if caret_top < st.scroll_y            { st.scroll_y = caret_top }
			if caret_bot > st.scroll_y + viewport_h {
				st.scroll_y = caret_bot - viewport_h
			}
		}

		if st.scroll_y < 0       { st.scroll_y = 0 }
		if st.scroll_y > max_off { st.scroll_y = max_off }
		st.content_h = content_h
	} else {
		st.scroll_y  = 0
		st.content_h = 0
	}

	st.cursor_pos       = cursor
	st.selection_anchor = anchor
	widget_set(ctx, id, st)

	// Edit dispatch is handled by the proc-group wrappers — they consume
	// the named return values and call the caller's on_change(new_value)
	// or on_change(payload, new_value) as appropriate. Keeping Msg
	// construction at the wrapper boundary lets one impl serve both
	// callback shapes.
	changed = new_value != value

	// Final render-time mask. new_value may have changed since the
	// hit-test-stage disp_text was built (typing, paste, delete), so
	// rebuild the mask and translate caret/anchor from real bytes to
	// mask bytes (each rune → 3 bytes since the bullet is U+2022).
	out_text    := new_value
	out_cursor  := cursor
	out_anchor  := anchor
	out_vls     := visual_lines
	if password {
		n := utf8.rune_count_in_string(new_value)
		out_text = strings.repeat("•", n, context.temp_allocator)
		out_cursor = utf8.rune_count_in_string(new_value[:cursor]) * 3
		out_anchor = utf8.rune_count_in_string(new_value[:anchor]) * 3
		out_vls = []Visual_Line{
			Visual_Line{start = 0, end = len(out_text), consume_space = false},
		}
	}

	field := View_Text_Input{
		id                = id,
		text              = out_text,
		placeholder       = placeholder,
		color_bg          = bg_c,
		color_fg          = fg_c,
		color_placeholder = th.color.fg_muted,
		color_border      = br_c,
		color_border_idle = th.color.border,
		color_caret       = fg_c,
		color_selection   = th.color.selection,
		color_track       = th.color.surface,
		color_thumb       = th.color.fg_muted,
		radius            = th.radius.sm,
		padding           = pad,
		font_size         = fs,
		width             = width,
		height            = h,
		focused           = focused,
		cursor_pos        = out_cursor,
		selection_anchor  = out_anchor,
		multiline         = multiline,
		scroll_y          = st.scroll_y,
		content_h         = content_h,
		visual_lines      = out_vls,
		invalid           = invalid,
		sb_hover          = sb_hover,
		sb_dragging       = st.pressed,
		show_clear        = show_clear,
		clear_hovered     = clear_hovered,
	}

	// Search-mode composition: when the field holds text, sit a clear
	// button to its right so the user has a one-click "empty it" affordance
	// on top of Escape-to-clear. Read-only searches don't get the button —
	// the app has disabled editing, so clearing doesn't make sense either.
	// The clear button's id is derived from the field's id so it keeps its
	// identity across frames; without that, `widget_resolve_id` would hand
	// out a fresh auto-id every render and break the button's press-state
	// tracking.
	// Error helper line sits directly under the field when both flags
	// are set. Width-less col keeps it content-sized so long messages
	// wrap via max_width against the field's declared width.
	if invalid && len(error) > 0 {
		view = col(
			field,
			text(error, th.color.danger, th.font.size_sm, 0, width - 4),
			spacing = 4,
		)
		return
	}

	view = field
	return
}

// text_input is the framework's editable string input. Two callback
// shapes are accepted via the proc group: pass `on_change` directly
// for a standalone field, or pass `payload` first when the same
// callback handles many rows / cells and needs to know which.
//
//     // Standalone:
//     skald.text_input(ctx, s.email, on_email_change)
//
//     // Per-row identity:
//     skald.text_input(ctx, p.qty_str, p.id, on_qty_change)
//     on_qty_change :: proc(id: int, v: string) -> Msg {
//         return Qty_Changed{id, v}
//     }
//
// The compiler picks between `text_input_simple` and
// `text_input_payload` based on whether a payload appears before the
// callback. Both share the same edit machinery; only the dispatch at
// the end differs. See the impl proc `_text_input_impl` for the full
// docstring of each parameter.
text_input :: proc{text_input_simple, text_input_payload}

// text_input_simple is the standalone-callback shape. The on_change
// callback receives the post-edit string only — use this when the
// field's identity is global to the view (a single email field, a
// single search box, anything not inside a row loop).
text_input_simple :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	on_change:   proc(new_value: string) -> Msg,
	id:          Widget_ID = 0,
	placeholder: string = "",
	width:       f32    = 0,
	height:      f32    = 0,
	font_size:   f32    = 0,
	padding:     [2]f32 = {0, 0},
	bg:          Color  = {},
	fg:          Color  = {},
	border:      Color  = {},
	disabled:     bool   = false,
	multiline:    bool   = false,
	wrap:         bool   = false,
	password:     bool   = false,
	clear_button: bool   = false,
	escape_clears:bool   = false,
	invalid:      bool   = false,
	error:        string = "",
	max_chars:    int    = 0,
) -> View {
	view, new_value, changed := _text_input_impl(
		ctx, value,
		id            = id,
		placeholder   = placeholder,
		width         = width,
		height        = height,
		font_size     = font_size,
		padding       = padding,
		bg            = bg,
		fg            = fg,
		border        = border,
		disabled      = disabled,
		multiline     = multiline,
		wrap          = wrap,
		password      = password,
		clear_button  = clear_button,
		escape_clears = escape_clears,
		invalid       = invalid,
		error         = error,
		max_chars     = max_chars,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

// text_input_payload is the typed-payload-callback shape. The
// `payload` value is captured at view-build time and handed back to
// `on_change` when the field's value changes — useful for tables /
// lists where one callback dispatches per-row identity. The payload
// type is fully polymorphic; pass an int row id, a struct, a pointer,
// or any other identifier shape.
text_input_payload :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	payload:     $Payload,
	on_change:   proc(payload: Payload, new_value: string) -> Msg,
	id:          Widget_ID = 0,
	placeholder: string = "",
	width:       f32    = 0,
	height:      f32    = 0,
	font_size:   f32    = 0,
	padding:     [2]f32 = {0, 0},
	bg:          Color  = {},
	fg:          Color  = {},
	border:      Color  = {},
	disabled:     bool   = false,
	multiline:    bool   = false,
	wrap:         bool   = false,
	password:     bool   = false,
	clear_button: bool   = false,
	escape_clears:bool   = false,
	invalid:      bool   = false,
	error:        string = "",
	max_chars:    int    = 0,
) -> View {
	view, new_value, changed := _text_input_impl(
		ctx, value,
		id            = id,
		placeholder   = placeholder,
		width         = width,
		height        = height,
		font_size     = font_size,
		padding       = padding,
		bg            = bg,
		fg            = fg,
		border        = border,
		disabled      = disabled,
		multiline     = multiline,
		wrap          = wrap,
		password      = password,
		clear_button  = clear_button,
		escape_clears = escape_clears,
		invalid       = invalid,
		error         = error,
		max_chars     = max_chars,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// search_field is the dedicated search-input widget: a `text_input`
// with `clear_button = true`, `escape_clears = true`, a localized
// "Search…" placeholder default, and a required Enter-submit callback.
//
// Split out instead of stapled onto text_input because a polymorphic
// `proc() -> $Msg = nil` default can't exist in Odin — requiring an
// `on_submit` on every text_input call would force a trailing `nil`
// at every site. Keeping submit on its own builder means plain text
// fields stay clean and search fields get the "type to filter
// incrementally, Enter to confirm" pattern for free.
//
// `on_submit` fires on Enter while focused, with no argument — the
// current value already round-tripped through `on_change` and sits in
// the app's state. Escape clears the field (then defocuses on the
// next press), the `×` clear button renders when the field holds
// text, and all other text_input contracts apply unchanged.
search_field :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	on_change:   proc(new_value: string) -> Msg,
	on_submit:   proc() -> Msg,
	id:          Widget_ID = 0,
	placeholder: string = "",
	width:       f32    = 0,
	height:      f32    = 0,
	font_size:   f32    = 0,
	padding:     [2]f32 = {0, 0},
	bg:          Color  = {},
	fg:          Color  = {},
	border:      Color  = {},
	invalid:     bool   = false,
	error:       string = "",
	disabled:   bool   = false,
) -> View {
	// Resolve the id up front so we can hit-test focus for the submit
	// path and then hand the same id to text_input. Passing it
	// explicitly stops text_input's auto-id counter from handing out a
	// fresh one and desyncing the two views.
	id := widget_resolve_id(ctx, id)

	// Fire submit when this field owns focus and Enter landed this frame.
	// text_input itself ignores Enter on single-line, so there's no
	// double-fire risk — the submit is purely this wrapper's concern.
	// Skip submit-on-Enter when the field is disabled — Enter would
	// fire on an uneditable value, which reads as a bug.
	if !disabled && widget_has_focus(ctx, id) && .Enter in ctx.input.keys_pressed {
		send(ctx, on_submit())
	}

	// Default the placeholder to the localized "Search…" if the caller
	// didn't pass one. Explicit placeholders are kept as-is.
	ph := placeholder
	if len(ph) == 0 { ph = ctx.labels.search_placeholder }

	return text_input(ctx, value, on_change,
		id            = id,
		placeholder   = ph,
		width         = width,
		height        = height,
		font_size     = font_size,
		padding       = padding,
		bg            = bg,
		fg            = fg,
		border        = border,
		clear_button  = true,
		escape_clears = true,
		invalid       = invalid,
		error         = error,
		disabled      = disabled,
	)
}

// --- text editing helpers ---
//
// All of these allocate into context.temp_allocator so the new string is
// valid for the rest of the frame (view + render + message drain). The
// run loop resets the frame arena only after messages are consumed, so
// these strings never dangle across the view→update handoff.

@(private)
string_insert_at :: proc(s: string, at: int, ins: string) -> string {
	return strings.concatenate({s[:at], ins, s[at:]}, context.temp_allocator)
}

// truncate_runes returns the longest prefix of `s` whose rune count is
// <= max_runes. Used by text_input's max_chars enforcement so a paste or
// typed burst that overflows the cap drops the tail on a rune boundary
// (never mid-codepoint).
@(private)
truncate_runes :: proc(s: string, max_runes: int) -> string {
	if max_runes <= 0 { return "" }
	n := 0
	for _, i in s {
		if n == max_runes { return s[:i] }
		n += 1
	}
	return s
}

// Multiline text helpers. All operate on byte offsets — rune boundaries
// are handled by the caller via `decode_*_rune_in_*` helpers. They're
// deliberately linear scans (no cached per-line table) because edit
// buffers tend to be small and an O(n) pass every frame beats keeping a
// side table in sync across every mutation.

@(private)
multiline_line_count :: proc(s: string) -> int {
	n := 1
	for i in 0..<len(s) {
		if s[i] == '\n' { n += 1 }
	}
	return n
}

// multiline_line_of returns the 0-based line index containing byte offset
// `byte_idx`. Offsets at a \n sit on the line the \n terminates (i.e. the
// offset *before* the following line).
@(private)
multiline_line_of :: proc(s: string, byte_idx: int) -> int {
	line := 0
	end := byte_idx
	if end > len(s) { end = len(s) }
	for i in 0..<end {
		if s[i] == '\n' { line += 1 }
	}
	return line
}

// multiline_line_nth_start returns the byte offset where the nth line
// begins (line 0 begins at 0; line N begins just after the nth \n).
// Clamps past the buffer to len(s) so callers can freely ask for one
// past the last line.
@(private)
multiline_line_nth_start :: proc(s: string, n: int) -> int {
	if n <= 0 { return 0 }
	count := 0
	for i in 0..<len(s) {
		if s[i] == '\n' {
			count += 1
			if count == n { return i + 1 }
		}
	}
	return len(s)
}

// multiline_line_end returns the byte offset of the \n that ends the line
// starting at `line_start`, or len(s) if it's the final line.
@(private)
multiline_line_end :: proc(s: string, line_start: int) -> int {
	i := line_start
	for i < len(s) && s[i] != '\n' { i += 1 }
	return i
}

// Visual_Line is one display-line in the multiline text_input. For
// non-wrapping fields there's a 1:1 mapping with \n-separated logical
// lines; soft-wrap splits a single logical line into multiple visual
// lines. `start` / `end` are byte offsets into the full buffer; when
// `end` sits on a space or newline that got consumed by the break, the
// renderer skips the consumed byte so the next line starts with the
// first visible glyph. All paths downstream of this (click hit-test,
// caret motion, render, content-height) run off this table so wrap and
// non-wrap share one codepath.
@(private)
Visual_Line :: struct {
	start:      int,
	end:        int,
	// consume_space: the break advanced past a trailing space (set when
	// wrap broke on a word boundary). The caret can still land at
	// `end` via End-key, but Down-arrow lands past the space on the
	// next line rather than on it.
	consume_space: bool,
}

// build_visual_lines materializes the visual-line table for a buffer.
// With `wrap = false` this degenerates to one entry per logical line.
// With `wrap = true` each logical line is broken at word boundaries
// (the last space before overflow) or, when no space exists, hard-broken
// at the last rune that fits. Measures each candidate prefix against
// `measure_text` — linear in the number of runes, which is fine for
// edit-buffer-sized text. If `inner_w <= 0` or the renderer is nil the
// wrap fallback is skipped and we behave as if wrap were off.
@(private)
build_visual_lines :: proc(
	r: ^Renderer, text: string, fs, inner_w: f32, wrap: bool,
) -> []Visual_Line {
	out := make([dynamic]Visual_Line, 0, 16, context.temp_allocator)

	do_wrap := wrap && r != nil && inner_w > 0

	i := 0
	for {
		// End of this logical line.
		le := i
		for le < len(text) && text[le] != '\n' { le += 1 }

		if !do_wrap || le == i {
			// Either wrap is off, or the logical line is empty — emit
			// the whole range as one visual line.
			append(&out, Visual_Line{start = i, end = le})
		} else {
			// Wrap the run [i, le] at word boundaries.
			pos := i
			for pos < le {
				// Walk one rune at a time, remembering the last space we
				// saw, and emit a break when the prefix exceeds inner_w.
				last_space := -1
				j := pos
				fits_all := true
				for j < le {
					// Advance one rune.
					_, rune_bytes := utf8.decode_rune_in_string(text[j:])
					if rune_bytes <= 0 { rune_bytes = 1 }
					next := j + rune_bytes
					if next > le { next = le }
					w, _ := measure_text(r, text[pos:next], fs)
					if w > inner_w && next > pos + 1 {
						fits_all = false
						break
					}
					if text[j] == ' ' { last_space = j }
					j = next
				}
				if fits_all {
					append(&out, Visual_Line{start = pos, end = le})
					pos = le
					break
				}
				// Overflow at byte `j`. Prefer breaking at the last
				// space in [pos, j); fall back to a hard rune-boundary
				// break if the word itself is wider than inner_w.
				if last_space > pos {
					append(&out, Visual_Line{
						start = pos, end = last_space, consume_space = true,
					})
					pos = last_space + 1
				} else {
					// Hard break: walk back one rune from `j` so the
					// current line doesn't overflow. If j == pos + 1
					// already (single-rune overflow), keep the rune —
					// we can't emit an empty line.
					cut := j
					if cut > pos + 1 {
						_, rb := utf8.decode_last_rune_in_string(text[pos:cut])
						if rb > 0 && cut - rb > pos { cut -= rb }
					}
					append(&out, Visual_Line{start = pos, end = cut})
					pos = cut
				}
			}
		}

		if le >= len(text) { break }
		i = le + 1
	}

	// Ensure the table is never empty so downstream code can safely
	// index line 0. The empty-buffer case lands here.
	if len(out) == 0 {
		append(&out, Visual_Line{start = 0, end = 0})
	}
	return out[:]
}

// visual_line_of_byte returns the visual-line index that contains
// `byte_idx`. A caret sitting on a line break (the byte right before
// the break consumption) stays on the earlier line; the byte *after*
// the break sits on the next.
@(private)
visual_line_of_byte :: proc(vls: []Visual_Line, byte_idx: int) -> int {
	for i := len(vls) - 1; i >= 0; i -= 1 {
		if byte_idx >= vls[i].start { return i }
	}
	return 0
}

@(private)
string_remove_range :: proc(s: string, lo, hi: int) -> string {
	return strings.concatenate({s[:lo], s[hi:]}, context.temp_allocator)
}

// decode_last_rune_in_prefix returns the rune ending at index `end` and
// its byte length. Used by Backspace / Left-arrow to step back by one
// whole code point instead of chopping a multi-byte UTF-8 sequence in
// half.
@(private)
decode_last_rune_in_prefix :: proc(s: string, end: int) -> (rune, int) {
	return utf8.decode_last_rune_in_string(s[:end])
}

// decode_first_rune_in_suffix is Delete / Right-arrow's counterpart: the
// rune starting at `start` and its byte length.
@(private)
decode_first_rune_in_suffix :: proc(s: string, start: int) -> (rune, int) {
	return utf8.decode_rune_in_string(s[start:])
}

// mask_byte_to_real_byte maps a byte offset in a password field's
// display mask back to a byte offset in the real buffer. The mask is
// `utf8.rune_count_in_string(real)` copies of U+2022 (3 bytes each),
// so one bullet corresponds to exactly one rune in the real buffer.
// Used when a click or drag hit-test ran against the mask and we need
// to land the caret on the real-buffer rune boundary.
@(private)
mask_byte_to_real_byte :: proc(real: string, mask_byte: int) -> int {
	n := mask_byte / 3
	i, k := 0, 0
	for i < len(real) && k < n {
		_, size := utf8.decode_rune_in_string(real[i:])
		i += size
		k += 1
	}
	return i
}

// word_bounds_at returns the (lo, hi) byte range of the word containing
// `at`. A "word" here is a run of adjacent bytes with the same word-char
// classification as byte `at` itself — so double-clicking inside a word
// selects the word, and double-clicking inside whitespace selects that
// whitespace run. This matches the common text-editor convention.
//
// Classification is deliberately coarse: ASCII alnum and underscore count
// as word bytes; any byte >= 0x80 is also counted (a cheap "treat all
// UTF-8 letters as word bytes" approximation that avoids pulling in a
// full Unicode category table for a feature that only affects
// double-click ergonomics). ASCII punctuation ends the word — so
// "hello, world" double-clicks to "hello" or "world" rather than the
// whole thing.
@(private)
word_bounds_at :: proc(s: string, at: int) -> (lo, hi: int) {
	n := len(s)
	if n == 0 { return 0, 0 }
	a := clamp(at, 0, n)
	// At the very end of the buffer, extend left so "hello|" still
	// selects "hello" rather than an empty range at EOF.
	probe := a
	if probe >= n { probe = n - 1 }
	target := is_word_byte(s[probe])
	lo = a
	for lo > 0 && is_word_byte(s[lo - 1]) == target { lo -= 1 }
	hi = a
	for hi < n && is_word_byte(s[hi]) == target { hi += 1 }
	return
}

@(private)
is_word_byte :: proc(b: u8) -> bool {
	switch {
	case b >= '0' && b <= '9': return true
	case b >= 'A' && b <= 'Z': return true
	case b >= 'a' && b <= 'z': return true
	case b == '_':             return true
	case b >= 0x80:            return true // UTF-8 continuation / non-ASCII
	}
	return false
}

// checkbox builds a boolean toggle with an optional label to the right of
// the box. Emits on_change(new_value) on click.
//
//     Msg :: union { Dark_Mode_Toggled: bool, ... }
//     on_dark_mode :: proc(v: bool) -> Msg { return Dark_Mode_Toggled(v) }
//     skald.checkbox(ctx, state.dark_mode, "Dark mode", on_dark_mode)
//
// Click semantics mirror the button: latch `pressed` on mouse-down-inside,
// fire on mouse-up-inside. No keyboard activation yet — that ships with
// the 5.4 polish batch (Space/Enter while focused).
// checkbox is the framework's binary on/off marker. Two callback shapes
// via the proc group:
//
//     skald.checkbox(ctx, s.notify, "Notify me", on_notify)
//     skald.checkbox(ctx, opt.enabled, opt.label, opt.id, on_toggle)
checkbox :: proc{checkbox_simple, checkbox_payload}

@(private)
_checkbox_impl :: proc(
	ctx:        ^Ctx($Msg),
	checked:    bool,
	label:      string,
	id:         Widget_ID = 0,
	font_size:  f32   = 0,
	box_size:   f32   = 0,
	color_box:  Color = {},
	color_fill: Color = {},
	disabled:  bool  = false,
) -> (view: View, new_value: bool, changed: bool) {
	th := ctx.theme

	fs := font_size; if fs == 0 { fs = th.font.size_md }
	bs := box_size;  if bs == 0 { bs = fs + 4 }

	cbox  := color_box;  if cbox[3]  == 0 { cbox  = th.color.surface }
	cfill := color_fill; if cfill[3] == 0 { cfill = th.color.primary }
	// Muted fill signals "not interactive" without hiding the current
	// value — checked read-only boxes still show their ✓.
	if disabled { cfill = th.color.fg_muted }
	fg_c := th.color.fg
	if disabled { fg_c = th.color.fg_muted }

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Checkbox)
	focused := !disabled && widget_has_focus(ctx, id)
	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	if !disabled {
		if ctx.input.mouse_pressed[.Left] && hovered {
			st.pressed = true
			widget_focus(ctx, id)
			focused = true
		}
		if ctx.input.mouse_released[.Left] {
			if st.pressed && hovered {
				new_value, changed = !checked, true
			}
			st.pressed = false
		}
		if !ctx.input.mouse_buttons[.Left] { st.pressed = false }

		// Space toggles when focused. Enter is deliberately *not* bound so
		// checkboxes inside a form don't steal Enter from a "primary" button.
		if focused && .Space in ctx.input.keys_pressed {
			new_value, changed = !checked, true
		}
	} else {
		st.pressed = false
	}

	widget_set(ctx, id, st)

	view = View_Checkbox{
		id           = id,
		checked      = checked,
		label        = label,
		color_box    = cbox,
		color_fill   = cfill,
		color_check  = th.color.on_primary,
		color_border = th.color.border,
		// Checked checkbox has bg = cfill (primary by default); the
		// ring would paint blue-on-blue without focus_ring_for.
		color_focus  = focus_ring_for(th^, cfill),
		color_fg     = fg_c,
		font_size    = fs,
		box_size     = bs,
		gap          = th.spacing.sm,
		hover        = hovered,
		pressed      = st.pressed,
		focused      = focused,
	}
	return
}

checkbox_simple :: proc(
	ctx:        ^Ctx($Msg),
	checked:    bool,
	label:      string,
	on_change:  proc(new_value: bool) -> Msg,
	id:         Widget_ID = 0,
	font_size:  f32   = 0,
	box_size:   f32   = 0,
	color_box:  Color = {},
	color_fill: Color = {},
	disabled:  bool  = false,
) -> View {
	view, new_value, changed := _checkbox_impl(
		ctx, checked, label,
		id = id, font_size = font_size, box_size = box_size,
		color_box = color_box, color_fill = color_fill, disabled = disabled,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

checkbox_payload :: proc(
	ctx:        ^Ctx($Msg),
	checked:    bool,
	label:      string,
	payload:    $Payload,
	on_change:  proc(payload: Payload, new_value: bool) -> Msg,
	id:         Widget_ID = 0,
	font_size:  f32   = 0,
	box_size:   f32   = 0,
	color_box:  Color = {},
	color_fill: Color = {},
	disabled:  bool  = false,
) -> View {
	view, new_value, changed := _checkbox_impl(
		ctx, checked, label,
		id = id, font_size = font_size, box_size = box_size,
		color_box = color_box, color_fill = color_fill, disabled = disabled,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// radio builds a single mutually-exclusive-selection marker with an
// optional label. Visually a circular outline with a filled inner dot
// when `selected`. Unlike `checkbox`, the builder does not toggle — the
// only operation is "select me", since clearing a radio without
// selecting another one breaks the mutual-exclusion invariant a radio
// group exists to maintain. `on_select` fires on click or Space when
// the widget isn't already selected; selecting the currently-selected
// radio is a no-op so the app doesn't see redundant msgs.
//
//     Msg :: union { Size_Changed: Size, ... }
//     on_small :: proc() -> Msg { return Size_Changed(.Small) }
//     skald.radio(ctx, state.size == .Small, "Small", on_small)
//
// For a linear list of options with arrow-key navigation between them,
// use `radio_group` — it wraps a sequence of radios and adds Up/Down
// (or Left/Right when laid out horizontally) steering between them.
radio :: proc{radio_simple, radio_payload}

@(private)
_radio_impl :: proc(
	ctx:       ^Ctx($Msg),
	selected:  bool,
	label:     string,
	id:        Widget_ID = 0,
	font_size: f32   = 0,
	box_size:  f32   = 0,
	color_bg:  Color = {},
	color_dot: Color = {},
	disabled: bool  = false,
) -> (view: View, fired: bool) {
	th := ctx.theme

	fs := font_size; if fs == 0 { fs = th.font.size_md }
	bs := box_size;  if bs == 0 { bs = fs + 4 }

	// Radio's disc has no outline in the render — bg contrast is the
	// whole visual. `track_color_for` gives an always-visible disc in
	// both palettes without vanishing into a surface-bg card.
	cbg  := color_bg;  if cbg[3]  == 0 { cbg = track_color_for(th^) }
	cdot := color_dot; if cdot[3] == 0 { cdot = th.color.primary }
	if disabled { cdot = th.color.fg_muted }
	fg_c := th.color.fg
	if disabled { fg_c = th.color.fg_muted }

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Radio)
	focused := !disabled && widget_has_focus(ctx, id)
	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	if !disabled {
		if ctx.input.mouse_pressed[.Left] && hovered {
			st.pressed = true
			widget_focus(ctx, id)
			focused = true
		}
		if ctx.input.mouse_released[.Left] {
			if st.pressed && hovered && !selected { fired = true }
			st.pressed = false
		}
		if !ctx.input.mouse_buttons[.Left] { st.pressed = false }

		// Space selects when focused (same convention as checkbox).
		// Enter is not bound for the same reason — a radio inside a form
		// shouldn't swallow Enter from a primary button. Re-selecting an
		// already-selected radio doesn't fire; groups rely on this to
		// stay idempotent when arrow-key nav lands on the current one.
		if focused && !selected && .Space in ctx.input.keys_pressed {
			fired = true
		}
	} else {
		st.pressed = false
	}

	widget_set(ctx, id, st)

	view = View_Radio{
		id           = id,
		selected     = selected,
		label        = label,
		color_bg     = cbg,
		color_dot    = cdot,
		color_border = th.color.border,
		color_focus  = focus_ring_for(th^, cbg),
		color_fg     = fg_c,
		font_size    = fs,
		box_size     = bs,
		gap          = th.spacing.sm,
		hover        = hovered,
		pressed      = st.pressed,
		focused      = focused,
	}
	return
}

radio_simple :: proc(
	ctx:       ^Ctx($Msg),
	selected:  bool,
	label:     string,
	on_select: proc() -> Msg,
	id:        Widget_ID = 0,
	font_size: f32   = 0,
	box_size:  f32   = 0,
	color_bg:  Color = {},
	color_dot: Color = {},
	disabled: bool  = false,
) -> View {
	view, fired := _radio_impl(
		ctx, selected, label,
		id = id, font_size = font_size, box_size = box_size,
		color_bg = color_bg, color_dot = color_dot, disabled = disabled,
	)
	if fired { send(ctx, on_select()) }
	return view
}

radio_payload :: proc(
	ctx:       ^Ctx($Msg),
	selected:  bool,
	label:     string,
	payload:   $Payload,
	on_select: proc(payload: Payload) -> Msg,
	id:        Widget_ID = 0,
	font_size: f32   = 0,
	box_size:  f32   = 0,
	color_bg:  Color = {},
	color_dot: Color = {},
	disabled: bool  = false,
) -> View {
	view, fired := _radio_impl(
		ctx, selected, label,
		id = id, font_size = font_size, box_size = box_size,
		color_bg = color_bg, color_dot = color_dot, disabled = disabled,
	)
	if fired { send(ctx, on_select(payload)) }
	return view
}

// radio_group renders a slice of string labels as radios laid out
// along the given direction (vertical by default). `selected` is the
// currently-selected option's index; `on_change` is fired with the new
// index when the user picks a different option via click, Space, or
// arrow-key navigation between group members.
//
// Arrow-key nav: when any radio in the group has focus, Up / Down
// (Column direction) or Left / Right (Row direction) moves selection
// to the previous / next option and transfers focus to that radio in
// the same frame so the focus ring follows the selection. The nav
// wraps — moving past the last option lands on the first, which
// matches how native radio groups behave on Windows / GTK / macOS.
//
//     Msg :: union { Theme_Changed: int, ... }
//     on_theme :: proc(i: int) -> Msg { return Theme_Changed(i) }
//     skald.radio_group(ctx, []string{"Dark", "Light", "High-Contrast"},
//         state.theme_idx, on_theme)
//
// For non-string options (enums, structs), build the radios yourself
// with individual `radio` calls — `radio_group` is the batteries-included
// convenience for the common string-label case.
radio_group :: proc{radio_group_simple, radio_group_payload}

@(private)
_radio_group_impl :: proc(
	ctx:       ^Ctx($Msg),
	options:   []string,
	selected:  int,
	msgs:      []Msg,
	id:        Widget_ID       = 0,
	direction: Stack_Direction = .Column,
	spacing:   f32             = -1, // -1 means use theme default
	disabled:  bool            = false,
) -> View {
	th := ctx.theme
	sp := spacing
	if sp < 0 { sp = th.spacing.xs }

	// Stable base id for the group so the per-option ids survive a
	// caller re-order of surrounding widgets. Child ids hang off the
	// base via `hash_id` with a per-index suffix.
	base_id := widget_resolve_id(ctx, id)

	children := make([]View, len(options), context.temp_allocator)

	// Per-option id scheme: FNV-mix the group's base id with the
	// option index so the radio's Widget_State survives even if the
	// caller re-orders other widgets around the group. Using an
	// explicit id here (instead of positional auto-id) lets us refer
	// to a sibling's id from the arrow-key handler below.
	opt_ids := make([]Widget_ID, len(options), context.temp_allocator)
	for _, i in options {
		key := fmt.tprintf("radio-group-%d-opt-%d", base_id, i)
		opt_ids[i] = hash_id(key)
	}

	// Arrow-key nav. Run this *before* building the child radios so
	// the on_change msg and focus move land on the same frame as the
	// keypress — otherwise the selection ring would lag one frame
	// behind the focus ring. Read-only groups skip this entirely since
	// their options aren't focusable.
	focused_idx := -1
	if !disabled {
		for _, i in options {
			if widget_has_focus(ctx, opt_ids[i]) { focused_idx = i; break }
		}
	}
	if focused_idx >= 0 && len(options) > 1 {
		prev_key, next_key: Key
		if direction == .Column {
			prev_key, next_key = .Up, .Down
		} else {
			prev_key, next_key = .Left, .Right
		}
		delta := 0
		if prev_key in ctx.input.keys_pressed { delta = -1 }
		if next_key in ctx.input.keys_pressed { delta = +1 }
		if delta != 0 {
			new_idx := (focused_idx + delta + len(options)) %% len(options)
			if new_idx != selected { send(ctx, msgs[new_idx]) }
			widget_focus(ctx, opt_ids[new_idx])
		}
	}

	// Build the radios. Each on_select closure needs the option's
	// index baked in; Odin procs don't capture, so we synthesize a
	// per-index proc via a small thunk. We can't actually do that
	// without capturing either, so instead the builder fires
	// on_change(i) directly on click by short-circuiting the radio's
	// on_select — we pass a nil on_select and handle activation here.
	//
	// Simpler compromise: call radio() with on_select = nil for the
	// Msg type, then detect clicks via widget_get on the radio's id.
	// That avoids the closure problem at the cost of mirroring the
	// radio's click logic here. Keep it — the duplication is small.
	for opt, i in options {
		children[i] = radio_group_option(ctx, opt_ids[i],
			opt, i == selected, msgs[i], disabled)
	}

	if direction == .Column {
		return col(..children, spacing = sp)
	}
	return row(..children, spacing = sp)
}

// radio_group_option builds one radio inside a radio_group. Split out
// so the outer `radio_group` stays focused on layout + arrow-key nav
// while this handles the per-option click / Space activation. The
// caller pre-computes the activation Msg (via on_change(index) or
// on_change(payload, index) depending on which proc-group variant is
// in use), letting this helper stay agnostic of callback shape.
@(private)
radio_group_option :: proc(
	ctx:       ^Ctx($Msg),
	opt_id:    Widget_ID,
	label:     string,
	selected:  bool,
	msg:       Msg,
	disabled: bool,
) -> View {
	th := ctx.theme
	fs := th.font.size_md
	bs := fs + 4

	if !disabled { widget_make_focusable(ctx, opt_id) }
	st := widget_get(ctx, opt_id, .Radio)
	focused := !disabled && widget_has_focus(ctx, opt_id)
	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	if !disabled {
		if ctx.input.mouse_pressed[.Left] && hovered {
			st.pressed = true
			widget_focus(ctx, opt_id)
			focused = true
		}
		if ctx.input.mouse_released[.Left] {
			if st.pressed && hovered && !selected { send(ctx, msg) }
			st.pressed = false
		}
		if !ctx.input.mouse_buttons[.Left] { st.pressed = false }
		if focused && !selected && .Space in ctx.input.keys_pressed {
			send(ctx, msg)
		}
	} else {
		st.pressed = false
	}

	widget_set(ctx, opt_id, st)

	dot := th.color.primary
	fg  := th.color.fg
	if disabled { dot = th.color.fg_muted; fg = th.color.fg_muted }

	return View_Radio{
		id           = opt_id,
		selected     = selected,
		label        = label,
		color_bg     = th.color.surface,
		color_dot    = dot,
		color_border = th.color.border,
		color_focus  = focus_ring_for(th^, th.color.surface),
		color_fg     = fg,
		font_size    = fs,
		box_size     = bs,
		gap          = th.spacing.sm,
		hover        = hovered,
		pressed      = st.pressed,
		focused      = focused,
	}
}

radio_group_simple :: proc(
	ctx:       ^Ctx($Msg),
	options:   []string,
	selected:  int,
	on_change: proc(index: int) -> Msg,
	id:        Widget_ID       = 0,
	direction: Stack_Direction = .Column,
	spacing:   f32             = -1,
	disabled:  bool            = false,
) -> View {
	msgs := make([]Msg, len(options), context.temp_allocator)
	for i in 0..<len(options) { msgs[i] = on_change(i) }
	return _radio_group_impl(
		ctx, options, selected, msgs,
		direction = direction, spacing = spacing, id = id, disabled = disabled,
	)
}

radio_group_payload :: proc(
	ctx:       ^Ctx($Msg),
	options:   []string,
	selected:  int,
	payload:   $Payload,
	on_change: proc(payload: Payload, index: int) -> Msg,
	id:        Widget_ID       = 0,
	direction: Stack_Direction = .Column,
	spacing:   f32             = -1,
	disabled:  bool            = false,
) -> View {
	msgs := make([]Msg, len(options), context.temp_allocator)
	for i in 0..<len(options) { msgs[i] = on_change(payload, i) }
	return _radio_group_impl(
		ctx, options, selected, msgs,
		direction = direction, spacing = spacing, id = id, disabled = disabled,
	)
}

// toggle builds an iOS-style pill switch — bool state, same semantics
// as `checkbox`, but drawn as a track + sliding knob instead of a
// square with a ✓. Reach for this when the change should read as
// applying immediately (setting, preference, feature flag); reach for
// `checkbox` when the change should read as "stage a choice, commit
// on OK". Input model matches checkbox: click or Space toggles, Tab
// moves focus, focus ring draws around the track.
//
//     Msg :: union { Wifi_Toggled, ... }
//     on_wifi :: proc(v: bool) -> Msg { return Wifi_Toggled(v) }
//     skald.toggle(ctx, state.wifi, "Wi-Fi", on_wifi)
toggle :: proc{toggle_simple, toggle_payload}

@(private)
_toggle_impl :: proc(
	ctx:       ^Ctx($Msg),
	on:        bool,
	label:     string,
	id:        Widget_ID = 0,
	font_size: f32   = 0,
	track_w:   f32   = 0,
	track_h:   f32   = 0,
	color_off: Color = {},
	color_on:  Color = {},
	color_knob: Color = {},
	disabled: bool  = false,
) -> (view: View, new_value: bool, changed: bool) {
	th := ctx.theme

	fs := font_size; if fs == 0 { fs = th.font.size_md }
	// Default dimensions: track wide enough for the knob to travel a
	// visibly meaningful distance — 2x height on track width reads as
	// a clear pill rather than a near-circle.
	th_size := track_h; if th_size == 0 { th_size = fs + 4 }
	tw      := track_w; if tw == 0      { tw      = th_size * 1.9 }

	coff  := color_off;  if coff[3]  == 0 { coff = track_color_for(th^) }
	con   := color_on;   if con[3]   == 0 { con   = th.color.primary }
	cknob := color_knob; if cknob[3] == 0 { cknob = th.color.on_primary }
	// Read-only swaps the "on" fill to muted so the knob position still
	// reads but the accent doesn't compete with live toggles on-screen.
	if disabled { con = th.color.fg_muted }
	fg_c := th.color.fg
	if disabled { fg_c = th.color.fg_muted }

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Toggle)
	focused := !disabled && widget_has_focus(ctx, id)
	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	if !disabled {
		if ctx.input.mouse_pressed[.Left] && hovered {
			st.pressed = true
			widget_focus(ctx, id)
			focused = true
		}
		if ctx.input.mouse_released[.Left] {
			if st.pressed && hovered {
				new_value, changed = !on, true
			}
			st.pressed = false
		}
		if !ctx.input.mouse_buttons[.Left] { st.pressed = false }
		if focused && .Space in ctx.input.keys_pressed {
			new_value, changed = !on, true
		}
	} else {
		st.pressed = false
	}

	widget_set(ctx, id, st)

	view = View_Toggle{
		id          = id,
		on          = on,
		label       = label,
		color_off   = coff,
		color_on    = con,
		color_knob  = cknob,
		// "On" track is primary; ring would vanish on blue-on-blue
		// when the toggle is on + focused without focus_ring_for.
		color_focus = focus_ring_for(th^, con),
		color_fg    = fg_c,
		font_size   = fs,
		track_w     = tw,
		track_h     = th_size,
		knob_pad    = 2,
		gap         = th.spacing.sm,
		hover       = hovered,
		pressed     = st.pressed,
		focused     = focused,
	}
	return
}

toggle_simple :: proc(
	ctx:       ^Ctx($Msg),
	on:        bool,
	label:     string,
	on_change: proc(new_value: bool) -> Msg,
	id:        Widget_ID = 0,
	font_size: f32   = 0,
	track_w:   f32   = 0,
	track_h:   f32   = 0,
	color_off: Color = {},
	color_on:  Color = {},
	color_knob: Color = {},
	disabled: bool  = false,
) -> View {
	view, new_value, changed := _toggle_impl(
		ctx, on, label,
		id = id, font_size = font_size, track_w = track_w, track_h = track_h,
		color_off = color_off, color_on = color_on, color_knob = color_knob,
		disabled = disabled,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

toggle_payload :: proc(
	ctx:       ^Ctx($Msg),
	on:        bool,
	label:     string,
	payload:   $Payload,
	on_change: proc(payload: Payload, new_value: bool) -> Msg,
	id:        Widget_ID = 0,
	font_size: f32   = 0,
	track_w:   f32   = 0,
	track_h:   f32   = 0,
	color_off: Color = {},
	color_on:  Color = {},
	color_knob: Color = {},
	disabled: bool  = false,
) -> View {
	view, new_value, changed := _toggle_impl(
		ctx, on, label,
		id = id, font_size = font_size, track_w = track_w, track_h = track_h,
		color_off = color_off, color_on = color_on, color_knob = color_knob,
		disabled = disabled,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// slider builds a horizontal draggable value control. `min` / `max` bound
// the output; `step` (when > 0) quantizes it. The drag model follows the
// native toolkit convention: grabbing the thumb or track latches a drag
// that follows the mouse until release, even if the pointer strays off
// the widget.
//
//     Msg :: union { Volume_Changed: f32, ... }
//     on_volume :: proc(v: f32) -> Msg { return Volume_Changed(v) }
//     skald.slider(ctx, state.volume, on_volume, min_value = 0, max_value = 100, step = 1, width = 220)
slider :: proc{slider_simple, slider_payload}

@(private)
_slider_impl :: proc(
	ctx:       ^Ctx($Msg),
	value:     f32,
	id:        Widget_ID = 0,
	min_value: f32   = 0,
	max_value: f32   = 1,
	step:      f32   = 0,
	width:     f32   = 0,
	track_h:   f32   = 4,
	thumb_r:   f32   = 8,
	disabled: bool  = false,
) -> (view: View, new_value: f32, changed: bool) {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Slider)
	focused := !disabled && widget_has_focus(ctx, id)
	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	// Start a drag on press-inside; hold it regardless of hover until the
	// button is released. Mirrors how every OS-level slider behaves so
	// "drag past the edge" doesn't strand the thumb. Read-only sliders
	// skip drag + key nudges entirely — the thumb still renders at the
	// value position so the widget functions as a visual gauge.
	if !disabled && ctx.input.mouse_pressed[.Left] && hovered {
		st.pressed = true
		widget_focus(ctx, id)
		focused = true
	}
	if !ctx.input.mouse_buttons[.Left]           { st.pressed = false }

	new_value = value
	if !disabled && st.pressed && st.last_rect.w > 0 {
		// Horizontal mapping inside the interior (stripped of the thumb
		// radius so the thumb center can reach the track's visual edges).
		r      := st.last_rect
		inset  := thumb_r
		usable := r.w - 2 * inset
		if usable <= 0 { usable = 1 }
		raw := (ctx.input.mouse_pos.x - (r.x + inset)) / usable
		if raw < 0 { raw = 0 }
		if raw > 1 { raw = 1 }
		new_value = min_value + raw * (max_value - min_value)
		if step > 0 {
			// Round to nearest step, anchored at `min_value` so step=1 gives
			// exact integers when min_value is an integer.
			n := (new_value - min_value) / step
			if n >= 0 { n += 0.5 } else { n -= 0.5 }
			new_value = min_value + f32(int(n)) * step
			if new_value < min_value { new_value = min_value }
			if new_value > max_value { new_value = max_value }
		}
	}

	// Keyboard adjustment: Left/Right nudge by `step` (or 5% of the
	// range when step=0). Matches the OS convention of "arrow keys
	// nudge, Page keys jump big." Page_Up/Page_Down cover the 10× case.
	if focused && !disabled {
		keys := ctx.input.keys_pressed
		span := max_value - min_value
		nudge := step
		if nudge == 0 { nudge = span * 0.05 }
		big := nudge * 10
		if .Left      in keys { new_value -= nudge     }
		if .Right     in keys { new_value += nudge     }
		if .Page_Up   in keys { new_value += big       }
		if .Page_Down in keys { new_value -= big       }
		if .Home      in keys { new_value  = min_value }
		if .End       in keys { new_value  = max_value }
		if new_value < min_value { new_value = min_value }
		if new_value > max_value { new_value = max_value }
	}

	widget_set(ctx, id, st)

	changed = new_value != value

	fill  := th.color.primary
	thumb := th.color.on_primary
	if disabled { fill = th.color.fg_muted; thumb = th.color.fg_muted }

	view = View_Slider{
		id          = id,
		value       = new_value,
		min_value   = min_value,
		max_value   = max_value,
		color_track = track_color_for(th^),
		color_fill  = fill,
		color_thumb = thumb,
		// Slider thumb is primary-filled; focus ring is a halo
		// around the thumb so blue-on-blue needs on_primary.
		color_focus = focus_ring_for(th^, fill),
		track_h     = track_h,
		thumb_r     = thumb_r,
		width       = width,
		height      = thumb_r * 2 + 4,
		dragging    = st.pressed,
		focused     = focused,
	}
	return
}

slider_simple :: proc(
	ctx:       ^Ctx($Msg),
	value:     f32,
	on_change: proc(new_value: f32) -> Msg,
	id:        Widget_ID = 0,
	min_value: f32   = 0,
	max_value: f32   = 1,
	step:      f32   = 0,
	width:     f32   = 0,
	track_h:   f32   = 4,
	thumb_r:   f32   = 8,
	disabled: bool  = false,
) -> View {
	view, new_value, changed := _slider_impl(
		ctx, value,
		id = id, min_value = min_value, max_value = max_value, step = step,
		width = width, track_h = track_h, thumb_r = thumb_r, disabled = disabled,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

slider_payload :: proc(
	ctx:       ^Ctx($Msg),
	value:     f32,
	payload:   $Payload,
	on_change: proc(payload: Payload, new_value: f32) -> Msg,
	id:        Widget_ID = 0,
	min_value: f32   = 0,
	max_value: f32   = 1,
	step:      f32   = 0,
	width:     f32   = 0,
	track_h:   f32   = 4,
	thumb_r:   f32   = 8,
	disabled: bool  = false,
) -> View {
	view, new_value, changed := _slider_impl(
		ctx, value,
		id = id, min_value = min_value, max_value = max_value, step = step,
		width = width, track_h = track_h, thumb_r = thumb_r, disabled = disabled,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// progress builds a non-interactive [0, 1] fill indicator. Pass `width = 0`
// to stretch across the assigned cross-axis of the parent stack (same
// convention as `rect`).
//
// Pass `indeterminate = true` for a "work in progress, no known ETA"
// animation: a chip sweeps left-to-right across the bar on a loop. `value`
// is ignored in that mode. The animation is a pure function of wall-clock
// time, so it stays smooth even when state is unchanged — the framework's
// loop redraws every frame.
//
// `period` is the sweep time in seconds; bump it if the chip feels frantic.
progress :: proc(
	ctx:           ^Ctx($Msg),
	value:         f32,
	width:         f32   = 0,
	height:        f32   = 6,
	color_bg:      Color = {},
	color_fill:    Color = {},
	indeterminate: bool  = false,
	period:        f32   = 1.2,
) -> View {
	th := ctx.theme
	cbg   := color_bg;   if cbg[3]   == 0 { cbg = track_color_for(th^) }
	cfill := color_fill; if cfill[3] == 0 { cfill = th.color.primary }
	chip:     f32 = 0
	chip_pos: f32 = 0
	if indeterminate {
		chip = 0.3
		period_s := period; if period_s <= 0 { period_s = 1.2 }
		// Keep the modulo in i64 nanoseconds — f32 only has 24 mantissa
		// bits, so converting `time.now()._nsec` to f32 up front loses
		// the low digits and the phase pins at a constant value.
		period_ns := i64(f64(period_s) * f64(time.Second))
		if period_ns < 1 { period_ns = 1 }
		now_ns := time.now()._nsec
		phase_ns := now_ns % period_ns
		phase := f32(phase_ns) / f32(period_ns)
		chip_pos = phase * (1 + chip) - chip
		// Continuous animation — ask for the next frame ~60 Hz so lazy
		// redraw keeps the chip moving smoothly.
		widget_request_frame_at(ctx, now_ns + i64(time.Millisecond) * 16)
	}
	return View_Progress{
		value      = value,
		color_bg   = cbg,
		color_fill = cfill,
		radius     = height / 2,
		width      = width,
		height     = height,
		chip       = chip,
		chip_pos   = chip_pos,
	}
}

// spinner renders a circular indeterminate progress affordance — eight
// dots in a ring, alpha trailing around the circle. Use for "working,
// no known ETA" feedback: data loading, background saves, anything
// without a measurable progress value.
//
//     skald.spinner(ctx, size = 24)
//
// Reads wall-clock time each frame and schedules the next render via
// `widget_request_frame_at` so lazy redraw keeps the animation running.
// Apps that want a linear bar instead should use `progress(indeterminate = true)`.
spinner :: proc(
	ctx:       ^Ctx($Msg),
	size:      f32   = 24,
	color:     Color = {},
	period_ms: int   = 900,
) -> View {
	th := ctx.theme
	c := color; if c[3] == 0 { c = th.color.primary }
	period_ns := i64(period_ms) * i64(time.Millisecond)
	if period_ns < 1 { period_ns = 1 }
	now_ns := time.now()._nsec
	phase  := f32(now_ns % period_ns) / f32(period_ns)

	// Drive the next frame at ~60 Hz so the ring spins smoothly.
	widget_request_frame_at(ctx, now_ns + i64(time.Millisecond) * 16)

	return View_Spinner{size = size, color = c, phase = phase}
}

// select builds a dropdown (combo box): a button-style trigger that
// shows the current value, plus an overlay of option rows the user
// picks from when the dropdown is open. Emits `on_change(option)` on
// selection.
//
//     Msg :: union { Theme_Changed: string, ... }
//     on_theme :: proc(v: string) -> Msg { return Theme_Changed(v) }
//     skald.select(ctx, state.theme, {"Light", "Dark", "High-Contrast"}, on_theme)
//
// Behavior:
//   * Click the trigger or press Space / Enter while focused → toggle open.
//   * Click an option → emit `on_change(option)`, close.
//   * Click outside trigger and overlay → close.
//   * Escape while focused → close.
//
// Known limitation: the option rows are stateful widgets built only
// when the dropdown is open, so opening/closing reshuffles positional
// Widget_IDs for siblings that come after. Place the select near the
// end of the view tree until explicit Widget_IDs land (Phase 5.6).
select :: proc{select_simple, select_payload}

@(private)
_select_impl :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	options:     []string,
	option_msgs: []Msg,        // pre-computed click Msg per option
	id:          Widget_ID = 0,
	width:       f32    = 0,
	placeholder: string = "",
	disabled:   bool   = false,
) -> View {
	th := ctx.theme
	placeholder := placeholder
	if len(placeholder) == 0 { placeholder = ctx.labels.select_placeholder }

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Select)
	focused := !disabled && widget_has_focus(ctx, id)

	// A read-only select renders the trigger only. Force any previously-
	// open overlay shut so toggling the flag on at runtime immediately
	// collapses the menu, and skip the interaction/overlay pipeline below.
	if disabled { st.open = false }
	// If a modal dialog is open and this widget sits outside its card,
	// force-close any in-progress popover. A stranded dropdown peeking
	// out from under a dialog reads as a bug, and input gates can't
	// reach it anyway.
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, st.last_rect) {
		st.open = false
	}

	trigger_rect := st.last_rect
	trigger_hovered := !disabled && rect_hovered(ctx, trigger_rect)

	// Predict the overlay rect so outside-click dismiss has something
	// to hit-test. Option rows are button-sized and sit flush against
	// each other (native dropdown convention — hover highlight is the
	// only row separator needed); the overlay sits 4 px under the
	// trigger. Add a 1-px hairline border layer + 4 px inner pad so
	// the menu reads as a raised card, not a color-matched panel.
	opt_h        := th.font.size_md + 2 * th.spacing.sm + 6
	option_gap   := f32(0)
	overlay_pad  := f32(4)
	BORDER_W     := f32(1)
	overlay_h    := 2 * (overlay_pad + BORDER_W) + f32(len(options)) * opt_h
	if len(options) > 1 {
		overlay_h += option_gap * f32(len(options) - 1)
	}
	overlay_w := trigger_rect.w if trigger_rect.w > 0 else width
	overlay_rect := overlay_placement_rect(ctx, trigger_rect,
		{overlay_w, overlay_h}, .Below, {0, 4})
	mouse_over_overlay := rect_contains_point(overlay_rect, ctx.input.mouse_pos)
	if st.open { widget_stamp_overlay_rect(ctx.widgets, overlay_rect) }

	// Trigger toggle on press. Outside-click dismiss also fires on press
	// (not release) so the overlay vanishes as soon as the user commits
	// to clicking somewhere else in the UI.
	if !disabled && ctx.input.mouse_pressed[.Left] {
		if trigger_hovered {
			st.open = !st.open
			widget_focus(ctx, id)
			focused = true
		} else if st.open && !mouse_over_overlay {
			st.open = false
		}
	}

	if focused && !disabled {
		keys := ctx.input.keys_pressed
		if .Space in keys || .Enter in keys { st.open = !st.open }
		if .Escape in keys                  { st.open = false   }
	}

	// Close on release inside the overlay is *deferred* until after the
	// option rows build this frame. The option row is a button that fires
	// on_click on release; if we closed first we'd skip the row's builder
	// and lose the selection.
	close_after_build := st.open && ctx.input.mouse_released[.Left] && mouse_over_overlay

	fg_c := th.color.fg
	if disabled { fg_c = th.color.fg_muted }

	if !st.open {
		// Reset fade state so the next open fades in from 0 again. No
		// frame wake needed — lazy redraw is idle until the user reopens.
		st.anim_t = 0
		st.anim_prev_ns = 0
		widget_set(ctx, id, st)
		return View_Select{
			id                = id,
			value             = value,
			placeholder       = placeholder,
			color_bg          = th.color.surface,
			color_fg          = fg_c,
			color_placeholder = th.color.fg_muted,
			color_border      = th.color.border,
			color_focus       = focus_ring_for(th^, th.color.surface),
			color_caret       = th.color.fg_muted,
			radius            = th.radius.sm,
			padding           = {th.spacing.md, th.spacing.sm},
			font_size         = th.font.size_md,
			width             = width,
			open              = false,
			hover             = trigger_hovered,
			focused           = focused,
		}
	}

	// Fade-in opacity for the popover. Close is instant for select
	// because `close_after_build` needs the option-click to land on
	// the same frame the popover disappears — a decaying overlay
	// during that one-frame handoff would make the option button
	// hit-testable twice.
	anim_op := widget_anim_step(ctx, &st, 1, 0.12)

	// Options list. Each row is a themed button that emits
	// `on_change(option)` on release. Unselected rows render on the
	// elevated bg (their color is inherited from the bg); selected
	// rows pick up the theme's translucent primary tint.
	//
	// The option-rows are wrapped in a per-select widget scope so the
	// auto-id counter they consume doesn't pollute the parent counter.
	// Without this, opening the popover (which spawns N option-row
	// buttons into the view tree) shifts every auto-id past the select
	// — e.g. a sibling dialog rendered after the select would get a
	// different id on open vs closed frames, its widget_get would
	// return a fresh state on the open frame, and its closed→open
	// sweep would fire and immediately kill the just-opened popover.
	scope := widget_scope_push(ctx, u64(id))
	rows := make([dynamic]View, 0, len(options), context.temp_allocator)
	for opt, i in options {
		is_selected := opt == value
		row_bg := th.color.elevated
		if is_selected { row_bg = th.color.selection }
		append(&rows, select_option_row(ctx, opt, option_msgs[i], row_bg, th))
	}
	widget_scope_pop(ctx, scope)

	// Two-layer card: outer border-colored rect lays down the hairline,
	// inner elevated rect leaves 1 px of border showing. Matches the
	// menu popover convention so the two readers feel native.
	inner := col(..rows[:],
		spacing     = option_gap,
		padding     = overlay_pad,
		width       = overlay_w - 2 * BORDER_W,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)
	list := col(
		inner,
		padding     = BORDER_W,
		width       = overlay_w,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)

	// Consume any press/release that landed inside our popover so sibling
	// widgets built *after* us don't also react. The popover is drawn on
	// top, so widgets underneath it shouldn't see the click. Without
	// this, a later select whose trigger's geometric rect sits inside
	// our popover would open spuriously on every click into the popover.
	// Option rows above have already observed the press/release, so
	// clearing now only affects downstream widgets.
	if ctx.input.mouse_pressed[.Left] && mouse_over_overlay {
		ctx.input.mouse_pressed[.Left] = false
	}
	if ctx.input.mouse_released[.Left] && mouse_over_overlay {
		ctx.input.mouse_released[.Left] = false
	}

	if close_after_build {
		st.open = false
		// Restore focus to the select itself. Without this, the option
		// button that fired on_change leaves focused_id pointing at an
		// auto-id that no longer exists this frame — and next frame
		// whichever sibling widget inherits that same auto-id (the
		// widget built right after the select in the tree) thinks it's
		// focused. Classic transient-id collision.
		widget_focus(ctx, id)
	}
	widget_set(ctx, id, st)

	trigger := View_Select{
		id                = id,
		value             = value,
		placeholder       = placeholder,
		color_bg          = th.color.surface,
		color_fg          = th.color.fg,
		color_placeholder = th.color.fg_muted,
		color_border      = th.color.border,
		color_focus       = focus_ring_for(th^, th.color.surface),
		color_caret       = th.color.fg_muted,
		radius            = th.radius.sm,
		padding           = {th.spacing.md, th.spacing.sm},
		font_size         = th.font.size_md,
		width             = width,
		open              = st.open,
		hover             = trigger_hovered,
		focused           = focused,
	}

	// If the deferred release just closed us, omit the overlay this
	// frame — options already fired on_click, so the popover disappearing
	// immediately is the desired end state.
	if !st.open { return trigger }

	// Returned as a stack so the overlay sits alongside the trigger in
	// the parent layout with zero impact on sibling placement (the
	// overlay contributes 0 size, and we clamp the stack's cross extent
	// to the trigger's width so the col doesn't stretch vertically).
	return col(
		trigger,
		overlay(trigger_rect, list, .Below, {0, 4}, anim_op),
	)
}

select_simple :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	options:     []string,
	on_change:   proc(new_value: string) -> Msg,
	id:          Widget_ID = 0,
	width:       f32    = 0,
	placeholder: string = "",
	disabled:   bool   = false,
) -> View {
	msgs := make([]Msg, len(options), context.temp_allocator)
	for opt, i in options { msgs[i] = on_change(opt) }
	return _select_impl(ctx, value, options, msgs,
		id = id, width = width, placeholder = placeholder, disabled = disabled)
}

select_payload :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	options:     []string,
	payload:     $Payload,
	on_change:   proc(payload: Payload, new_value: string) -> Msg,
	id:          Widget_ID = 0,
	width:       f32    = 0,
	placeholder: string = "",
	disabled:   bool   = false,
) -> View {
	msgs := make([]Msg, len(options), context.temp_allocator)
	for opt, i in options { msgs[i] = on_change(payload, opt) }
	return _select_impl(ctx, value, options, msgs,
		id = id, width = width, placeholder = placeholder, disabled = disabled)
}

// combobox is `select`'s typeable cousin: a text trigger with a
// dropdown that lists the `options`. Typing filters the visible list
// (by default); arrow-keys move the highlight; Enter / click commits.
// Use `select` when no typing is wanted; reach for `combobox` when the
// list is long enough that scanning is slower than typing.
//
//     Msg :: union { Language_Chosen: string, … }
//     on_lang :: proc(s: string) -> Msg { return Language_Chosen(s) }
//
//     skald.combobox(ctx,
//         s.language,
//         {"English", "Español", "Français", "Deutsch", "日本語", …},
//         on_lang,
//         width = 240,
//     )
//
// Flags:
//
// `filter = true` (default) — typing narrows the dropdown to options
// whose label contains the typed substring (case-insensitive). Classic
// "searchable select."
//
// `filter = false` — full list stays visible; typing jumps the
// highlight to the first option starting with the typed prefix.
// Windows-style typeahead, occasionally preferred for short lists.
//
// `free_form = false` (default) — Enter commits the highlighted option.
// If nothing matches, Enter is a no-op (caller never sees an off-list
// value).
//
// `free_form = true` — Enter commits *whatever the user typed* even if
// it isn't in the options list. Use for email / tag entry with
// suggestions, or any "I know what I want, suggestions are a helper"
// shape.
//
// Escape cancels (clears the draft, blurs, leaves `value` unchanged).
// Clicking outside the trigger-or-dropdown also dismisses without
// committing. Max input length follows `max_chars` the same way
// `text_input` does.
combobox :: proc{combobox_simple, combobox_payload}

@(private)
_combobox_impl :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	options:     []string,
	id:          Widget_ID = 0,
	width:       f32       = 0,
	placeholder: string    = "",
	filter:      bool      = true,
	free_form:   bool      = false,
	disabled:   bool      = false,
	max_chars:   int       = 0,
) -> (view: View, new_value: string, changed: bool) {
	th := ctx.theme
	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Combobox)
	focused := !disabled && widget_has_focus(ctx, id)

	if disabled { st.open = false }
	// If a modal dialog is open and this widget sits outside its card,
	// force-close any in-progress popover. A stranded dropdown peeking
	// out from under a dialog reads as a bug, and input gates can't
	// reach it anyway.
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, st.last_rect) {
		st.open = false
	}

	// Focus-edge: open the popover with an empty draft so the dropdown
	// shows *all* options on first click. Seeding the draft with `value`
	// instead would filter the list down to a single matching row, which
	// (a) hides the other options the user probably wanted to scan, and
	// (b) flashes: one frame shows all rows (empty buffer from last
	// close), the next frame filters to one (buffer just got seeded).
	// The displayed trigger text falls back to `value` when `draft` is
	// empty, so the field still reads as populated. Blur clears both.
	if focused && !st.was_focused {
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
		st.text_buffer = ""
		st.cursor_pos  = 0
		st.open        = true
		st.drag_donor  = 0 // highlight index stored here
	}
	if !focused && len(st.text_buffer) > 0 {
		delete(st.text_buffer)
		st.text_buffer = ""
		st.cursor_pos  = 0
		st.open        = false
		st.drag_donor  = 0
	}
	st.was_focused = focused

	draft  := st.text_buffer
	cursor := clamp(st.cursor_pos, 0, len(draft))

	// Filtered option indices. With `filter = true`, case-insensitive
	// substring match narrows the list as the user types; otherwise the
	// full list stays visible and typing just steers the highlight.
	visible := make([dynamic]int, 0, len(options), context.temp_allocator)
	if filter && len(draft) > 0 {
		lower_draft := strings.to_lower(draft, context.temp_allocator)
		for opt, i in options {
			lower_opt := strings.to_lower(opt, context.temp_allocator)
			if strings.contains(lower_opt, lower_draft) {
				append(&visible, i)
			}
		}
	} else {
		for _, i in options { append(&visible, i) }
	}

	// Popover geometry (capped at 8 rows for reasonable height).
	trigger_rect    := st.last_rect
	trigger_hovered := !disabled && rect_hovered(ctx, trigger_rect)

	fs    := th.font.size_md
	pad_x := th.spacing.md
	pad_y := th.spacing.sm
	tr_h  := fs + 2*pad_y + 6
	tr_w  := width
	if tr_w <= 0 { tr_w = 220 }

	opt_h       := fs + 2 * th.spacing.sm + 6
	overlay_pad := f32(4)
	BORDER_W    := f32(1)
	visible_max := min(len(visible), 8)
	overlay_h   := 2*(overlay_pad + BORDER_W) + f32(visible_max) * opt_h
	overlay_w   := trigger_rect.w if trigger_rect.w > 0 else tr_w
	// Only compute an overlay rect (and therefore a mouse_over_overlay
	// hit-test) when the popover is actually open. A closed combobox
	// would otherwise eat clicks whose target sits inside the *phantom*
	// below-trigger strip that the overlay would occupy — blocking
	// widgets stacked below (e.g. the Date picker trigger) from
	// receiving their own clicks.
	overlay_rect: Rect
	mouse_over_overlay: bool
	if st.open {
		overlay_rect = overlay_placement_rect(ctx, trigger_rect,
			{overlay_w, overlay_h}, .Below, {0, 4})
		mouse_over_overlay = rect_contains_point(overlay_rect, ctx.input.mouse_pos)
		widget_stamp_overlay_rect(ctx.widgets, overlay_rect)
	}

	// Trigger click: focus + open. Outside click: blur + close.
	// Seed the draft inline on focus-enter so the field doesn't flash
	// empty for one frame (the edge-detector below only fires on the
	// *next* frame, by which time the user has already seen a blank
	// trigger — not a great first impression).
	if !disabled && ctx.input.mouse_pressed[.Left] {
		if trigger_hovered {
			if !focused {
				if len(st.text_buffer) > 0 { delete(st.text_buffer) }
				st.text_buffer = strings.clone(value)
				st.cursor_pos  = len(st.text_buffer)
				st.drag_donor  = 0
				draft  = st.text_buffer
				cursor = st.cursor_pos
			}
			widget_focus(ctx, id)
			focused  = true
			st.open  = true
		} else if st.open && !mouse_over_overlay {
			widget_focus(ctx, 0)
			focused = false
			st.open = false
		}
	}

	highlight := clamp(int(st.drag_donor), 0, max(0, len(visible) - 1))

	if focused && !disabled {
		ctx.widgets.wants_text_input = true
		keys := ctx.input.keys_pressed

		// Character insertion — any printable ASCII for v1. No special
		// filter like number_input; the app's options list is what
		// narrows semantics.
		if len(ctx.input.text) > 0 {
			for i := 0; i < len(ctx.input.text); i += 1 {
				if max_chars > 0 && utf8.rune_count_in_string(draft) >= max_chars { break }
				ch := ctx.input.text[i]
				if ch >= 0x20 && ch != 0x7f {
					draft  = string_insert_at(draft, cursor, ctx.input.text[i:i+1])
					cursor += 1
				}
			}
			st.open   = true
			highlight = 0
		}

		if .Backspace in keys && cursor > 0 {
			draft = strings.concatenate({draft[:cursor-1], draft[cursor:]},
				context.temp_allocator)
			cursor  -= 1
			st.open  = true
			highlight = 0
		}
		if .Delete in keys && cursor < len(draft) {
			draft = strings.concatenate({draft[:cursor], draft[cursor+1:]},
				context.temp_allocator)
			st.open = true
		}
		if .Left  in keys && cursor > 0          { cursor -= 1 }
		if .Right in keys && cursor < len(draft) { cursor += 1 }
		if .Home  in keys                        { cursor = 0 }
		if .End   in keys                        { cursor = len(draft) }

		if .Down in keys && len(visible) > 0 {
			highlight = (highlight + 1) %% len(visible)
			st.open   = true
		}
		if .Up in keys && len(visible) > 0 {
			highlight = (highlight - 1 + len(visible)) %% len(visible)
			st.open   = true
		}

		if .Enter in keys {
			if len(visible) > 0 {
				new_value, changed = options[visible[highlight]], true
				widget_focus(ctx, 0)
				focused  = false
				st.open  = false
			} else if free_form {
				new_value, changed = strings.clone(draft, context.temp_allocator), true
				widget_focus(ctx, 0)
				focused  = false
				st.open  = false
			}
		}
		if .Escape in keys {
			widget_focus(ctx, 0)
			focused  = false
			st.open  = false
		}
	}

	// Mouse-hover tracks the highlighted option so the focus ring follows
	// the cursor — native combobox convention. Keyboard nav still updates
	// it too; whichever moved last wins.
	if st.open && mouse_over_overlay {
		content_y := overlay_rect.y + overlay_pad + BORDER_W
		rel_y := ctx.input.mouse_pos.y - content_y
		idx := int(rel_y / opt_h)
		if idx >= 0 && idx < len(visible) {
			highlight = idx
		}
	}

	// Option-row click (must run before the overlay-click consume below).
	if st.open && ctx.input.mouse_released[.Left] && mouse_over_overlay {
		content_y := overlay_rect.y + overlay_pad + BORDER_W
		rel_y := ctx.input.mouse_pos.y - content_y
		idx := int(rel_y / opt_h)
		if idx >= 0 && idx < len(visible) {
			new_value, changed = options[visible[idx]], true
			widget_focus(ctx, 0)
			focused = false
			st.open = false
		}
	}

	// Persist draft + cursor + highlight.
	if draft != st.text_buffer {
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
		st.text_buffer = strings.clone(draft)
	}
	st.cursor_pos = cursor
	st.drag_donor = highlight

	// Popover fade-in. Tween state resets while closed so each open
	// fades from 0 again; mid-tween the anim helper wakes the next frame.
	anim_op: f32 = 0
	if st.open {
		anim_op = widget_anim_step(ctx, &st, 1, 0.12)
	} else {
		st.anim_t = 0
		st.anim_prev_ns = 0
	}

	widget_set(ctx, id, st)

	// Consume clicks inside overlay so siblings don't double-fire.
	if ctx.input.mouse_pressed[.Left] && mouse_over_overlay {
		ctx.input.mouse_pressed[.Left] = false
	}
	if ctx.input.mouse_released[.Left] && mouse_over_overlay {
		ctx.input.mouse_released[.Left] = false
	}

	// Trigger text: show the current value when the user hasn't typed
	// anything yet (including the just-opened state). Once they start
	// typing, draft takes over so filtering feels responsive.
	disp_text := value
	if focused && len(draft) > 0 { disp_text = draft }

	trigger := View_Text_Input{
		id                = id,
		text              = disp_text,
		placeholder       = placeholder,
		color_bg          = th.color.surface,
		color_fg          = th.color.fg,
		color_placeholder = th.color.fg_muted,
		color_border      = th.color.primary,
		color_border_idle = th.color.border,
		color_caret       = th.color.fg,
		color_selection   = th.color.selection,
		radius            = th.radius.sm,
		padding           = {pad_x, pad_y},
		font_size         = fs,
		width             = tr_w,
		height            = tr_h,
		focused           = focused,
		cursor_pos        = cursor,
		selection_anchor  = cursor,
		visual_lines      = []Visual_Line{
			Visual_Line{start = 0, end = len(disp_text), consume_space = false},
		},
	}

	if !st.open || len(visible) == 0 {
		view = trigger
		return
	}

	// Dropdown rows. Highlight tracks `drag_donor`; hovered-row follows
	// mouse position so visual + keyboard highlight stay in sync.
	rows := make([dynamic]View, 0, len(visible), context.temp_allocator)
	visible_count := min(len(visible), 8)
	for vi in 0 ..< visible_count {
		opt_idx := visible[vi]
		label   := options[opt_idx]
		is_hl   := vi == highlight
		row_bg := Color{}
		if is_hl { row_bg = th.color.selection }
		append(&rows, col(
			text(label, th.color.fg, fs),
			width       = overlay_w - 2*(overlay_pad + BORDER_W),
			height      = opt_h,
			padding     = th.spacing.sm,
			main_align  = .Center,
			cross_align = .Start,
			bg          = row_bg,
			radius      = th.radius.sm,
		))
	}
	inner := col(..rows[:],
		spacing     = 0,
		padding     = overlay_pad,
		width       = overlay_w - 2*BORDER_W,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)
	list := col(
		inner,
		padding     = BORDER_W,
		width       = overlay_w,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)

	view = col(
		trigger,
		overlay(trigger_rect, list, .Below, {0, 4}, anim_op),
	)
	return
}

combobox_simple :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	options:     []string,
	on_change:   proc(new_value: string) -> Msg,
	id:          Widget_ID = 0,
	width:       f32       = 0,
	placeholder: string    = "",
	filter:      bool      = true,
	free_form:   bool      = false,
	disabled:   bool      = false,
	max_chars:   int       = 0,
) -> View {
	view, new_value, changed := _combobox_impl(
		ctx, value, options,
		id = id, width = width, placeholder = placeholder,
		filter = filter, free_form = free_form,
		disabled = disabled, max_chars = max_chars,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

combobox_payload :: proc(
	ctx:         ^Ctx($Msg),
	value:       string,
	options:     []string,
	payload:     $Payload,
	on_change:   proc(payload: Payload, new_value: string) -> Msg,
	id:          Widget_ID = 0,
	width:       f32       = 0,
	placeholder: string    = "",
	filter:      bool      = true,
	free_form:   bool      = false,
	disabled:   bool      = false,
	max_chars:   int       = 0,
) -> View {
	view, new_value, changed := _combobox_impl(
		ctx, value, options,
		id = id, width = width, placeholder = placeholder,
		filter = filter, free_form = free_form,
		disabled = disabled, max_chars = max_chars,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// Date is a year/month/day triple with 1-based month (1..12) and day
// (1..31). The zero value (all three fields 0) represents "no date
// chosen" — pass it to `date_picker`'s `value` to render the field as
// empty (placeholder visible). Apps typically store a Date in their
// state and update it from the `on_change` callback.
Date :: struct {
	year:  int,
	month: int,
	day:   int,
}

@(private)
date_is_zero :: proc(d: Date) -> bool {
	return d.year == 0 && d.month == 0 && d.day == 0
}

@(private)
date_is_leap :: proc(year: int) -> bool {
	return year %% 4 == 0 && (year %% 100 != 0 || year %% 400 == 0)
}

@(private)
date_days_in_month :: proc(year, month: int) -> int {
	switch month {
	case 1, 3, 5, 7, 8, 10, 12: return 31
	case 4, 6, 9, 11:           return 30
	case 2:
		if date_is_leap(year) { return 29 }
		return 28
	}
	return 0
}

// date_weekday_of_first returns Sakamoto's day-of-week for the 1st of
// the month: 0=Sunday, 1=Monday, …, 6=Saturday. Valid for Gregorian
// dates (year ≥ 1583 in practice, but mathematically works further
// back); we assume the calendar widget never cares about pre-Gregorian.
@(private)
date_weekday_of_first :: proc(year, month: int) -> int {
	t := [12]int{0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
	y := year
	if month < 3 { y -= 1 }
	return (y + y/4 - y/100 + y/400 + t[month-1] + 1) %% 7
}

// date_add_months shifts (year, month) by `delta` months, carrying into
// years. Clamps at year 1 — the calendar widget has no meaningful
// semantics for year 0 or negative years.
@(private)
date_add_months :: proc(y, m, delta: int) -> (int, int) {
	total := y*12 + (m - 1) + delta
	if total < 12 { total = 12 } // clamp to Jan of year 1
	return total / 12, (total %% 12) + 1
}

@(private)
date_compare :: proc(a, b: Date) -> int {
	if a.year  != b.year  { return a.year  < b.year  ? -1 : 1 }
	if a.month != b.month { return a.month < b.month ? -1 : 1 }
	if a.day   != b.day   { return a.day   < b.day   ? -1 : 1 }
	return 0
}

// Date formatters. All return strings in the frame arena (tprintf) —
// clone into the persistent allocator if you need to retain them past
// frame end. `date_format` is the default used by `date_picker`: it
// reads the `LC_TIME` / `LANG` environment variables once per process
// and routes to the regional style most readers in that locale expect
// (US → MM/DD/YYYY, other named locales → DD/MM/YYYY, C / POSIX /
// unset → ISO). The named variants are here for apps that want a
// specific format regardless of environment.
date_format_iso :: proc(d: Date) -> string {
	return fmt.tprintf("%04d-%02d-%02d", d.year, d.month, d.day)
}

// date_format_us formats a Date as MM/DD/YYYY regardless of locale.
date_format_us :: proc(d: Date) -> string {
	return fmt.tprintf("%02d/%02d/%04d", d.month, d.day, d.year)
}

// date_format_eu formats a Date as DD/MM/YYYY regardless of locale.
date_format_eu :: proc(d: Date) -> string {
	return fmt.tprintf("%02d/%02d/%04d", d.day, d.month, d.year)
}

// date_format_ymd_slash formats a Date as YYYY/MM/DD — common in
// Japanese, Chinese, and Korean UIs.
date_format_ymd_slash :: proc(d: Date) -> string {
	return fmt.tprintf("%04d/%02d/%02d", d.year, d.month, d.day)
}

// date_format_long formats a Date as "July 11, 2024" — month name +
// numeric day + four-digit year. Month names are English-only; pass a
// custom formatter if you need localization.
date_format_long :: proc(d: Date) -> string {
	names := [12]string{
		"January", "February", "March",     "April",   "May",      "June",
		"July",    "August",   "September", "October", "November", "December",
	}
	if d.month < 1 || d.month > 12 { return date_format_iso(d) }
	return fmt.tprintf("%d %s %04d", d.day, names[d.month-1], d.year)
}

@(private)
Date_Locale_Style :: enum u8 { Unknown, ISO, US, EU, YMD_Slash }

@(private)
_date_locale_cache: Date_Locale_Style

// classify_locale_tag maps a BCP-47-ish locale tag to a date style.
// Accepts both the POSIX-flavoured "en_GB" / "ja_JP" and the Win32
// "en-GB" / "ja-JP" form — we normalize by checking prefixes and
// treating `-` and `_` as equivalent separators.
@(private)
classify_locale_tag :: proc(tag: string) -> Date_Locale_Style {
	if len(tag) == 0 || tag == "C" || tag == "POSIX" { return .ISO }
	has_en_prefix :: proc(tag, region: string) -> bool {
		return strings.has_prefix(tag, strings.concatenate({"en_", region}, context.temp_allocator)) ||
		       strings.has_prefix(tag, strings.concatenate({"en-", region}, context.temp_allocator))
	}
	switch {
	case has_en_prefix(tag, "US"), has_en_prefix(tag, "CA"):
		return .US
	case strings.has_prefix(tag, "ja"), strings.has_prefix(tag, "zh"),
	     strings.has_prefix(tag, "ko"), strings.has_prefix(tag, "hu"),
	     strings.has_prefix(tag, "lt"):
		// Asian locales and a handful of European ones (Hungarian,
		// Lithuanian) conventionally write dates year-first.
		return .YMD_Slash
	case strings.contains(tag, "_"), strings.contains(tag, "-"):
		return .EU
	}
	return .ISO
}

// date_locale_style sniffs LC_TIME then LANG, then (on Windows) the
// Win32 user-default locale name. Cached on first call because locale
// doesn't change mid-run and this is hit per-frame from `date_format`.
// Heuristic: the "en_US" / "en_CA" family → US; Asian + a few European
// locales → year-first; anything else with a region → EU;
// "C" / "POSIX" / empty → ISO (the unambiguous safe default).
@(private)
date_locale_style :: proc() -> Date_Locale_Style {
	if _date_locale_cache != .Unknown { return _date_locale_cache }

	val, _ := os.lookup_env("LC_TIME", context.temp_allocator)
	if len(val) == 0 {
		val, _ = os.lookup_env("LANG", context.temp_allocator)
	}
	if len(val) == 0 {
		val = win32_user_locale_name()
	}

	_date_locale_cache = classify_locale_tag(val)
	return _date_locale_cache
}

// date_format picks a regional style from the process environment. For
// an unambiguous stable format (logs, serialized state) call
// `date_format_iso` directly instead.
date_format :: proc(d: Date) -> string {
	switch date_locale_style() {
	case .US:                 return date_format_us(d)
	case .EU:                 return date_format_eu(d)
	case .YMD_Slash:          return date_format_ymd_slash(d)
	case .ISO, .Unknown:      return date_format_iso(d)
	}
	return date_format_iso(d)
}

// Week_Start selects which weekday sits in the first column of the
// date picker's calendar grid. `Locale` (the default) resolves from the
// same env-var sniff `date_format` uses: US/CA → Sunday; everything
// else → Monday (ISO 8601 and most of the non-US world). Pass `Sunday`
// or `Monday` explicitly to override.
Week_Start :: enum u8 {
	Locale,
	Sunday,
	Monday,
}

@(private)
week_start_resolved :: proc(ws: Week_Start) -> int {
	// Returns 0 if Sunday-first, 1 if Monday-first.
	switch ws {
	case .Sunday: return 0
	case .Monday: return 1
	case .Locale:
		switch date_locale_style() {
		case .US:                                return 0
		case .EU, .ISO, .YMD_Slash, .Unknown:    return 1
		}
	}
	return 1
}

// date_picker builds a form-row-sized trigger that opens a calendar
// popover. Clicking a day in the grid fires `on_change(new_value)` and
// closes the popover; prev/next arrows in the header navigate months
// without firing on_change (navigation is widget-internal state).
//
//     Msg :: union { Date_Picked: skald.Date, … }
//     on_pick :: proc(d: skald.Date) -> Msg { return Date_Picked{d} }
//
//     skald.date_picker(ctx, state.birthday, on_pick,
//         placeholder = "Pick a birthday",
//         max_date    = skald.Date{2026, 4, 20},
//     )
//
// Sizing: `width = 0` fills the parent's cross-axis allocation (matches
// text_input / select / slider). Pass an explicit width for a fixed-
// width field.
//
// Bounds: `min_date` / `max_date` grey out days outside the allowed
// range and swallow clicks on them. Passing the zero value for either
// means "no bound in that direction".
//
// Formatting: `format` controls how the chosen date renders in the
// trigger. Leave it nil to use `date_format` (reads LC_TIME / LANG);
// pass `date_format_iso` / `date_format_us` / `date_format_eu` /
// `date_format_ymd_slash` / `date_format_long` for a specific style, or
// any `proc(Date) -> string` the app prefers.
//
// Week layout: `week_start` selects which day sits in the grid's
// leftmost column. Defaults to `Locale` which resolves US/Canada to
// Sunday and everything else to Monday.
date_picker :: proc{date_picker_simple, date_picker_payload}

@(private)
_date_picker_impl :: proc(
	ctx:         ^Ctx($Msg),
	value:       Date,
	id:          Widget_ID  = 0,
	width:       f32        = 0,
	placeholder: string     = "",
	disabled:   bool       = false,
	min_date:    Date       = {},
	max_date:    Date       = {},
	format:      proc(d: Date) -> string = nil,
	week_start:  Week_Start = .Locale,
) -> (view: View, new_value: Date, changed: bool) {
	th := ctx.theme
	placeholder := placeholder
	if len(placeholder) == 0 { placeholder = ctx.labels.date_picker_placeholder }

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Date_Picker)
	focused := !disabled && widget_has_focus(ctx, id)

	// A read-only picker renders the trigger only; force any previously-
	// open popover shut so toggling the flag on at runtime collapses it.
	if disabled { st.open = false }
	// If a modal dialog is open and this widget sits outside its card,
	// force-close any in-progress popover. A stranded dropdown peeking
	// out from under a dialog reads as a bug, and input gates can't
	// reach it anyway.
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, st.last_rect) {
		st.open = false
	}

	display := ""
	if !date_is_zero(value) {
		display = format(value) if format != nil else date_format(value)
	}

	trigger_rect := st.last_rect
	trigger_hovered := !disabled && rect_hovered(ctx, trigger_rect)

	// Wall-clock today, used for the "today" highlight and as the seed
	// month when no value / last-viewed month is set.
	now_t := time.now()
	ty, tm, td := time.date(now_t)
	today := Date{year = ty, month = int(tm), day = td}

	// Popover geometry. Constants mirror the select popover's border +
	// padding convention so the two controls feel like the same family.
	POPOVER_W :: f32(260)
	HEADER_H  :: f32(32)
	CELL_H    :: f32(28)
	FOOTER_H  :: f32(32)
	overlay_pad := f32(8)
	BORDER_W    := f32(1)
	inner_w  := POPOVER_W - 2*(overlay_pad + BORDER_W)
	cell_w   := inner_w / 7
	gap      := th.spacing.xs
	overlay_h := 2*(overlay_pad + BORDER_W) + HEADER_H + gap + CELL_H + 6*CELL_H + gap + FOOTER_H

	overlay_rect := overlay_placement_rect(ctx, trigger_rect,
		{POPOVER_W, overlay_h}, .Below, {0, 4})
	mouse_over_overlay := rect_contains_point(overlay_rect, ctx.input.mouse_pos)
	if st.open { widget_stamp_overlay_rect(ctx.widgets, overlay_rect) }

	// Seed nav state when opening — prefer the current value so the grid
	// lands on the selected month, else keep the last-viewed month, else
	// fall to today's month.
	seed_nav :: proc(st: ^Widget_State, value, today: Date) {
		if !date_is_zero(value) {
			st.nav_year  = value.year
			st.nav_month = value.month
		} else if st.nav_year == 0 || st.nav_month == 0 {
			st.nav_year  = today.year
			st.nav_month = today.month
		}
		st.cursor_pos = 0 // always reopen in day mode
	}

	// Trigger toggle + outside-click dismiss, matching select's pattern.
	if !disabled && ctx.input.mouse_pressed[.Left] {
		if trigger_hovered {
			st.open = !st.open
			widget_focus(ctx, id)
			focused = true
			if st.open { seed_nav(&st, value, today) }
		} else if st.open && !mouse_over_overlay {
			st.open = false
		}
	}

	if focused && !disabled {
		keys := ctx.input.keys_pressed
		// Trigger-level Enter/Space only opens the picker; once open, the
		// grid-level handler (further down) uses Enter to commit the
		// focused cell so the same key doesn't toggle-close the popover.
		if !st.open && (.Space in keys || .Enter in keys) {
			st.open = true
			seed_nav(&st, value, today)
		}
		if .Escape in keys {
			st.open = false
			st.selection_anchor = 0 // clear keyboard focus on dismiss
		}
	}

	fg_c := th.color.fg
	if disabled { fg_c = th.color.fg_muted }

	if !st.open {
		st.anim_t = 0
		st.anim_prev_ns = 0
		widget_set(ctx, id, st)
		view = View_Select{
			id                = id,
			value             = display,
			placeholder       = placeholder,
			color_bg          = th.color.surface,
			color_fg          = fg_c,
			color_placeholder = th.color.fg_muted,
			color_border      = th.color.border,
			color_focus       = focus_ring_for(th^, th.color.surface),
			color_caret       = th.color.fg_muted,
			radius            = th.radius.sm,
			padding           = {th.spacing.md, th.spacing.sm},
			font_size         = th.font.size_md,
			width             = width,
			open              = false,
			hover             = trigger_hovered,
			focused           = focused,
		}
		return
	}

	anim_op := widget_anim_step(ctx, &st, 1, 0.12)

	// Popover open: intercept clicks before building the visual tree.
	content_x := overlay_rect.x + overlay_pad + BORDER_W
	content_y := overlay_rect.y + overlay_pad + BORDER_W

	prev_rect  := Rect{content_x, content_y, HEADER_H, HEADER_H}
	next_rect  := Rect{content_x + inner_w - HEADER_H, content_y, HEADER_H, HEADER_H}
	title_rect := Rect{content_x + HEADER_H, content_y, inner_w - 2*HEADER_H, HEADER_H}
	grid_origin_y := content_y + HEADER_H + gap + CELL_H

	nav_year  := st.nav_year
	nav_month := st.nav_month
	if nav_year == 0 || nav_month == 0 {
		nav_year, nav_month = today.year, today.month
		st.nav_year, st.nav_month = nav_year, nav_month
	}

	// cursor_pos is repurposed on the date_picker slot as a mode flag:
	// 0 = day grid, 1 = year picker. It only carries meaning while
	// .Date_Picker owns the slot; widget_get's kind-mismatch reset wipes
	// it if a different widget ever inherits the id.
	year_mode := st.cursor_pos == 1

	prev_hover  := rect_contains_point(prev_rect,  ctx.input.mouse_pos)
	next_hover  := rect_contains_point(next_rect,  ctx.input.mouse_pos)
	title_hover := rect_contains_point(title_rect, ctx.input.mouse_pos)

	// Header arrows: ±1 month in day mode, ±12 years in year mode.
	// Title click toggles the two modes.
	if ctx.input.mouse_pressed[.Left] {
		if prev_hover {
			if year_mode {
				nav_year -= 12; if nav_year < 1 { nav_year = 1 }
				st.nav_year = nav_year
			} else {
				nav_year, nav_month = date_add_months(nav_year, nav_month, -1)
				st.nav_year, st.nav_month = nav_year, nav_month
			}
		} else if next_hover {
			if year_mode {
				nav_year += 12
				st.nav_year = nav_year
			} else {
				nav_year, nav_month = date_add_months(nav_year, nav_month, 1)
				st.nav_year, st.nav_month = nav_year, nav_month
			}
		} else if title_hover {
			year_mode = !year_mode
			st.cursor_pos = 1 if year_mode else 0
		}
	}

	days_in := date_days_in_month(nav_year, nav_month)

	// Grid-level keyboard navigation (day mode only). Arrow keys move the
	// focused-cell marker; Enter/Space commits it; PageUp/PageDown shift
	// the month. Focused day lives in `st.selection_anchor` and seeds
	// lazily on the first navigation key so a plain click→pick flow
	// doesn't render a stray focus ring.
	commit_keyboard_pick := false
	if focused && st.open && !disabled && !year_mode {
		keys  := ctx.input.keys_pressed
		focus := st.selection_anchor

		any_nav := .Left in keys || .Right in keys || .Up in keys ||
		           .Down in keys || .Home in keys || .End in keys
		if focus == 0 && any_nav {
			switch {
			case !date_is_zero(value) && value.year == nav_year && value.month == nav_month:
				focus = value.day
			case today.year == nav_year && today.month == nav_month:
				focus = today.day
			case:
				focus = 1
			}
		}

		if focus > 0 {
			if .Left  in keys { focus -= 1 }
			if .Right in keys { focus += 1 }
			if .Up    in keys { focus -= 7 }
			if .Down  in keys { focus += 7 }
			if .Home  in keys { focus = 1 }
			if .End   in keys { focus = days_in }

			// Wrap across month boundaries: a single arrow-press shifts
			// by at most 7 days so one correction suffices either way.
			if focus < 1 {
				nav_year, nav_month = date_add_months(nav_year, nav_month, -1)
				prev_days := date_days_in_month(nav_year, nav_month)
				focus += prev_days
				days_in = prev_days
				st.nav_year, st.nav_month = nav_year, nav_month
			} else if focus > days_in {
				focus -= days_in
				nav_year, nav_month = date_add_months(nav_year, nav_month, 1)
				days_in = date_days_in_month(nav_year, nav_month)
				st.nav_year, st.nav_month = nav_year, nav_month
			}
			st.selection_anchor = focus
		}

		if .Page_Up in keys {
			nav_year, nav_month = date_add_months(nav_year, nav_month, -1)
			st.nav_year, st.nav_month = nav_year, nav_month
			days_in = date_days_in_month(nav_year, nav_month)
		}
		if .Page_Down in keys {
			nav_year, nav_month = date_add_months(nav_year, nav_month, 1)
			st.nav_year, st.nav_month = nav_year, nav_month
			days_in = date_days_in_month(nav_year, nav_month)
		}

		if focus > 0 && (.Enter in keys || .Space in keys) {
			picked := Date{year = nav_year, month = nav_month, day = focus}
			in_bounds := true
			if !date_is_zero(min_date) && date_compare(picked, min_date) < 0 { in_bounds = false }
			if !date_is_zero(max_date) && date_compare(picked, max_date) > 0 { in_bounds = false }
			if in_bounds {
				new_value, changed = picked, true
				commit_keyboard_pick = true
			}
		}
	}

	week_offset := week_start_resolved(week_start) // 0=Sun-first, 1=Mon-first
	wd_raw      := date_weekday_of_first(nav_year, nav_month) // 0=Sun..6=Sat
	wd_first    := (wd_raw - week_offset + 7) %% 7 // leading blanks in grid

	// Year-picker layout: 4 rows × 3 cols of 12 consecutive years centered
	// on nav_year. Cells split the same vertical space the day grid +
	// weekday row uses so the popover height stays constant across modes.
	YEAR_COLS :: 3
	YEAR_ROWS :: 4
	year_cell_w := inner_w / f32(YEAR_COLS)
	year_cell_h := (CELL_H + 6*CELL_H) / f32(YEAR_ROWS)
	year_origin_y := content_y + HEADER_H + gap
	year_base := nav_year - (YEAR_ROWS*YEAR_COLS)/2 // 12-cell window centered on nav_year

	// Hit-test the active grid: day cells in day mode, year cells in
	// year mode. Day selection fires on_change + closes; year selection
	// switches back to day mode at the chosen year.
	close_after_build := false
	if ctx.input.mouse_released[.Left] {
		if year_mode {
			rel_x := ctx.input.mouse_pos.x - content_x
			rel_y := ctx.input.mouse_pos.y - year_origin_y
			if rel_x >= 0 && rel_y >= 0 && rel_x < year_cell_w*f32(YEAR_COLS) &&
			   rel_y < year_cell_h*f32(YEAR_ROWS) {
				c := int(rel_x / year_cell_w)
				r := int(rel_y / year_cell_h)
				picked_y := year_base + r*YEAR_COLS + c
				if picked_y >= 1 {
					nav_year = picked_y
					st.nav_year = nav_year
					year_mode = false
					st.cursor_pos = 0
				}
			}
		} else {
			rel_x := ctx.input.mouse_pos.x - content_x
			rel_y := ctx.input.mouse_pos.y - grid_origin_y
			if rel_x >= 0 && rel_y >= 0 && rel_x < cell_w*7 && rel_y < CELL_H*6 {
				c := int(rel_x / cell_w)
				r := int(rel_y / CELL_H)
				slot := r*7 + c
				day_n := slot - wd_first + 1
				if day_n >= 1 && day_n <= days_in {
					picked := Date{year = nav_year, month = nav_month, day = day_n}
					in_bounds := true
					if !date_is_zero(min_date) && date_compare(picked, min_date) < 0 { in_bounds = false }
					if !date_is_zero(max_date) && date_compare(picked, max_date) > 0 { in_bounds = false }
					if in_bounds {
						new_value, changed = picked, true
						close_after_build = true
					}
				}
			}
		}
	}

	// Footer hit-test — must run BEFORE the overlay-consume below so the
	// swallow doesn't eat the click before we can read it, and before
	// widget_set below so close_after_build commits this frame. Today
	// jumps to the current date; Clear zeroes the value so the trigger
	// reverts to its placeholder.
	date_footer_y  := content_y + overlay_h - 2*(overlay_pad + BORDER_W) - FOOTER_H
	date_today_rect := Rect{content_x, date_footer_y,
	                        inner_w * 0.5 - gap * 0.5, FOOTER_H}
	date_clear_rect := Rect{content_x + inner_w * 0.5 + gap * 0.5, date_footer_y,
	                        inner_w * 0.5 - gap * 0.5, FOOTER_H}
	if ctx.input.mouse_released[.Left] {
		if rect_contains_point(date_today_rect, ctx.input.mouse_pos) {
			new_value, changed = today, true
			close_after_build = true
		} else if rect_contains_point(date_clear_rect, ctx.input.mouse_pos) {
			new_value, changed = Date{}, true
			close_after_build = true
		}
	}

	// Swallow presses/releases that landed in the popover so widgets
	// built after us don't double-fire. Matches select's end-of-body
	// cleanup — see the comment there for the rationale.
	if ctx.input.mouse_pressed[.Left] && mouse_over_overlay {
		ctx.input.mouse_pressed[.Left] = false
	}
	if ctx.input.mouse_released[.Left] && mouse_over_overlay {
		ctx.input.mouse_released[.Left] = false
	}

	if close_after_build || commit_keyboard_pick {
		st.open = false
		st.selection_anchor = 0
	}
	widget_set(ctx, id, st)

	// Header: [◀] [title] [▶]. Title reads "Month YYYY" in day mode,
	// "YYYY–YYYY" in year mode (the currently shown 12-year window).
	// Month name comes from the app's localized labels.
	title_str := ""
	if year_mode {
		title_str = fmt.tprintf("%04d – %04d", year_base, year_base + (YEAR_ROWS*YEAR_COLS) - 1)
	} else {
		title_str = fmt.tprintf("%s %04d", ctx.labels.month_names[nav_month-1], nav_year)
	}

	prev_bg  := th.color.elevated
	next_bg  := th.color.elevated
	title_bg := th.color.elevated
	if prev_hover  { prev_bg  = th.color.surface }
	if next_hover  { next_bg  = th.color.surface }
	if title_hover { title_bg = th.color.surface }

	header := row(
		col(
			text("<", th.color.fg, th.font.size_md),
			width = HEADER_H, height = HEADER_H,
			main_align = .Center, cross_align = .Center,
			bg = prev_bg, radius = th.radius.sm,
		),
		flex(1, col(
			text(title_str, th.color.fg, th.font.size_md),
			height = HEADER_H,
			main_align = .Center, cross_align = .Center,
			bg = title_bg, radius = th.radius.sm,
		)),
		col(
			text(">", th.color.fg, th.font.size_md),
			width = HEADER_H, height = HEADER_H,
			main_align = .Center, cross_align = .Center,
			bg = next_bg, radius = th.radius.sm,
		),
		width = inner_w,
	)

	// Weekday labels. Short two-char labels come from the app's localized
	// labels (Sunday-first indexing). Rotate by week_offset so the first
	// column matches the start day.
	wd_items := make([]View, 7, context.temp_allocator)
	for i in 0..<7 {
		label := ctx.labels.weekday_short[(i + week_offset) %% 7]
		wd_items[i] = col(
			text(label, th.color.fg_muted, th.font.size_sm),
			width = cell_w, height = CELL_H,
			main_align = .Center, cross_align = .Center,
		)
	}
	weekday_row := row(..wd_items, width = inner_w)

	// Day grid. 6 rows × 7 cols covers every possible month layout.
	// Leading/trailing empty slots render as blank cells rather than
	// bleeding adjacent-month days, which keeps the picker unambiguous
	// at a glance.
	grid_rows := make([]View, 6, context.temp_allocator)
	for r in 0..<6 {
		cells := make([]View, 7, context.temp_allocator)
		for c in 0..<7 {
			slot := r*7 + c
			day_n := slot - wd_first + 1
			if day_n < 1 || day_n > days_in {
				cells[c] = col(
					text("", th.color.fg, th.font.size_sm),
					width = cell_w, height = CELL_H,
				)
				continue
			}

			cell_rect := Rect{
				content_x + f32(c)*cell_w,
				grid_origin_y + f32(r)*CELL_H,
				cell_w, CELL_H,
			}

			picked := Date{year = nav_year, month = nav_month, day = day_n}
			is_selected := !date_is_zero(value) && date_compare(picked, value) == 0
			is_today    := date_compare(picked, today) == 0
			is_focused  := focused && day_n == st.selection_anchor
			disabled := false
			if !date_is_zero(min_date) && date_compare(picked, min_date) < 0 { disabled = true }
			if !date_is_zero(max_date) && date_compare(picked, max_date) > 0 { disabled = true }

			bg_c  := Color{}
			fg_c2 := th.color.fg
			// Priority: disabled > selected > focused > today > hover.
			if disabled {
				fg_c2 = th.color.fg_muted
			} else if is_selected {
				bg_c  = th.color.primary
				fg_c2 = th.color.on_primary
			} else if is_focused {
				bg_c = th.color.selection
				if is_today { fg_c2 = th.color.primary }
			} else if is_today {
				// Today reads as a tinted number (no fill) so it doesn't
				// compete with the selection's solid primary.
				fg_c2 = th.color.primary
				if rect_contains_point(cell_rect, ctx.input.mouse_pos) {
					bg_c = th.color.surface
				}
			} else if rect_contains_point(cell_rect, ctx.input.mouse_pos) {
				bg_c = th.color.surface
			}

			cells[c] = col(
				text(fmt.tprintf("%d", day_n), fg_c2, th.font.size_sm),
				width = cell_w, height = CELL_H,
				main_align = .Center, cross_align = .Center,
				bg = bg_c, radius = th.radius.sm,
			)
		}
		grid_rows[r] = row(..cells, width = inner_w)
	}

	day_grid := col(..grid_rows, width = inner_w)

	// Year grid (year mode). Each cell holds a year; the one matching
	// nav_year (or today.year for first-open pickers) gets a visual
	// highlight like the "today" day cell.
	year_rows := make([]View, YEAR_ROWS, context.temp_allocator)
	for r in 0..<YEAR_ROWS {
		ycells := make([]View, YEAR_COLS, context.temp_allocator)
		for c in 0..<YEAR_COLS {
			yn := year_base + r*YEAR_COLS + c
			cell_rect := Rect{
				content_x + f32(c)*year_cell_w,
				year_origin_y + f32(r)*year_cell_h,
				year_cell_w, year_cell_h,
			}

			is_current := yn == nav_year
			is_today_y := yn == today.year
			out_of_bounds := yn < 1
			if !date_is_zero(min_date) && yn < min_date.year { out_of_bounds = true }
			if !date_is_zero(max_date) && yn > max_date.year { out_of_bounds = true }

			bg_c  := Color{}
			fg_c2 := th.color.fg
			if out_of_bounds {
				fg_c2 = th.color.fg_muted
			} else if is_current {
				bg_c  = th.color.primary
				fg_c2 = th.color.on_primary
			} else if is_today_y {
				fg_c2 = th.color.primary
				if rect_contains_point(cell_rect, ctx.input.mouse_pos) {
					bg_c = th.color.surface
				}
			} else if rect_contains_point(cell_rect, ctx.input.mouse_pos) {
				bg_c = th.color.surface
			}

			label_str := "" if out_of_bounds else fmt.tprintf("%d", yn)
			ycells[c] = col(
				text(label_str, fg_c2, th.font.size_md),
				width = year_cell_w, height = year_cell_h,
				main_align = .Center, cross_align = .Center,
				bg = bg_c, radius = th.radius.sm,
			)
		}
		year_rows[r] = row(..ycells, width = inner_w)
	}
	year_grid := col(..year_rows, width = inner_w)

	grid: View
	if year_mode {
		grid = year_grid
	} else {
		grid = col(weekday_row, day_grid, spacing = 0, width = inner_w)
	}

	// Footer row geometry (hit-test computed earlier, visual row built
	// here). The rects were derived from content_x/_y + overlay_h above.
	today_label_hovered := rect_contains_point(date_today_rect, ctx.input.mouse_pos)
	clear_label_hovered := rect_contains_point(date_clear_rect, ctx.input.mouse_pos)

	today_bg := Color{}
	if today_label_hovered { today_bg = th.color.surface }
	clear_bg := Color{}
	if clear_label_hovered { clear_bg = th.color.surface }

	footer := row(
		col(text(ctx.labels.today, th.color.primary, th.font.size_md),
		    width = date_today_rect.w, height = FOOTER_H,
		    main_align = .Center, cross_align = .Center,
		    bg = today_bg, radius = th.radius.sm),
		spacer(gap),
		col(text(ctx.labels.clear, th.color.fg_muted, th.font.size_md),
		    width = date_clear_rect.w, height = FOOTER_H,
		    main_align = .Center, cross_align = .Center,
		    bg = clear_bg, radius = th.radius.sm),
		width = inner_w, height = FOOTER_H,
	)

	// Two-layer card: hairline border wraps the elevated body, same as
	// select / menu popovers for visual consistency.
	inner := col(
		header,
		grid,
		footer,
		spacing     = gap,
		padding     = overlay_pad,
		width       = POPOVER_W - 2*BORDER_W,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Start,
	)
	card := col(
		inner,
		padding     = BORDER_W,
		width       = POPOVER_W,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Start,
	)

	trigger := View_Select{
		id                = id,
		value             = display,
		placeholder       = placeholder,
		color_bg          = th.color.surface,
		color_fg          = th.color.fg,
		color_placeholder = th.color.fg_muted,
		color_border      = th.color.border,
		color_focus       = focus_ring_for(th^, th.color.surface),
		color_caret       = th.color.fg_muted,
		radius            = th.radius.sm,
		padding           = {th.spacing.md, th.spacing.sm},
		font_size         = th.font.size_md,
		width             = width,
		open              = st.open,
		hover             = trigger_hovered,
		focused           = focused,
	}

	if !st.open {
		view = trigger
		return
	}
	view = col(
		trigger,
		overlay(trigger_rect, card, .Below, {0, 4}, anim_op),
	)
	return
}

date_picker_simple :: proc(
	ctx:         ^Ctx($Msg),
	value:       Date,
	on_change:   proc(new_value: Date) -> Msg,
	id:          Widget_ID  = 0,
	width:       f32        = 0,
	placeholder: string     = "",
	disabled:   bool       = false,
	min_date:    Date       = {},
	max_date:    Date       = {},
	format:      proc(d: Date) -> string = nil,
	week_start:  Week_Start = .Locale,
) -> View {
	view, new_value, changed := _date_picker_impl(
		ctx, value,
		id = id, width = width, placeholder = placeholder,
		disabled = disabled, min_date = min_date, max_date = max_date,
		format = format, week_start = week_start,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

date_picker_payload :: proc(
	ctx:         ^Ctx($Msg),
	value:       Date,
	payload:     $Payload,
	on_change:   proc(payload: Payload, new_value: Date) -> Msg,
	id:          Widget_ID  = 0,
	width:       f32        = 0,
	placeholder: string     = "",
	disabled:   bool       = false,
	min_date:    Date       = {},
	max_date:    Date       = {},
	format:      proc(d: Date) -> string = nil,
	week_start:  Week_Start = .Locale,
) -> View {
	view, new_value, changed := _date_picker_impl(
		ctx, value,
		id = id, width = width, placeholder = placeholder,
		disabled = disabled, min_date = min_date, max_date = max_date,
		format = format, week_start = week_start,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// Time is a 24-hour wall-clock time. `hour` is 0..23, `minute` and
// `second` are 0..59. The zero value (all zero) is a valid time
// (midnight), so the picker treats all Time values as set — there's
// no "unset" sentinel. Apps that want a placeholder state should wrap
// Time in an Odin union (e.g. `union { Time }`) and branch on presence
// at the view layer. `second` is only surfaced when `time_picker` is
// configured with `second_step > 0`; the default grids write zero.
Time :: struct {
	hour:   int,
	minute: int,
	second: int,
}

// time_format_24h formats a Time as HH:MM (or HH:MM:SS when seconds
// are nonzero). Always 24-hour regardless of locale.
time_format_24h :: proc(t: Time) -> string {
	if t.second != 0 {
		return fmt.tprintf("%02d:%02d:%02d", t.hour, t.minute, t.second)
	}
	return fmt.tprintf("%02d:%02d", t.hour, t.minute)
}

// time_format_12h formats a Time as H:MM AM/PM (or H:MM:SS AM/PM when
// seconds are nonzero). Hour is zero-padded only when seconds are
// included, matching the convention most English-locale apps use.
//
// AM/PM defaults to English here; apps shipping other locales wire a
// localized formatter via `time_picker(format = ...)` that reads from
// `ctx.labels.am` / `ctx.labels.pm`. The stateless form here (no Ctx)
// is kept as an English-default convenience.
time_format_12h :: proc(t: Time) -> string {
	h := t.hour %% 12
	if h == 0 { h = 12 }
	suffix := "AM"
	if t.hour >= 12 { suffix = "PM" }
	if t.second != 0 {
		return fmt.tprintf("%d:%02d:%02d %s", h, t.minute, t.second, suffix)
	}
	return fmt.tprintf("%d:%02d %s", h, t.minute, suffix)
}

// time_format is the default used by `time_picker`. Currently returns
// 24-hour `HH:MM` regardless of locale — locale-aware time is a deep
// rabbit hole (12h vs 24h per region, surrounding whitespace rules,
// colon vs period) that we're not chasing. Apps that want 12h display
// should pass `time_format_12h` via the `format` param.
time_format :: proc(t: Time) -> string {
	return time_format_24h(t)
}

// time_picker builds a trigger that opens a popover with hour and
// minute grids. Clicking a cell fires `on_change` with the updated
// Time value — the popover stays open so callers can tweak both
// fields in one flow, and a click outside (or Escape) dismisses.
//
//     Msg :: union { Time_Picked: skald.Time, … }
//     on_pick :: proc(t: skald.Time) -> Msg { return Time_Picked(t) }
//
//     skald.time_picker(ctx, state.alarm, on_pick,
//         minute_step = 5,
//         width       = 180,
//     )
//
// `minute_step` controls the minute grid's granularity: 15 → four
// cells (:00, :15, :30, :45), 5 → twelve cells, 1 → sixty cells (dense
// but valid). Values are clamped to 1..30.
//
// `second_step` adds a third grid for seconds when > 0: 1 → 60 cells
// (six-column grid, ten rows tall), 5 → twelve cells, 15 → four. Zero
// (the default) hides the seconds grid entirely and `Time.second`
// stays whatever the app wrote into `value`.
//
// Formatting: `format` overrides the trigger's display string. Pass
// `time_format_12h` for AM/PM style, or any `proc(Time) -> string`.
// The built-in formatters append `:SS` only when `t.second != 0` so
// minute-only pickers keep their `HH:MM` appearance.
time_picker :: proc{time_picker_simple, time_picker_payload}

@(private)
_time_picker_impl :: proc(
	ctx:         ^Ctx($Msg),
	value:       Time,
	id:          Widget_ID = 0,
	width:       f32       = 0,
	placeholder: string    = "",
	disabled:   bool      = false,
	minute_step: int       = 15,
	second_step: int       = 0,
	format:      proc(t: Time) -> string = nil,
) -> (view: View, new_value: Time, changed: bool) {
	th := ctx.theme
	placeholder := placeholder
	if len(placeholder) == 0 { placeholder = ctx.labels.time_picker_placeholder }

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Time_Picker)
	focused := !disabled && widget_has_focus(ctx, id)

	if disabled { st.open = false }
	// If a modal dialog is open and this widget sits outside its card,
	// force-close any in-progress popover. A stranded dropdown peeking
	// out from under a dialog reads as a bug, and input gates can't
	// reach it anyway.
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, st.last_rect) {
		st.open = false
	}

	step := minute_step
	if step < 1  { step = 1  }
	if step > 30 { step = 30 }

	sec_step := second_step
	if sec_step < 0  { sec_step = 0  }
	if sec_step > 30 { sec_step = 30 }
	show_sec := sec_step > 0

	display := format(value) if format != nil else time_format(value)

	trigger_rect := st.last_rect
	trigger_hovered := !disabled && rect_hovered(ctx, trigger_rect)

	// Popover is paginated like the date picker: one grid at a time,
	// with `< Hour >` / `< Minute >` / `< Second >` in the header to
	// cycle modes. `st.cursor_pos` persists the active mode
	// (0=Hour, 1=Minute, 2=Second). Reset to 0 on each open so the
	// picker always lands on Hour first.
	POPOVER_W  :: f32(280)
	HEADER_H   :: f32(32)
	CELL_H     :: f32(28)
	overlay_pad := f32(8)
	BORDER_W    := f32(1)
	inner_w     := POPOVER_W - 2*(overlay_pad + BORDER_W)

	HOUR_COLS :: 6
	HOUR_ROWS :: 4
	hour_cell_w := inner_w / f32(HOUR_COLS)

	// Column count scales with cell count so dense grids (step=1 → 60
	// cells) don't tower vertically. ≤6 cells: one row. ≤12: 6-col. More:
	// 10-col, which keeps two-digit labels legible at the popover width.
	grid_cols :: proc(n: int) -> int {
		if n <= 1  { return 1 }
		if n <= 6  { return n }
		if n <= 12 { return 6 }
		return 10
	}

	min_n := 60 / step
	min_cols := grid_cols(min_n)
	min_rows := (min_n + min_cols - 1) / min_cols
	min_cell_w := inner_w / f32(min_cols)

	sec_n := 0
	sec_cols := 1
	sec_rows := 0
	sec_cell_w := f32(0)
	if show_sec {
		sec_n = 60 / sec_step
		sec_cols = grid_cols(sec_n)
		sec_rows = (sec_n + sec_cols - 1) / sec_cols
		sec_cell_w = inner_w / f32(sec_cols)
	}

	mode_count := 2
	if show_sec { mode_count = 3 }

	// Popover height pins to the tallest grid so switching modes
	// doesn't bounce the overlay's size. Hour is fixed at 4 rows;
	// minute/seconds vary with step.
	max_rows := HOUR_ROWS
	if min_rows > max_rows { max_rows = min_rows }
	if show_sec && sec_rows > max_rows { max_rows = sec_rows }

	TIME_FOOTER_H :: f32(32)
	overlay_h := 2*(overlay_pad + BORDER_W) + HEADER_H + f32(max_rows)*CELL_H + th.spacing.xs + TIME_FOOTER_H

	overlay_rect := overlay_placement_rect(ctx, trigger_rect,
		{POPOVER_W, overlay_h}, .Below, {0, 4})
	mouse_over_overlay := rect_contains_point(overlay_rect, ctx.input.mouse_pos)
	if st.open { widget_stamp_overlay_rect(ctx.widgets, overlay_rect) }

	if !disabled && ctx.input.mouse_pressed[.Left] {
		if trigger_hovered {
			new_open := !st.open
			if new_open { st.cursor_pos = 0 }
			st.open = new_open
			widget_focus(ctx, id)
			focused = true
		} else if st.open && !mouse_over_overlay {
			st.open = false
		}
	}

	if focused && !disabled {
		keys := ctx.input.keys_pressed
		if !st.open && (.Space in keys || .Enter in keys) {
			st.open = true
			st.cursor_pos = 0
		}
		if .Escape in keys { st.open = false }
	}

	mode := st.cursor_pos
	if mode < 0 || mode >= mode_count { mode = 0 }

	fg_c := th.color.fg
	if disabled { fg_c = th.color.fg_muted }

	if !st.open {
		st.anim_t = 0
		st.anim_prev_ns = 0
		widget_set(ctx, id, st)
		view = View_Select{
			id                = id,
			value             = display,
			placeholder       = placeholder,
			color_bg          = th.color.surface,
			color_fg          = fg_c,
			color_placeholder = th.color.fg_muted,
			color_border      = th.color.border,
			color_focus       = focus_ring_for(th^, th.color.surface),
			color_caret       = th.color.fg_muted,
			radius            = th.radius.sm,
			padding           = {th.spacing.md, th.spacing.sm},
			font_size         = th.font.size_md,
			width             = width,
			open              = false,
			hover             = trigger_hovered,
			focused           = focused,
		}
		return
	}

	anim_op := widget_anim_step(ctx, &st, 1, 0.12)

	// Popover open: hit-test header arrows + active grid only.
	content_x := overlay_rect.x + overlay_pad + BORDER_W
	content_y := overlay_rect.y + overlay_pad + BORDER_W

	prev_rect  := Rect{content_x, content_y, HEADER_H, HEADER_H}
	next_rect  := Rect{content_x + inner_w - HEADER_H, content_y, HEADER_H, HEADER_H}
	title_rect := Rect{content_x + HEADER_H, content_y, inner_w - 2*HEADER_H, HEADER_H}

	prev_hover  := rect_contains_point(prev_rect,  ctx.input.mouse_pos)
	next_hover  := rect_contains_point(next_rect,  ctx.input.mouse_pos)

	grid_origin_y := content_y + HEADER_H

	// Footer row rect: Now → set to wall clock + close. No Clear button
	// because Time{} = 00:00 is a valid value (midnight), so "clear" has
	// no unset state to snap back to — see the Time struct's doc comment.
	time_footer_y := content_y + overlay_h - 2*(overlay_pad + BORDER_W) - TIME_FOOTER_H
	time_now_rect := Rect{content_x, time_footer_y, inner_w, TIME_FOOTER_H}

	if ctx.input.mouse_released[.Left] {
		if prev_hover {
			mode = (mode - 1 + mode_count) %% mode_count
			st.cursor_pos = mode
		} else if next_hover {
			mode = (mode + 1) %% mode_count
			st.cursor_pos = mode
		} else if rect_contains_point(time_now_rect, ctx.input.mouse_pos) {
			now_t := time.now()
			nh, nm, _ := time.clock_from_time(now_t)
			// Snap minutes to the *nearest* step so Now commits a valid
			// grid value close to the wall clock — 14:03 with step=5
			// rounds up to 14:05, 14:02 rounds down to 14:00. The +step/2
			// bias turns floor-divide into round-to-nearest. Carry the
			// hour if rounding pushes past :60.
			nm = ((nm + step / 2) / step) * step
			if nm >= 60 {
				nm -= 60
				nh = (nh + 1) %% 24
			}
			// Seconds are always zeroed — wall-clock seconds feel
			// arbitrary by the time the user has clicked the button, so
			// "Now" conventionally means "current hour + minute, fresh
			// seconds." Apps that genuinely need wall-clock-second
			// precision can wire their own button with
			// `on_change(Time{hour = h, minute = m, second = s})`.
			new_value, changed = Time{hour = nh, minute = nm, second = 0}, true
			st.open = false
		} else {
			rel_x := ctx.input.mouse_pos.x - content_x
			rel_y := ctx.input.mouse_pos.y - grid_origin_y
			switch mode {
			case 0: // Hour
				if rel_x >= 0 && rel_y >= 0 && rel_x < hour_cell_w*f32(HOUR_COLS) &&
				   rel_y < CELL_H*f32(HOUR_ROWS) {
					c := int(rel_x / hour_cell_w)
					r := int(rel_y / CELL_H)
					new_hour := r*HOUR_COLS + c
					if new_hour >= 0 && new_hour < 24 && new_hour != value.hour {
						new_value, changed = Time{hour = new_hour, minute = value.minute, second = value.second}, true
					}
				}
			case 1: // Minute
				if rel_x >= 0 && rel_y >= 0 && rel_x < min_cell_w*f32(min_cols) &&
				   rel_y < CELL_H*f32(min_rows) {
					c := int(rel_x / min_cell_w)
					r := int(rel_y / CELL_H)
					idx := r*min_cols + c
					if idx >= 0 && idx < min_n {
						new_min := idx * step
						if new_min != value.minute {
							new_value, changed = Time{hour = value.hour, minute = new_min, second = value.second}, true
						}
					}
				}
			case 2: // Second
				if show_sec && rel_x >= 0 && rel_y >= 0 && rel_x < sec_cell_w*f32(sec_cols) &&
				   rel_y < CELL_H*f32(sec_rows) {
					c := int(rel_x / sec_cell_w)
					r := int(rel_y / CELL_H)
					idx := r*sec_cols + c
					if idx >= 0 && idx < sec_n {
						new_sec := idx * sec_step
						if new_sec != value.second {
							new_value, changed = Time{hour = value.hour, minute = value.minute, second = new_sec}, true
						}
					}
				}
			}
		}
	}

	if ctx.input.mouse_pressed[.Left] && mouse_over_overlay {
		ctx.input.mouse_pressed[.Left] = false
	}
	if ctx.input.mouse_released[.Left] && mouse_over_overlay {
		ctx.input.mouse_released[.Left] = false
	}

	widget_set(ctx, id, st)

	// Build header (< Title >).
	title_str := "Hour"
	switch mode {
	case 1: title_str = "Minute"
	case 2: title_str = "Second"
	}

	prev_bg := th.color.elevated
	next_bg := th.color.elevated
	if prev_hover { prev_bg = th.color.surface }
	if next_hover { next_bg = th.color.surface }

	header := row(
		col(
			text("<", th.color.fg, th.font.size_md),
			width = HEADER_H, height = HEADER_H,
			main_align = .Center, cross_align = .Center,
			bg = prev_bg, radius = th.radius.sm,
		),
		flex(1, col(
			text(title_str, th.color.fg, th.font.size_md),
			height = HEADER_H,
			main_align = .Center, cross_align = .Center,
		)),
		col(
			text(">", th.color.fg, th.font.size_md),
			width = HEADER_H, height = HEADER_H,
			main_align = .Center, cross_align = .Center,
			bg = next_bg, radius = th.radius.sm,
		),
		width = inner_w,
	)

	// Build only the active mode's grid.
	active_grid: View
	switch mode {
	case 0:
		hour_rows := make([]View, HOUR_ROWS, context.temp_allocator)
		for r in 0..<HOUR_ROWS {
			hcells := make([]View, HOUR_COLS, context.temp_allocator)
			for c in 0..<HOUR_COLS {
				h := r*HOUR_COLS + c
				cell_rect := Rect{
					content_x + f32(c)*hour_cell_w,
					grid_origin_y + f32(r)*CELL_H,
					hour_cell_w, CELL_H,
				}
				is_selected := h == value.hour
				bg_c  := Color{}
				fg_c2 := th.color.fg
				if is_selected {
					bg_c  = th.color.primary
					fg_c2 = th.color.on_primary
				} else if rect_contains_point(cell_rect, ctx.input.mouse_pos) {
					bg_c = th.color.surface
				}
				hcells[c] = col(
					text(fmt.tprintf("%02d", h), fg_c2, th.font.size_sm),
					width = hour_cell_w, height = CELL_H,
					main_align = .Center, cross_align = .Center,
					bg = bg_c, radius = th.radius.sm,
				)
			}
			hour_rows[r] = row(..hcells, width = inner_w)
		}
		active_grid = col(..hour_rows, width = inner_w)

	case 1:
		min_rows_v := make([]View, min_rows, context.temp_allocator)
		for r in 0..<min_rows {
			mcells := make([]View, min_cols, context.temp_allocator)
			for c in 0..<min_cols {
				idx := r*min_cols + c
				if idx >= min_n {
					mcells[c] = col(
						text("", th.color.fg, th.font.size_sm),
						width = min_cell_w, height = CELL_H,
					)
					continue
				}
				m := idx * step
				cell_rect := Rect{
					content_x + f32(c)*min_cell_w,
					grid_origin_y + f32(r)*CELL_H,
					min_cell_w, CELL_H,
				}
				is_selected := m == value.minute
				bg_c  := Color{}
				fg_c2 := th.color.fg
				if is_selected {
					bg_c  = th.color.primary
					fg_c2 = th.color.on_primary
				} else if rect_contains_point(cell_rect, ctx.input.mouse_pos) {
					bg_c = th.color.surface
				}
				mcells[c] = col(
					text(fmt.tprintf("%02d", m), fg_c2, th.font.size_sm),
					width = min_cell_w, height = CELL_H,
					main_align = .Center, cross_align = .Center,
					bg = bg_c, radius = th.radius.sm,
				)
			}
			min_rows_v[r] = row(..mcells, width = inner_w)
		}
		active_grid = col(..min_rows_v, width = inner_w)

	case 2:
		sec_rows_v := make([]View, sec_rows, context.temp_allocator)
		for r in 0..<sec_rows {
			scells := make([]View, sec_cols, context.temp_allocator)
			for c in 0..<sec_cols {
				idx := r*sec_cols + c
				if idx >= sec_n {
					scells[c] = col(
						text("", th.color.fg, th.font.size_sm),
						width = sec_cell_w, height = CELL_H,
					)
					continue
				}
				s := idx * sec_step
				cell_rect := Rect{
					content_x + f32(c)*sec_cell_w,
					grid_origin_y + f32(r)*CELL_H,
					sec_cell_w, CELL_H,
				}
				is_selected := s == value.second
				bg_c  := Color{}
				fg_c2 := th.color.fg
				if is_selected {
					bg_c  = th.color.primary
					fg_c2 = th.color.on_primary
				} else if rect_contains_point(cell_rect, ctx.input.mouse_pos) {
					bg_c = th.color.surface
				}
				scells[c] = col(
					text(fmt.tprintf("%02d", s), fg_c2, th.font.size_sm),
					width = sec_cell_w, height = CELL_H,
					main_align = .Center, cross_align = .Center,
					bg = bg_c, radius = th.radius.sm,
				)
			}
			sec_rows_v[r] = row(..scells, width = inner_w)
		}
		active_grid = col(..sec_rows_v, width = inner_w)
	}

	// Footer: full-width Now button jumps to the wall-clock time and
	// closes the popover. No Clear — see the hit-test above for why.
	time_now_hovered := rect_contains_point(time_now_rect, ctx.input.mouse_pos)
	time_now_bg: Color = {}
	if time_now_hovered { time_now_bg = th.color.surface }
	time_footer := col(
		text(ctx.labels.now, th.color.primary, th.font.size_md),
		width       = inner_w, height = TIME_FOOTER_H,
		main_align  = .Center, cross_align = .Center,
		bg          = time_now_bg,
		radius      = th.radius.sm,
	)

	inner := col(
		header,
		active_grid,
		flex(1, spacer(0)),
		time_footer,
		spacing     = 0,
		padding     = overlay_pad,
		width       = POPOVER_W - 2*BORDER_W,
		height      = overlay_h - 2*BORDER_W,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Start,
	)
	card := col(
		inner,
		padding     = BORDER_W,
		width       = POPOVER_W,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Start,
	)

	trigger := View_Select{
		id                = id,
		value             = display,
		placeholder       = placeholder,
		color_bg          = th.color.surface,
		color_fg          = th.color.fg,
		color_placeholder = th.color.fg_muted,
		color_border      = th.color.border,
		color_focus       = focus_ring_for(th^, th.color.surface),
		color_caret       = th.color.fg_muted,
		radius            = th.radius.sm,
		padding           = {th.spacing.md, th.spacing.sm},
		font_size         = th.font.size_md,
		width             = width,
		open              = st.open,
		hover             = trigger_hovered,
		focused           = focused,
	}

	view = col(
		trigger,
		overlay(trigger_rect, card, .Below, {0, 4}, anim_op),
	)
	return
}

time_picker_simple :: proc(
	ctx:         ^Ctx($Msg),
	value:       Time,
	on_change:   proc(new_value: Time) -> Msg,
	id:          Widget_ID = 0,
	width:       f32       = 0,
	placeholder: string    = "",
	disabled:   bool      = false,
	minute_step: int       = 15,
	second_step: int       = 0,
	format:      proc(t: Time) -> string = nil,
) -> View {
	view, new_value, changed := _time_picker_impl(
		ctx, value,
		id = id, width = width, placeholder = placeholder,
		disabled = disabled, minute_step = minute_step, second_step = second_step,
		format = format,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

time_picker_payload :: proc(
	ctx:         ^Ctx($Msg),
	value:       Time,
	payload:     $Payload,
	on_change:   proc(payload: Payload, new_value: Time) -> Msg,
	id:          Widget_ID = 0,
	width:       f32       = 0,
	placeholder: string    = "",
	disabled:   bool      = false,
	minute_step: int       = 15,
	second_step: int       = 0,
	format:      proc(t: Time) -> string = nil,
) -> View {
	view, new_value, changed := _time_picker_impl(
		ctx, value,
		id = id, width = width, placeholder = placeholder,
		disabled = disabled, minute_step = minute_step, second_step = second_step,
		format = format,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// color_picker builds a swatch trigger that opens a popover with an HSV
// square (saturation × value at the current hue), a hue strip, and a
// read-only hex label. Clicking or dragging inside either region fires
// `on_change(new_value)` continuously — the popover stays open until the
// user clicks outside or presses Escape.
//
//     Msg :: union { Color_Picked: skald.Color, … }
//     on_pick :: proc(c: skald.Color) -> Msg { return Color_Picked(c) }
//
//     skald.color_picker(ctx, state.brand_color, on_pick, width = 140)
//
// The trigger renders as a 32-px-tall rounded rect: a square swatch on
// the left showing the current color, and the 6-digit sRGB hex string
// on the right. `width = 0` falls through to a content-sized trigger
// (swatch + hex). Pass an explicit width to match surrounding fields.
//
// Hue preservation: when the user drags saturation to zero the value
// produced is grey, which on its own would lose the active hue. The
// picker caches the last-known hue on its widget slot while open so
// follow-on drags at S=0 and V>0 still track the same column of the
// rainbow.
color_picker :: proc{color_picker_simple, color_picker_payload}

@(private)
_color_picker_impl :: proc(
	ctx:       ^Ctx($Msg),
	value:     Color,
	id:        Widget_ID = 0,
	width:     f32       = 0,
	disabled: bool      = false,
) -> (view: View, new_value: Color, changed: bool) {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Color_Picker)
	focused := !disabled && widget_has_focus(ctx, id)

	if disabled { st.open = false }
	// If a modal dialog is open and this widget sits outside its card,
	// force-close any in-progress popover. A stranded dropdown peeking
	// out from under a dialog reads as a bug, and input gates can't
	// reach it anyway.
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, st.last_rect) {
		st.open = false
	}

	trigger_rect    := st.last_rect
	trigger_hovered := !disabled && rect_hovered(ctx, trigger_rect)

	// Popover geometry. The SV square is square-ish (square at 220×160 here
	// which is close enough; shortens vertical so hex+hue fit in one card).
	POPOVER_W :: f32(260)
	SV_W      :: f32(220)
	SV_H      :: f32(160)
	HUE_H     :: f32(16)
	FOOTER_H  :: f32(28)
	HUE_SEGS  :: 30 // vertical segments decomposing the hue gradient
	overlay_pad := th.spacing.md
	BORDER_W    := f32(1)
	inner_gap   := th.spacing.sm
	overlay_h := 2*(overlay_pad + BORDER_W) + SV_H + inner_gap + HUE_H + inner_gap + FOOTER_H

	overlay_rect := overlay_placement_rect(ctx, trigger_rect,
		{POPOVER_W, overlay_h}, .Below, {0, 4})
	mouse_over_overlay := rect_contains_point(overlay_rect, ctx.input.mouse_pos)
	if st.open { widget_stamp_overlay_rect(ctx.widgets, overlay_rect) }

	// Content rects inside the overlay (post-border, post-pad).
	content_x := overlay_rect.x + overlay_pad + BORDER_W
	content_y := overlay_rect.y + overlay_pad + BORDER_W
	sv_rect  := Rect{content_x, content_y, SV_W, SV_H}
	hue_rect := Rect{content_x, content_y + SV_H + inner_gap, SV_W, HUE_H}

	// Seed cached hue on open. `drag_anchor` stores hue in degrees while
	// the picker is open; 0 is a valid hue so we also use `selection_anchor`
	// as a "has been seeded" bit (non-zero = seeded).
	seed_hue :: proc(st: ^Widget_State, v: Color) {
		h := rgb_to_hsv(v)
		st.drag_anchor = h.h
		st.selection_anchor = 1
	}

	// Trigger toggle + outside-click dismiss.
	if !disabled && ctx.input.mouse_pressed[.Left] {
		if trigger_hovered {
			st.open = !st.open
			widget_focus(ctx, id)
			focused = true
			if st.open { seed_hue(&st, value) }
		} else if st.open && !mouse_over_overlay {
			st.open = false
		}
	}

	if focused && !disabled {
		keys := ctx.input.keys_pressed
		if !st.open && (.Space in keys || .Enter in keys) {
			st.open = true
			seed_hue(&st, value)
		}
		if .Escape in keys { st.open = false }
	}

	// Resolve the active hue: if not seeded, derive from current value.
	hue := st.drag_anchor
	if st.selection_anchor == 0 { hue = rgb_to_hsv(value).h }

	// Inline hex editor — a sub-slot that lives inside the popover footer.
	// Typing a six-character hex emits on_change; partial input (<6 chars
	// or hex that fails to parse) is retained on the buffer so the user can
	// keep typing across frames. We re-sync the buffer from `value` whenever
	// the hex field isn't focused so SV/hue drags show up as canonical text.
	hex_id := hash_id(fmt.tprintf("color_picker_hex_%x", u64(id)))
	if !disabled && st.open { widget_make_focusable(ctx, hex_id) }
	hex_st := widget_get(ctx, hex_id, .Text_Input)
	hex_focused := !disabled && st.open && widget_has_focus(ctx, hex_id)

	if !st.open {
		if len(hex_st.text_buffer) > 0 { delete(hex_st.text_buffer) }
		hex_st.text_buffer = ""
		hex_st.cursor_pos  = 0
		if widget_has_focus(ctx, hex_id) { widget_focus(ctx, 0) }
	}

	// Latch a drag target on press, release on mouse up.
	// cursor_pos: 0 = none, 1 = SV drag, 2 = Hue drag.
	if st.open && !disabled {
		if ctx.input.mouse_pressed[.Left] {
			over_hex := rect_contains_point(hex_st.last_rect, ctx.input.mouse_pos)
			if over_hex {
				widget_focus(ctx, hex_id)
				hex_focused = true
			} else if hex_focused && mouse_over_overlay {
				widget_focus(ctx, id)
				hex_focused = false
			}
			if rect_contains_point(sv_rect, ctx.input.mouse_pos) {
				st.pressed    = true
				st.cursor_pos = 1
			} else if rect_contains_point(hue_rect, ctx.input.mouse_pos) {
				st.pressed    = true
				st.cursor_pos = 2
			}
		}
		if ctx.input.mouse_released[.Left] {
			st.pressed    = false
			st.cursor_pos = 0
		}

		if st.pressed {
			mp := ctx.input.mouse_pos
			switch st.cursor_pos {
			case 1: // SV
				s := clamp((mp.x - sv_rect.x) / sv_rect.w, 0, 1)
				v := 1 - clamp((mp.y - sv_rect.y) / sv_rect.h, 0, 1)
				new_c := hsv_to_rgb(HSV{h = hue, s = s, v = v})
				new_c.a = value.a
				new_value, changed = new_c, true
			case 2: // Hue
				h := clamp((mp.x - hue_rect.x) / hue_rect.w, 0, 1) * 360
				st.drag_anchor = h
				hue = h
				hsv := rgb_to_hsv(value)
				new_c := hsv_to_rgb(HSV{h = h, s = hsv.s, v = hsv.v})
				new_c.a = value.a
				new_value, changed = new_c, true
			}
		}
	}

	// Hex buffer sync + text-input handling.
	if st.open && !disabled {
		if !hex_focused {
			canonical := color_to_hex(value)
			if hex_st.text_buffer != canonical {
				if len(hex_st.text_buffer) > 0 { delete(hex_st.text_buffer) }
				hex_st.text_buffer = strings.clone(canonical)
				hex_st.cursor_pos  = len(hex_st.text_buffer)
			}
		} else {
			ctx.widgets.wants_text_input = true

			// Clone into temp so every mutation below produces a
			// frame-arena string — otherwise `draft[:len(draft)-1]`
			// after a Backspace would alias the persistent buffer
			// we're about to free, corrupting the next assignment.
			draft       := strings.clone(hex_st.text_buffer, context.temp_allocator)
			hex_changed := false

			if len(ctx.input.text) > 0 {
				for i := 0; i < len(ctx.input.text); i += 1 {
					if len(draft) >= 6 { break }
					ch := ctx.input.text[i]
					ok := (ch >= '0' && ch <= '9') ||
					      (ch >= 'a' && ch <= 'f') ||
					      (ch >= 'A' && ch <= 'F')
					if !ok { continue }
					if ch >= 'a' && ch <= 'f' { ch -= 'a' - 'A' }
					draft       = strings.concatenate({draft, string([]u8{ch})}, context.temp_allocator)
					hex_changed = true
				}
			}

			keys := ctx.input.keys_pressed
			if .Backspace in keys && len(draft) > 0 {
				draft       = draft[:len(draft) - 1]
				hex_changed = true
			}
			if .Enter in keys || .Escape in keys {
				widget_focus(ctx, id)
				hex_focused = false
			}

			if hex_changed {
				if len(hex_st.text_buffer) > 0 { delete(hex_st.text_buffer) }
				hex_st.text_buffer = strings.clone(draft)
				hex_st.cursor_pos  = len(hex_st.text_buffer)
				if c, ok := hex_to_color(hex_st.text_buffer); ok {
					new_c := c
					new_c.a = value.a
					new_value, changed = new_c, true
				}
			}
		}
	}

	// Swallow clicks inside the overlay so widgets built afterwards don't
	// see them (matches select/date_picker).
	if st.open {
		if ctx.input.mouse_pressed[.Left]  && mouse_over_overlay {
			ctx.input.mouse_pressed[.Left]  = false
		}
		if ctx.input.mouse_released[.Left] && mouse_over_overlay {
			ctx.input.mouse_released[.Left] = false
		}
	}

	anim_op: f32 = 0
	if st.open {
		anim_op = widget_anim_step(ctx, &st, 1, 0.12)
	} else {
		st.anim_t = 0
		st.anim_prev_ns = 0
	}

	widget_set(ctx, id, st)
	widget_set(ctx, hex_id, hex_st)

	// Build the trigger: swatch + hex label inside a bordered rounded row.
	hex := color_to_hex(value)
	border_c := th.color.border
	if focused  { border_c = th.color.primary }
	// Checkerboard would sit here if we drew alpha — skipped for MVP.
	swatch_box := col(
		rect({20, 20}, value, th.radius.sm),
		width = 20, height = 20,
	)
	trigger_label := text(fmt.tprintf("#%s", hex), th.color.fg, th.font.size_md)
	// Trailing caret (same ▼ glyph used by collapsibles / section toggles
	// — Inter ships it, unlike ▾ which renders as a fallback rectangle).
	// Signals "clickable trigger" to match the select / date / time picker
	// family, who get a hand-drawn caret from View_Select.
	trigger_caret := text("▼", th.color.fg_muted, th.font.size_sm)
	trigger_inner := row(
		swatch_box,
		trigger_label,
		flex(1, spacer(0)),
		trigger_caret,
		spacing     = th.spacing.sm,
		cross_align = .Center,
	)
	trigger_view := col(
		trigger_inner,
		height      = th.font.size_md + 2*th.spacing.sm,
		width       = width,
		padding     = th.spacing.sm,
		bg          = th.color.surface,
		radius      = th.radius.sm,
		cross_align = .Stretch,
		main_align  = .Center,
	)
	// Replace outer col with bordered row: simpler — wrap in a 1-px border
	// col so the focus ring is unambiguous.
	bordered_trigger := col(
		trigger_view,
		padding     = BORDER_W,
		width       = width,
		bg          = border_c,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)
	c := new(View, context.temp_allocator)
	c^ = bordered_trigger
	zone_trigger := View(View_Zone{id = id, child = c})

	if !st.open {
		view = zone_trigger
		return
	}

	// Build the popover contents. True HSV at (s, v) is
	//     C(s, v) = v * lerp(white, hue, s)
	// — multiplicative in v, which a single linear bilinear quad can't
	// express (it leaves the bottom-left corner bright where it should
	// be black). Decompose into two passes:
	//   1. Horizontal gradient from white (s=0) to the pure hue (s=1),
	//      constant over v — this is lerp(white, hue, s).
	//   2. Overlayed vertical gradient, transparent at top and opaque
	//      black at the bottom — source-over alpha blending multiplies
	//      the base by v, producing the correct C(s, v).
	// Pass 2 is queued as an overlay so it renders after the base, and
	// the SV marker + hue marker queue after pass 2 so they stay on top.
	hue_color := hsv_to_rgb(HSV{h = hue, s = 1, v = 1})
	white     := Color{1, 1, 1, 1}
	sv_square := View_Gradient_Rect{
		size   = {SV_W, SV_H},
		c_tl   = white,     c_tr = hue_color,
		c_bl   = white,     c_br = hue_color,
		radius = 0,
	}
	sv_black_overlay := View_Gradient_Rect{
		size   = {SV_W, SV_H},
		c_tl   = {0, 0, 0, 0}, c_tr = {0, 0, 0, 0},
		c_bl   = {0, 0, 0, 1}, c_br = {0, 0, 0, 1},
		radius = 0,
	}
	sv_black_ovl := overlay(
		Rect{sv_rect.x, sv_rect.y, 0, 0},
		sv_black_overlay, .Below, {0, 0}, anim_op,
	)

	// Hue strip — decompose into HUE_SEGS vertical segments so we sample
	// the hue curve in linear space finely enough to look smooth.
	hue_seg_views := make([]View, HUE_SEGS, context.temp_allocator)
	for i in 0..<HUE_SEGS {
		h0 := f32(i)   * 360 / f32(HUE_SEGS)
		h1 := f32(i+1) * 360 / f32(HUE_SEGS)
		cl := hsv_to_rgb(HSV{h = h0, s = 1, v = 1})
		cr := hsv_to_rgb(HSV{h = h1, s = 1, v = 1})
		hue_seg_views[i] = View_Gradient_Rect{
			size   = {SV_W / f32(HUE_SEGS), HUE_H},
			c_tl   = cl, c_tr = cr, c_br = cr, c_bl = cl,
			radius = 0,
		}
	}
	hue_strip := row(
		..hue_seg_views,
		spacing = 0,
		width   = SV_W,
		height  = HUE_H,
	)

	// Markers: circular for SV (ring), thin vertical bar for hue.
	cur_hsv := rgb_to_hsv(value)
	// Keep marker in sync with active hue (cur_hsv.h may differ from `hue`
	// if the value is grey or if user just dragged).
	sv_mx := sv_rect.x + cur_hsv.s * sv_rect.w
	sv_my := sv_rect.y + (1 - cur_hsv.v) * sv_rect.h
	marker_sz := f32(12)
	sv_marker := col(
		col(
			rect({marker_sz - 4, marker_sz - 4}, value, (marker_sz - 4) * 0.5),
			width   = marker_sz - 4,
			height  = marker_sz - 4,
			padding = 0,
		),
		width       = marker_sz,
		height      = marker_sz,
		padding     = 2,
		bg          = rgb(0xffffff),
		radius      = marker_sz * 0.5,
		cross_align = .Center,
		main_align  = .Center,
	)
	sv_marker_ovl := overlay(
		Rect{sv_mx - marker_sz*0.5, sv_my - marker_sz*0.5, 0, 0},
		sv_marker, .Below, {0, 0}, anim_op,
	)

	hue_mx := hue_rect.x + (hue / 360) * hue_rect.w
	hue_marker := col(
		rect({2, HUE_H + 4}, rgb(0xffffff), 1),
		width  = 2,
		height = HUE_H + 4,
	)
	hue_marker_ovl := overlay(
		Rect{hue_mx - 1, hue_rect.y - 2, 0, 0},
		hue_marker, .Below, {0, 0}, anim_op,
	)

	// Editable hex field. Uses our own mini-renderer via View_Text_Input so
	// the sub-slot's last_rect gets stamped by the layout pass — that's what
	// the mouse hit-test above reads next frame. Caret lives at end of the
	// draft, which is the only position typing and backspace can reach.
	hex_font   := th.font.size_md
	hex_pad_x  := th.spacing.sm
	hex_pad_y  := th.spacing.xs
	hex_h      := hex_font + 2*hex_pad_y + 6
	hex_w      := f32(96)
	hex_draft  := hex_st.text_buffer
	if !st.open { hex_draft = color_to_hex(value) }
	hex_border := th.color.border
	if hex_focused { hex_border = th.color.primary }
	hex_field := View_Text_Input{
		id                = hex_id,
		text              = hex_draft,
		color_bg          = th.color.surface,
		color_fg          = th.color.fg,
		color_placeholder = th.color.fg_muted,
		color_border      = hex_border,
		color_border_idle = th.color.border,
		color_caret       = th.color.fg,
		color_selection   = th.color.selection,
		radius            = th.radius.sm,
		padding           = {hex_pad_x, hex_pad_y},
		font_size         = hex_font,
		width             = hex_w,
		height            = hex_h,
		focused           = hex_focused,
		cursor_pos        = len(hex_draft),
		selection_anchor  = len(hex_draft),
		visual_lines      = []Visual_Line{
			Visual_Line{start = 0, end = len(hex_draft), consume_space = false},
		},
	}
	footer := row(
		col(
			rect({24, 20}, value, th.radius.sm),
			width = 24, height = 20,
		),
		text("#", th.color.fg_muted, th.font.size_md),
		View(hex_field),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	)

	inner := col(
		sv_square,
		hue_strip,
		footer,
		spacing     = inner_gap,
		padding     = overlay_pad,
		width       = POPOVER_W - 2*BORDER_W,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Start,
	)
	card := col(
		inner,
		padding     = BORDER_W,
		width       = POPOVER_W,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Start,
	)

	view = col(
		zone_trigger,
		overlay(trigger_rect, card, .Below, {0, 4}, anim_op),
		sv_black_ovl,
		sv_marker_ovl,
		hue_marker_ovl,
	)
	return
}

color_picker_simple :: proc(
	ctx:       ^Ctx($Msg),
	value:     Color,
	on_change: proc(new_value: Color) -> Msg,
	id:        Widget_ID = 0,
	width:     f32       = 0,
	disabled: bool      = false,
) -> View {
	view, new_value, changed := _color_picker_impl(
		ctx, value, id = id, width = width, disabled = disabled,
	)
	if changed { send(ctx, on_change(new_value)) }
	return view
}

color_picker_payload :: proc(
	ctx:       ^Ctx($Msg),
	value:     Color,
	payload:   $Payload,
	on_change: proc(payload: Payload, new_value: Color) -> Msg,
	id:        Widget_ID = 0,
	width:     f32       = 0,
	disabled: bool      = false,
) -> View {
	view, new_value, changed := _color_picker_impl(
		ctx, value, id = id, width = width, disabled = disabled,
	)
	if changed { send(ctx, on_change(payload, new_value)) }
	return view
}

// tabs builds a horizontal strip of label headers with one marked
// "active". Clicking a label fires `on_change(index)`. Renders just
// the header row — the caller switches on `active` to build the
// content panel below, which keeps tabs composable with any layout
// (sidebars, split panes, conditional content).
//
//     Msg :: union { Tab_Changed: int, ... }
//     on_tab :: proc(i: int) -> Msg { return Tab_Changed(i) }
//
//     skald.col(
//         skald.tabs(ctx, []string{"General", "Advanced"}, state.tab, on_tab),
//         skald.spacer(th.spacing.md),
//         panel_for(state.tab),
//     )
//
// Active tab: surface fill + unmuted fg + 2-px accent underline so the
// selected header reads clearly. Inactive tabs: window bg + muted fg.
// The underline is part of the tab's layout column (not floated) so
// adjacent tabs can't visually overlap it.
tabs :: proc(
	ctx:       ^Ctx($Msg),
	labels:    []string,
	active:    int,
	on_change: proc(index: int) -> Msg,
) -> View {
	th := ctx.theme

	items := make([]View, len(labels), context.temp_allocator)
	for label, i in labels {
		is_active := i == active

		// Tabs read cleanly on any parent when active/inactive don't
		// fight the parent's bg. Inactive: plain `surface` — blends
		// into a surface card, reads as a flat tile on a page body.
		// Active: a faint primary tint over surface (~6% primary mixed
		// in) so the selected tab always looks subtly *lit* whatever
		// the parent is. The accent underline + unmuted fg carry the
		// rest of the selection signal.
		bg := th.color.surface
		fg := th.color.fg_muted
		if is_active {
			bg = color_mix(th.color.primary, th.color.surface, 0.94)
			fg = th.color.fg
		}

		// Underline: inactive rows get a border-colored hairline so the
		// strip sits on a shared baseline; active rows paint the accent
		// on top, 2-px for emphasis.
		underline_color := th.color.border
		underline_h     := f32(1)
		if is_active {
			underline_color = th.color.primary
			underline_h     = 2
		}

		items[i] = col(
			button(ctx, label, on_change(i),
				color     = bg,
				fg        = fg,
				radius    = th.radius.sm,
				padding   = {th.spacing.md, th.spacing.sm},
				font_size = th.font.size_md,
			),
			rect({0, underline_h}, underline_color, 0),
			spacing     = 2,
			cross_align = .Stretch,
		)
	}
	return row(..items, spacing = th.spacing.xs, cross_align = .End)
}

// menu builds a vertical card of clickable rows — a popover for
// context menus, dropdowns, and command palettes. The menu itself
// is stateless visually (no open/closed of its own): compose it
// with `overlay(anchor, menu(...))` and hide the whole thing from
// the view tree while closed. Clicking a row fires `on_select(i)`;
// the caller is responsible for flipping the open flag off in its
// `update` — matching `button`'s "emit and move on" style.
//
//     menu(ctx,
//         []string{"Rename", "Duplicate", "Delete"},
//         proc(i: int) -> Msg { return Menu_Selected(i) },
//         on_dismiss = proc() -> Msg { return Menu_Closed{} },
//     )
//
// A left-click that lands outside the menu's previous-frame rect
// fires `on_dismiss`. That's how "click anywhere else to cancel" is
// wired up — the app's update maps the dismiss msg to
// `menu_open = false` and the menu vanishes next frame. The callback
// is required because a menu without a dismiss path would be a trap;
// apps that legitimately want an always-open menu can pass a no-op
// Msg variant that their update ignores.
//
// Widget-ID note: passing an explicit `id` makes the menu's rect-
// tracking slot stable across opens; without one the positional id
// depends on where the menu sits in the tree, which is fine because
// the menu usually lives at a single tree position anyway.
menu :: proc(
	ctx:        ^Ctx($Msg),
	labels:     []string,
	on_select:  proc(index: int) -> Msg,
	on_dismiss: proc() -> Msg,
	id:         Widget_ID = 0,
	width:      f32 = 200,
) -> View {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Click_Zone)

	// Outside-click dismissal. Guard against the zero rect on the
	// first frame of the menu — without this, the "click is outside
	// an empty rect" check fires immediately and the menu closes
	// before it's visible.
	if ctx.input.mouse_pressed[.Left] &&
	   st.last_rect.w > 0 &&
	   !rect_contains_point(st.last_rect, ctx.input.mouse_pos) {
		send(ctx, on_dismiss())
	}

	widget_set(ctx, id, st)

	// Wrap the option-row buttons in a per-menu widget scope so their
	// auto-id consumption doesn't pollute the parent counter. Without
	// this, opening the menu (which adds N buttons to the view tree)
	// would shift every auto-id past the menu — a sibling dialog or
	// popover-bearing widget rendered after this menu would get a
	// different id when it's open vs closed, breaking its state.
	scope := widget_scope_push(ctx, u64(id))
	rows := make([dynamic]View, 0, len(labels), context.temp_allocator)
	for label, i in labels {
		append(&rows, button(ctx, label, on_select(i),
			color     = th.color.elevated,
			fg        = th.color.fg,
			radius    = th.radius.sm,
			padding   = {th.spacing.md, th.spacing.sm},
			font_size = th.font.size_md,
		))
	}
	widget_scope_pop(ctx, scope)

	// Two layers: an outer border-colored rect 1 px larger than the
	// inner, padded by 1 so the inner's edge leaves a hairline of
	// border color showing. No shadow primitive yet — the 1 px
	// outline + elevated fill is enough to separate the menu from
	// the surface beneath it without real depth.
	inner := col(..rows[:],
		spacing     = 2,
		padding     = 4,
		width       = width - 2,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)
	card := col(
		inner,
		padding     = 1,
		width       = width,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)

	c := new(View, context.temp_allocator)
	c^ = card
	return View_Zone{id = id, child = c}
}

// right_click_zone wraps `child` in a passthrough that emits
// `on_right_click` whenever a right-mouse press lands inside
// the child's rect. It's the canonical way to attach a
// context-menu trigger to a region — a list row, a canvas, the
// empty area of a pane — without pushing right-click semantics
// into every leaf widget.
//
//     skald.right_click_zone(ctx, row_body,
//         Menu_Opened{key = item.key, pos = ctx.input.mouse_pos},
//     )
//
// Odin procs don't capture, so the cursor position must be baked
// into the Msg at construction time — `ctx.input.mouse_pos` is
// already the fresh-pressed position on the frame the right-click
// fires, so reading it here produces the pixel the user clicked.
// The child still gets all left-clicks and hover as usual; the
// zone only listens for the right-button press event.
right_click_zone :: proc(
	ctx:            ^Ctx($Msg),
	child:          View,
	on_right_click: Msg,
	id:             Widget_ID = 0,
) -> View {
	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Click_Zone)

	if ctx.input.mouse_pressed[.Right] &&
	   rect_contains_point(st.last_rect, ctx.input.mouse_pos) {
		send(ctx, on_right_click)
	}

	widget_set(ctx, id, st)

	c := new(View, context.temp_allocator)
	c^ = child
	return View_Zone{id = id, child = c}
}

// context_menu wraps `child` in a right-click-detecting zone that pops a
// menu of `items` at the click point. Selecting an item fires
// `on_select(i)`; clicking outside the popover or pressing Escape
// dismisses it. The popover's open/closed state lives inside the
// widget — callers only see the on_select msg when the user commits.
//
//     Msg :: union { Layer_Menu: int, … }
//     on_layer_menu :: proc(i: int) -> Msg { return Layer_Menu(i) }
//
//     skald.context_menu(ctx,
//         layer_row_view,
//         {"Rename", "Duplicate", "Delete"},
//         on_layer_menu,
//     )
//
// Passing an explicit `id` makes the widget's state slot stable across
// tree reshuffles (e.g. reorderable rows) so the popover doesn't close
// itself the moment the child moves. Pair with `hash_id(row.key)` when
// the child's position can change.
//
// `width` controls the popover's fixed width. The menu height follows
// the item count; the popover auto-flips above the cursor if a below-
// cursor placement would overflow the framebuffer (same flip rule as
// date / time / color pickers).
context_menu :: proc(
	ctx:       ^Ctx($Msg),
	child:     View,
	items:     []string,
	on_select: proc(index: int) -> Msg,
	id:        Widget_ID = 0,
	width:     f32       = 200,
) -> View {
	th := ctx.theme
	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Click_Zone)

	// Modal dialog open? Force-close any live popover unless the child
	// this widget wraps actually sits inside the dialog's card.
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, st.last_rect) {
		st.open = false
	}

	// Open on right-click inside the child's last-frame rect. Anchor the
	// popover at the cursor position so the menu reads as "attached to
	// what I just clicked," matching native context-menu behaviour.
	child_hovered := rect_hovered(ctx, st.last_rect)
	if ctx.input.mouse_pressed[.Right] && child_hovered {
		st.open       = true
		st.anchor_pos = ctx.input.mouse_pos
		// Consume so a parent right_click_zone doesn't also fire.
		ctx.input.mouse_pressed[.Right] = false
	}

	// When open, compute the popover rect so we can hit-test and stamp
	// the overlay list for modal-input accounting. Height tracks the
	// items count; 2-px padding, 1-px border, per-row (md+2·sm) tile.
	row_h := th.font.size_md + 2*th.spacing.sm
	popover_h := 2 * 4 + 2 * 1 + f32(len(items)) * row_h + f32(max(0, len(items)-1)) * 2
	popover_w := width
	anchor_rect := Rect{st.anchor_pos.x, st.anchor_pos.y, 0, 0}
	popover_rect := overlay_placement_rect(ctx, anchor_rect,
		{popover_w, popover_h}, .Below, {0, 0})

	if st.open {
		// Outside-click (Left) dismiss — fires before the tree renders so
		// the popover doesn't flash on the dismissal frame.
		if ctx.input.mouse_pressed[.Left] &&
		   !rect_contains_point(popover_rect, ctx.input.mouse_pos) {
			st.open = false
		}
		// Escape also dismisses.
		if .Escape in ctx.input.keys_pressed { st.open = false }
		// Any click inside the popover closes it — the row buttons still
		// fire their own on_select on release, so the selection lands
		// before the popover disappears next frame.
		if ctx.input.mouse_released[.Left] &&
		   rect_contains_point(popover_rect, ctx.input.mouse_pos) {
			st.open = false
		}
	}
	// Keep stamping the overlay rect while the popover is still
	// visible (open or mid-fade-out). Without this the gate drops
	// when st.open flips, and widgets underneath the fading menu
	// immediately claim clicks — the menu looks alive but routes
	// events to the wrong target.
	if st.open || st.anim_t > 0.01 {
		widget_stamp_overlay_rect(ctx.widgets, popover_rect)
	}

	// Target-seeking fade: 1 while open, 0 when closed. The helper
	// auto-wakes the next frame while mid-tween so the decay finishes
	// even under lazy redraw. Rendering the popover keeps going while
	// anim_op > 0; interactive paths gate on `st.open` so a fading
	// popover can't swallow clicks.
	target: f32 = 1 if st.open else 0
	anim_op := widget_anim_step(ctx, &st, target, 0.12)

	widget_set(ctx, id, st)

	c := new(View, context.temp_allocator)
	c^ = child
	zoned := View(View_Zone{id = id, child = c})

	if !st.open && anim_op <= 0.01 { return zoned }

	// Build the popover: same two-layer card (border + elevated) as the
	// menu widget so the two read as the same family visually.
	// Wrap in a per-context-menu widget scope so the option-row buttons'
	// auto-id consumption stays isolated from the parent counter — see
	// the same pattern in `menu` and `_select_impl`.
	scope := widget_scope_push(ctx, u64(id))
	rows := make([dynamic]View, 0, len(items), context.temp_allocator)
	for label, i in items {
		append(&rows, button(ctx, label, on_select(i),
			color      = th.color.elevated,
			fg         = th.color.fg,
			radius     = th.radius.sm,
			padding    = {th.spacing.md, th.spacing.sm},
			font_size  = th.font.size_md,
			text_align = .Start,
		))
	}
	widget_scope_pop(ctx, scope)
	inner := col(..rows[:],
		spacing     = 2,
		padding     = 4,
		width       = popover_w - 2,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)
	card := col(
		inner,
		padding     = 1,
		width       = popover_w,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Stretch,
	)

	return col(
		zoned,
		overlay(anchor_rect, card, .Below, {0, 0}, anim_op),
	)
}

// drop_zone wraps `child` in a passthrough that fires `on_drop` when
// the user releases one or more files dragged from the OS onto the
// child's rect. Siblings of the zone are unaffected — a drop that
// lands outside the last-frame rect is ignored here and passes
// through to the Input snapshot for whichever zone (if any) contains
// it. Multiple zones in the tree all see the same `dropped_files`
// slice; each tests its own containment and may fire independently
// if the drop landed inside.
//
//     skald.drop_zone(ctx, canvas,
//         proc(files: []string) -> Msg { return Files_Dropped{files} },
//     )
//
// The `files` slice lives in the frame arena — the handler must
// `strings.clone` any path it intends to retain past the current
// frame. For hover feedback during the drag (before the release),
// read `skald.drag_over(ctx, id)` to tint the child conditionally.
drop_zone :: proc(
	ctx:     ^Ctx($Msg),
	child:   View,
	on_drop: proc(files: []string) -> Msg,
	id:      Widget_ID = 0,
) -> View {
	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Click_Zone)

	if len(ctx.input.dropped_files) > 0 &&
	   rect_contains_point(st.last_rect, ctx.input.drop_pos) {
		send(ctx, on_drop(ctx.input.dropped_files))
	}

	widget_set(ctx, id, st)

	c := new(View, context.temp_allocator)
	c^ = child
	return View_Zone{id = id, child = c}
}

// drag_over reports whether a drag is currently in progress (files
// hovering over the window) AND the cursor sits over the rect the
// zone with id `id` last painted. Use it to conditionally style a
// drop target: swap a bg color, add a dashed border, nudge a scale.
// Returns false when id wasn't used by a drop_zone on the previous
// frame (the rect will be zero, so no point contains it).
drag_over :: proc(ctx: ^Ctx($Msg), id: Widget_ID) -> bool {
	if !ctx.input.drag_active { return false }
	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Click_Zone)
	return st.last_rect.w > 0 &&
	       rect_contains_point(st.last_rect, ctx.input.drag_pos)
}

// dialog presents `content` as a modal: a full-frame scrim dims the app,
// a centered card hosts the child, and keyboard/mouse outside the card
// is trapped so nothing behind it fires. When `open` is false the return
// value is a zero-size passthrough — drop it inline in your view tree
// and toggle `open` from state.
//
//     skald.dialog(ctx,
//         open       = state.confirm_open,
//         on_dismiss = proc() -> Msg { return Close_Confirm{} },
//         content    = skald.col(
//             skald.text("Delete this file?", th.color.fg, th.font.size_lg),
//             skald.spacer(th.spacing.sm),
//             skald.text("This cannot be undone.",
//                 th.color.fg_muted, th.font.size_md),
//             skald.spacer(th.spacing.lg),
//             skald.row(
//                 skald.button(ctx, "Cancel", Cancel_Msg),
//                 skald.spacer(th.spacing.sm),
//                 skald.button(ctx, "Delete", Confirm_Msg),
//                 main_align = .End,
//             ),
//         ),
//     )
//
// Dismissal is decoupled from the `open` flag: `on_dismiss` fires when
// Escape is pressed. The app's update maps it back to `open = false` —
// same pattern as `menu`. The callback is required — apps that want a
// truly undismissable dialog (a "saving…" progress modal that the app
// closes itself) can pass a no-op Msg variant that their update
// ignores. Backdrop clicks are swallowed but never dismiss.
//
// Focus trap has one frame of lag: on the frame the dialog opens, Tab
// still cycles every focusable. From the next frame onward Tab cycles
// only focusables inside the card because the renderer has stamped the
// card rect onto Widget_Store. Clicks outside the card are consumed by
// the run-loop preprocessor the frame after open so the widgets under
// the scrim never see them.
dialog :: proc(
	ctx:           ^Ctx($Msg),
	open:          bool,
	content:       View,
	on_dismiss:    proc() -> Msg,
	id:            Widget_ID = 0,
	initial_focus: Widget_ID = 0,
	width:         f32 = 0,
	max_width:     f32 = 480,
	padding:       f32 = 0,
	bg:            Color  = {},
	border:        Color  = {},
	scrim:         Color  = {},
) -> View {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Dialog)

	// Closed: forget any retained state (so a reopened dialog doesn't
	// inherit the previous close-frame's rect) and emit a zero-size
	// view. Modal_rect from this frame stays cleared — no render will
	// re-stamp it.
	//
	// Open→closed transition: restore focus to whatever widget had it
	// before the dialog opened. Lets "type → open dialog → cancel →
	// keep typing" flow naturally. If the return target no longer
	// exists (the widget was unmounted), widget_focus with a stale id
	// is harmless — widget_has_focus returns false and Tab cycles.
	if !open {
		if st.open && ctx.widgets.focus_return_id != 0 {
			widget_focus(ctx, ctx.widgets.focus_return_id)
			ctx.widgets.focus_return_id = 0
		}
		st.last_rect = {}
		st.open      = false
		widget_set(ctx, id, st)
		return View_Spacer{size = 0}
	}

	// Escape funnels through `on_dismiss`. Backdrop clicks are
	// swallowed by the run loop but don't dismiss — accidental clicks
	// losing typed input is worse than forcing an explicit Cancel.
	if .Escape in ctx.input.keys_pressed {
		send(ctx, on_dismiss())
	}

	// Closed→open transition: snapshot whatever currently holds focus
	// so we can hand it back when the dialog closes. Then seed focus
	// into the caller-designated widget (initial_focus) so forms can
	// start accepting input immediately without the app tracking the
	// transition itself. Stored-open flag lives in the dialog's own
	// Widget_State so the check is stable across frames where
	// open=true keeps firing.
	if !st.open {
		// Close any popovers that were open outside this dialog.
		// Without this sweep, a dropdown or picker that the user had
		// open when the dialog appeared stays visible (possibly peeking
		// out from under the scrim) until the picker's own builder runs
		// next frame and sees modal_rect_prev. Only popover-bearing
		// widget kinds have an `open` field worth clearing.
		//
		// Must only run on the open-transition frame: popovers opened
		// *inside* the dialog after it's up would otherwise be killed
		// one frame later.
		for id2, &st2 in ctx.widgets.states {
			_ = id2
			#partial switch st2.kind {
			case .Select, .Combobox, .Date_Picker, .Time_Picker,
			     .Color_Picker, .Click_Zone:
				st2.open = false
			}
		}

		// Only snapshot if nothing else already did this frame (e.g.
		// two nested dialogs opening in the same frame — unlikely, but
		// the earlier opener's return target should win).
		if ctx.widgets.focus_return_id == 0 {
			ctx.widgets.focus_return_id = ctx.widgets.focused_id
		}
		if initial_focus != 0 {
			widget_focus(ctx, initial_focus)
		}
	}
	st.open = true

	widget_set(ctx, id, st)

	pad := padding
	if pad == 0 { pad = th.spacing.lg }

	bg_c := bg;     if bg_c[3]     == 0 { bg_c     = th.color.elevated }
	br_c := border; if br_c[3]     == 0 { br_c     = th.color.primary  }
	sc_c := scrim;  if sc_c[3]     == 0 { sc_c     = Color{0, 0, 0, 0.55} }

	c := new(View, context.temp_allocator)
	c^ = content
	return View_Dialog{
		id           = id,
		open         = true,
		child        = c,
		color_scrim  = sc_c,
		color_bg     = bg_c,
		color_border = br_c,
		radius       = th.radius.md,
		padding      = pad,
		max_width    = max_width,
		width        = width,
	}
}

// confirm_dialog is a thin sugar layer over `dialog` for the ubiquitous
// "are you sure?" prompt. Opens modally when `open` is true; shows
// `title` + `body` text plus two buttons — a primary Confirm firing
// `on_confirm` and a neutral Cancel firing `on_cancel`. Both Msg
// callbacks should typically flip your `open` flag back to false in
// `update`; the framework doesn't do it for you.
//
// `confirm_label` / `cancel_label` default to "OK" / "Cancel" — pass
// custom strings for destructive flows ("Delete", "Keep") or plain
// acknowledgement ("Got it"). The `danger` flag tints the Confirm
// button red for destructive actions (delete / discard).
confirm_dialog :: proc(
	ctx:           ^Ctx($Msg),
	open:          bool,
	title:         string,
	body:          string,
	on_confirm:    proc() -> Msg,
	on_cancel:     proc() -> Msg,
	confirm_label: string = "OK",
	cancel_label:  string = "Cancel",
	danger:        bool   = false,
	width:         f32    = 0,
) -> View {
	th := ctx.theme
	confirm_color := th.color.primary
	if danger { confirm_color = th.color.danger }

	// Cap the text wrap width to the dialog's inner content area so a
	// long body doesn't overflow the card. If the caller didn't set an
	// explicit `width`, fall back to `dialog`'s default `max_width`
	// (480 px — kept in sync with the dialog builder).
	outer_w := width if width > 0 else 480
	text_max_w := outer_w - 2 * th.spacing.lg

	content := col(
		text(title, th.color.fg, th.font.size_lg, max_width = text_max_w),
		spacer(th.spacing.sm),
		text(body, th.color.fg_muted, th.font.size_md, max_width = text_max_w),
		spacer(th.spacing.lg),
		row(
			flex(1, spacer(0)),
			button(ctx, cancel_label, on_cancel(),
				color = th.color.surface, fg = th.color.fg),
			spacer(th.spacing.sm),
			button(ctx, confirm_label, on_confirm(),
				color = confirm_color, fg = th.color.on_primary),
			spacing = 0,
		),
		spacing     = 0,
		cross_align = .Stretch,
	)
	return dialog(ctx, open, content, on_cancel, width = width)
}

// alert_dialog is the single-button variant of `confirm_dialog`:
// title + body + one OK button (or whatever `ok_label` specifies).
// Use for errors, success confirmations, and "you've been signed out"
// style notices where there's no alternative to acknowledge.
alert_dialog :: proc(
	ctx:      ^Ctx($Msg),
	open:     bool,
	title:    string,
	body:     string,
	on_ok:    proc() -> Msg,
	ok_label: string = "OK",
	width:    f32    = 0,
) -> View {
	th := ctx.theme
	// Wrap width matches the dialog's inner content area; see the
	// comment on the identical computation in `confirm_dialog`.
	outer_w := width if width > 0 else 480
	text_max_w := outer_w - 2 * th.spacing.lg

	content := col(
		text(title, th.color.fg, th.font.size_lg, max_width = text_max_w),
		spacer(th.spacing.sm),
		text(body, th.color.fg_muted, th.font.size_md, max_width = text_max_w),
		spacer(th.spacing.lg),
		row(
			flex(1, spacer(0)),
			button(ctx, ok_label, on_ok(),
				color = th.color.primary, fg = th.color.on_primary),
			spacing = 0,
		),
		spacing     = 0,
		cross_align = .Stretch,
	)
	return dialog(ctx, open, content, on_ok, width = width)
}

// image draws the image file at `path`, scaled into a slot of `width` ×
// `height` pixels. Fit modes:
//
//   .Fill    stretch to fill, aspect ignored
//   .Contain scale to fit inside, letterbox around the shorter axis
//   .Cover   scale to fill, crop the overflow via UV trim (default)
//   .None    native size, centered (for icons shipped at 1:1)
//
// The first frame a path is referenced triggers a sync stb_image decode
// + GPU upload; subsequent frames hit the cache. If either `width` or
// `height` is 0, the image's natural extent is used — this requires
// decoding the file now (at view time) so the layout knows the size.
// Pass explicit dimensions to avoid that if responsiveness matters.
//
// `tint` defaults to white (no tint). Multiplies the sampled RGBA
// per-pixel, so e.g. `tint = {1,1,1,0.5}` fades the image to half
// opacity and `tint = th.color.primary` recolors a monochrome asset.
image :: proc(
	ctx:    ^Ctx($Msg),
	path:   string,
	width:  f32        = 0,
	height: f32        = 0,
	fit:    Image_Fit  = .Cover,
	tint:   Color      = {1, 1, 1, 1},
) -> View {
	w := width
	h := height
	// Natural-size fallback needs the texture's real dimensions, so
	// decode eagerly. Cache hits after the first reference are free.
	if (w == 0 || h == 0) && ctx.renderer != nil {
		if entry := image_cache_get(ctx.renderer, path); entry != nil {
			if w == 0 { w = f32(entry.width) }
			if h == 0 { h = f32(entry.height) }
		}
	}
	return View_Image{
		path = path,
		size = {w, h},
		fit  = fit,
		tint = tint,
	}
}

// split is a two-pane container with a draggable divider. `first_size`
// is the main-axis extent (width for `.Row`, height for `.Column`) of
// the first pane; the second pane takes whatever main-axis space is
// left. Drag the divider to resize; `on_resize(new_first_size)` fires
// once per frame the value changes, and the app owns the canonical
// value — feed the clamped result back into `first_size` next frame.
//
// Donor model: main-axis is conserved. Growing `first_size` by Δ
// shrinks the second pane by Δ; the second pane is implicit, so no
// second on_resize call is needed. Clamps: `min_first`/`min_second`
// are honored at drag time (first_size is pinned so neither pane
// falls below its minimum).
//
// Orientation: `.Row` stacks children left-to-right with a vertical
// divider between; `.Column` stacks top-to-bottom with a horizontal
// divider. Matches the direction convention used by `col`/`row`.
//
// Nesting: children are `View`, so a split can contain another split
// for IDE-style three-pane layouts (sidebar | content-split | preview).
split :: proc(
	ctx:                ^Ctx($Msg),
	first:              View,
	second:             View,
	first_size:         f32,
	on_resize:          proc(new_first_size: f32) -> Msg,
	direction:          Stack_Direction = .Row,
	divider_thickness:  f32             = 6,
	min_first:          f32             = 40,
	min_second:         f32             = 40,
	id:                 Widget_ID       = 0,
	color_divider:          Color = {},
	color_divider_hover:    Color = {},
	color_divider_pressed:  Color = {},
) -> View {
	id := widget_resolve_id(ctx, id)
	th := ctx.theme

	st := widget_get(ctx, id, .Split)

	// Container rect (written by render_view last frame). Divider
	// hit-rect is derived from it + first_size so we don't need a
	// second widget state; the main-axis extent also comes from here
	// for clamp math during a drag.
	cont := st.last_rect
	main_axis_size: f32
	switch direction {
	case .Row:    main_axis_size = cont.w
	case .Column: main_axis_size = cont.h
	}

	// Divider rect in framebuffer pixels.
	div_rect: Rect
	switch direction {
	case .Row:
		div_rect = Rect{cont.x + first_size, cont.y, divider_thickness, cont.h}
	case .Column:
		div_rect = Rect{cont.x, cont.y + first_size, cont.w, divider_thickness}
	}

	hover := rect_contains_point(div_rect, ctx.input.mouse_pos)

	// Latch the drag on press-inside-divider. `drag_anchor` stores the
	// grab offset `mouse − first_size` so the divider tracks the cursor
	// through the drag even as first_size changes in response.
	if !st.pressed &&
	   ctx.input.mouse_pressed[.Left] &&
	   hover {
		st.pressed = true
		mouse_main: f32
		switch direction {
		case .Row:    mouse_main = ctx.input.mouse_pos.x - cont.x
		case .Column: mouse_main = ctx.input.mouse_pos.y - cont.y
		}
		st.drag_anchor = mouse_main - first_size
	}
	if st.pressed && !ctx.input.mouse_buttons[.Left] {
		st.pressed = false
	}

	// While dragging, compute the new first_size and emit on_resize if
	// it actually changed. Clamp against min_first and the remaining
	// space after reserving min_second + divider.
	if st.pressed && on_resize != nil && main_axis_size > 0 {
		mouse_main: f32
		switch direction {
		case .Row:    mouse_main = ctx.input.mouse_pos.x - cont.x
		case .Column: mouse_main = ctx.input.mouse_pos.y - cont.y
		}
		want := mouse_main - st.drag_anchor

		max_first := main_axis_size - min_second - divider_thickness
		if max_first < min_first { max_first = min_first }
		if want < min_first { want = min_first }
		if want > max_first { want = max_first }

		if want != first_size {
			send(ctx, on_resize(want))
		}
	}

	widget_set(ctx, id, st)

	col_div         := color_divider
	col_div_hover   := color_divider_hover
	col_div_pressed := color_divider_pressed
	if col_div.a         == 0 { col_div         = th.color.border   }
	if col_div_hover.a   == 0 { col_div_hover   = th.color.fg_muted }
	if col_div_pressed.a == 0 { col_div_pressed = th.color.primary  }

	f := new(View, context.temp_allocator); f^ = first
	s := new(View, context.temp_allocator); s^ = second
	return View_Split{
		id                    = id,
		direction             = direction,
		first                 = f,
		second                = s,
		first_size            = first_size,
		divider_thickness     = divider_thickness,
		color_divider         = col_div,
		color_divider_hover   = col_div_hover,
		color_divider_pressed = col_div_pressed,
		hover                 = hover,
		pressed               = st.pressed,
	}
}

// segmented builds a row of mutually exclusive tabs styled as a
// connected pill. One segment is selected at a time — clicking another
// emits `on_change(index)`; clicking the selected one is a no-op.
//
// Visually it's a container rect with a rounded bg, hosting N button
// children. The selected child paints with the accent color; unselected
// children match the container bg so they blend into the pill.
// Content-sized segments by default — labels dictate width.
//
// Compared to `radio_group`: segmented is horizontal, looks punchier,
// and suits 2–5 short labels (view modes, sort orders). Radios are
// better for longer labels or 6+ options where the vertical column
// reads cleanly.
segmented :: proc{segmented_simple, segmented_payload}

@(private)
_segmented_impl :: proc(
	ctx:       ^Ctx($Msg),
	options:   []string,
	selected:  int,
	msgs:      []Msg,
	id:        Widget_ID = 0,
	disabled: bool      = false,
) -> View {
	th := ctx.theme
	base_id := widget_resolve_id(ctx, id)

	if len(options) == 0 {
		return row()
	}

	fs    := th.font.size_md
	pad_x := th.spacing.md
	pad_y := th.spacing.sm

	// Auto-equal-width: measure every label and size every segment to
	// the widest one. A fixed per-segment width gives the pill a tidy
	// "tabs" rhythm regardless of label length — iOS/macOS do the same.
	seg_w: f32 = 0
	if ctx.renderer != nil {
		for opt in options {
			w, _ := measure_text(ctx.renderer, opt, fs)
			if w > seg_w { seg_w = w }
		}
	}
	seg_w += 2 * pad_x
	// Modest floor so a segmented of very short labels ("A"/"B") still
	// reads as a deliberate group rather than two pinprick tabs.
	if seg_w < 56 { seg_w = 56 }

	// Children are segments interleaved with thin separators. Separators
	// only appear between two *unselected* neighbors — adjacent to the
	// selected pill they'd clash with the accent, so we leave a clean
	// gap there instead.
	children: [dynamic]View
	children.allocator = context.temp_allocator

	for opt, i in options {
		seg_id := hash_id(fmt.tprintf("segmented-%d-opt-%d", base_id, i))

		is_sel := i == selected

		bg := th.color.surface
		fg := th.color.fg_muted
		if is_sel {
			bg = th.color.primary
			fg = th.color.on_primary
		}
		if disabled && !is_sel { fg = th.color.fg_muted }
		if disabled && is_sel  { bg = th.color.fg_muted }

		if disabled {
			// Inert tile that matches the button's geometry so the row
			// doesn't reflow when the widget flips to/from disabled.
			label_view := make([]View, 1, context.temp_allocator)
			label_view[0] = View_Text{str = opt, color = fg, size = fs}
			append(&children, View_Stack{
				direction   = .Row,
				width       = seg_w,
				height      = fs + 2 * pad_y,
				bg          = bg,
				radius      = th.radius.sm,
				main_align  = .Center,
				cross_align = .Center,
				children    = label_view,
			})
		} else {
			// Clicking the already-selected segment is a no-op: passing an
			// invalid Msg would need a nil-union, so instead we re-emit the
			// current selection. The app's update coalesces into a no-op.
			msg := msgs[i]
			append(&children, button(
				ctx,
				opt,
				msg,
				id        = seg_id,
				color     = bg,
				fg        = fg,
				radius    = th.radius.sm,
				padding   = {pad_x, pad_y},
				font_size = fs,
				width     = seg_w,
			))
		}

		// Separator between this segment and the next: skip on the last
		// segment, and skip when either neighbor is the selected one.
		if i < len(options) - 1 && !is_sel && i + 1 != selected {
			append(&children, rect({1, 0}, th.color.border, 0))
		} else if i < len(options) - 1 {
			// Transparent breathing room that matches the separator's
			// footprint so segment alignment stays identical whether
			// a divider is drawn here or not.
			append(&children, spacer(1))
		}
	}

	return row(
		..children[:],
		spacing     = 0,
		padding     = 2,
		bg          = th.color.surface,
		radius      = th.radius.md,
		cross_align = .Stretch,
	)
}

segmented_simple :: proc(
	ctx:       ^Ctx($Msg),
	options:   []string,
	selected:  int,
	on_change: proc(index: int) -> Msg,
	id:        Widget_ID = 0,
	disabled: bool      = false,
) -> View {
	// Pre-build the Msg per option so the impl doesn't need to know
	// which callback shape it's wrapping. Cheap — one allocation in
	// the frame arena, len(options) Msg values.
	msgs := make([]Msg, len(options), context.temp_allocator)
	for i in 0..<len(options) { msgs[i] = on_change(i) }
	return _segmented_impl(ctx, options, selected, msgs, id = id, disabled = disabled)
}

segmented_payload :: proc(
	ctx:       ^Ctx($Msg),
	options:   []string,
	selected:  int,
	payload:   $Payload,
	on_change: proc(payload: Payload, index: int) -> Msg,
	id:        Widget_ID = 0,
	disabled: bool      = false,
) -> View {
	msgs := make([]Msg, len(options), context.temp_allocator)
	for i in 0..<len(options) { msgs[i] = on_change(payload, i) }
	return _segmented_impl(ctx, options, selected, msgs, id = id, disabled = disabled)
}

// number_input builds a typeable numeric field flanked by +/- stepper
// buttons. The app owns the value as `f64`; the builder formats it for
// display using `decimals`. Both clicks on the steppers and valid parses
// of typed input emit `on_change(new_value)` — always clamped to
// `[min_value, max_value]` so the app's update handler can just store
// the value without extra validation.
//
// Typing contract: while the field is focused, the builder keeps a
// per-widget draft string (`Widget_State.text_buffer`) on the persistent
// heap. The draft is the source of truth while focused so partial states
// — "1." between "1" and "1.5", a lone "-" before the first digit — survive
// between frames. Accepted characters: digits, `.` (when `decimals > 0`),
// and `-` (when `min_value < 0`, only at position 0). Editing keys
// supported: Backspace, Delete, Left, Right, Home, End, Enter/Escape (blur).
// Selection, clipboard and undo are deliberately skipped — they bloat the
// widget without adding much for a numeric input. Compose `text_input`
// with a validator if you need those.
//
// On each frame the draft is parsed; if it yields a number that differs
// from `value` (after clamp), `on_change` fires. On blur the draft
// reformats to the canonical `%.*f` representation so the next focus
// starts from a tidy value.
//
// `id` ties the field (and its draft) to a stable widget slot; the
// stepper button ids are derived from it so they survive view reshuffles.
//
// `disabled` mutes the text color, drops the stepper buttons, and
// ignores focus + keyboard edits — the field still shows the canonical
// value but can't be changed. Use for display-only numbers in a form
// that otherwise contains editable inputs.
number_input :: proc{number_input_simple, number_input_payload}

@(private)
_number_input_impl :: proc(
	ctx:         ^Ctx($Msg),
	value:       f64,
	dec_msg:     Msg,    // pre-computed by wrapper: on_change(value-step) clamped
	inc_msg:     Msg,    // pre-computed by wrapper: on_change(value+step) clamped
	id:          Widget_ID = 0,
	step:        f64       = 1,
	min_value:   f64       = min(f64),
	max_value:   f64       = max(f64),
	decimals:    int       = 0,
	width:       f32       = 140,
	disabled:    bool      = false,
	max_chars:   int       = 0,
) -> (view: View, parsed: f64, changed: bool) {
	parsed = value
	th := ctx.theme
	base := widget_resolve_id(ctx, id)

	dec_id := hash_id(fmt.tprintf("num_dec_%x", u64(base)))
	inc_id := hash_id(fmt.tprintf("num_inc_%x", u64(base)))

	// Local alias so the rest of the body doesn't have to spell out the
	// flag check at every site. With v2's collapsed flag (no more
	// separate disabled) it's a one-liner — kept named for grep-ability
	// and parity with prior versions.
	non_interactive := disabled
	if !non_interactive { widget_make_focusable(ctx, base) }
	st := widget_get(ctx, base, .Number_Input)
	focused := !non_interactive && widget_has_focus(ctx, base)

	v := value
	if v < min_value { v = min_value }
	if v > max_value { v = max_value }

	canonical := fmt.tprintf("%.*f", decimals, v)

	fs     := th.font.size_md
	pad_x  := th.spacing.md
	pad_y  := th.spacing.sm
	disp_h := fs + 2*pad_y + 6

	btn_w: f32 = 32
	gap:   f32 = th.spacing.xs
	disp_w := width - 2*btn_w - 2*gap
	if disp_w < 40 { disp_w = 40 }

	// Mouse: a press inside the display tile focuses the field; a press
	// outside blurs it. `last_rect` is the display box's rect from the
	// previous frame — the renderer stamps it via View_Text_Input. Caret
	// placement happens after the draft is seeded so hit-testing runs
	// against the string that will actually render.
	mouse_in := !non_interactive && rect_hovered(ctx, st.last_rect)
	if !non_interactive && ctx.input.mouse_pressed[.Left] {
		if mouse_in {
			if !focused {
				widget_focus(ctx, base)
				focused = true
			}
		} else if focused {
			widget_focus(ctx, 0)
			focused = false
		}
	}

	// Seed the draft on the focus-enter edge so external value changes
	// land in the draft the next time the field gains focus, and drop it
	// on blur so the canonical reformats when idle. Seeding on the edge
	// (not on `draft == ""`) is what lets the user backspace the field
	// all the way empty without the builder re-populating it next frame.
	if focused && !st.was_focused {
		if len(st.text_buffer) > 0 { delete(st.text_buffer) }
		st.text_buffer = strings.clone(canonical)
		st.cursor_pos  = len(st.text_buffer)
	}
	if !focused && len(st.text_buffer) > 0 {
		delete(st.text_buffer)
		st.text_buffer = ""
		st.cursor_pos  = 0
	}
	st.was_focused = focused

	// Place the caret from the click position now that the draft exists.
	if focused && mouse_in && ctx.input.mouse_pressed[.Left] && ctx.renderer != nil {
		rel_x := ctx.input.mouse_pos.x - (st.last_rect.x + pad_x)
		st.cursor_pos = byte_index_at_x(ctx.renderer, st.text_buffer, fs, 0, rel_x)
	}

	draft := st.text_buffer
	cursor := clamp(st.cursor_pos, 0, len(draft))

	emit_parsed :: proc(draft: string, value, min_value, max_value: f64,
	                   out_parsed: ^f64, out_changed: ^bool) {
		p, ok := strconv.parse_f64(draft)
		if !ok { return }
		if p < min_value { p = min_value }
		if p > max_value { p = max_value }
		if p != value {
			out_parsed^  = p
			out_changed^ = true
		}
	}

	if focused {
		ctx.widgets.wants_text_input = true
		keys := ctx.input.keys_pressed

		// Character insertion. We don't use ctx.input.text wholesale —
		// numeric fields should silently drop letters — so we filter
		// byte-by-byte. Dots are allowed at most once, and only when the
		// caller asked for decimals; minus only in the first position and
		// only when the range admits negatives. `max_chars` caps the total
		// draft rune-count; overflow is silently dropped at the caret.
		if len(ctx.input.text) > 0 {
			has_dot   := strings.contains_rune(draft, '.')
			has_minus := strings.contains_rune(draft, '-')
			for i := 0; i < len(ctx.input.text); i += 1 {
				if max_chars > 0 && utf8.rune_count_in_string(draft) >= max_chars {
					break
				}
				ch := ctx.input.text[i]
				ins: string
				switch {
				case ch >= '0' && ch <= '9':
					ins = ctx.input.text[i:i+1]
				case ch == '.' && decimals > 0 && !has_dot:
					ins = "."
					has_dot = true
				case ch == '-' && min_value < 0 && cursor == 0 && !has_minus:
					ins = "-"
					has_minus = true
				}
				if len(ins) > 0 {
					draft  = string_insert_at(draft, cursor, ins)
					cursor += 1
				}
			}
		}

		if .Backspace in keys && cursor > 0 {
			draft = strings.concatenate({draft[:cursor-1], draft[cursor:]},
				context.temp_allocator)
			cursor -= 1
		}
		if .Delete in keys && cursor < len(draft) {
			draft = strings.concatenate({draft[:cursor], draft[cursor+1:]},
				context.temp_allocator)
		}
		if .Left in keys && cursor > 0  { cursor -= 1 }
		if .Right in keys && cursor < len(draft) { cursor += 1 }
		if .Home in keys                { cursor = 0 }
		if .End in keys                 { cursor = len(draft) }

		// Enter / Escape / Tab all commit the draft and relinquish focus.
		// Tab is handled by the run loop's focus cycler — we still catch
		// Enter and Escape here. The canonical reformat on blur happens
		// next frame when focused goes false.
		if .Enter in keys || .Escape in keys {
			widget_focus(ctx, 0)
		}

		// Persist the draft on the heap if it changed. strings.clone uses
		// context.allocator by default, which is the persistent heap —
		// exactly what the widget slot needs to outlive the frame arena.
		if draft != st.text_buffer {
			if len(st.text_buffer) > 0 { delete(st.text_buffer) }
			st.text_buffer = strings.clone(draft)
			emit_parsed(st.text_buffer, v, min_value, max_value, &parsed, &changed)
		}
		st.cursor_pos = cursor
	}

	widget_set(ctx, base, st)

	// Decide what to display: the live draft while focused (even when
	// empty — the user just backspaced it), the canonical string
	// otherwise.
	disp_text := st.text_buffer if focused else canonical

	// Render as a View_Text_Input populated directly — we already handled
	// editing, so the renderer just draws the frame, the text, and the
	// caret at `cursor_pos`. Using the widget's own id means `last_rect`
	// gets stamped on our Number_Input slot, which is what our mouse
	// hit-test reads next frame.
	fg_c := th.color.fg
	if non_interactive { fg_c = th.color.fg_muted }
	field_w := disp_w
	if non_interactive { field_w = width }
	field := View_Text_Input{
		id                = base,
		text              = disp_text,
		color_bg          = th.color.surface,
		color_fg          = fg_c,
		color_placeholder = th.color.fg_muted,
		color_border      = th.color.primary,
		color_border_idle = th.color.border,
		color_caret       = th.color.fg,
		color_selection   = th.color.selection,
		radius            = th.radius.sm,
		padding           = {pad_x, pad_y},
		font_size         = fs,
		width             = field_w,
		height            = disp_h,
		focused           = focused,
		cursor_pos        = cursor,
		selection_anchor  = cursor,
		visual_lines      = []Visual_Line{
			Visual_Line{start = 0, end = len(disp_text), consume_space = false},
		},
	}

	if non_interactive {
		view = field
		return
	}

	view = row(
		button(ctx, "\u2212", dec_msg, id = dec_id, width = btn_w),
		spacer(gap),
		View(field),
		spacer(gap),
		button(ctx, "+", inc_msg, id = inc_id, width = btn_w),
		cross_align = .Center,
	)
	return
}

number_input_simple :: proc(
	ctx:         ^Ctx($Msg),
	value:       f64,
	on_change:   proc(new_value: f64) -> Msg,
	id:          Widget_ID = 0,
	step:        f64       = 1,
	min_value:   f64       = min(f64),
	max_value:   f64       = max(f64),
	decimals:    int       = 0,
	width:       f32       = 140,
	disabled:    bool      = false,
	max_chars:   int       = 0,
) -> View {
	dec := value - step
	if dec < min_value { dec = min_value }
	inc := value + step
	if inc > max_value { inc = max_value }
	view, parsed, changed := _number_input_impl(
		ctx, value, on_change(dec), on_change(inc),
		id = id, step = step, min_value = min_value, max_value = max_value,
		decimals = decimals, width = width,
		disabled = disabled, max_chars = max_chars,
	)
	if changed { send(ctx, on_change(parsed)) }
	return view
}

number_input_payload :: proc(
	ctx:         ^Ctx($Msg),
	value:       f64,
	payload:     $Payload,
	on_change:   proc(payload: Payload, new_value: f64) -> Msg,
	id:          Widget_ID = 0,
	step:        f64       = 1,
	min_value:   f64       = min(f64),
	max_value:   f64       = max(f64),
	decimals:    int       = 0,
	width:       f32       = 140,
	disabled:    bool      = false,
	max_chars:   int       = 0,
) -> View {
	dec := value - step
	if dec < min_value { dec = min_value }
	inc := value + step
	if inc > max_value { inc = max_value }
	view, parsed, changed := _number_input_impl(
		ctx, value, on_change(payload, dec), on_change(payload, inc),
		id = id, step = step, min_value = min_value, max_value = max_value,
		decimals = decimals, width = width,
		disabled = disabled, max_chars = max_chars,
	)
	if changed { send(ctx, on_change(payload, parsed)) }
	return view
}


// link builds a text-only clickable. Hit-testing and keyboard activation
// mirror `button`, but the visual is just the glyph run — no background,
// no padding. The default tint is `theme.color.primary`, hovered is a
// lighter variant, focused keeps the hover tint and adds a focus ring
// around the text rect.
link :: proc(
	ctx:        ^Ctx($Msg),
	label:      string,
	on_click:   Msg,
	id:         Widget_ID = 0,
	color:      Color = {},
	color_hover: Color = {},
	font_size:  f32   = 0,
	underline:  bool  = true,
	disabled:   bool  = false,
) -> View {
	th := ctx.theme

	c  := color;       if c.a  == 0 { c  = th.color.primary }
	ch := color_hover; if ch.a == 0 { ch = color_tint(c, 0.15) }
	fs := font_size;   if fs   == 0 { fs = th.font.size_md }

	if disabled {
		c  = th.color.fg_muted
		ch = c
	}

	id := widget_resolve_id(ctx, id)
	if !disabled { widget_make_focusable(ctx, id) }
	st := widget_get(ctx, id, .Link)
	focused := !disabled && widget_has_focus(ctx, id)

	hovered := !disabled && rect_hovered(ctx, st.last_rect)

	if !disabled {
		if ctx.input.mouse_pressed[.Left] && hovered {
			st.pressed = true
			widget_focus(ctx, id)
			focused = true
		}
		if ctx.input.mouse_released[.Left] {
			if st.pressed && hovered {
				send(ctx, on_click)
			}
			st.pressed = false
		}
		if !ctx.input.mouse_buttons[.Left] {
			st.pressed = false
		}

		if focused {
			keys := ctx.input.keys_pressed
			if .Space in keys || .Enter in keys {
				send(ctx, on_click)
			}
		}
	} else {
		st.pressed = false
	}

	widget_set(ctx, id, st)

	return View_Link{
		id          = id,
		label       = label,
		color       = c,
		color_hover = ch,
		color_focus = focus_ring_for(th^, th.color.surface),
		font_size   = fs,
		underline   = underline,
		hover       = hovered,
		focused     = focused,
	}
}

// toast builds a viewport-pinned notification card — the "snackbar" of
// iOS / material / web. The app owns `visible` as part of its state,
// typically flipping it on from an update branch and back off when the
// user clicks the close button (or auto-dismiss fires).
//
// When `visible` is false, the returned view is a zero-size spacer so
// it costs nothing to leave in the tree. When visible, the builder
// composes a standard card: a thin left accent stripe + the message +
// a small X button wired to `on_close`, then wraps it in a View_Toast
// that positions against the framebuffer corner.
//
// Auto-dismiss: when `dismiss_after > 0`, the widget tracks how long
// it has been visible this cycle and sends `on_close()` once the
// elapsed time exceeds `dismiss_after` seconds. The app's update is
// responsible for flipping `visible` back to false on the close msg —
// same contract as the user clicking the X.
//
// For custom toast layouts (progress bars, action buttons, icons),
// build the card with the usual row/col/text helpers and hand it
// straight to a View_Toast — this builder is just the common shape.
toast :: proc(
	ctx:            ^Ctx($Msg),
	visible:        bool,
	message:        string,
	on_close:       proc() -> Msg,
	kind:           Toast_Kind   = .Info,
	anchor:         Toast_Anchor = .Bottom_Center,
	id:             Widget_ID    = 0,
	max_width:      f32          = 420,
	margin:         f32          = 16,
	dismiss_after:  f32          = 0,
) -> View {
	base_id := widget_resolve_id(ctx, id)

	if !visible {
		// Clear any leftover visibility timer so the next show-cycle
		// starts its countdown fresh.
		st := widget_get(ctx, base_id, .Toast)
		if st.visible_start_ns != 0 {
			st.visible_start_ns = 0
			widget_set(ctx, base_id, st)
		}
		return View_Spacer{size = 0}
	}

	th := ctx.theme

	// Track visibility start + fire auto-dismiss once the deadline passes.
	// send() only enqueues for next frame's update, so the app still sees
	// visible=true for the final frame — that's fine; it'll flip off next.
	if dismiss_after > 0 {
		st := widget_get(ctx, base_id, .Toast)
		now_ns := time.now()._nsec
		if st.visible_start_ns == 0 {
			st.visible_start_ns = now_ns
		} else {
			elapsed := now_ns - st.visible_start_ns
			if f32(elapsed) >= dismiss_after * f32(time.Second) {
				send(ctx, on_close())
			}
		}
		// Ask the run loop to wake at the exact dismiss deadline —
		// otherwise lazy redraw would leave the toast up indefinitely.
		deadline_ns := st.visible_start_ns + i64(f64(dismiss_after) * f64(time.Second))
		widget_request_frame_at(ctx, deadline_ns)
		// widget_set every frame so last_frame advances; without it
		// widget_get's staleness check (last_frame + 1 < current_frame)
		// wipes the state after one missed frame and the timer restarts.
		widget_set(ctx, base_id, st)
	}

	// Accent color picks up the semantic kind.
	accent := th.color.primary
	switch kind {
	case .Info:    accent = th.color.primary
	case .Success: accent = th.color.success
	case .Warning: accent = th.color.warning
	case .Danger:  accent = th.color.danger
	}

	// Card body. cross_align .Stretch makes the accent stripe fill the
	// card's full height; the row's intrinsic height comes from the
	// wrapped message text.
	stripe := rect({4, 0}, accent, 2)
	label  := text(message, th.color.fg, th.font.size_md, 0, max_width)

	children: [dynamic]View
	children.allocator = context.temp_allocator
	append(&children, stripe)
	append(&children, label)

	close_id := hash_id(fmt.tprintf("toast-close-%d", base_id))
	append(&children,
		button(ctx, "\u00d7", on_close(),
			id        = close_id,
			color     = th.color.surface,
			fg        = th.color.fg_muted,
			radius    = th.radius.sm,
			padding   = {th.spacing.sm, th.spacing.xs},
			font_size = th.font.size_md,
		),
	)

	card := row(
		..children[:],
		spacing     = th.spacing.sm,
		padding     = th.spacing.md,
		bg          = th.color.elevated,
		radius      = th.radius.md,
		cross_align = .Center,
	)

	c := new(View, context.temp_allocator)
	c^ = card
	return View_Toast{
		visible = true,
		child   = c,
		anchor  = anchor,
		margin  = margin,
	}
}

@(private)
select_option_button :: proc(
	ctx:       ^Ctx($Msg),
	label:     string,
	on_change: proc(new_value: string) -> Msg,
	bg:        Color,
	th:        ^Theme,
) -> View {
	// A bit of indirection: we need each option's click to deliver
	// on_change(label), but button() takes a ready-made Msg. Wrap the
	// option into a tiny closure-like proc via a single allocation —
	// the label string is the stable payload the button carries back.
	// Note: closing the dropdown happens naturally because the next
	// frame's mouse_pressed dismiss branch will see the click was
	// outside the trigger (since on-option clicks land in overlay).
	// Here we additionally close it synchronously so the option list
	// disappears on the same frame the selection fires.
	msg := on_change(label)

	// A button styled as a list row: left-aligned label, no border,
	// radius small so it reads as part of the popover sheet.
	return select_option_row(ctx, label, msg, bg, th)
}

@(private)
select_option_row :: proc(
	ctx:   ^Ctx($Msg),
	label: string,
	msg:   Msg,
	bg:    Color,
	th:    ^Theme,
) -> View {
	return button(ctx, label, msg,
		color      = bg,
		fg         = th.color.fg,
		radius     = 0, // rows sit flush — no row-level rounding; overlay rounds the outer edge
		padding    = {th.spacing.md, th.spacing.sm},
		font_size  = th.font.size_md,
		width      = 0, // stretched to the col's cross axis by the surrounding stack
		text_align = .Start,
	)
}

// scroll wraps `content` in a vertically-scrollable viewport of the given
// pixel size. The wheel advances the offset while the pointer is inside
// the viewport; the renderer clamps against content height and writes
// the clamped value back to widget state so a rapid wheel tick doesn't
// leave the stored offset drifting out of range.
//
//     skald.scroll(ctx, {width, height},
//         skald.col(row1, row2, row3, ..., spacing = 8))
//
// Fill-parent: passing 0 on either axis of `size` asks the parent stack
// to decide that extent — wrap in `flex(1, scroll(...))` inside a col
// (or give the parent col `cross_align = .Stretch` for horizontal fill)
// and the viewport grows with the window:
//
//     skald.col(
//         toolbar(s, ctx),
//         skald.flex(1, skald.scroll(ctx, {0, 0}, list_content)),
//         cross_align = .Stretch,
//     )
//
// `virtual_list` follows the same {0, 0} = fill contract. On the first
// frame a fill-mode list has no prior rect so the visible-range math
// sees zero rows; it catches up on frame 2.
//
// `wheel_step` controls how many pixels one wheel notch moves. SDL wheel
// events aren't in pixels (they're in lines/ticks), so the default
// multiplier of 40 approximates a typical 3-line step.
// scroll_keyboard_nav consumes Page_Up/Down, Home/End, Up/Down arrow
// presses when a focusable scroll container has focus. Writes the new
// `scroll_y` back through `widget_set` so scroll_advance / render see
// the updated value this frame. Returns true if anything changed, so
// callers can skip redundant updates.
//
// `viewport_h` is the scroll viewport's main extent (used for page
// size). `content_h` clamps the bottom; if it's smaller than the
// viewport, nothing scrolls.
@(private)
scroll_keyboard_nav :: proc(ctx: ^Ctx($Msg), id: Widget_ID, viewport_h, content_h, wheel_step: f32) -> bool {
	st := widget_get(ctx, id, .Scroll)
	max_off := content_h - viewport_h
	if max_off <= 0 { return false }

	scroll_y := st.scroll_y
	keys := ctx.input.keys_pressed
	page := viewport_h
	changed := false

	if .Page_Up   in keys { scroll_y -= page;       changed = true }
	if .Page_Down in keys { scroll_y += page;       changed = true }
	if .Home      in keys { scroll_y  = 0;          changed = true }
	if .End       in keys { scroll_y  = max_off;    changed = true }
	if .Up        in keys { scroll_y -= wheel_step; changed = true }
	if .Down      in keys { scroll_y += wheel_step; changed = true }

	if !changed { return false }
	if scroll_y < 0       { scroll_y = 0       }
	if scroll_y > max_off { scroll_y = max_off }
	if scroll_y == st.scroll_y { return false }
	st.scroll_y = scroll_y
	widget_set(ctx, id, st)
	return true
}

// scroll_advance runs a single frame's scroll-input step against the
// `id`'s Widget_State: wheel delta while hovered, scrollbar-thumb
// drag, track-click page-scroll. Returns the updated state and the
// hover-thumb flag (for render styling). Writes the new state back
// to the widget store so later builders / the renderer see the
// current-frame value.
//
// Shared by `scroll` (which passes the prior-frame content_h cached
// on the widget state) and `virtual_list` (which passes the exact
// total-content height so the scrollbar thumb sizes and positions
// correctly from the very first frame).
@(private)
scroll_advance :: proc(
	ctx:        ^Ctx($Msg),
	id:         Widget_ID,
	content_h:  f32,
	wheel_step: f32,
) -> (Widget_State, bool) {
	st := widget_get(ctx, id, .Scroll)
	st.content_h = content_h

	vp := st.last_rect
	hovered    := rect_contains_point(vp, ctx.input.mouse_pos)
	scrollable := content_h > vp.h

	// Publish this viewport to the scroll-rects list so sibling / deeper
	// scrollers in the same frame can see it next frame and decide who's
	// innermost. Outer stamps first (render order), inner last.
	if scrollable && vp.w > 0 && vp.h > 0 {
		append(&ctx.widgets.scroll_rects, Scroll_Rect{id = id, rect = vp})
	}

	// Nested-scroll wheel routing: only the *innermost* hovered scrollable
	// viewport eats the wheel delta; outer scrollers pass. We consult the
	// previous frame's stamp list (one-frame lag is imperceptible for wheel
	// UX and avoids a second render pass). Iterating backwards picks the
	// deepest rect first — it's the one that was stamped most recently in
	// last frame's render walk, which for a properly-nested tree is the
	// innermost scroller at the mouse position.
	claim_wheel := false
	if hovered && scrollable && ctx.input.scroll.y != 0 {
		found := false
		for i := len(ctx.widgets.scroll_rects_prev) - 1; i >= 0; i -= 1 {
			cand := ctx.widgets.scroll_rects_prev[i]
			if rect_contains_point(cand.rect, ctx.input.mouse_pos) {
				claim_wheel = cand.id == id
				found = true
				break
			}
		}
		// Fallback for the very first frame (no prev stamps yet): let the
		// outer-most hovered scroller claim, so a plain single-scroll page
		// isn't inert on frame 1.
		if !found { claim_wheel = true }
	}

	if claim_wheel {
		// Wheel-up (positive y) should scroll content DOWN (reveal
		// content at the top), which on screen means decreasing offset.
		st.scroll_y -= ctx.input.scroll.y * wheel_step
		ctx.input.scroll.y = 0
	}

	hover_thumb := false

	if vp.w > 0 && vp.h > 0 && content_h > vp.h {
		bar_w: f32 = 6
		bar_pad: f32 = 2
		bar := Rect{
			vp.x + vp.w - bar_w - bar_pad,
			vp.y + bar_pad,
			bar_w,
			vp.h - 2 * bar_pad,
		}
		max_off := content_h - vp.h
		ratio   := vp.h / content_h
		thumb_h := bar.h * ratio
		if thumb_h < 16        { thumb_h = 16 }
		if thumb_h > bar.h     { thumb_h = bar.h }
		clamped_off := st.scroll_y
		if clamped_off < 0       { clamped_off = 0 }
		if clamped_off > max_off { clamped_off = max_off }
		t: f32 = 0
		if max_off > 0 { t = clamped_off / max_off }
		thumb_y := bar.y + (bar.h - thumb_h) * t
		thumb := Rect{bar.x, thumb_y, bar.w, thumb_h}

		mp := ctx.input.mouse_pos
		on_thumb := rect_contains_point(thumb, mp)
		on_track := rect_contains_point(bar,   mp) && !on_thumb
		hover_thumb = on_thumb

		if ctx.input.mouse_pressed[.Left] {
			if on_thumb {
				st.pressed = true
				st.drag_anchor = mp.y - thumb_y
			} else if on_track {
				page := vp.h
				if mp.y < thumb_y { st.scroll_y -= page }
				else              { st.scroll_y += page }
			}
		}
		if !ctx.input.mouse_buttons[.Left] { st.pressed = false }

		if st.pressed {
			travel := bar.h - thumb_h
			if travel > 0 {
				want_thumb_y := mp.y - st.drag_anchor
				rel := (want_thumb_y - bar.y) / travel
				if rel < 0 { rel = 0 }
				if rel > 1 { rel = 1 }
				st.scroll_y = rel * max_off
			}
		}
	} else {
		st.pressed = false
	}

	widget_set(ctx, id, st)
	return st, hover_thumb
}

// Scroll_Params mirrors `scroll`'s parameters so the fill-mode path can
// hand the full call across the `sized` deferred boundary. Private — the
// caller never constructs it; scroll packs it internally when `size` has
// a zero axis.
@(private)
Scroll_Params :: struct($Msg: typeid) {
	content:     View,
	id:          Widget_ID,
	wheel_step:  f32,
	track_color: Color,
	thumb_color: Color,
	focusable:   bool,
	min:         [2]f32,
}

// scroll wraps `content` in a clipped viewport with an autohiding
// scrollbar. `size` is the visible viewport extent; passing a zero on
// either axis means "fill whatever my flex parent gives me" (the
// builder defers through `sized` so the assigned rect is known this
// frame — there's no last-frame lag).
//
// `wheel_step` is the pixel delta per wheel tick (default 40). Track
// and thumb colors fall back to the active theme when left zero.
// Setting `focusable = true` lets the viewport take keyboard focus so
// PageUp / PageDown / arrow keys scroll it when nothing inside has
// captured focus — the default is off because most scrollers live
// under a text_input or list that should own the keyboard instead.
//
// Supply `id` only when you have two scrolls at the same call site
// that the auto-id hash can't tell apart; otherwise leave it zero.
scroll :: proc(
	ctx:         ^Ctx($Msg),
	size:        [2]f32,
	content:     View,
	id:          Widget_ID = 0,
	wheel_step:  f32 = 40,
	track_color: Color = {},
	thumb_color: Color = {},
	focusable:   bool = false,
) -> View {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)

	// Fill-mode: a zero axis on `size` means "take what my flex parent
	// gives me." Defer through `sized` so the assigned rect is known
	// this frame — no last_rect lag. Pack every parameter into a
	// frame-arena struct; the trampoline re-enters scroll with the
	// resolved size.
	if size.x <= 0 || size.y <= 0 {
		P :: Scroll_Params(Msg)
		p := new(P, context.temp_allocator)
		p^ = P{
			content     = content,
			id          = id,
			wheel_step  = wheel_step,
			track_color = track_color,
			thumb_color = thumb_color,
			focusable   = focusable,
			min         = size,
		}
		fill_builder :: proc(ctx: ^Ctx(Msg), data: ^P, sz: [2]f32) -> View {
			// Tight-window guard: if the parent had no space left to
			// give (e.g. a flex(1, scroll) whose row was already full
			// from non-flex siblings), the assigned axes can come back
			// at 0. Re-entering scroll(...) with another zero would
			// produce a fresh deferred and we'd recurse forever, blowing
			// the stack. Render an empty rect at the assigned slot
			// instead — invisible but safe.
			if sz.x <= 0 || sz.y <= 0 {
				return View_Spacer{size = 0}
			}
			return scroll(
				ctx,
				sz,
				data.content,
				id          = data.id,
				wheel_step  = data.wheel_step,
				track_color = data.track_color,
				thumb_color = data.thumb_color,
				focusable   = data.focusable,
			)
		}
		return sized(ctx, p, fill_builder,
			min_w = size.x, min_h = size.y)
	}

	// Non-virtualized scroll doesn't know its content height until
	// the renderer measures the child; use the prior-frame cached
	// value, which is zero on frame 1 (no scrollbar until the
	// second frame — acceptable).
	prior := widget_get(ctx, id, .Scroll)

	// When focusable, register this scroll container with the focus
	// list so Tab can land on it. Arrow / Page / Home / End then drive
	// scroll_y directly (handled inside scroll_advance via the
	// scroll_keyboard_nav helper). Default is opt-out because most
	// scroll containers don't want to crowd the Tab ring.
	if focusable {
		widget_make_focusable(ctx, id)
		if widget_has_focus(ctx, id) {
			scroll_keyboard_nav(ctx, id, size.y, prior.content_h, wheel_step)
		}
	}
	st, hover_thumb := scroll_advance(ctx, id, prior.content_h, wheel_step)

	tc := track_color; if tc[3] == 0 { tc = th.color.surface }
	uc := thumb_color; if uc[3] == 0 { uc = th.color.fg_muted }

	c := new(View, context.temp_allocator)
	c^ = content

	return View_Scroll{
		id          = id,
		size        = size,
		content     = c,
		offset_y    = st.scroll_y,
		wheel_step  = wheel_step,
		track_color = tc,
		thumb_color = uc,
		hover_thumb = hover_thumb,
		dragging    = st.pressed,
	}
}

// virtual_list renders huge lists efficiently by only building the
// row views currently visible in the scroll viewport. In fixed-height
// mode (the default) every row is `item_height` tall; pass
// `variable_height = true` plus an `estimated_height` hint to let
// each row measure to its own intrinsic size.
//
//     // Fixed row height:
//     skald.virtual_list(ctx, &state, len(state.items), 48, {600, 400},
//         proc(ctx: ^skald.Ctx(Msg), s: ^State, i: int) -> skald.View {
//             return render_row(ctx, s.items[i])
//         })
//
//     // Variable row height — wrapped chat messages, for instance:
//     skald.virtual_list(ctx, &state, len(state.msgs), 0, {600, 400},
//         render_row,
//         variable_height  = true,
//         estimated_height = 60,
//     )
//
// How the math works (fixed mode): the prior-frame `scroll_y` in
// Widget_State (kind = .Scroll, shared with the inner scroll)
// determines the visible index window `[first, last)`. We pad with
// `overscan` rows above and below to hide one-frame lag — a wheel
// burst briefly exceeds the prior viewport, so without overscan the
// top/bottom edges flash empty during fast scrolls. The row-builder
// proc is invoked only for indices in the window; every skipped row
// contributes to a leading or trailing `spacer` so the scrollbar math
// sees the full virtual content height.
//
// Variable-height mode keeps a persistent `heights` slice per virtual
// list (on the widget slot, persistent heap). Unmeasured rows start
// at `estimated_height`; each frame, rows inside the built window are
// measured via `view_size` and their stored height updated. A prefix
// sum of `heights` drives both the first/last search and the leading/
// trailing spacer sizes. When a row above the viewport gets remeasured
// and its height changes, `scroll_y` is re-anchored by the delta so
// the first visible row keeps its on-screen position — otherwise fast
// scrolling through estimate mismatches would jitter visibly.
//
// Widget-ID hygiene: auto-IDs inside `row_builder` are scoped per row
// index, so widgets you build there (buttons, checkboxes, text_inputs,
// ...) keep their hover / focus / press state stable as the visible
// window slides — no `hash_id(row_key)` boilerplate required. If you
// need cross-row identity (e.g. stable state when rows reorder or get
// filtered), pass an explicit `hash_id(row.key)` on the widget; that
// bypasses the scope and rides on the key you chose.
//
// Known v1 limits:
//   * No eviction of never-re-visited row Widget_State entries — a
//     long session through a million-row list will accumulate
//     widget-store entries. Acceptable for v1; add eviction when
//     real apps hit the ceiling.
//   * Vertical only (no horizontal virtualization).
//   * Variable-height mode assumes rows never change width (a resize
//     that reflows wrapped text invalidates cached heights — the next
//     pass through the viewport re-measures, but rows still above/below
//     keep their pre-resize height until next measured).
// Virtual_List_Params bundles every parameter of `virtual_list` so the
// fill-mode path can hand the whole call across the `sized` deferred
// boundary without a twelve-arg rawptr dance. Private: the caller never
// constructs this — virtual_list packs it internally when `viewport`
// has a zero axis.
@(private)
Virtual_List_Params :: struct($Msg: typeid, $T: typeid) {
	state:            T,
	total_count:      int,
	item_height:      f32,
	row_builder:      proc(ctx: ^Ctx(Msg), state: T, index: int) -> View,
	row_key:          proc(state: T, index: int) -> u64,
	id:               Widget_ID,
	overscan:         int,
	wheel_step:       f32,
	track_color:      Color,
	thumb_color:      Color,
	variable_height:  bool,
	estimated_height: f32,
	focusable:        bool,
	min:              [2]f32,
}

// virtual_list renders only the rows currently visible in `viewport`,
// which keeps frame time flat regardless of `total_count`. `row_builder`
// is called once per visible index per frame with `state` passed
// through untouched — put the row's data source there and index into
// it inside the builder.
//
// `item_height` is the fixed row height in logical pixels. Use
// `variable_height = true` with `estimated_height` as a seed when rows
// differ in height; the list will measure each row on first render and
// cache the real height. `overscan` renders that many extra rows above
// and below the viewport to smooth fast scrolls (default 4).
//
// `viewport` is the visible scroll window; a zero on either axis means
// "fill whatever my flex parent gives me" (see `scroll`'s fill mode).
// Track/thumb colors fall back to the theme when zero. `focusable` lets
// the list take keyboard focus for PageUp/PageDown/arrow-key scrolling.
virtual_list :: proc(
	ctx:         ^Ctx($Msg),
	state:       $T,
	total_count: int,
	item_height: f32,
	viewport:    [2]f32,
	row_builder: proc(ctx: ^Ctx(Msg), state: T, index: int) -> View,
	row_key:     proc(state: T, index: int) -> u64,
	id:          Widget_ID = 0,
	overscan:    int = 4,
	wheel_step:  f32 = 40,
	track_color: Color = {},
	thumb_color: Color = {},
	variable_height:  bool = false,
	estimated_height: f32  = 0,
	focusable:        bool = false,
) -> View {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)

	// Fill-mode: caller passed 0 on an axis to mean "take what my
	// flex parent gives me." Defer the real build through `sized` so
	// the assigned rect is known *this* frame — no last_rect lag. We
	// capture every parameter into a frame-arena struct because the
	// deferred build runs after `view` has returned. The trampoline
	// unpacks and re-enters virtual_list with the resolved viewport.
	if viewport.x <= 0 || viewport.y <= 0 {
		// When `state` is a pointer (the typical `&s_mut` call), the
		// pointee lives on view's stack. Deep-snapshot into the frame
		// arena so the deferred row_builder doesn't deref freed stack.
		state_snap := state
		when intrinsics.type_is_pointer(T) {
			Elem :: intrinsics.type_elem_type(T)
			elem := new(Elem, context.temp_allocator)
			elem^ = state^
			state_snap = cast(T) elem
		}

		P :: Virtual_List_Params(Msg, T)
		p := new(P, context.temp_allocator)
		p^ = P{
			state            = state_snap,
			total_count      = total_count,
			item_height      = item_height,
			row_builder      = row_builder,
			row_key          = row_key,
			id               = id,
			overscan         = overscan,
			wheel_step       = wheel_step,
			track_color      = track_color,
			thumb_color      = thumb_color,
			variable_height  = variable_height,
			estimated_height = estimated_height,
			focusable        = focusable,
			min              = viewport, // min-size hints
		}
		fill_builder :: proc(ctx: ^Ctx(Msg), data: ^P, size: [2]f32) -> View {
			// Tight-window guard — same as scroll() / grid().
			if size.x <= 0 || size.y <= 0 { return View_Spacer{size = 0} }
			return virtual_list(
				ctx,
				data.state,
				data.total_count,
				data.item_height,
				size, // concrete viewport now — skips the deferred branch
				data.row_builder,
				data.row_key,
				id               = data.id,
				overscan         = data.overscan,
				wheel_step       = data.wheel_step,
				track_color      = data.track_color,
				thumb_color      = data.thumb_color,
				variable_height  = data.variable_height,
				estimated_height = data.estimated_height,
				focusable        = data.focusable,
			)
		}
		return sized(ctx, p, fill_builder,
			min_w = viewport.x, min_h = viewport.y)
	}

	if variable_height {
		return virtual_list_variable(
			ctx, state, total_count, viewport, row_builder, row_key,
			id, overscan, wheel_step, track_color, thumb_color,
			estimated_height, item_height, focusable)
	}

	// viewport is now guaranteed non-zero on both axes.
	vp_y := viewport.y

	// Drive scroll input *this* frame before deciding the visible
	// range. Passing the exact content height means a scrollbar
	// drag that jumps scroll_y by thousands of pixels lands on the
	// same frame we build the new visible rows — no one-frame flash
	// of empty content during fast drags / track clicks.
	content_h := f32(total_count) * item_height
	if focusable {
		widget_make_focusable(ctx, id)
		if widget_has_focus(ctx, id) {
			scroll_keyboard_nav(ctx, id, vp_y, content_h, wheel_step)
		}
	}
	st, hover_thumb := scroll_advance(ctx, id, content_h, wheel_step)

	scroll_y := st.scroll_y
	max_off  := content_h - vp_y
	if max_off  < 0         { max_off  = 0         }
	if scroll_y < 0         { scroll_y = 0         }
	if scroll_y > max_off   { scroll_y = max_off   }

	first := int(scroll_y / item_height) - overscan
	last  := int((scroll_y + vp_y) / item_height) + overscan + 1
	if first < 0             { first = 0             }
	if last  > total_count   { last  = total_count   }
	if first > last          { first = last          }

	// Leading + built rows + trailing. Spacer(0) is a legal no-op
	// so we don't need to branch on first == 0 / last == total.
	rows := make([dynamic]View, 0, (last - first) + 2, context.temp_allocator)
	append(&rows, spacer(f32(first) * item_height))

	// Debug-only: warn the dev if `row_key` returns duplicate values
	// across visible rows. Same key → same widget scope → state
	// collisions inside the row (button hover/press, text_input edit
	// buffer, checkbox checked, etc.). Stripped from release builds.
	when ODIN_DEBUG {
		seen_keys := make(map[u64]int, (last - first), context.temp_allocator)
		warned    := false
	}

	for i in first..<last {
		// Per-row id scope built from the caller-supplied `row_key`
		// rather than the row index. That way widget state (checked,
		// focus, scroll) follows the *item* — a filter or reorder
		// doesn't smear state across neighbors the way index-keying
		// would. Salting with the list's own id keeps two sibling
		// virtual_lists with overlapping item-key ranges from
		// colliding; the fibonacci multiplier scatters adjacent keys
		// so consecutive uids don't cluster.
		//
		// `row_key` is a required param, but a caller passing `nil`
		// (a fresh proc variable left unset, say) would crash here.
		// Fall back to index-keying instead — same behaviour the
		// framework had before `row_key` existed. Lists that don't
		// reorder see no difference; lists that do should pass a
		// real key proc.
		k: u64 = u64(i)
		if row_key != nil { k = row_key(state, i) }
		when ODIN_DEBUG {
			if first_i, dup := seen_keys[k]; dup && !warned {
				fmt.eprintfln("[skald] virtual_list id=%v: row_key returned duplicate value 0x%X at rows %d and %d — widget state will collide between these rows. Make row_key unique per row (e.g. include a category code, or `return u64(i)` if reorder isn't a concern).",
					id, k, first_i, i)
				warned = true
			} else if !dup {
				seen_keys[k] = i
			}
		}
		scope := u64(widget_make_sub_id(id, k))
		saved := widget_scope_push(ctx, scope)
		append(&rows, row_builder(ctx, state, i))
		widget_scope_pop(ctx, saved)
	}
	append(&rows, spacer(f32(total_count - last) * item_height))

	content := col(..rows[:], spacing = 0, cross_align = .Stretch)

	tc := track_color; if tc[3] == 0 { tc = th.color.surface }
	uc := thumb_color; if uc[3] == 0 { uc = th.color.fg_muted }

	c := new(View, context.temp_allocator)
	c^ = content

	return View_Scroll{
		id          = id,
		size        = viewport,
		content     = c,
		offset_y    = scroll_y,
		wheel_step  = wheel_step,
		track_color = tc,
		thumb_color = uc,
		hover_thumb = hover_thumb,
		dragging    = st.pressed,
	}
}

// virtual_list_variable is the variable-height branch of `virtual_list`.
// Split into its own proc because the bookkeeping (per-row height cache,
// prefix-sum visible-range search, scroll re-anchoring on remeasure) is
// substantially more involved than the fixed-height path and inlining
// everything behind one `if variable_height` made the parent unreadable.
//
// Lifetime of the heights slice: lives on `Widget_State.virtual_heights`
// (persistent heap, owned by the slot). widget_get frees it when the slot
// is reused by a different widget kind; widget_store_destroy frees it on
// shutdown.
@(private)
virtual_list_variable :: proc(
	ctx:         ^Ctx($Msg),
	state:       $T,
	total_count: int,
	viewport:    [2]f32,
	row_builder: proc(ctx: ^Ctx(Msg), state: T, index: int) -> View,
	row_key:     proc(state: T, index: int) -> u64,
	id:          Widget_ID,
	overscan:    int,
	wheel_step:  f32,
	track_color: Color,
	thumb_color: Color,
	estimated_height: f32,
	fallback_height: f32,
	focusable:   bool,
) -> View {
	th := ctx.theme

	// Pick an estimate. estimated_height wins; then the legacy
	// item_height param if the caller also set it; else a reasonable
	// default that at least keeps the scrollbar non-degenerate.
	est := estimated_height
	if est <= 0 { est = fallback_height }
	if est <= 0 { est = 32 }

	// Get (or carry over) widget state. We reuse .Scroll kind so the
	// inner scroll_advance call finds the same slot.
	st := widget_get(ctx, id, .Scroll)

	// Lazily allocate the per-row height cache. Grow / shrink to the
	// current total_count, seeding new entries with the estimate so
	// the scrollbar doesn't flicker while rows page in. Shrinking is
	// fine: the trailing entries belonged to rows that no longer
	// exist, and keeping them would inflate content_h.
	if st.virtual_heights == nil {
		hp := new([dynamic]f32)
		hp^ = make([dynamic]f32)
		st.virtual_heights = hp
	}
	heights := st.virtual_heights
	prev_n  := len(heights^)
	if prev_n < total_count {
		resize(heights, total_count)
		for i in prev_n..<total_count { heights[i] = est }
	} else if prev_n > total_count {
		resize(heights, total_count)
	}

	if total_count == 0 {
		widget_set(ctx, id, st)
		tc := track_color; if tc[3] == 0 { tc = th.color.surface }
		uc := thumb_color; if uc[3] == 0 { uc = th.color.fg_muted }
		empty := col(spacing = 0, cross_align = .Stretch)
		c := new(View, context.temp_allocator)
		c^ = empty
		return View_Scroll{
			id = id, size = viewport, content = c,
			offset_y = 0, wheel_step = wheel_step,
			track_color = tc, thumb_color = uc,
		}
	}

	// Sum the cached heights *before* this frame's remeasurement. This
	// is the content_h the renderer used last frame, and the one the
	// scrollbar thumb was drawn against. Passing it into scroll_advance
	// keeps the drag mapping (cursor-y → scroll_y) stable from frame to
	// frame — if we used the post-measurement total, max_off would
	// change under the cursor mid-drag and the content would race
	// ahead or lag behind the thumb, which reads as flicker.
	content_h_pre: f32 = 0
	for h in heights^ { content_h_pre += h }

	// Commit the caller's (carried-over) scroll_y before scroll_advance
	// reads it — widget_get gave us a snapshot, not a live reference.
	widget_set(ctx, id, st)

	// Focus registration + keyboard nav (Page_Up/Down, Home/End, arrows)
	// happens before scroll_advance so the widget_set inside
	// scroll_keyboard_nav is picked up by scroll_advance's widget_get.
	if focusable {
		widget_make_focusable(ctx, id)
		if widget_has_focus(ctx, id) {
			scroll_keyboard_nav(ctx, id, viewport.y, content_h_pre, wheel_step)
		}
	}

	// Run all scroll input *first* so layout, spacers, and offset_y
	// agree on one scroll_y. The previous order built the layout from
	// st.scroll_y and then let scroll_advance overwrite scroll_y for
	// the returned offset_y, leaving spacers sized for one position
	// and content rendered at another.
	st2, hover_thumb := scroll_advance(ctx, id, content_h_pre, wheel_step)
	scroll_y := st2.scroll_y
	if scroll_y < 0 { scroll_y = 0 }
	dragging := st2.pressed

	// Locate the first visible row using the *old* heights. A linear
	// scan is O(total_count) which stays acceptable into the low 6-
	// figure row counts; upgrade to a Fenwick tree if a real app
	// hits the ceiling.
	first_visible: int = 0
	offset_at_first_old: f32 = 0  // prefix_sum_old[first_visible]
	{
		acc: f32 = 0
		found := false
		for i in 0..<total_count {
			h := heights[i]
			if acc + h > scroll_y {
				first_visible      = i
				offset_at_first_old = acc
				found = true
				break
			}
			acc += h
		}
		if !found {
			first_visible       = total_count - 1
			offset_at_first_old = acc - heights[first_visible]
		}
	}

	// Expand to overscan on both ends.
	first := first_visible - overscan
	if first < 0 { first = 0 }

	// Find last visible (exclusive) — where prefix_sum passes
	// scroll_y + viewport.y.
	last: int = total_count
	{
		acc: f32 = offset_at_first_old
		last_found := false
		for i in first_visible..<total_count {
			acc += heights[i]
			if acc >= scroll_y + viewport.y {
				last = i + 1
				last_found = true
				break
			}
		}
		if !last_found { last = total_count }
	}
	last += overscan
	if last > total_count { last = total_count }
	if first > last       { first = last       }

	// Build + measure each row in the visible window. Update the
	// stored height in place — next frame's visible-range search will
	// use the measured values. Scope auto-ids per row so hover/press
	// state rides the index, not the visible-window slot.
	built := make([dynamic]View, 0, last - first, context.temp_allocator)
	when ODIN_DEBUG {
		seen_keys := make(map[u64]int, (last - first), context.temp_allocator)
		warned    := false
	}
	for i in first..<last {
		// Caller-supplied stable key so state follows items through
		// reorders / filters. See the equivalent comment in
		// virtual_list. Nil-safe fallback to index keying.
		k: u64 = u64(i)
		if row_key != nil { k = row_key(state, i) }
		when ODIN_DEBUG {
			if first_i, dup := seen_keys[k]; dup && !warned {
				fmt.eprintfln("[skald] virtual_list_variable id=%v: row_key returned duplicate value 0x%X at rows %d and %d — widget state will collide between these rows. Make row_key unique per row.",
					id, k, first_i, i)
				warned = true
			} else if !dup {
				seen_keys[k] = i
			}
		}
		scope   := u64(widget_make_sub_id(id, k))
		saved   := widget_scope_push(ctx, scope)
		v  := row_builder(ctx, state, i)
		sz := view_size(ctx.renderer, v)
		if sz.y > 0 { heights[i] = sz.y }
		append(&built, v)
		widget_scope_pop(ctx, saved)
	}

	// Recompute total content height under the *new* heights.
	content_h: f32 = 0
	for h in heights^ { content_h += h }

	// Re-anchor: if rows in [first, first_visible) got measured to
	// heights different from their cached values, the prefix sum shifted
	// under our scroll_y. Nudge scroll_y so first_visible stays visually
	// pinned. Skip this while the user is dragging the thumb — their
	// cursor-driven scroll_y already reflects where they want the
	// content to be, and an extra nudge here just fights the drag.
	if !dragging {
		anchor_offset_new: f32 = 0
		for i in 0..<first_visible { anchor_offset_new += heights[i] }
		delta := anchor_offset_new - offset_at_first_old
		if delta != 0 {
			scroll_y += delta
			st2.scroll_y = scroll_y
			widget_set(ctx, id, st2)
		}
	}

	// Leading spacer = new prefix_sum[first]; trailing =
	// content_h - new prefix_sum[last]. We already summed the body
	// range while measuring, but recomputing here keeps the three
	// spans obvious and matches the numbers used for layout.
	lead: f32 = 0
	for i in 0..<first { lead += heights[i] }
	body_sum: f32 = 0
	for i in first..<last { body_sum += heights[i] }
	trail := content_h - (lead + body_sum)
	if trail < 0 { trail = 0 }

	rows := make([dynamic]View, 0, len(built) + 2, context.temp_allocator)
	append(&rows, spacer(lead))
	for v in built { append(&rows, v) }
	append(&rows, spacer(trail))

	content := col(..rows[:], spacing = 0, cross_align = .Stretch)

	tc := track_color; if tc[3] == 0 { tc = th.color.surface }
	uc := thumb_color; if uc[3] == 0 { uc = th.color.fg_muted }

	c := new(View, context.temp_allocator)
	c^ = content

	return View_Scroll{
		id          = id,
		size        = viewport,
		content     = c,
		offset_y    = scroll_y,
		wheel_step  = wheel_step,
		track_color = tc,
		thumb_color = uc,
		hover_thumb = hover_thumb,
		dragging    = st2.pressed,
	}
}

// Table_Column describes one column of a `table`. Either `width` or
// `flex` should be set — a fixed `width` claims that many pixels
// regardless of the viewport, while `flex` weights proportional
// distribution of remaining space after fixed columns take their
// share. `align` controls the horizontal placement of the cell
// content within the column's box, not the content itself.
//
// `sortable` turns the header cell into a clickable zone that emits
// the table's `on_sort_change` when pressed, and draws a ▲/▼
// indicator when this column matches the table's `sort_column`.
// `resizable` adds a 6-px drag handle at the column's right edge
// that emits `on_resize(col, new_width)` while the user drags;
// resizable columns must start with a non-zero `width` (flex
// columns have no fixed pixel value to resize from). Both flags
// default to false so tables without interactive headers get no
// behavior they didn't ask for.
Table_Column :: struct {
	label:     string,
	width:     f32,         // fixed width in pixels; 0 means flex-sized
	flex:      f32,         // weight when width == 0; ignored otherwise
	align:     Cross_Align, // horizontal alignment of cell content in the column
	sortable:  bool,        // clicking the header fires on_sort_change
	resizable: bool,        // right-edge drag fires on_resize; needs width > 0
	// hidden=true collapses the column entirely: the header cell, body
	// cells, and any resize/sort hit-targets are skipped. The app's
	// `row_builder` is still called with the full set of cells — it's
	// simpler to over-produce and let the table drop the hidden ones
	// than to thread a visible-column mask through the builder.
	hidden:    bool,
}

// SCROLLBAR_GUTTER reserves pixels on the right of the header so
// header cells line up with body cells even when the scrollbar is
// visible (the body's scrollbar is painted on top of the rightmost
// 6-8 px of the scroll viewport; we leave a matching strip on the
// header for visual alignment).
@(private)
SCROLLBAR_GUTTER :: f32(12)

// RESIZE_HANDLE_W is the width of the invisible hit-zone placed at
// the right edge of each resizable column header. A 1-px divider is
// drawn inside the zone so the edge is visible without forcing the
// user to land on an exactly 1-px target.
@(private)
RESIZE_HANDLE_W :: f32(6)

// MIN_COLUMN_W clamps how narrow a resizable column can shrink to,
// so a sloppy drag can't collapse a column into unclickable
// invisibility.
@(private)
MIN_COLUMN_W :: f32(40)

// compute_column_widths distributes `total` horizontal pixels
// across `columns`: fixed widths first, then flex-weighted shares
// of what's left. Returns a temp-allocator slice of widths in the
// same order as the input columns.
@(private)
// compute_column_widths distributes `total` pixels across columns.
// Fixed widths first, then flex-weighted shares of the remainder.
compute_column_widths :: proc(columns: []Table_Column, total: f32) -> []f32 {
	widths := make([]f32, len(columns), context.temp_allocator)
	fixed_sum: f32 = 0
	flex_sum:  f32 = 0
	for c, i in columns {
		if c.hidden { widths[i] = 0; continue }
		if c.width > 0 {
			widths[i] = c.width
			fixed_sum += c.width
		} else {
			flex_sum += c.flex
		}
	}
	if flex_sum > 0 {
		pool := total - fixed_sum
		if pool < 0 { pool = 0 }
		for c, i in columns {
			if c.hidden { continue }
			if c.width == 0 {
				widths[i] = pool * (c.flex / flex_sum)
			}
		}
	}
	return widths
}

// table is a pinned-header + virtualized-body grid. Columns are
// shared between header and body so cells line up vertically; the
// body is virtualized via the same machinery as `virtual_list`, so
// a 100k-row table costs the same per frame as a 100-row one.
//
//     cols := []skald.Table_Column{
//         {label = "Name",     flex = 3, align = .Start},
//         {label = "Size",     width = 80, align = .End},
//         {label = "Modified", width = 160, align = .Start},
//     }
//     skald.table(ctx, &state, cols, len(state.files), 32,
//         {width, height},
//         proc(ctx: ^skald.Ctx(Msg), s: ^State, i: int) -> []skald.View {
//             f := s.files[i]
//             return []skald.View{
//                 skald.text(f.name, fg, size),
//                 skald.text(f.size, fg_muted, size),
//                 skald.text(f.mtime, fg_muted, size),
//             }
//         })
//
// The row builder returns one View per column, in the order matching
// `columns`. The table wraps each cell in a fixed-width column box
// using `align` for horizontal placement and stitches the row
// together. Returning a shorter slice is fine — missing columns
// render empty.
//
// `viewport` is the *total* table size (header + body). Header
// claims `header_height`; the remaining `viewport.y - header_height`
// becomes the scrollable body's viewport.
//
// Selection model: `is_selected(state, row)` drives the row bg
// tint and `on_row_click(row, mods)` delivers the click along
// with the current modifier keys. Storage and multi-select rules
// (Ctrl-toggle, Shift-extend, select-all) live in the app — the
// table only delivers events. That's intentional: real apps want
// range sets, exclusion filters, or selection scoped by column,
// none of which a built-in "selected row index" could model.
//
// Sortable / resizable columns are opt-in at the column level
// (`Table_Column.sortable` / `.resizable`). When a column is
// sortable and `on_sort_change != nil`, clicking its header emits
// the callback; the table draws a ▲/▼ indicator next to the label
// when `sort_column` matches. When a column is resizable and
// `on_resize != nil`, a 6-px drag handle at the right edge uses a
// donor model: grow the dragged column by Δ and shrink the next
// fixed column by Δ, so total width stays equal to `usable_w` and
// the divider tracks the cursor without overflow or release-snap.
// Each drag frame emits two callbacks, one per affected column.
// When no fixed donor exists to the right (e.g. dragging the last
// column's handle), the first flex column is locked to its current
// computed width via a one-shot `on_resize` on latch and used as
// the donor from then on — once the user touches sizing, flex
// yields to manual widths. In both cases the app holds the state
// (sort direction, column widths) and feeds it back in next
// frame's arguments — the table is event-only, consistent with
// the selection model.
// Callback params have no `= nil` default because Odin can't unify a
// nil literal with the parametric `Msg`/`T`-returning proc type at
// the caller's instantiation point. Callers pass `nil` explicitly to
// opt out of any given interaction — that also makes the capability
// set of a given table self-documenting at the call site.
//
// Keyboard: the table registers as focusable when `on_row_click` is
// non-nil. When focused (reached via Tab or by clicking a row),
// Up / Down / PageUp / PageDown / Home / End synthesize a click on
// the new row via `on_row_click(new_row, synth_mods)` — Shift is
// preserved so keyboard range-extend mirrors Shift-click, other
// modifiers are stripped. Enter / Space fire `on_row_activate` on
// the current focus row (when non-nil). The table auto-scrolls to
// keep the newly-focused row in view.
//
// `focus_row` is the app's cursor row; the table reads it to draw
// the focus tint and compute nav deltas. It isn't owned by the
// table — the app updates focus_row in response to `on_row_click`
// (the same handler that updates selection), so focus and selection
// stay in sync without the table having to duplicate bookkeeping.
// Table_Params bundles every `table` argument so the fill-mode path
// can round-trip them across `sized`. Private — only the internal
// deferred-wrapper constructs it.
@(private)
Table_Params :: struct($Msg: typeid, $T: typeid) {
	state:           T,
	columns:         []Table_Column,
	row_count:       int,
	item_height:     f32,
	row_builder:     proc(ctx: ^Ctx(Msg), state: T, row: int) -> []View,
	row_key:         proc(state: T, row: int) -> u64,
	on_row_click:    proc(row: int, mods: Modifiers) -> Msg,
	is_selected:     proc(state: T, row: int) -> bool,
	on_sort_change:  proc(col: int, ascending: bool) -> Msg,
	on_resize:       proc(col: int, new_width: f32) -> Msg,
	on_row_activate: proc(row: int) -> Msg,
	sort_column:     int,
	sort_ascending:  bool,
	focus_row:       int,
	id:              Widget_ID,
	overscan:        int,
	header_height:   f32,
	hairline:        bool,
}

// table is a virtualized, sortable, resizable, selectable data grid.
// Visible rows only are rendered each frame (see `virtual_list`), so
// `row_count` can be large without frame-time cost.
//
// `columns` describes the headers and per-column widths + flex + sort
// behavior. `row_builder` returns one View per column for the given
// row index; the returned slice must have `len(columns)` elements in
// the same order. `state` is passed through to the builder untouched.
//
// Interaction callbacks:
//   - `on_row_click(row, mods)`   — single click; inspect mods for
//     Shift (range select) or Ctrl (toggle) to implement multi-select
//   - `is_selected(state, row)`   — drives the selected-row background
//   - `on_sort_change(col, asc)`  — click on a sortable column header
//   - `on_resize(col, new_width)` — dragged the column divider
//   - `on_row_activate(row)`      — double-click or Enter on focused row
//
// Any callback may be nil — pass nil to disable that interaction.
//
// Optional: `sort_column`/`sort_ascending` draw the sort indicator;
// `focus_row` is the keyboard-focused row (drawn with a ring);
// `header_height` defaults to 32 logical pixels; `overscan` is the
// extra rows rendered outside the viewport for smooth scrolling.
// `viewport` follows the same zero-axis fill convention as `scroll`.
table :: proc(
	ctx:             ^Ctx($Msg),
	state:           $T,
	columns:         []Table_Column,
	row_count:       int,
	item_height:     f32,
	viewport:        [2]f32,
	row_builder:     proc(ctx: ^Ctx(Msg), state: T, row: int) -> []View,
	row_key:         proc(state: T, row: int) -> u64,
	on_row_click:    proc(row: int, mods: Modifiers) -> Msg,
	is_selected:     proc(state: T, row: int)        -> bool,
	on_sort_change:  proc(col: int, ascending: bool) -> Msg,
	on_resize:       proc(col: int, new_width: f32)  -> Msg,
	on_row_activate: proc(row: int) -> Msg,
	sort_column:     int       = -1,
	sort_ascending:  bool      = true,
	focus_row:       int       = -1,
	id:              Widget_ID = 0,
	overscan:        int       = 4,
	header_height:   f32       = 32,
	// hairline draws a 1-px divider along the bottom of every row
	// (theme.color.border). The Stripe / Linear / GitHub data-table
	// look — separates rows without fighting the bg of cells that
	// hold widgets with their own surface fills (number_input,
	// select, button). Selected / focused rows render under the
	// hairline so it still reads consistently.
	hairline:        bool      = false,
) -> View {
	th := ctx.theme

	// Fill-mode: zero on an axis → defer to the assigned rect via
	// `sized`. Same pattern as virtual_list. The trampoline re-enters
	// `table` with the resolved viewport and skips this branch.
	if viewport.x <= 0 || viewport.y <= 0 {
		// `columns` is typically a stack-local slice literal inside
		// `view` — clone its backing array into temp arena so the
		// deferred builder doesn't iterate freed stack memory. Element
		// fields (label strings etc.) are almost always string literals
		// or tprintf output, so a shallow copy is sufficient.
		cols_clone := make([]Table_Column, len(columns), context.temp_allocator)
		copy(cols_clone, columns)

		// Deep-snapshot `state` when it's a pointer — same reasoning as
		// virtual_list's fill branch.
		state_snap := state
		when intrinsics.type_is_pointer(T) {
			Elem :: intrinsics.type_elem_type(T)
			elem := new(Elem, context.temp_allocator)
			elem^ = state^
			state_snap = cast(T) elem
		}

		P :: Table_Params(Msg, T)
		p := new(P, context.temp_allocator)
		p^ = P{
			state           = state_snap,
			columns         = cols_clone,
			row_count       = row_count,
			item_height     = item_height,
			row_builder     = row_builder,
			row_key         = row_key,
			on_row_click    = on_row_click,
			is_selected     = is_selected,
			on_sort_change  = on_sort_change,
			on_resize       = on_resize,
			on_row_activate = on_row_activate,
			sort_column     = sort_column,
			sort_ascending  = sort_ascending,
			focus_row       = focus_row,
			id              = id,
			overscan        = overscan,
			header_height   = header_height,
			hairline        = hairline,
		}
		fill_builder :: proc(ctx: ^Ctx(Msg), data: ^P, size: [2]f32) -> View {
			// Tight-window guard — same as scroll() / grid() / virtual_list().
			if size.x <= 0 || size.y <= 0 { return View_Spacer{size = 0} }
			return table(
				ctx,
				data.state,
				data.columns,
				data.row_count,
				data.item_height,
				size,
				data.row_builder,
				data.row_key,
				data.on_row_click,
				data.is_selected,
				data.on_sort_change,
				data.on_resize,
				data.on_row_activate,
				sort_column    = data.sort_column,
				sort_ascending = data.sort_ascending,
				focus_row      = data.focus_row,
				id             = data.id,
				overscan       = data.overscan,
				header_height  = data.header_height,
				hairline       = data.hairline,
			)
		}
		return sized(ctx, p, fill_builder,
			min_w = viewport.x, min_h = viewport.y)
	}

	// Column widths are computed against viewport.x minus the
	// scrollbar gutter so header cells line up with body cells
	// whenever the body's scrollbar is visible. When the rows
	// fit inside the viewport (no scrollbar) we let the columns
	// claim the full width — otherwise the header trails off into
	// an empty strip on the right that reads as a layout bug.
	// Drag-time width bookkeeping is resolved through the donor
	// model below — the handle grows one column and shrinks
	// another by the same delta, so total stays equal to
	// `usable_w` and the divider tracks the cursor without the
	// table overflowing or the flex column silently absorbing
	// every pixel.
	body_h_est    := viewport.y - header_height
	will_scroll   := f32(row_count) * item_height > body_h_est
	gutter        := SCROLLBAR_GUTTER if will_scroll else 0
	usable_w := viewport.x - gutter
	if usable_w < 0 { usable_w = 0 }
	widths := compute_column_widths(columns, usable_w)

	// --- Header ---
	// Each column contributes either [label] or [label, resize_handle]
	// to the header row, so two views max per column. Using a dynamic
	// array keeps the append loop readable — the allocation lands in
	// the temp arena and is freed at frame end.
	hdr_items := make([dynamic]View, 0, len(columns) * 2, context.temp_allocator)
	for c, i in columns {
		if c.hidden { continue }
		handle_w: f32 = 0
		if c.resizable { handle_w = RESIZE_HANDLE_W }
		label_w := widths[i] - handle_w
		if label_w < 0 { label_w = 0 }

		// Append the sort indicator to the label text when this
		// column is the one the app is currently sorting by. Using
		// tprintf means the expanded label lives in the frame arena;
		// no cleanup needed.
		label_str := c.label
		if c.sortable && sort_column == i {
			arrow := "▼"
			if sort_ascending { arrow = "▲" }
			label_str = fmt.tprintf("%s %s", c.label, arrow)
		}

		label_view := col(
			text(label_str, th.color.fg, th.font.size_sm),
			width       = label_w,
			height      = header_height,
			padding     = th.spacing.sm,
			main_align  = .Center,
			cross_align = c.align,
		)

		// Sort click zone. The whole label area is the hit target so
		// the user doesn't have to aim at the arrow glyph. Convention:
		// clicking the same column flips direction; clicking a new
		// column starts ascending.
		if c.sortable && on_sort_change != nil {
			sort_id := widget_auto_id(ctx)
			sort_st := widget_get(ctx, sort_id, .Click_Zone)
			if ctx.input.mouse_pressed[.Left] &&
			   rect_hovered(ctx, sort_st.last_rect) {
				new_asc := true
				if sort_column == i { new_asc = !sort_ascending }
				send(ctx, on_sort_change(i, new_asc))
			}
			widget_set(ctx, sort_id, sort_st)
			lv := new(View, context.temp_allocator)
			lv^ = label_view
			label_view = View_Zone{id = sort_id, child = lv}
		}
		append(&hdr_items, label_view)

		// Resize handle: a 6-px zone with a centered 1-px divider.
		// The hit area is 6 px so the user doesn't have to pixel-hunt;
		// the drawn divider is 1 px so the column edge reads as a
		// line, not a slab. Drag state reuses the Click_Zone kind —
		// kind-tagging isn't needed to disambiguate it from sort
		// zones because the positional auto-id ordering already
		// partitions them per column.
		if c.resizable {
			handle_id := widget_auto_id(ctx)
			handle_st := widget_get(ctx, handle_id, .Click_Zone)

			// Drag state machine. On press-inside-handle, latch the
			// offset `mouse_x - width` so the divider tracks the
			// cursor through the whole drag even after the width
			// changes in response. Mirrors the scrollbar thumb's
			// grab-offset trick.
			//
			// Donor model: dragging col i's right edge grows col i and
			// shrinks a donor column by the same delta, so total
			// stays constant and the table never overflows mid-drag.
			// Donor search prefers the next fixed column (keeps the
			// user's flex column stable where possible); when none
			// exists — e.g. the last column, or columns with only a
			// flex column to their right — we fall back to the first
			// flex column and lock it to its current computed width
			// via an extra Col_Resized, so from the next frame onward
			// both sides of the donor split are fixed-width. The
			// donor index is stamped on handle_st so it stays
			// consistent across the gesture: a re-search after
			// lock-in would miss the flex case on subsequent frames.
			if !handle_st.pressed &&
			   ctx.input.mouse_pressed[.Left] &&
			   rect_hovered(ctx, handle_st.last_rect) {
				handle_st.pressed     = true
				handle_st.drag_anchor = ctx.input.mouse_pos.x - widths[i]

				donor := -1
				for j := i + 1; j < len(columns); j += 1 {
					if columns[j].hidden { continue }
					if columns[j].width > 0 { donor = j; break }
				}
				if donor < 0 {
					for j := 0; j < len(columns); j += 1 {
						if columns[j].hidden { continue }
						if j != i && columns[j].width == 0 { donor = j; break }
					}
					if donor >= 0 && on_resize != nil {
						send(ctx, on_resize(donor, widths[donor]))
					}
				}
				handle_st.drag_donor = donor
			}
			if handle_st.pressed && !ctx.input.mouse_buttons[.Left] {
				handle_st.pressed = false
			}
			if handle_st.pressed && on_resize != nil {
				new_w := ctx.input.mouse_pos.x - handle_st.drag_anchor
				if new_w < MIN_COLUMN_W { new_w = MIN_COLUMN_W }

				donor := handle_st.drag_donor
				if donor >= 0 && donor < len(columns) {
					delta := new_w - widths[i]
					donor_new := widths[donor] - delta
					// Clamp the donor first — if it would go below
					// MIN, pull `delta` back so the donor lands at
					// exactly MIN and the dragged column ends up with
					// whatever that leaves. Keeps totals invariant
					// even at the extreme.
					if donor_new < MIN_COLUMN_W {
						donor_new = MIN_COLUMN_W
						delta     = widths[donor] - MIN_COLUMN_W
						new_w     = widths[i] + delta
					}
					if new_w < MIN_COLUMN_W {
						new_w     = MIN_COLUMN_W
						delta     = new_w - widths[i]
						donor_new = widths[donor] - delta
					}
					if new_w != widths[i] {
						send(ctx, on_resize(i, new_w))
						send(ctx, on_resize(donor, donor_new))
					}
				} else if new_w != widths[i] {
					send(ctx, on_resize(i, new_w))
				}
			}
			widget_set(ctx, handle_id, handle_st)

			// 2-px divider centered in the 6-px hit zone. fg_muted is a
			// much higher-contrast pick than `border`, which disappears
			// against `elevated` in the dark theme and makes the handle
			// look like dead space you can't click. Hover bumps the
			// color to primary so the user sees what they're about to
			// drag; active drag stays primary for the whole gesture.
			divider_color := th.color.fg_muted
			handle_hover := rect_hovered(ctx, handle_st.last_rect)
			if handle_hover || handle_st.pressed {
				divider_color = th.color.primary
			}
			handle_visual := col(
				rect({2, header_height}, divider_color),
				width       = handle_w,
				height      = header_height,
				cross_align = .Center,
			)
			hv := new(View, context.temp_allocator)
			hv^ = handle_visual
			append(&hdr_items, View_Zone{id = handle_id, child = hv})
		}
	}

	// Header width matches the body's usable area, not the full viewport.
	// When a scrollbar is visible the gutter sits to the right of both —
	// header bg ends at usable_w, body row content ends at usable_w, the
	// scrollbar lives in the 12 px gap to their right. Without this the
	// header's elevated bg extended into the gutter as a stray empty
	// strip past the last column.
	header := row(..hdr_items[:],
		width       = usable_w,
		height      = header_height,
		bg          = th.color.elevated,
		radius      = 0,
		spacing     = 0,
		cross_align = .Stretch,
	)

	// --- Body: virtualized rows, each a row of column-sized cells.
	// We can't call virtual_list directly because its row builder
	// returns a single View; we need to wrap the caller's cells in
	// column boxes. Inline the virtualization instead — it's only
	// a few lines past the shared `scroll_advance` helper.
	body_viewport := [2]f32{viewport.x, viewport.y - header_height}
	body_id := widget_resolve_id(ctx, id)

	// Tables with row interactions register as focusable so Tab
	// traversal and the "click a row to focus the table for arrow
	// nav" UX both work. A read-only static table skips this — no
	// point in Tab landing on something that can't be steered.
	if on_row_click != nil {
		widget_make_focusable(ctx, body_id)
	}
	table_focused := widget_has_focus(ctx, body_id)

	content_h := f32(row_count) * item_height
	st, hover_thumb := scroll_advance(ctx, body_id, content_h, 40)

	scroll_y := st.scroll_y
	max_off  := content_h - body_viewport.y
	if max_off  < 0         { max_off  = 0         }
	if scroll_y < 0         { scroll_y = 0         }
	if scroll_y > max_off   { scroll_y = max_off   }

	// Keyboard nav. Up / Down / PageUp / PageDown / Home / End
	// compute a new focus row and synthesize a click on it so the
	// app's existing selection logic applies. Shift is preserved
	// for range-extend; Ctrl is stripped because we don't model a
	// separate "focus cursor" distinct from selection anchor yet
	// (v1 keeps them unified). Enter / Space fire on_row_activate.
	if table_focused && row_count > 0 && on_row_click != nil {
		keys := ctx.input.keys_pressed
		mods := ctx.input.modifiers

		nav := -1
		visible_rows := int(body_viewport.y / item_height)
		if visible_rows < 1 { visible_rows = 1 }

		if focus_row < 0 {
			// First-time nav with no focus row lands somewhere
			// sensible per key, not at "row -1 + 1 = 0" by accident.
			if .Up   in keys || .Home in keys || .Page_Up   in keys { nav = 0             }
			if .Down in keys                 || .Page_Down in keys { nav = 0             }
			if .End  in keys                                       { nav = row_count - 1 }
		} else {
			cur := focus_row
			if .Up       in keys && cur > 0                { nav = cur - 1 }
			if .Down     in keys && cur < row_count - 1    { nav = cur + 1 }
			if .Page_Up in keys {
				nav = cur - visible_rows
				if nav < 0 { nav = 0 }
			}
			if .Page_Down in keys {
				nav = cur + visible_rows
				if nav > row_count - 1 { nav = row_count - 1 }
			}
			if .Home in keys { nav = 0             }
			if .End  in keys { nav = row_count - 1 }
		}

		if nav >= 0 {
			synth: Modifiers
			if .Shift in mods { synth = synth + {.Shift} }
			send(ctx, on_row_click(nav, synth))

			// Auto-scroll the minimal amount to bring `nav` into
			// view. If the row is above the current viewport, snap
			// its top to scroll_y; if below, snap its bottom to the
			// viewport's bottom edge. No-op when already visible.
			top    := f32(nav) * item_height
			bottom := top + item_height
			if top    < scroll_y                   { scroll_y = top                      }
			if bottom > scroll_y + body_viewport.y { scroll_y = bottom - body_viewport.y }
			if scroll_y > max_off                  { scroll_y = max_off                  }
			if scroll_y < 0                        { scroll_y = 0                        }
			st.scroll_y = scroll_y
			widget_set(ctx, body_id, st)
		}

		if (.Enter in keys || .Space in keys) &&
		   on_row_activate != nil &&
		   focus_row >= 0 && focus_row < row_count {
			send(ctx, on_row_activate(focus_row))
		}
	}

	first := int(scroll_y / item_height) - overscan
	last  := int((scroll_y + body_viewport.y) / item_height) + overscan + 1
	if first < 0          { first = 0          }
	if last  > row_count  { last  = row_count  }
	if first > last       { first = last       }

	body_rows := make([dynamic]View, 0, (last - first) + 2, context.temp_allocator)
	append(&body_rows, spacer(f32(first) * item_height))
	when ODIN_DEBUG {
		seen_keys := make(map[u64]int, (last - first), context.temp_allocator)
		warned    := false
	}
	for i in first..<last {
		// Per-row id scope built off the caller-supplied `row_key` so
		// widget state inside cells (and the row-click zone below)
		// follows the *item*, not the row index. Filtering or sorting
		// the data doesn't smear state across neighbors. Nil-safe
		// fallback to index keying.
		k: u64 = u64(i)
		if row_key != nil { k = row_key(state, i) }
		when ODIN_DEBUG {
			if first_i, dup := seen_keys[k]; dup && !warned {
				fmt.eprintfln("[skald] table id=%v: row_key returned duplicate value 0x%X at rows %d and %d — widget state inside cells will collide between these rows. Make row_key unique per row (e.g. include a discriminator field, or `return u64(i)` if your data isn't reordered).",
					id, k, first_i, i)
				warned = true
			} else if !dup {
				seen_keys[k] = i
			}
		}
		scope   := u64(widget_make_sub_id(body_id, k))
		saved   := widget_scope_push(ctx, scope)
		cells := row_builder(ctx, state, i)
		// Catch a common footgun in debug builds: columns array out of
		// sync with what row_builder returns. Silent mis-rendering
		// (e.g. the Status badge landing in the Owner column) is
		// hard to diagnose; crash loudly in -debug so the bug
		// surfaces at the call site instead of three widgets away.
		when ODIN_DEBUG {
			assert(len(cells) == len(columns),
				"table row_builder returned the wrong number of cells for the columns slice")
		}
		wrapped := make([dynamic]View, 0, len(columns), context.temp_allocator)
		for col_spec, ci in columns {
			if col_spec.hidden { continue }
			cell: View
			if ci < len(cells) { cell = cells[ci] }
			append(&wrapped, col(
				cell,
				width       = widths[ci],
				height      = item_height,
				padding     = th.spacing.sm,
				main_align  = .Center,
				cross_align = col_spec.align,
			))
		}

		// Row background layers three states:
		//   * selected + table-focused    → primary   (solid accent)
		//   * table-focused cursor row    → selection (translucent primary)
		//   * selected, table unfocused   → elevated  (subtle stand-out)
		//   * everything else             → surface   (default)
		// When the table loses focus (user clicks elsewhere), the
		// primary bg fades back to elevated so the selection stays
		// readable but visibly "inactive" — matches native toolkits.
		selected := is_selected != nil && is_selected(state, i)
		focused_cursor := table_focused && i == focus_row
		row_bg := th.color.surface
		switch {
		case selected && focused_cursor: row_bg = th.color.primary
		case focused_cursor:              row_bg = th.color.selection
		case selected:                    row_bg = selected_inactive_bg_for(th^)
		}

		// hairline mode: split the row's height between an inner
		// content row (item_height - 1 px) and a 1-px divider at the
		// bottom. The total row height stays exactly `item_height`
		// so the virtualized scroll math still works. Last row skips
		// the divider so the table doesn't end with a floating line.
		row_view: View
		if hairline {
			inner_h := item_height - 1
			if inner_h < 0 { inner_h = item_height }
			inner := row(..wrapped[:],
				width       = usable_w,
				height      = inner_h,
				spacing     = 0,
				bg          = row_bg,
				radius      = 0,
				cross_align = .Stretch,
			)
			if i < row_count - 1 {
				row_view = col(
					inner,
					divider(ctx),
					width       = usable_w,
					height      = item_height,
					cross_align = .Stretch,
				)
			} else {
				row_view = inner
			}
		} else {
			row_view = row(..wrapped[:],
				width       = usable_w,
				height      = item_height,
				spacing     = 0,
				bg          = row_bg,
				radius      = 0,
				cross_align = .Stretch,
			)
		}

		if on_row_click != nil {
			row_id := widget_auto_id(ctx)
			row_st := widget_get(ctx, row_id, .Click_Zone)
			if ctx.input.mouse_pressed[.Left] &&
			   rect_hovered(ctx, row_st.last_rect) {
				send(ctx, on_row_click(i, ctx.input.modifiers))
				// Clicking a row moves keyboard focus to the table
				// so arrow keys Just Work without an extra Tab.
				widget_focus(ctx, body_id)
			}
			widget_set(ctx, row_id, row_st)
			rc := new(View, context.temp_allocator)
			rc^ = row_view
			append(&body_rows, View_Zone{id = row_id, child = rc})
		} else {
			append(&body_rows, row_view)
		}
		widget_scope_pop(ctx, saved)
	}
	append(&body_rows, spacer(f32(row_count - last) * item_height))

	body_content := col(..body_rows[:], spacing = 0, cross_align = .Start)

	bc := new(View, context.temp_allocator)
	bc^ = body_content

	body_view := View_Scroll{
		id          = body_id,
		size        = body_viewport,
		content     = bc,
		offset_y    = scroll_y,
		wheel_step  = 40,
		track_color = th.color.surface,
		thumb_color = th.color.fg_muted,
		hover_thumb = hover_thumb,
		dragging    = st.pressed,
	}

	return col(header, body_view,
		width       = viewport.x,
		spacing     = 0,
		cross_align = .Start,
	)
}

// Menu_Item is one row in a menu_bar dropdown. `label` is the command
// name; `shortcut` is an optional accelerator rendered right-aligned in
// the row and registered via `shortcut` so the hotkey fires globally
// (skip with a zero-value Shortcut{}). `msg` is dispatched on click —
// and on accelerator — unless `disabled` is true. `separator = true`
// renders a horizontal divider instead of a row; all other fields are
// ignored in that case. `checked = true` prefixes the row with a ✓
// glyph for togglable items (View → Show Grid, etc.) — set this from
// your state in `view`, dispatch a flip-msg on click. The column is
// only reserved when at least one item in the active menu has
// `checked = true`, so menus without any checks lay out identically
// to before.
Menu_Item :: struct($Msg: typeid) {
	label:     string,
	shortcut:  Shortcut,
	msg:       Msg,
	separator: bool,
	disabled:  bool,
	checked:   bool,
}

// Menu_Entry is one top-level menu on a menu_bar — the label that sits
// on the bar (File, Edit, Help) plus the items its dropdown should
// list.
Menu_Entry :: struct($Msg: typeid) {
	label: string,
	items: []Menu_Item(Msg),
}

// menu_bar is the classic desktop top-level menu row: each `Menu_Entry`
// produces a clickable label on the bar, and clicking it opens a
// dropdown listing that entry's `Menu_Item`s. Hovering a different
// entry while any menu is open switches to that menu, mirroring native
// behavior. Escape, an outside click, or selecting an item dismisses.
//
//     Msg :: union { Msg_New, Msg_Save, Msg_Quit, Msg_About }
//
//     skald.menu_bar(ctx, []skald.Menu_Entry(Msg){
//         {"File", []skald.Menu_Item(Msg){
//             {label = "New",  shortcut = {.N, {.Ctrl}}, msg = Msg_New{}},
//             {label = "Save", shortcut = {.S, {.Ctrl}}, msg = Msg_Save{}},
//             {separator = true},
//             {label = "Quit", shortcut = {.Q, {.Ctrl}}, msg = Msg_Quit{}},
//         }},
//         {"Help", []skald.Menu_Item(Msg){
//             {label = "About", msg = Msg_About{}},
//         }},
//     })
//
// Every non-disabled item with a non-empty shortcut is registered via
// `shortcut` inside this builder, so its hotkey works regardless of
// whether the menu is open. Because shortcuts pre-empt widgets later
// in the tree, place `menu_bar` at the top of your `view` proc.
menu_bar :: proc(
	ctx:     ^Ctx($Msg),
	entries: []Menu_Entry(Msg),
	id:      Widget_ID = 0,
) -> View {
	th := ctx.theme
	id := widget_resolve_id(ctx, id)
	st := widget_get(ctx, id, .Menu_Bar)

	// Register accelerators up front so they fire even when the menu is
	// closed. Disabled items stay off the registry — a greyed-out menu
	// command's hotkey should feel inert too.
	for entry in entries {
		for item in entry.items {
			if item.separator || item.disabled { continue }
			shortcut(ctx, item.shortcut, item.msg)
		}
	}

	fs            := th.font.size_md
	fs_short      := th.font.size_sm
	TRIG_PAD_X    := th.spacing.md
	TRIG_GAP      := th.spacing.xs
	TRIG_H        := fs + 2*th.spacing.sm + 4
	ROW_H         := fs + 2*th.spacing.sm + 4
	SEP_H         := th.spacing.sm + 1
	ROW_PAD_X     := th.spacing.md
	SHORTCUT_GAP  := th.spacing.lg
	DROPDOWN_PAD  := f32(4)
	BORDER_W      := f32(1)
	MIN_DROPDOWN_W := f32(160)

	// Measure each trigger so we can hit-test this frame using last
	// frame's bar origin. Widths are stable while labels are, which is
	// essentially always in practice.
	trig_widths := make([]f32, len(entries), context.temp_allocator)
	for entry, i in entries {
		w, _ := measure_text(ctx.renderer, entry.label, fs)
		trig_widths[i] = w + 2*TRIG_PAD_X
	}

	bar_rect := st.last_rect
	trig_rects := make([]Rect, len(entries), context.temp_allocator)
	cur_x := bar_rect.x
	for _, i in entries {
		trig_rects[i] = Rect{cur_x, bar_rect.y, trig_widths[i], TRIG_H}
		cur_x += trig_widths[i]
		if i < len(entries) - 1 { cur_x += TRIG_GAP }
	}

	// cursor_pos stores the 1-based open-entry index (0 = closed) so
	// the zero-value state keeps the bar quiet on first frame.
	open_idx := st.cursor_pos - 1
	if open_idx < -1 || open_idx >= len(entries) { open_idx = -1 }

	// A modal dialog outranks any open menu. Force-close so a dropdown
	// can't peek out from behind a modal's card; accelerators still fire
	// at the global level because the shortcut registry runs above.
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 && !rect_contains_rect(mr, bar_rect) {
		open_idx = -1
	}

	mouse := ctx.input.mouse_pos
	hover_trig := -1
	for r, i in trig_rects {
		if rect_contains_point(r, mouse) { hover_trig = i; break }
	}

	// Hover-switch: once any menu is open, gliding across the bar
	// follows the cursor — matches every native menu since CUA.
	if open_idx >= 0 && hover_trig >= 0 && hover_trig != open_idx {
		open_idx = hover_trig
	}

	if ctx.input.mouse_pressed[.Left] && hover_trig >= 0 {
		if open_idx == hover_trig { open_idx = -1        }
		else                      { open_idx = hover_trig }
	}

	if open_idx >= 0 && .Escape in ctx.input.keys_pressed { open_idx = -1 }

	// Compute dropdown geometry so outside-click dismiss + input-swallow
	// have something to hit-test. Height sums per-item to keep separators
	// compact, width picks the widest label + accelerator pair.
	dropdown_rect: Rect
	dropdown_w: f32
	active_items: []Menu_Item(Msg)
	check_col_w := f32(0)
	if open_idx >= 0 {
		active_items = entries[open_idx].items
		max_label := f32(0)
		max_short := f32(0)
		has_checks := false
		for item in active_items {
			if item.separator { continue }
			if item.checked { has_checks = true }
			lw, _ := measure_text(ctx.renderer, item.label, fs)
			if lw > max_label { max_label = lw }
			if !shortcut_is_empty(item.shortcut) {
				sw, _ := measure_text(ctx.renderer,
					shortcut_format(item.shortcut), fs_short)
				if sw > max_short { max_short = sw }
			}
		}
		// Reserve a checkmark column only when this menu actually has a
		// checked item right now — keeps unchecked menus visually identical
		// to pre-1.2 builds. Width is the glyph + a spacing.sm gutter.
		if has_checks {
			cw, _ := measure_text(ctx.renderer, "✓", fs)
			check_col_w = cw + th.spacing.sm
		}
		inner_w := check_col_w + max_label + max_short
		if max_short > 0 { inner_w += SHORTCUT_GAP }
		dropdown_w = inner_w + 2*(DROPDOWN_PAD + BORDER_W + ROW_PAD_X)
		if dropdown_w < MIN_DROPDOWN_W { dropdown_w = MIN_DROPDOWN_W }

		dropdown_h := f32(2*(DROPDOWN_PAD + BORDER_W))
		for item in active_items {
			if item.separator { dropdown_h += SEP_H } else { dropdown_h += ROW_H }
		}

		anchor := trig_rects[open_idx]
		dropdown_rect = Rect{anchor.x, anchor.y + anchor.h, dropdown_w, dropdown_h}
	}

	// Outside-click dismiss: a press anywhere not in the bar or dropdown.
	if open_idx >= 0 && ctx.input.mouse_pressed[.Left] && hover_trig < 0 &&
	   !rect_contains_point(dropdown_rect, mouse) {
		open_idx = -1
	}

	// Release-on-item fires the command. Release is the standard click
	// convention in this codebase (matches select); mapping to press
	// would race with the same-frame open.
	item_hover := -1
	if open_idx >= 0 && rect_contains_point(dropdown_rect, mouse) {
		row_y := dropdown_rect.y + DROPDOWN_PAD + BORDER_W
		inner_x := dropdown_rect.x + DROPDOWN_PAD + BORDER_W
		inner_w := dropdown_rect.w - 2*(DROPDOWN_PAD + BORDER_W)
		for item, i in active_items {
			rh := SEP_H if item.separator else ROW_H
			r := Rect{inner_x, row_y, inner_w, rh}
			if !item.separator && !item.disabled &&
			   rect_contains_point(r, mouse) {
				item_hover = i
				if ctx.input.mouse_released[.Left] {
					send(ctx, item.msg)
					open_idx = -1
				}
			}
			row_y += rh
		}
	}

	// Swallow mouse edges inside the dropdown so siblings rendered
	// later don't also see them. Same convention as select / date_picker.
	if open_idx >= 0 && rect_contains_point(dropdown_rect, mouse) {
		ctx.input.mouse_pressed[.Left]  = false
		ctx.input.mouse_released[.Left] = false
	}
	if hover_trig >= 0 && ctx.input.mouse_pressed[.Left] {
		ctx.input.mouse_pressed[.Left] = false
	}

	st.cursor_pos = open_idx + 1

	anim_op: f32 = 0
	if open_idx >= 0 {
		anim_op = widget_anim_step(ctx, &st, 1, 0.12)
	} else {
		st.anim_t = 0
		st.anim_prev_ns = 0
	}

	widget_set(ctx, id, st)

	// Build trigger row views. Active entry uses the primary fill so
	// the connection to the dropdown reads clearly; hover uses the
	// elevated tint.
	trig_items := make([]View, len(entries), context.temp_allocator)
	for entry, i in entries {
		bg := Color{}
		fg := th.color.fg
		switch {
		case i == open_idx:
			bg = th.color.primary
			fg = th.color.on_primary
		case i == hover_trig:
			// selection is translucent primary — reads as a hover on any
			// parent bg (white body in light mode, charcoal in dark).
			bg = th.color.selection
		}
		trig_items[i] = col(
			text(entry.label, fg, fs),
			width       = trig_widths[i],
			height      = TRIG_H,
			main_align  = .Center,
			cross_align = .Center,
			bg          = bg,
			radius      = th.radius.sm,
		)
	}
	bar := row(..trig_items,
		spacing     = TRIG_GAP,
		cross_align = .Center,
	)

	// Wrap the bar in a zone so the renderer stamps the row's rect —
	// our positional entry rects are relative to bar_rect.x next frame.
	bar_child := new(View, context.temp_allocator)
	bar_child^ = bar
	bar_zone := View_Zone{id = id, child = bar_child}

	if open_idx < 0 { return bar_zone }

	// Build dropdown rows. Each non-separator row is a row( label,
	// flex(1, spacer), short ) so the accelerator pins to the right
	// edge regardless of label length.
	inner_w := dropdown_w - 2*(DROPDOWN_PAD + BORDER_W)
	rows := make([]View, len(active_items), context.temp_allocator)
	for item, i in active_items {
		if item.separator {
			rows[i] = col(
				rect({inner_w - 2*ROW_PAD_X, 1}, th.color.border),
				width       = inner_w,
				height      = SEP_H,
				main_align  = .Center,
				cross_align = .Center,
			)
			continue
		}

		row_bg := Color{}
		fg     := th.color.fg
		fg_sh  := th.color.fg_muted
		if item.disabled {
			fg    = th.color.fg_muted
			fg_sh = th.color.fg_muted
		} else if i == item_hover {
			row_bg = th.color.selection
		}

		short_str := shortcut_format(item.shortcut)
		short_view: View = spacer(0)
		if short_str != "" { short_view = text(short_str, fg_sh, fs_short) }

		// Check column: empty spacer when the menu has no checks at all
		// (check_col_w == 0), or for unchecked items in a menu that does.
		// Only the actually-checked rows paint the glyph.
		check_view: View = spacer(check_col_w)
		if item.checked {
			check_view = col(
				text("✓", fg, fs),
				width       = check_col_w,
				cross_align = .Start,
			)
		}

		rows[i] = row(
			spacer(ROW_PAD_X),
			check_view,
			text(item.label, fg, fs),
			flex(1, spacer(0)),
			short_view,
			spacer(ROW_PAD_X),
			width       = inner_w,
			height      = ROW_H,
			main_align  = .Start,
			cross_align = .Center,
			bg          = row_bg,
			radius      = th.radius.sm,
		)
	}

	inner := col(..rows,
		spacing     = 0,
		padding     = DROPDOWN_PAD,
		width       = dropdown_w - 2*BORDER_W,
		bg          = th.color.elevated,
		radius      = th.radius.sm,
		cross_align = .Start,
	)
	card := col(
		inner,
		padding     = BORDER_W,
		width       = dropdown_w,
		bg          = th.color.border,
		radius      = th.radius.sm,
		cross_align = .Start,
	)

	anchor := trig_rects[open_idx]
	return col(
		bar_zone,
		overlay(anchor, card, .Below, {0, 0}, anim_op),
	)
}

// Tree_Row is one flattened row in a `tree`. The *app* flattens its
// hierarchical data into rows before each frame — the widget only
// knows what to render, never the original tree shape. This gives
// callers full control over ordering, filtering, and lazy loading.
//
// `depth` is the zero-based nesting level (0 = root). `expandable` is
// true for parent nodes that could show children; `expanded` toggles
// the chevron glyph (▶ collapsed, ▼ expanded). `selected` paints the
// row with the selection highlight. `icon` is an optional single-glyph
// string rendered between the chevron and the label — pass "" to skip.
Tree_Row :: struct {
	depth:      int,
	label:      string,
	expandable: bool,
	expanded:   bool,
	selected:   bool,
	icon:       string,
}

// tree renders a flat slice of `Tree_Row`s as a collapsible outline.
// Click the chevron to fire `on_toggle(i)`; click the row body to fire
// `on_select(i)`. The widget never mutates anything — it just reports
// intents by index, same contract as table/virtual_list. The app owns
// expansion + selection state and re-flattens its tree each frame in
// response to the messages it receives.
//
//     type_node :: struct { label: string, children: []^type_node }
//
//     flatten :: proc(n: ^type_node, depth: int, rows: ^[dynamic]skald.Tree_Row,
//                     expanded: map[rawptr]bool, selected: rawptr) {
//         append(rows, skald.Tree_Row{
//             depth      = depth,
//             label      = n.label,
//             expandable = len(n.children) > 0,
//             expanded   = expanded[rawptr(n)],
//             selected   = rawptr(n) == selected,
//         })
//         if expanded[rawptr(n)] {
//             for c in n.children { flatten(c, depth + 1, rows, expanded, selected) }
//         }
//     }
//
//     skald.tree(ctx, state.rows, on_toggle, on_select, width = 260)
//
// Keyboard (when the tree has focus):
//   * Up/Down — move selection (fires on_select)
//   * Right   — expand if collapsed expandable row (fires on_toggle)
//   * Left    — collapse if expanded; else jump focus to parent row
//   * Enter/Space — toggle if expandable, else no-op
//
// Wrap in `scroll` when the row count can outgrow the viewport;
// `tree` itself doesn't virtualize because real-world outlines are
// bounded and virtualization would complicate per-row rect tracking
// without a meaningful payoff at typical sizes.
tree :: proc(
	ctx:        ^Ctx($Msg),
	rows:       []Tree_Row,
	on_toggle:  proc(row_idx: int) -> Msg,
	on_select:  proc(row_idx: int) -> Msg,
	id:         Widget_ID = 0,
	row_height: f32 = 0,
	indent:     f32 = 0,
	width:      f32 = 0,
) -> View {
	th := ctx.theme

	id := widget_resolve_id(ctx, id)
	widget_make_focusable(ctx, id)
	st := widget_get(ctx, id, .Tree)
	focused := widget_has_focus(ctx, id)

	fs       := th.font.size_md
	rh       := row_height; if rh <= 0 { rh = fs + 2*th.spacing.sm + 6 }
	ind      := indent;     if ind <= 0 { ind = th.spacing.lg }
	CHEV_W   := f32(16)
	PAD_X    := th.spacing.sm
	ICON_GAP := th.spacing.xs

	// tree_rect is the outer zone's rect from last frame; per-row rects
	// are stacked vertically from its origin. width is carried forward
	// to the rendered col so every row has a consistent hit target even
	// when labels vary in length.
	tree_rect := st.last_rect
	tree_w := width
	if tree_w <= 0 { tree_w = tree_rect.w }

	// Find the currently selected row (if any) so keyboard nav has a
	// starting point. cursor_pos doubles as a focus-cursor for a tree
	// that's focused but has no selected row yet; when the app hasn't
	// selected anything we walk from cursor_pos instead.
	sel_idx := -1
	for r, i in rows {
		if r.selected { sel_idx = i; break }
	}
	focus_idx := sel_idx
	if focus_idx < 0 && st.cursor_pos > 0 && st.cursor_pos-1 < len(rows) {
		focus_idx = st.cursor_pos - 1
	}

	mouse := ctx.input.mouse_pos

	// Mouse: press-on-chevron toggles, press-on-body selects + focuses.
	// Chevron has its own hit rect carved from the leading indent so a
	// user can expand without changing the selection.
	if ctx.input.mouse_pressed[.Left] &&
	   tree_rect.w > 0 && tree_rect.h > 0 &&
	   rect_contains_point(tree_rect, mouse) {
		rel_y := mouse.y - tree_rect.y
		i := int(rel_y / rh)
		if i >= 0 && i < len(rows) {
			r := rows[i]
			chev_x := tree_rect.x + PAD_X + f32(r.depth)*ind
			chev_rect := Rect{chev_x, tree_rect.y + f32(i)*rh, CHEV_W, rh}
			if r.expandable && rect_contains_point(chev_rect, mouse) {
				send(ctx, on_toggle(i))
			} else {
				send(ctx, on_select(i))
				focus_idx = i
				widget_focus(ctx, id)
				focused = true
			}
		}
	}

	// Keyboard nav. Up/Down wraps through the visible rows; Right/Left
	// collapse-or-jump. The "jump to parent" case walks backwards until
	// a row at depth-1 — `rows` is linear, so this is O(n) in the worst
	// case but tiny in practice.
	if focused && len(rows) > 0 {
		keys := ctx.input.keys_pressed
		if focus_idx < 0 { focus_idx = 0 }
		if .Down in keys && focus_idx < len(rows) - 1 {
			focus_idx += 1
			send(ctx, on_select(focus_idx))
		}
		if .Up in keys && focus_idx > 0 {
			focus_idx -= 1
			send(ctx, on_select(focus_idx))
		}
		if .Home in keys {
			focus_idx = 0
			send(ctx, on_select(focus_idx))
		}
		if .End in keys {
			focus_idx = len(rows) - 1
			send(ctx, on_select(focus_idx))
		}
		if .Right in keys && focus_idx >= 0 && focus_idx < len(rows) {
			r := rows[focus_idx]
			if r.expandable && !r.expanded {
				send(ctx, on_toggle(focus_idx))
			}
		}
		if .Left in keys && focus_idx >= 0 && focus_idx < len(rows) {
			r := rows[focus_idx]
			if r.expandable && r.expanded {
				send(ctx, on_toggle(focus_idx))
			} else if r.depth > 0 {
				// Walk back to the first row at shallower depth.
				for j := focus_idx - 1; j >= 0; j -= 1 {
					if rows[j].depth < r.depth {
						focus_idx = j
						send(ctx, on_select(focus_idx))
						break
					}
				}
			}
		}
		if (.Enter in keys || .Space in keys) &&
		   focus_idx >= 0 && focus_idx < len(rows) &&
		   rows[focus_idx].expandable {
			send(ctx, on_toggle(focus_idx))
		}
	}

	st.cursor_pos = focus_idx + 1
	widget_set(ctx, id, st)

	// Build row views.
	row_views := make([]View, len(rows), context.temp_allocator)
	for r, i in rows {
		chevron := "  "
		if r.expandable { chevron = "▶" if !r.expanded else "▼" }

		// Selection priority mirrors table's:
		//   selected + tree focused → primary fill
		//   selected + tree blurred → subtle primary tint
		//   focus cursor, unselected, tree focused → selection tint
		//   else → transparent
		// In dark theme `elevated` alone is enough distinction, but
		// in light theme surface == elevated so we fall back to a
		// faint primary mix (matching the table's convention).
		bg   := Color{}
		fg   := th.color.fg
		fg_c := th.color.fg_muted // chevron + icon default
		switch {
		case r.selected && focused:
			bg   = th.color.primary
			fg   = th.color.on_primary
			fg_c = th.color.on_primary
		case r.selected:
			bg = selected_inactive_bg_for(th^)
		case focused && i == focus_idx:
			bg = th.color.selection
		}

		children: [dynamic]View
		children.allocator = context.temp_allocator
		append(&children, spacer(PAD_X + f32(r.depth)*ind))
		append(&children,
			col(
				text(chevron, fg_c, fs),
				width       = CHEV_W,
				height      = rh,
				main_align  = .Center,
				cross_align = .Center,
			),
		)
		if r.icon != "" {
			append(&children, spacer(ICON_GAP))
			append(&children, text(r.icon, fg_c, fs))
		}
		append(&children, spacer(ICON_GAP))
		append(&children, text(r.label, fg, fs))
		append(&children, flex(1, spacer(0)))

		row_views[i] = row(..children[:],
			width       = tree_w,
			height      = rh,
			spacing     = 0,
			cross_align = .Center,
			bg          = bg,
			radius      = th.radius.sm,
		)
	}

	content := col(..row_views,
		width       = tree_w,
		spacing     = 0,
		cross_align = .Start,
	)

	c := new(View, context.temp_allocator)
	c^ = content
	return View_Zone{id = id, child = c}
}
