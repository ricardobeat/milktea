module boba;

import milktea;
import glaze;
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
	bool show_cursor;
	bool cursor_blink;
	bool cursor_visible;
	bool focused;
	glaze::Style focused_style;
	glaze::Style blurred_style;
	glaze::Style cursor_style;
	glaze::Style placeholder_style;
	glaze::Style line_number_style;
	glaze::Style prompt_style;
}

// new_textarea creates a textarea with the given dimensions.
fn Textarea new_textarea(int width, int height) {
	Textarea t = { };
	t.width = width;
	t.height = height;
	t.show_line_numbers = true;
	t.show_cursor = true;
	t.cursor_blink = true;
	t.cursor_visible = true;
	t.focused_style = glaze::style().foreground(glaze::color_hex("#ffffff"));
	t.blurred_style = glaze::style().foreground(glaze::color_hex("#888888"));
	t.cursor_style = glaze::style().background(glaze::color_hex("#ffffff")).foreground(glaze::color_hex("#000000"));
	t.placeholder_style = glaze::style().foreground(glaze::color_hex("#555555"));
	t.line_number_style = glaze::style().foreground(glaze::color_hex("#555555"));
	t.prompt_style = glaze::style().foreground(glaze::color_hex("#555555"));
	return t;
}

// with_placeholder returns a copy with a placeholder.
fn Textarea Textarea.with_placeholder(self, String ph) {
	Textarea t = self;
	t.placeholder = ph;
	return t;
}

const int CURSOR_BLINK_MS = 530;

fn milktea::Cmd Textarea.update(&self, milktea::Msg msg) {
	if (msg.kind != milktea::MsgKind.TICK || msg.owner != self) return null;
	if (self.focused && self.cursor_blink) {
		self.cursor_visible = !self.cursor_visible;
		milktea::tick(CURSOR_BLINK_MS, owner: self);
	}
	return null;
}

fn void Textarea.start_blink(&self) {
	if (self.cursor_blink) {
		self.cursor_visible = true;
		milktea::cancel(self);
		milktea::tick(CURSOR_BLINK_MS, owner: self);
	}
}

