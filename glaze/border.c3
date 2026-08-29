module glaze;

import std::core::dstring;

struct Border {
	String top;
	String bottom;
	String left;
	String right;
	String top_left;
	String top_right;
	String bottom_left;
	String bottom_right;
}

// Border presets. These are plain values, so they can be named directly in a
// style literal: { .border = glaze::ROUNDED }. A custom shape fills in the
// eight strings itself.
const Border NONE = { };

const Border NORMAL = {
	.top = "─",
	.bottom = "─",
	.left = "│",
	.right = "│",
	.top_left = "┌",
	.top_right = "┐",
	.bottom_left = "└",
	.bottom_right = "┘"
};

const Border ROUNDED = {
	.top = "─",
	.bottom = "─",
	.left = "│",
	.right = "│",
	.top_left = "╭",
	.top_right = "╮",
	.bottom_left = "╰",
	.bottom_right = "╯"
};

// HIDDEN occupies the same space as ROUNDED but renders with spaces, so
// content does not shift when a border is switched on and off with focus.
const Border HIDDEN = {
	.top = " ",
	.bottom = " ",
	.left = " ",
	.right = " ",
	.top_left = " ",
	.top_right = " ",
	.bottom_left = " ",
	.bottom_right = " "
};

const Border THICK = {
	.top = "━",
	.bottom = "━",
	.left = "┃",
	.right = "┃",
	.top_left = "┏",
	.top_right = "┓",
	.bottom_left = "┗",
	.bottom_right = "┛"
};

const Border DOUBLE = {
	.top = "═",
	.bottom = "═",
	.left = "║",
	.right = "║",
	.top_left = "╔",
	.top_right = "╗",
	.bottom_left = "╚",
	.bottom_right = "╝"
};

// Wrap input lines (split by '\n') with this border.
// If border_fg is not NONE, border characters are wrapped in SGR.
fn String Border.wrap(self, String input) {
	return self.wrap_with_color(input, { .kind = ColorKind.NONE });
}

fn String Border.wrap_with_color(self, String input, Color border_fg, Color border_bg = { .kind = ColorKind.NONE }) {
	bool is_empty = self.top.len == 0 && self.bottom.len == 0 && self.left.len == 0 && self.right.len == 0
		&& self.top_left.len == 0
		&& self.top_right.len == 0
		&& self.bottom_left.len == 0
		&& self.bottom_right.len == 0;
	if (is_empty) return input.tcopy();

	bool color_border = border_fg.kind != ColorKind.NONE || border_bg.kind != ColorKind.NONE;
	DString sgr_open  = dstring::temp();
	String sgr_close  = "\x1b[0m";
	if (color_border) {
		sgr_open.append_string("\x1b[0");
		if (border_fg.kind != ColorKind.NONE) {
			sgr_open.append_char(';');
			border_fg.write_sgr_params(&sgr_open, true);
		}
		if (border_bg.kind != ColorKind.NONE) {
			sgr_open.append_char(';');
			border_bg.write_sgr_params(&sgr_open, false);
		}
		sgr_open.append_char('m');
	}
	String sgr_open_str = sgr_open.str_view();

	// Find max line width (visual).
	sz max_width  = 0;
	sz line_start = 0;
	for (sz i = 0; i <= input.len; i++) {
		if (i == input.len || input[i] == '\n') {
			String line = input[line_start:i - line_start];
			sz w        = (sz)string_width(line);
			if (w > max_width) max_width = w;
			line_start = i + 1;
			if (i == input.len) break;
		}
	}

	DString out = dstring::temp();

	// Top border row.
	if (color_border) out.append_string(sgr_open_str);
	out.append_string(self.top_left);
	for (sz i = 0; i < max_width; i++) out.append_string(self.top);
	out.append_string(self.top_right);
	if (color_border) out.append_string(sgr_close);
	out.append_char('\n');

	// Body lines.
	line_start = 0;
	for (sz i = 0; i <= input.len; i++) {
		if (i == input.len || input[i] == '\n') {
			String line = input[line_start:i - line_start];
			if (color_border) out.append_string(sgr_open_str);
			out.append_string(self.left);
			if (color_border) out.append_string(sgr_close);
			out.append_string(line);
			for (sz p = (sz)string_width(line); p < max_width; p++) out.append_char(' ');
			if (color_border) out.append_string(sgr_open_str);
			out.append_string(self.right);
			if (color_border) out.append_string(sgr_close);
			out.append_char('\n');
			line_start = i + 1;
			if (i == input.len) break;
		}
	}

	// Bottom border row.
	if (color_border) out.append_string(sgr_open_str);
	out.append_string(self.bottom_left);
	for (sz i = 0; i < max_width; i++) out.append_string(self.bottom);
	out.append_string(self.bottom_right);
	if (color_border) out.append_string(sgr_close);

	return out.copy_str(tmem);
}