module pearls;

import tea;
import lipgloss;
import std::core::dstring;

// Textarea is a multi-line text input component.
struct Textarea {
	char[4096] buf;
	sz len;
	sz cursor;
	int width;
	int height;
	int cursor_row;
	int cursor_col;
	int scroll_offset;
	String placeholder;
	String prompt; // prefix shown before each line (e.g. "> ")
	bool show_line_numbers;
	bool show_cursor; // draw a fake block cursor in the content (option 2)
	bool focused;
	lipgloss::Style focused_style;
	lipgloss::Style blurred_style;
	lipgloss::Style cursor_style;
	lipgloss::Style line_number_style;
	lipgloss::Style prompt_style;
}

// new_textarea creates a textarea with the given dimensions.
fn Textarea new_textarea(int width, int height) {
	Textarea t = { };
	t.width = width;
	t.height = height;
	t.show_line_numbers = true;
	t.focused_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ffffff"));
	t.blurred_style = lipgloss::new_style().foreground(lipgloss::color_hex("#888888"));
	t.cursor_style = lipgloss::new_style().background(lipgloss::color_hex("#ffffff"))
		.foreground(lipgloss::color_hex("#000000"));
	t.line_number_style = lipgloss::new_style().foreground(lipgloss::color_hex("#555555"));
	t.prompt_style = lipgloss::new_style().foreground(lipgloss::color_hex("#555555"));
	return t;
}

// with_placeholder returns a copy with a placeholder.
fn Textarea Textarea.with_placeholder(self, String ph) {
	Textarea t = self;
	t.placeholder = ph;
	return t;
}

// clear empties the textarea.
fn void Textarea.clear(&self) {
	self.len = 0;
	self.cursor = 0;
	self.cursor_row = 0;
	self.cursor_col = 0;
}

// insert inserts a character at the cursor position.
fn void Textarea.insert(&self, char c) {
	if (self.len >= self.buf.len - 1) return;

	if (c == '\n') {
		// Insert newline: shift everything after cursor
		for (sz i = self.len; i > self.cursor; i--) {
			self.buf[i] = self.buf[i - 1];
		}
		self.buf[self.cursor] = '\n';
		self.len++;
		self.cursor++;
		self.cursor_row++;
		self.cursor_col = 0;
		return;
	}

	for (sz i = self.len; i > self.cursor; i--) {
		self.buf[i] = self.buf[i - 1];
	}
	self.buf[self.cursor] = c;
	self.len++;
	self.cursor++;
	self.cursor_col++;
}

// backspace deletes the character before the cursor.
fn void Textarea.backspace(&self) {
	if (self.cursor == 0) return;

	char prev = self.buf[self.cursor - 1];
	for (sz i = self.cursor; i < self.len; i++) {
		self.buf[i - 1] = self.buf[i];
	}
	self.len--;
	self.cursor--;

	if (prev == '\n') {
		self.cursor_row--;
		// Count column in previous line
		int col = 0;
		sz pos  = self.cursor - 1;
		while (pos > 0 && self.buf[pos] != '\n') {
			col++;
			pos--;
		}
		self.cursor_col = col;
	} else {
		self.cursor_col--;
	}
}

// delete_char deletes the character at the cursor.
fn void Textarea.delete_char(&self) {
	if (self.cursor >= self.len) return;
	for (sz i = self.cursor; i < self.len - 1; i++) {
		self.buf[i] = self.buf[i + 1];
	}
	self.len--;
}

// text returns the current content as a String.
fn String Textarea.text(&self) {
	return (String)self.buf[:self.len];
}

// handle_key processes a key message and returns true if consumed.
fn bool Textarea.handle_key(&self, tea::KeyMsg k) {
	switch (k.code) {
		case tea::KeyCode.LEFT:
			if (self.cursor > 0) {
				self.cursor--;
				if (self.cursor_col > 0) {
					self.cursor_col--;
				} else {
					// Moved to previous line
					self.cursor_row--;
					int col = 0;
					sz pos  = self.cursor - 1;
					while (pos > 0 && self.buf[pos] != '\n') {
						col++;
						pos--;
					}
					self.cursor_col = col;
				}
			}
			return true;
		case tea::KeyCode.RIGHT:
			if (self.cursor < self.len) {
				if (self.buf[self.cursor] == '\n') {
					self.cursor_row++;
					self.cursor_col = 0;
				} else {
					self.cursor_col++;
				}
				self.cursor++;
			}
			return true;
		case tea::KeyCode.UP:
			// Move to same column on previous line



			{
				int target_col = self.cursor_col;
				int r          = self.cursor_row - 1;
				if (r < 0) return true;
				sz pos    = 0;
				int cur_r = 0;
				while (pos < self.len && cur_r < r) {
					if (self.buf[pos] == '\n') cur_r++;
					pos++;
				}
				// pos is now at start of line r
				int col       = 0;
				sz line_start = pos;
				while (pos < self.len && self.buf[pos] != '\n' && col < target_col) {
					col++;
					pos++;
				}
				self.cursor = pos;
				self.cursor_row = r;
				self.cursor_col = col;
			}
			return true;
		case tea::KeyCode.DOWN:
			// Move to same column on next line



			{
				int target_col = self.cursor_col;
				int r          = self.cursor_row + 1;
				sz pos         = 0;
				int cur_r      = 0;
				while (pos < self.len && cur_r < r) {
					if (self.buf[pos] == '\n') cur_r++;
					pos++;
				}
				if (cur_r < r) return true; // no next line
				// pos is now at start of line r
				int col       = 0;
				sz line_start = pos;
				while (pos < self.len && self.buf[pos] != '\n' && col < target_col) {
					col++;
					pos++;
				}
				self.cursor = pos;
				self.cursor_row = r;
				self.cursor_col = col;
			}
			return true;
		case tea::KeyCode.HOME:
			// Move to start of current line



			{
				sz pos = self.cursor;
				while (pos > 0 && self.buf[pos - 1] != '\n') pos--;
				self.cursor = pos;
				self.cursor_col = 0;
			}
			return true;
		case tea::KeyCode.END:
			// Move to end of current line



			{
				sz pos = self.cursor;
				while (pos < self.len && self.buf[pos] != '\n') pos++;
				self.cursor = pos;
				self.cursor_col = (int)(pos - (self.cursor > 0 ? self.cursor : 0));
			}
			return true;
		case tea::KeyCode.BACKSPACE:
			self.backspace();
			return true;
		case tea::KeyCode.DELETE:
			self.delete_char();
			return true;
		case tea::KeyCode.ENTER:
			self.insert('\n');
			return true;
		case tea::KeyCode.TAB:
			// Insert spaces
			for (int i = 0; i < 4; i++) self.insert(' ');
			return true;
		case tea::KeyCode.RUNE:
			self.insert(k.rune);
			return true;
		default:
			return false;
	}
}

