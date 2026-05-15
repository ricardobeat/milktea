module lipgloss;

import std::core::dstring;

// ============================================================
// Position — alignment constants for layout functions.
// ============================================================

enum Position : char {
	TOP,     // vertical: top
	CENTER,  // horizontal or vertical: center
	BOTTOM,  // vertical: bottom
	LEFT,    // horizontal: left
	RIGHT,   // horizontal: right
}

// ============================================================
// Line splitting helper
// ============================================================

const sz MAX_LAYOUT_LINES = 256;

struct LineSet {
	String[MAX_LAYOUT_LINES] lines;
	sz count;
}

fn LineSet split_lines(String s) @local {
	LineSet ls;
	sz start = 0;
	for (sz i = 0; i <= s.len; i++) {
		if (i == s.len || s[i] == '\n') {
			if (ls.count < MAX_LAYOUT_LINES) {
				ls.lines[ls.count] = s[start:i - start];
				ls.count++;
			}
			start = i + 1;
			if (i == s.len) break;
		}
	}
	return ls;
}

fn int max_line_width(LineSet* ls) @local {
	int max_w = 0;
	for (sz i = 0; i < ls.count; i++) {
		int w = string_width(ls.lines[i]);
		if (w > max_w) max_w = w;
	}
	return max_w;
}

// ============================================================
// join_horizontal — join two strings side by line.
// ============================================================

fn String join_horizontal(String left, String right, int gap) {
	return join_horizontal_pos(Position.TOP, left, right, gap);
}

// join_horizontal_pos joins two strings side by side with vertical alignment.
fn String join_horizontal_pos(Position pos, String left, String right, int gap) {
	LineSet ll = split_lines(left);
	LineSet rl = split_lines(right);

	int max_left_w = max_line_width(&ll);
	int total = (int)ll.count;
	if ((int)rl.count > total) total = (int)rl.count;

	// Compute vertical offset for alignment
	int left_pad = 0;
	int right_pad = 0;
	if (pos == Position.CENTER) {
		left_pad = (total - (int)ll.count) / 2;
		right_pad = (total - (int)rl.count) / 2;
	} else if (pos == Position.BOTTOM) {
		left_pad = total - (int)ll.count;
		right_pad = total - (int)rl.count;
	}

	DString out = dstring::temp();
	for (int i = 0; i < total; i++) {
		// Left side
		int li = i - left_pad;
		if (li >= 0 && li < (int)ll.count) {
			String l = ll.lines[li];
			int l_w = string_width(l);
			out.append_string(l);
			for (int p = l_w; p < max_left_w + gap; p++) out.append_char(' ');
		} else {
			for (int p = 0; p < max_left_w + gap; p++) out.append_char(' ');
		}

		// Right side
		int ri = i - right_pad;
		if (ri >= 0 && ri < (int)rl.count) {
			out.append_string(rl.lines[ri]);
		}

		if (i < total - 1) out.append_char('\n');
	}
	return out.str_view();
}

// ============================================================
// join_horizontal_arr — join multiple strings side by side.
// ============================================================

fn String join_horizontal_arr(Position pos, String[] views, int gap) {
	if (views.len == 0) return "";
	if (views.len == 1) return views[0];

	String result = views[0];
	for (sz i = 1; i < views.len; i++) {
		result = join_horizontal_pos(pos, result, views[i], gap);
	}
	return result;
}

// ============================================================
// join_vertical — join strings stacked vertically.
// ============================================================

fn String join_vertical(Position pos, String top, String bottom) {
	return join_vertical_pos(pos, top, bottom);
}

fn String join_vertical_pos(Position pos, String top, String bottom) {
	LineSet tl = split_lines(top);
	LineSet bl = split_lines(bottom);

	int max_top_w = max_line_width(&tl);
	int max_bot_w = max_line_width(&bl);
	int max_w = max_top_w;
	if (max_bot_w > max_w) max_w = max_bot_w;

	DString out = dstring::temp();

	// Top block
	for (sz i = 0; i < tl.count; i++) {
		String line = tl.lines[i];
		int w = string_width(line);
		if (pos == Position.CENTER) {
			int pad = (max_w - w) / 2;
			for (int p = 0; p < pad; p++) out.append_char(' ');
		} else if (pos == Position.RIGHT) {
			int pad = max_w - w;
			for (int p = 0; p < pad; p++) out.append_char(' ');
		}
		out.append_string(line);
		if (pos != Position.RIGHT) {
			for (int p = w; p < max_w; p++) out.append_char(' ');
		}
		out.append_char('\n');
	}

	// Bottom block
	for (sz i = 0; i < bl.count; i++) {
		String line = bl.lines[i];
		int w = string_width(line);
		if (pos == Position.CENTER) {
			int pad = (max_w - w) / 2;
			for (int p = 0; p < pad; p++) out.append_char(' ');
		} else if (pos == Position.RIGHT) {
			int pad = max_w - w;
			for (int p = 0; p < pad; p++) out.append_char(' ');
		}
		out.append_string(line);
		if (pos != Position.RIGHT) {
			for (int p = w; p < max_w; p++) out.append_char(' ');
		}
		if (i < bl.count - 1) out.append_char('\n');
	}

	return out.str_view();
}

