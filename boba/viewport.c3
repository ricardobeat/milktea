module boba;

import milktea;
import glaze;
import std::core::dstring;
import std::core::mem;
import std::collections::list;

struct Viewport {
	int offset;
	int width;
	int height;
	int total_lines;
	std::collections::list::List{String} lines;
	bool mouse_wheel_enabled;
	bool show_scrollbar;
	glaze::Style content_style;
	glaze::Style track_style;
	glaze::Style thumb_style;

	// Selection state
	bool sel_active;
	int sel_start_row;
	int sel_start_col;
	int sel_end_row;
	int sel_end_col;
	bool has_selection;
	glaze::Style selection_style;
}

fn Viewport new_viewport(int width, int height) {
	Viewport v = { };
	v.width = width;
	v.height = height;
	v.lines.init(mem);
	v.content_style = glaze::style().foreground(glaze::color_hex("#cccccc"));
	v.track_style = glaze::style().foreground(glaze::color_hex("#333344"));
	v.thumb_style = glaze::style().foreground(glaze::color_hex("#888888"));
	// Default selection style: inverted (white bg, black fg)
	v.selection_style = glaze::style().foreground(glaze::color_hex("#000000")).background(glaze::color_hex("#ffffff"));
	v.sel_end_row = -1;
	v.sel_end_col = -1;
	return v;
}

// with_mouse_wheel returns a copy with mouse wheel scrolling enabled.
fn Viewport Viewport.with_mouse_wheel(self) {
	Viewport v = self;
	v.mouse_wheel_enabled = true;
	return v;
}

fn void Viewport.set_content(&self, int total_lines) {
	self.total_lines = total_lines;
	int max_offset = self.total_lines - self.height;
	if (max_offset < 0) max_offset = 0;
	if (self.offset > max_offset) self.offset = max_offset;
}

fn void Viewport.add_line(&self, String line) {
	if (!self.lines.is_initialized()) self.lines.init(mem);
	self.lines.push(line);
	self.total_lines = (int)self.lines.len();
}

fn void Viewport.set_lines(&self, String[] src) {
	if (!self.lines.is_initialized()) self.lines.init(mem);
	self.lines.clear();
	self.lines.push_all(src);
	self.total_lines = (int)self.lines.len();
}

// free releases the backing line storage. Call when the Viewport itself is
// being discarded (not needed for the common case of a long-lived field).
fn void Viewport.free(&self) {
	if (self.lines.is_initialized()) self.lines.free();
}

// scroll_up scrolls up by one line.
fn void Viewport.scroll_up(&self) {
	if (self.offset > 0) self.offset--;
}

// scroll_down scrolls down by one line.
fn void Viewport.scroll_down(&self) {
	int max_offset = self.total_lines - self.height;
	if (max_offset < 0) max_offset = 0;
	if (self.offset < max_offset) self.offset++;
}

// page_up scrolls up by one page.
fn void Viewport.page_up(&self) {
	self.offset -= self.height;
	if (self.offset < 0) self.offset = 0;
}

// page_down scrolls down by one page.
fn void Viewport.page_down(&self) {
	self.offset += self.height;
	int max_offset = self.total_lines - self.height;
	if (max_offset < 0) max_offset = 0;
	if (self.offset > max_offset) self.offset = max_offset;
}

// scroll_to_top scrolls to the beginning.
fn void Viewport.scroll_to_top(&self) {
	self.offset = 0;
}

// scroll_to_bottom scrolls to the end.
fn void Viewport.scroll_to_bottom(&self) {
	int max_offset = self.total_lines - self.height;
	if (max_offset < 0) max_offset = 0;
	self.offset = max_offset;
}

// clear_selection clears any active or completed selection.
fn void Viewport.clear_selection(&self) {
	self.sel_active = false;
	self.has_selection = false;
	self.sel_start_row = -1;
	self.sel_start_col = -1;
	self.sel_end_row = -1;
	self.sel_end_col = -1;
}

// handle_key processes common scroll keybindings.
// Returns true if the key was consumed.
fn bool Viewport.handle_key(&self, milktea::KeyMsg k) {
	self.clear_selection();
	switch (k.code) {
		case milktea::KeyCode.UP:
			self.scroll_up();
			return true;
		case milktea::KeyCode.DOWN:
			self.scroll_down();
			return true;
		case milktea::KeyCode.PAGE_UP:
			self.page_up();
			return true;
		case milktea::KeyCode.PAGE_DOWN:
			self.page_down();
			return true;
		case milktea::KeyCode.HOME:
			self.scroll_to_top();
			return true;
		case milktea::KeyCode.END:
			self.scroll_to_bottom();
			return true;
		default:
			return false;
	}
}

// view_line_range returns the visible line indices [start, end).
fn int Viewport.view_line_start(&self) {
	return self.offset;
}

fn int Viewport.view_line_end(&self) {
	int end = self.offset + self.height;
	if (end > self.total_lines) end = self.total_lines;
	return end;
}