// line_count returns the number of lines in the content.
fn int Textarea.line_count(&self) {
	if (self.len == 0) return 1;
	int count = 1;
	for (sz i = 0; i < self.len; i++) {
		if (self.buf[i] == '\n') count++;
	}
	return count;
}

// view returns the rendered textarea string.
fn String Textarea.view(&self) {
	DString out = dstring::temp();
	int lc      = self.line_count();

	int gutter_width = 0;
	if (self.show_line_numbers) {
		gutter_width = 2;
		if (lc >= 10) gutter_width = 3;
		if (lc >= 100) gutter_width = 4;
	}

	lipgloss::Style content_style = self.focused ? self.focused_style : self.blurred_style;

	// Split content into lines and render visible ones
	int start_row = self.scroll_offset;
	int end_row   = start_row + self.height;
	if (end_row > lc) end_row = lc;

	sz pos        = 0;
	int row       = 0;
	sz line_start = 0;

	// Skip to start_row
	while (pos < self.len && row < start_row) {
		if (self.buf[pos] == '\n') {
			row++;
			line_start = pos + 1;
		}
		pos++;
	}
	if (row == start_row) line_start = pos;

	// Render visible lines
	for (int r = start_row; r < end_row; r++) {
		// Optional line number gutter
		if (self.show_line_numbers) {
			String num = string::tformat(string::tformat("%%%dd ", gutter_width), r + 1);
			out.append_string(self.line_number_style.render(num));
		}

		// Optional prompt prefix
		if (self.prompt.len > 0) {
			out.append_string(self.prompt_style.render(self.prompt));
		}

		// Line content — width constrained so the outer style doesn't expand
		sz line_end = line_start;
		while (line_end < self.len && self.buf[line_end] != '\n') line_end++;

		int content_w = self.width - (int)self.prompt.len;
		if (content_w < 1) content_w = 1;
		lipgloss::Style line_style = content_style.set_width(content_w);

		bool is_cursor_row = self.focused && self.show_cursor && (r == self.cursor_row);

		if (line_start == self.len && self.len > 0 && self.buf[self.len - 1] == '\n') {
			// Empty line after trailing newline
			if (is_cursor_row) {
				// Cursor on empty trailing line — render a single highlighted space
				out.append_string(self.cursor_style.render(" "));
				out.append_char('\n');
			} else {
				out.append_string(line_style.render(""));
				out.append_char('\n');
			}
		} else if (line_start < self.len) {
			String line_text = (String)self.buf[line_start:line_end];
			if (is_cursor_row) {
				sz cur      = (sz)self.cursor_col;
				sz line_len = line_end - line_start;
				// before-cursor segment



				if (cur > 0) {
					sz blen = cur < line_len ? cur : line_len;
					out.append_string(content_style.render(line_text[:blen]));
				}
				// cursor character (or space if at end)
				if (cur < line_len) {
					char[2] ch_buf = { line_text[cur], 0 };
					out.append_string(self.cursor_style.render(((ZString)&ch_buf).str_view()));
					// after-cursor segment
					if (cur + 1 < line_len) {
						int remaining_w = content_w - (int)cur - 1;
						if (remaining_w < 1) remaining_w = 1;
						out.append_string(content_style.set_width(remaining_w)
							.render(line_text[cur + 1:line_len - cur - 1]));
					}
				} else {
					// Cursor past end of line — append highlighted space
					out.append_string(self.cursor_style.render(" "));
				}
				out.append_char('\n');
			} else {
				out.append_string(line_style.render(line_text));
				out.append_char('\n');
			}
		} else if (r == 0 && self.len == 0) {
			if (is_cursor_row) {
				// Empty buffer with cursor — highlighted space then placeholder styling
				out.append_string(self.cursor_style.render(" "));
				out.append_char('\n');
			} else {
				out.append_string(line_style.render(self.placeholder));
				out.append_char('\n');
			}
		}

		line_start = line_end + 1;
	}

	String s = out.str_view();
	// Strip trailing newline — the outer lipgloss render() adds its own line breaks



	if (s.len > 0 && s[s.len - 1] == '\n') s = s[:s.len - 1];
	return s;
}