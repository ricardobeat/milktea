module lipgloss;

import std::core::dstring;

// Render a horizontal progress bar.
// width:       total width in cells (including brackets)
// percentage:  0-100
// fill_char:   string for the filled portion (typically 1 display-width char)
// empty_char:  string for the empty portion
// fill_color:  color for the filled portion (NONE = no color)
// empty_color: color for the empty portion (NONE = no color)
fn String progress_bar(
	int width,
	int percentage,
	String fill_char,
	String empty_char,
	Color fill_color,
	Color empty_color
) {
	if (width < 3) width = 3;
	if (percentage < 0) percentage = 0;
	if (percentage > 100) percentage = 100;

	int inner  = width - 2; // minus [ and ]
	int filled = (inner * percentage + 50) / 100;
	if (filled > inner) filled = inner;

	DString out = dstring::temp();
	out.append_char('[');

	// Filled portion
	if (fill_color.kind != ColorKind.NONE) {
		out.append_string("\x1b[");
		fill_color.write_sgr_params(&out, true);
		out.append_string("m");
	}
	for (int i = 0; i < filled; i++) out.append_string(fill_char);
	if (fill_color.kind != ColorKind.NONE) out.append_string("\x1b[0m");

	// Empty portion
	if (empty_color.kind != ColorKind.NONE) {
		out.append_string("\x1b[");
		empty_color.write_sgr_params(&out, true);
		out.append_string("m");
	}
	for (int i = filled; i < inner; i++) out.append_string(empty_char);
	if (empty_color.kind != ColorKind.NONE) out.append_string("\x1b[0m");

	out.append_char(']');
	return out.str_view();
}