// handle_mouse_msg processes mouse events: scroll wheel and text selection.
fn bool Viewport.handle_mouse_msg(&self, milktea::MouseMsg msg) {
	// Scrollbar occupies the rightmost 3 chars; don't select if clicking there
	bool has_bar = self.show_scrollbar && self.total_lines > self.height;
	int text_w = self.width - (has_bar ? 3 : 0);
	if (text_w < 1) text_w = 1;

	bool is_scrollbar_area = has_bar && msg.col >= text_w;

	// Wheel scroll (even over scrollbar)
	if (msg.button == milktea::MouseButton.MOUSE_WHEEL_UP) {
		self.scroll_up();
		return true;
	}
	if (msg.button == milktea::MouseButton.MOUSE_WHEEL_DOWN) {
		self.scroll_down();
		return true;
	}

	// Text selection with left button (not over scrollbar)
	if (!is_scrollbar_area && msg.button == milktea::MouseButton.MOUSE_LEFT) {
		// Convert screen-relative (msg.row, msg.col) to content-relative
		int content_row = self.offset + msg.row;
		int content_col = msg.col;

		if (msg.action == milktea::MouseAction.MOUSE_PRESS) {
			// Start selection anchor
			self.sel_active = true;
			self.has_selection = false;
			self.sel_start_row = content_row;
			self.sel_start_col = content_col;
			self.sel_end_row = content_row;
			self.sel_end_col = content_col;
			return true;
		}

		if (msg.action == milktea::MouseAction.MOUSE_MOTION && self.sel_active) {
			// Update selection endpoint during drag
			self.sel_end_row = content_row;
			self.sel_end_col = content_col;
			self.has_selection = true;
			return true;
		}

		if (msg.action == milktea::MouseAction.MOUSE_RELEASE && self.sel_active) {
			// Finalize selection
			self.sel_end_row = content_row;
			self.sel_end_col = content_col;
			self.sel_active = false;
			self.has_selection = true;
			// Copy to clipboard via OSC 52
			self.copy_to_clipboard();
			return true;
		}
	}

	// Legacy fallback for scroll wheel via left/middle motion (deprecated but kept for compatibility)
	if (self.mouse_wheel_enabled && !self.sel_active) {
		if (msg.action == milktea::MouseAction.MOUSE_MOTION) {
			if (msg.button == milktea::MouseButton.MOUSE_LEFT) {
				self.scroll_up();
				return true;
			}
			if (msg.button == milktea::MouseButton.MOUSE_MIDDLE) {
				self.scroll_down();
				return true;
			}
		}
	}

	return false;
}

// handle_mouse (legacy) processes mouse events from string button/action parameters.
// Maintained for backward compatibility with taro module.
// Returns true if the event was consumed.
fn bool Viewport.handle_mouse(&self, String button, String action) {
	if (!self.mouse_wheel_enabled) return false;
	// New wheel button names — work on press
	if (button == "wheel_up") {
		self.scroll_up();
		return true;
	}
	if (button == "wheel_down") {
		self.scroll_down();
		return true;
	}
	// Legacy fallback: "left" on motion = scroll up, "middle" on motion = scroll down
	if (action == "motion") {
		if (button == "left") {
			self.scroll_up();
			return true;
		}
		if (button == "middle") {
			self.scroll_down();
			return true;
		}
	}
	return false;
}

// scroll_by scrolls by the given number of lines (negative = up, positive = down).
fn void Viewport.scroll_by(&self, int lines) {
	if (lines < 0) {
		for (int i = 0; i < -lines; i++) self.scroll_up();
	} else {
		for (int i = 0; i < lines; i++) self.scroll_down();
	}
}