// join_vertical_arr joins multiple strings stacked vertically.
fn String join_vertical_arr(Position pos, String[] views) {
	if (views.len == 0) return "";
	if (views.len == 1) return views[0];

	String result = views[0];
	for (sz i = 1; i < views.len; i++) {
		result = join_vertical_pos(pos, result, views[i]);
	}
	return result;
}

// ============================================================
// place — center content in a box of given width and height.
// ============================================================

fn String place(int width, int height, String content) {
	return place_pos(width, height, Position.CENTER, Position.CENTER, content);
}

// place_pos places content at the given horizontal and vertical positions
// within a box of the specified width and height.
fn String place_pos(int width, int height, Position hpos, Position vpos, String content) {
	LineSet ls = split_lines(content);
	int content_w = max_line_width(&ls);
	int content_h = (int)ls.count;

	// Vertical offset
	int pad_top = 0;
	if (vpos == Position.CENTER) {
		pad_top = (height - content_h) / 2;
	} else if (vpos == Position.BOTTOM) {
		pad_top = height - content_h;
	}
	if (pad_top < 0) pad_top = 0;

	DString out = dstring::temp();

	// Top padding
	for (int i = 0; i < pad_top; i++) {
		for (int j = 0; j < width; j++) out.append_char(' ');
		out.append_char('\n');
	}

	// Content lines
	for (sz i = 0; i < ls.count; i++) {
		String line = ls.lines[i];
		int w = string_width(line);

		// Horizontal offset
		int pad_left = 0;
		if (hpos == Position.CENTER) {
			pad_left = (width - w) / 2;
		} else if (hpos == Position.RIGHT) {
			pad_left = width - w;
		}
		if (pad_left < 0) pad_left = 0;

		for (int j = 0; j < pad_left; j++) out.append_char(' ');
		out.append_string(line);
		for (int j = w + pad_left; j < width; j++) out.append_char(' ');
		if (i < ls.count - 1) out.append_char('\n');
	}

	// Bottom padding
	for (int i = pad_top + content_h; i < height; i++) {
		out.append_char('\n');
		for (int j = 0; j < width; j++) out.append_char(' ');
	}

	return out.str_view();
}

// ============================================================
// place_horizontal — place content at a horizontal position within width.
// ============================================================

fn String place_horizontal(int width, Position pos, String content) {
	LineSet ls = split_lines(content);
	DString out = dstring::temp();

	for (sz i = 0; i < ls.count; i++) {
		String line = ls.lines[i];
		int w = string_width(line);

		int pad_left = 0;
		if (pos == Position.CENTER) {
			pad_left = (width - w) / 2;
		} else if (pos == Position.RIGHT) {
			pad_left = width - w;
		}
		if (pad_left < 0) pad_left = 0;

		for (int j = 0; j < pad_left; j++) out.append_char(' ');
		out.append_string(line);
		for (int j = w + pad_left; j < width; j++) out.append_char(' ');
		if (i < ls.count - 1) out.append_char('\n');
	}

	return out.str_view();
}

// ============================================================
// place_vertical — place content at a vertical position within height.
// ============================================================

fn String place_vertical(int height, Position pos, String content) {
	LineSet ls = split_lines(content);
	int content_h = (int)ls.count;

	int pad_top = 0;
	if (pos == Position.CENTER) {
		pad_top = (height - content_h) / 2;
	} else if (pos == Position.BOTTOM) {
		pad_top = height - content_h;
	}
	if (pad_top < 0) pad_top = 0;

	DString out = dstring::temp();

	for (int i = 0; i < pad_top; i++) {
		out.append_char('\n');
	}
	for (sz i = 0; i < ls.count; i++) {
		out.append_string(ls.lines[i]);
		if (i < ls.count - 1) out.append_char('\n');
	}
	for (int i = pad_top + content_h; i < height; i++) {
		out.append_char('\n');
	}

	return out.str_view();
}