fn void Textarea.stop_blink(&self) {
	milktea::cancel(self);
	self.cursor_visible = true;
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

// insert_rune encodes a Unicode codepoint as UTF-8 and inserts it at the cursor.
// Checked up front so a full buffer can't truncate a sequence mid-way.
fn void Textarea.insert_rune(&self, uint cp) {
	char[4] enc;
	sz n = milktea::utf8_encode(cp, enc[..]);
	if (self.len + n >= self.buf.len) return;
	for (sz i = 0; i < n; i++) self.insert(enc[i]);
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

fn bool Textarea.handle_key(&self, milktea::KeyMsg k) {
	self.start_blink();
	switch (k.code) {
		case milktea::KeyCode.LEFT:
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
		case milktea::KeyCode.RIGHT:
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
		case milktea::KeyCode.UP:
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
		case milktea::KeyCode.DOWN:
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
		case milktea::KeyCode.HOME:
			// Move to start of current line



			{
				sz pos = self.cursor;
				while (pos > 0 && self.buf[pos - 1] != '\n') pos--;
				self.cursor = pos;
				self.cursor_col = 0;
			}
			return true;
		case milktea::KeyCode.END:
			// Move to end of current line



			{
				sz pos = self.cursor;
				while (pos < self.len && self.buf[pos] != '\n') pos++;
				self.cursor = pos;
				self.cursor_col = (int)(pos - (self.cursor > 0 ? self.cursor : 0));
			}
			return true;
		case milktea::KeyCode.BACKSPACE:
			self.backspace();
			return true;
		case milktea::KeyCode.DELETE:
			self.delete_char();
			return true;
		case milktea::KeyCode.ENTER:
			self.insert('\n');
			return true;
		case milktea::KeyCode.TAB:
			// Insert spaces
			for (int i = 0; i < 4; i++) self.insert(' ');
			return true;
		case milktea::KeyCode.RUNE:
			self.insert_rune(k.rune);
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

	// Gutter visual width: digits + one trailing space (e.g. " 1 " = gutter_width+1 chars).
	int gutter_visual = self.show_line_numbers ? gutter_width + 1 : 0;

	// Prompt visual width.
	int prompt_visual = (int)self.prompt.len;

	// Content width is the space available for actual text on each visual row.
	int content_w = self.width - gutter_visual - prompt_visual;
	if (content_w < 1) content_w = 1;

	glaze::Style content_style = self.focused ? self.focused_style : self.blurred_style;

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

	// visual_row tracks how many visual rows we have rendered (for height clipping).
	int visual_row = 0;

	// Render visible lines
	for (int r = start_row; r < end_row && visual_row < self.height; r++) {
		// Find end of this logical line
		sz line_end = line_start;
		while (line_end < self.len && self.buf[line_end] != '\n') line_end++;

		sz line_len  = line_end - line_start;
		// Use correct slice: start at line_start, length = line_end - line_start
		String line_text = (String)self.buf[line_start:line_len];

		bool is_cursor_row = self.focused && self.show_cursor && self.cursor_visible && (r == self.cursor_row);

		// Handle empty line (either empty buffer, or trailing newline case)
		if (line_len == 0) {
			if (visual_row >= self.height) break;
			// Render gutter
			if (self.show_line_numbers) {
				String num = string::tformat(string::tformat("%%%dd ", gutter_width), r + 1);
				out.append_string(self.line_number_style.render(num));
			}
			// Render prompt
			if (self.prompt.len > 0) {
				out.append_string(self.prompt_style.render(self.prompt));
			}
			// Render content
			if (r == 0 && self.len == 0 && self.placeholder.len > 0) {
				if (is_cursor_row) {
					out.append_string(self.cursor_style.render(self.placeholder[:1]));
					if (self.placeholder.len > 1) {
						out.append_string(self.placeholder_style.render(self.placeholder[1..]));
					}
				} else {
					out.append_string(self.placeholder_style.render(self.placeholder));
				}
			} else if (is_cursor_row) {
				out.append_string(self.cursor_style.render(" "));
			} else {
				out.append_string(content_style.render(""));
			}
			out.append_char('\n');
			visual_row++;
			line_start = line_end + 1;
			continue;
		}

		// Soft-wrap: split line_text into chunks of content_w columns each.
		sz chunk_start = 0;
		int chunk_idx  = 0;
		while (chunk_start < line_len) {
			if (visual_row >= self.height) break;

			// Determine how many bytes fit in content_w columns.
			sz chunk_end   = chunk_start;
			int col_count  = 0;
			while (chunk_end < line_len && col_count < content_w) {
				// Simple 1-column-per-byte for ASCII; proper UTF-8 would need glaze::string_width
				col_count++;
				chunk_end++;
			}

			// If this is the last chunk and we've consumed all text, stop.
			// (chunk_start == line_len means we went one past the end — only show if cursor is here)
			bool is_last_chunk = (chunk_end == line_len);

			// Render gutter: first chunk gets line number, continuations get blank space.
			if (self.show_line_numbers) {
				if (chunk_idx == 0) {
					String num = string::tformat(string::tformat("%%%dd ", gutter_width), r + 1);
					out.append_string(self.line_number_style.render(num));
				} else {
					// Continuation line: blank gutter of same width
					for (int g = 0; g < gutter_visual; g++) out.append_char(' ');
				}
			}

			// Render prompt (only on first chunk)
			if (chunk_idx == 0 && self.prompt.len > 0) {
				out.append_string(self.prompt_style.render(self.prompt));
			} else if (chunk_idx > 0 && self.prompt.len > 0) {
				// Blank prompt space on continuation lines
				for (int p = 0; p < prompt_visual; p++) out.append_char(' ');
			}

			String chunk_text = line_text[chunk_start:chunk_end - chunk_start];

			// Determine cursor position within this chunk (if cursor is on this row)
			bool cursor_in_chunk = false;
			sz chunk_cursor_col  = 0;
			if (is_cursor_row) {
				sz cur = (sz)self.cursor_col;
				if (cur >= chunk_start && (cur < chunk_end || (is_last_chunk && cur == line_len))) {
					cursor_in_chunk  = true;
					chunk_cursor_col = cur - chunk_start;
				}
			}

			if (cursor_in_chunk) {
				sz chunk_len = chunk_end - chunk_start;
				// before-cursor segment
				if (chunk_cursor_col > 0) {
					sz blen = chunk_cursor_col < chunk_len ? chunk_cursor_col : chunk_len;
					out.append_string(content_style.render(chunk_text[:blen]));
				}
				// cursor character or space if at end
				if (chunk_cursor_col < chunk_len) {
					char[2] ch_buf = { chunk_text[chunk_cursor_col], 0 };
					out.append_string(self.cursor_style.render(((ZString)&ch_buf).str_view()));
					// after-cursor segment
					if (chunk_cursor_col + 1 < chunk_len) {
						out.append_string(content_style.render(chunk_text[chunk_cursor_col + 1:chunk_len - chunk_cursor_col - 1]));
					}
				} else {
					// Cursor past end of chunk text — highlighted space
					out.append_string(self.cursor_style.render(" "));
				}
			} else {
				out.append_string(content_style.render(chunk_text));
			}

			out.append_char('\n');
			visual_row++;
			chunk_idx++;

			if (is_last_chunk) break;
			chunk_start = chunk_end;
		}

		line_start = line_end + 1;
	}

	String s = out.str_view();
	// Strip trailing newline — the outer glaze render() adds its own line breaks
	if (s.len > 0 && s[s.len - 1] == '\n') s = s[:s.len - 1];
	return s;
}
