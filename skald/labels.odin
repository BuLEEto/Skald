package skald

// Labels is the Skald-side bag of user-visible strings the framework
// itself produces (placeholders, date/time helpers). App-supplied text
// — button labels, dialog titles, form headings — is the caller's
// concern and lives in their own translation flow.
//
// Passed through `Ctx.labels` the same way `Theme` is threaded. Apps
// construct a Labels by calling `labels_en()` (the default) and either
// using it as-is or copying-and-overriding fields for other locales.
// Themes and labels compose: a single app can have theme_dark + Spanish
// labels or theme_light + Japanese labels interchangeably.
//
//     labels := skald.labels_en()
//     labels.select_placeholder       = "Seleccionar…"
//     labels.date_picker_placeholder  = "Elegir fecha"
//     labels.month_names              = {
//         "Enero", "Febrero", "Marzo", "Abril",
//         "Mayo",  "Junio",   "Julio", "Agosto",
//         "Septiembre", "Octubre", "Noviembre", "Diciembre",
//     }
//     skald.run(skald.App(State, Msg){..., labels = labels, ...})
//
// Out of scope for 1.0 (separate concerns, deferred):
//   * RTL layout mirroring — affects widget geometry, not strings.
//   * Font coverage for CJK / Arabic / Devanagari — a fallback-font
//     system, not an i18n strings issue.
//   * Pluralisation, number formatting, currency — app concern via
//     `core:fmt` and any library the app wants to pull in.
Labels :: struct {
	// Placeholder strings the framework emits when the caller doesn't
	// supply one. `search_placeholder` is used by `search_field` as
	// the default placeholder. The other three default the
	// corresponding picker's trigger text when the widget has no
	// value yet.
	search_placeholder:      string,
	select_placeholder:      string,
	date_picker_placeholder: string,
	time_picker_placeholder: string,

	// Date helpers: month names (1-indexed — [0] is January) and
	// short weekday labels (Sunday-first: [0] = Sunday).
	// `weekday_short` is rendered directly in the date_picker's
	// weekday header row; `month_names` appears in the header's
	// "Month YYYY" title and in `date_format_long`'s output.
	month_names:             [12]string,
	weekday_short:           [7]string,

	// AM / PM suffix used by `time_format_12h`. The 24-hour formatter
	// doesn't consult these.
	am: string,
	pm: string,

	// Picker popover footer buttons. `today` jumps the date_picker to
	// the current date; `now` jumps the time_picker to the wall clock;
	// `clear` zeros the value (picker reverts to its placeholder).
	today: string,
	now:   string,
	clear: string,
}

// labels_en returns the default English labels. Matches what the
// framework used to hard-code, so a Skald app that leaves `App.labels`
// unset behaves identically to pre-i18n builds.
labels_en :: proc() -> Labels {
	return Labels{
		search_placeholder      = "Search",
		select_placeholder      = "Select…",
		date_picker_placeholder = "Select date",
		time_picker_placeholder = "Select time",
		month_names = [12]string{
			"January",   "February", "March",     "April",
			"May",       "June",     "July",      "August",
			"September", "October",  "November",  "December",
		},
		weekday_short = [7]string{"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"},
		am    = "AM",
		pm    = "PM",
		today = "Today",
		now   = "Now",
		clear = "Clear",
	}
}