fn String base64_encode(String input) {
	const String B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	DString out = dstring::temp();

	sz i = 0;
	while (i < input.len) {
		sz remaining = input.len - i;
		int b0 = (int)input[i] & 0xff;
		int b1 = remaining > 1 ? ((int)input[i + 1] & 0xff) : 0;
		int b2 = remaining > 2 ? ((int)input[i + 2] & 0xff) : 0;

		out.append_char(B64_CHARS[(b0 >> 2) & 0x3f]);
		out.append_char(B64_CHARS[((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0f)]);
		out.append_char(remaining > 1 ? B64_CHARS[((b1 & 0x0f) << 2) | ((b2 >> 6) & 0x03)] : '=');
		out.append_char(remaining > 2 ? B64_CHARS[b2 & 0x3f] : '=');

		i += 3;
	}

	return out.str_view();
}

// get_selected_text extracts the text between sel_start and sel_end (content coordinates).
fn String Viewport.get_selected_text(&self) {
	if (!self.has_selection) return "";

	DString out = dstring::temp();
	int start_row = self.sel_start_row;
	int start_col = self.sel_start_col;
	int end_row = self.sel_end_row;
	int end_col = self.sel_end_col;

	// Normalize: ensure start <= end
	if (start_row > end_row || (start_row == end_row && start_col > end_col)) {
		int tr = start_row;
		int tc = start_col;
		start_row = end_row;
		start_col = end_col;
		end_row = tr;
		end_col = tc;
	}

	// Extract text line by line
	for (int row = start_row; row <= end_row && row < self.total_lines; row++) {
		String line = self.lines[row];
		int line_len = (int)line.len;

		int col_start = (row == start_row) ? start_col : 0;
		int col_end = (row == end_row) ? end_col : line_len;

		if (col_start < 0) col_start = 0;
		if (col_end > line_len) col_end = line_len;
		if (col_start >= line_len) col_start = line_len;
		if (col_end < col_start) col_end = col_start;

		if (col_end > col_start) {
			out.append_string(line[(sz)col_start:(sz)(col_end - col_start)]);
		}

		if (row < end_row) out.append_char('\n');
	}

	return out.str_view();
}

// copy_to_clipboard sends selected text to clipboard via OSC 52.
fn void Viewport.copy_to_clipboard(&self) {
	if (!self.has_selection) return;

	String text = self.get_selected_text();
	if (text.len == 0) return;

	String b64 = base64_encode(text);

	// OSC 52 sequence: \x1b]52;c;<base64>\x07
	DString seq = dstring::temp();
	seq.append_string("\x1b]52;c;");
	seq.append_string(b64);
	seq.append_char('\x07');

	// Write to stdout
	milktea::write_stdout((char[])seq.str_view());
}

// is_in_selection checks if a content-relative position falls within the selection.
fn bool Viewport.is_in_selection(&self, int row, int col) {
	if (!self.has_selection) return false;

	int start_row = self.sel_start_row;
	int start_col = self.sel_start_col;
	int end_row = self.sel_end_row;
	int end_col = self.sel_end_col;

	// Normalize: ensure start <= end
	if (start_row > end_row || (start_row == end_row && start_col > end_col)) {
		int tr = start_row;
		int tc = start_col;
		start_row = end_row;
		start_col = end_col;
		end_row = tr;
		end_col = tc;
	}

	if (row < start_row || row > end_row) return false;
	if (row == start_row && col < start_col) return false;
	if (row == end_row && col >= end_col) return false;

	return true;
}
fn String Viewport.view(&self) {
	DString out = dstring::temp();
	int start = self.offset;
	int end = start + self.height;
	if (end > self.total_lines) end = self.total_lines;

	bool has_bar = self.show_scrollbar && self.total_lines > self.height;
	int text_w = self.width - (has_bar ? 3 : 0); // 2 gap + 1 bar char
	if (text_w < 1) text_w = 1;

	int thumb_pos = 0;
	if (has_bar && self.total_lines > self.height) {
		thumb_pos = (self.offset * (self.height - 1)) / (self.total_lines - self.height);
	}

	for (int i = start; i < end; i++) {
		String line = self.lines[i];
		int line_w = glaze::string_width(line);

		// Render content with selection highlighting
		if (line_w <= text_w) {
			// Render normally and pad with spaces
			out.append_string(self.render_line_with_selection(i, line, text_w));
		} else {
			// Cut on a display-width boundary, not a byte index: a byte cut
			// splits multi-byte characters and can leave a partial escape
			// sequence that renders as visible garbage.
			String truncated = glaze::truncate_to_width(line, text_w);
			out.append_string(self.render_line_with_selection(i, truncated, text_w));
		}

		if (has_bar) {
			out.append_string("  ");
			int row = i - start;
			if (row == thumb_pos) {
				out.append_string(self.thumb_style.render("┃"));
			} else {
				out.append_string(self.track_style.render("│"));
			}
		}

		if (i < end - 1) out.append_char('\n');
	}

	return out.str_view();
}

// render_line_with_selection renders a line with selection highlighting and pads to width.
fn String Viewport.render_line_with_selection(&self, int row, String line, int pad_to_width) {
	DString out = dstring::temp();
	int col = 0;

	// Render character by character with selection styling. Stepping one BYTE
	// at a time wrapped each byte of a multi-byte character in its own SGR
	// pair, so "日本語" rendered as nine replacement glyphs and the padding
	// was computed against a byte count instead of a display width.
	//
	// col tracks the DISPLAY column — what the terminal shows, and what the
	// selection anchors from mouse events are measured in. Wide glyphs occupy
	// two columns, so they advance col by two; counting every character once
	// left the highlight boundary one column short for every wide glyph before
	// it.
	sz i = 0;
	while (i < line.len) {
		sz char_len = glaze::utf8_sequence_len(line, i);
		String ch   = line[i:char_len];
		glaze::Style s = self.is_in_selection(row, col) ? self.selection_style : self.content_style;
		out.append_string(s.render(ch));
		col += glaze::utf8_width_at(line, i);
		i += char_len;
	}

	// Pad remainder with spaces
	int line_w = glaze::string_width(line);
	for (int p = line_w; p < pad_to_width; p++) {
		out.append_char(' ');
	}

	return out.str_view();
}

fn int Viewport.scroll_percent(&self) {
	if (self.total_lines <= self.height) return 100;
	int max_offset = self.total_lines - self.height;
	if (max_offset <= 0) return 100;
	return (self.offset * 100) / max_offset;
}