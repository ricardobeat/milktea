module glaze;

import std::core::dstring;

// Clip a multi-line string to max_lines visible rows.
// If the string has more than max_lines lines, the bottom max_lines lines are shown.
fn String clip_lines(String input, int max_lines) {
	if (max_lines <= 0) return "";

	// Count newlines and find line starts
	int total_lines = 1;
	for (sz i = 0; i < input.len; i++) {
		if (input[i] == '\n') total_lines++;
	}

	if (total_lines <= max_lines) return input.tcopy();

	// Skip lines from the top
	int skip = total_lines - max_lines;
	sz pos   = 0;
	for (int l = 0; l < skip && pos < input.len; l++) {
		while (pos < input.len && input[pos] != '\n') pos++;
		if (pos < input.len) pos++; // skip the newline itself
	}

	return input[pos..].tcopy();
}