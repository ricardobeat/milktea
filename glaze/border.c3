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

// NORMAL and SQUARE draw the same box: rounded corners are the ones that
// differ (see ROUNDED), so there is one set of square glyphs behind both
// names.
const Border SQUARE = NORMAL;

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

// wrap_with_color is wrap with colors: border_fg for the sides, corner_fg
// for the corners (border_fg when unset) and border_bg behind both. With
// border_to set, the border's color runs from border_fg on the top row to
// border_to on the bottom one, blended in LUV; a corner_fg of its own stays
// fixed.
fn String Border.wrap_with_color(self, String input, Color border_fg, Color border_bg = { .kind = ColorKind.NONE }, Color corner_fg = { .kind = ColorKind.NONE }, Color border_to = { .kind = ColorKind.NONE }) {
	bool is_empty = self.top.len == 0 && self.bottom.len == 0 && self.left.len == 0 && self.right.len == 0
		&& self.top_left.len == 0
		&& self.top_right.len == 0
		&& self.bottom_left.len == 0
		&& self.bottom_right.len == 0;
	if (is_empty) return input.tcopy();

	bool graded = border_to.kind == ColorKind.TRUECOLOR && border_fg.kind == ColorKind.TRUECOLOR;

	// Find max line width (visual) and count lines.
	sz max_width  = 0;
	sz line_count = 0;
	sz line_start = 0;
	for (sz i = 0; i <= input.len; i++) {
		if (i == input.len || input[i] == '\n') {
			String line = input[line_start:i - line_start];
			sz w        = (sz)string_width(line);
			if (w > max_width) max_width = w;
			line_count++;
			line_start = i + 1;
			if (i == input.len) break;
		}
	}

	DString out = dstring::temp();

	// A side with no characters draws no row at all. A partial border — say a
	// half-block shadow down the right edge and along the bottom — would
	// otherwise cost a blank line where its missing top should be.
	bool has_top = self.top.len > 0 || self.top_left.len > 0 || self.top_right.len > 0;
	bool has_bottom = self.bottom.len > 0 || self.bottom_left.len > 0 || self.bottom_right.len > 0;
	sz rows = line_count + (has_top ? 1 : 0) + (has_bottom ? 1 : 0);
	sz row = 0;

	String sgr_close = "\x1b[0m";
	String side;
	String corner;

	// Top border row.
	if (has_top) {
		side_sgrs(border_fg, border_to, graded, corner_fg, border_bg, row++, rows, &side, &corner);
		out.append_string(corner);
		out.append_string(self.top_left);
		if (corner.len > 0) out.append_string(sgr_close);
		out.append_string(side);
		for (sz i = 0; i < max_width; i++) out.append_string(self.top);
		if (side.len > 0) out.append_string(sgr_close);
		out.append_string(corner);
		out.append_string(self.top_right);
		if (corner.len > 0) out.append_string(sgr_close);
		out.append_char('\n');
	}

	// Body lines.
	line_start = 0;
	for (sz i = 0; i <= input.len; i++) {
		if (i == input.len || input[i] == '\n') {
			String line = input[line_start:i - line_start];
			side_sgrs(border_fg, border_to, graded, corner_fg, border_bg, row++, rows, &side, &corner);
			out.append_string(side);
			out.append_string(self.left);
			if (side.len > 0) out.append_string(sgr_close);
			out.append_string(line);
			for (sz p = (sz)string_width(line); p < max_width; p++) out.append_char(' ');
			out.append_string(side);
			out.append_string(self.right);
			if (side.len > 0) out.append_string(sgr_close);
			out.append_char('\n');
			line_start = i + 1;
			if (i == input.len) break;
		}
	}

	// Bottom border row.
	if (has_bottom) {
		side_sgrs(border_fg, border_to, graded, corner_fg, border_bg, row++, rows, &side, &corner);
		out.append_string(corner);
		out.append_string(self.bottom_left);
		if (corner.len > 0) out.append_string(sgr_close);
		out.append_string(side);
		for (sz i = 0; i < max_width; i++) out.append_string(self.bottom);
		if (side.len > 0) out.append_string(sgr_close);
		out.append_string(corner);
		out.append_string(self.bottom_right);
		if (corner.len > 0) out.append_string(sgr_close);
	} else {
		// The last body line left a trailing newline that nothing follows.
		out.chop(out.len() - 1);
	}

	return out.copy_str(tmem);
}

// side_sgrs sets the escapes that open a border's sides and corners on one
// row: empty when that part has no color.
fn void side_sgrs(Color from, Color to, bool graded, Color corner_fg, Color bg, sz row, sz rows,
		String* side, String* corner) @local {
	Color fg = from;
	if (graded) fg = blend_luv(from, to, rows > 1 ? (double)row / (double)(rows - 1) : 0.0);
	*side = border_sgr(fg, bg);
	*corner = border_sgr(corner_fg.kind != ColorKind.NONE ? corner_fg : fg, bg);
}

fn String border_sgr(Color fg, Color bg) @local {
	if (fg.kind == ColorKind.NONE && bg.kind == ColorKind.NONE) return "";
	DString s = dstring::temp();
	s.append_string("\x1b[0");
	if (fg.kind != ColorKind.NONE) {
		s.append_char(';');
		fg.write_sgr_params(&s, true);
	}
	if (bg.kind != ColorKind.NONE) {
		s.append_char(';');
		bg.write_sgr_params(&s, false);
	}
	s.append_char('m');
	return s.str_view();
}