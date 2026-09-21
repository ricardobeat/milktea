module boba;

import milktea;
import xray;
import glaze;
import std::core::dstring;
import std::core::mem;

// Textarea is a multi-line text input component.
struct Textarea (xray::Content) {
	char[4096] buf;
	sz len;
	// Byte offset of the caret within buf.
	sz cursor_pos;
	int width;
	int height;
	int cursor_row;
	int cursor_col;
	int scroll_offset;
	String placeholder;
	String prompt; // prefix shown before each line (e.g. "> ")
	bool show_line_numbers;
	bool show_cursor;
	// How the terminal caret looks while this field is focused. Distinct from
	// cursor_style below, which colors the cell the caret sits on when the
	// field paints its own block cursor into the text.
	milktea::CursorStyle caret;
	bool cursor_blink;
	bool cursor_visible;
	bool focused;
	glaze::Style focused_style;
	glaze::Style blurred_style;
	glaze::Style cursor_style;
	glaze::Style placeholder_style;
	glaze::Style line_number_style;
	glaze::Style prompt_style;
	// Press callback, fired when a mouse press lands inside the textarea's
	// rect. The callback receives the cell row/col (already adjusted for the
	// gutter, prompt, and scroll — i.e. text coordinates, not screen), and
	// is the hook the app uses to focus the editor and move the caret. ctx
	// is whatever the app registered; the textarea stores the address, and
	// the owning component outlasts the node tree.
	TextareaPressFn on_press_fn;
	void* on_press_ctx;
}

// TextareaPressFn fires when a mouse press lands inside the textarea. row
// and col are the position in the textarea's own coordinates — the space
// set_cursor takes, already past the gutter and prompt and with the wrap and
// the scroll resolved — so the callback can hand them straight back to
// set_cursor without knowing how the text is laid out. id is the per-call
// ctx the app registered through on_press.
alias TextareaPressFn = fn void(void* id, int row, int col);

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
	self.cursor_pos = 0;
	self.cursor_row = 0;
	self.cursor_col = 0;
}

// set_cursor places the caret at the given text-coordinate row/col. row and
// col are in the same space the textarea paints — col 0 is the first cell of
// the line, not counting the gutter or prompt — and out-of-range values are
// clamped to the buffer. The textarea updates scroll_offset so the new
// caret position is visible.
//
// This is the hook a click handler uses to move the caret without driving
// the keyboard path: a press inside the editor reports (row, col) text
// coordinates (already adjusted for the gutter, prompt and scroll) and the
// app forwards them straight to set_cursor.
fn void Textarea.set_cursor(&self, int row, int col) {
	if (self.len == 0) {
		self.cursor_pos = 0;
		self.cursor_row = 0;
		self.cursor_col = 0;
		return;
	}
	int lc = self.line_count();
	if (row < 0) row = 0;
	if (row >= lc) row = lc - 1;
	// Find the byte position at the start of row-th line and walk forward
	// by `col` cells (not bytes — multi-byte runes are skipped whole).
	sz pos = 0;
	int r = 0;
	while (r < row && pos < self.len) {
		if (self.buf[pos] == '\n') r++;
		pos++;
	}
	// pos now points at the first byte of row `row`. Walk forward by col
	// runes, stopping at the newline or buffer end.
	int walked = 0;
	while (walked < col && pos < self.len && self.buf[pos] != '\n') {
		sz next = utf8_next_boundary(self.buf[:self.len], pos);
		if (next <= pos) break;
		pos = next;
		walked++;
	}
	self.cursor_pos = pos;
	self.cursor_row = row;
	self.cursor_col = walked;
	self.scroll_to_caret();
}

// rows_for is how many rows the view spends on a line of len bytes. A line
// wider than the content area is wrapped, so this is the count of chunks the
// render draws — at least one, since even an empty line is a row.
fn int rows_for(sz len, int width) @local {
	if (len <= 0) return 1;
	return (int)((len + (sz)width - 1) / (sz)width);
}

// caret_visual_pos gives the caret's row from the top of the view and its
// column inside the chunk it sits in — the two numbers the drawn cursor and
// the scroll check both need, and both counted the way the render counts
// them: a wrapped line above the caret adds rows to that distance, so
// counting lines instead draws the cursor over a line that merely happens to
// be that far down, and scrolls for a caret that was on screen all along.
//
// The chunk is clamped to the caret line's own last one, so a caret at a
// column that is a whole number of chunks wide sits at the end of the text
// rather than on a row the line does not have.
fn void Textarea.caret_visual_pos(&self, int* out_row, int* out_col) {
	int width = self.width - self.text_offset();
	if (width < 1) width = 1;

	int rows = 0;
	sz pos = 0;
	for (int r = 0; r < self.cursor_row && pos < self.len; r++) {
		sz line_end = pos;
		while (line_end < self.len && self.buf[line_end] != '\n') line_end++;
		if (r >= self.scroll_offset) rows += rows_for(line_end - pos, width);
		pos = line_end < self.len ? line_end + 1 : line_end;
	}

	// pos is the start of the caret's own line now.
	sz line_end = pos;
	while (line_end < self.len && self.buf[line_end] != '\n') line_end++;
	int chunks = rows_for(line_end - pos, width);
	int chunk = self.cursor_col / width;
	if (chunk > chunks - 1) chunk = chunks - 1;
	if (chunk < 0) chunk = 0;

	*out_row = rows + chunk;
	*out_col = self.cursor_col - chunk * width;
}

// scroll_to_caret brings the caret back into the view after set_cursor moved
// it. A click lands inside the view by definition, so it never moves for one;
// a position placed from elsewhere ends up on the view's first row.
fn void Textarea.scroll_to_caret(&self) {
	if (self.cursor_row < self.scroll_offset) {
		self.scroll_offset = self.cursor_row;
		return;
	}
	int vis = self.height;
	if (vis < 1) vis = 1;
	int row;
	int col;
	self.caret_visual_pos(&row, &col);
	if (row >= vis) self.scroll_offset = self.cursor_row;
	if (self.scroll_offset < 0) self.scroll_offset = 0;
}

// text_pos_at converts a press at (row, col) in the component's own cells —
// the space xray reports a click in — into the (row, col) set_cursor takes.
//
// The two only agree while the view sits at the top of the buffer and no line
// wraps. The render starts at scroll_offset and breaks a line wider than the
// content area into several rows, so a screen row is neither a line number
// nor a fixed distance from one: counting rows through the same wrap the
// render walks is what puts the caret on the row the click named, and the
// column is then counted only inside the chunk it landed in.
//
// A press past the end of the text answers with the end of the buffer, which
// is where a click under the last line belongs.
fn void Textarea.text_pos_at(&self, int row, int col, int* out_row, int* out_col) {
	if (row < 0) row = 0;
	int width = self.width - self.text_offset();
	if (width < 1) width = 1;

	int lc = self.line_count();
	int first = self.scroll_offset;
	if (first < 0) first = 0;
	if (first >= lc) first = lc - 1;

	// Walk to the line the view draws first; rows are counted from there,
	// since that line is row 0 on screen.
	sz pos = 0;
	for (int r = 0; r < first && pos < self.len; r++) {
		while (pos < self.len && self.buf[pos] != '\n') pos++;
		if (pos < self.len) pos++;
	}

	int visual = 0;
	int last_row = first;
	int last_col = 0;
	for (int r = first; r < lc; r++) {
		sz line_start = pos;
		while (pos < self.len && self.buf[pos] != '\n') pos++;
		sz line_len = pos - line_start;
		last_row = r;
		last_col = (int)line_len;
		int chunks = rows_for(line_len, width);
		if (row < visual + chunks) {
			sz chunk_start = (sz)(row - visual) * (sz)width;
			if (chunk_start > line_len) chunk_start = line_len;
			int text_col = (int)chunk_start + (col - self.text_offset());
			if (text_col < (int)chunk_start) text_col = (int)chunk_start;
			sz chunk_end = chunk_start + (sz)width;
			if (chunk_end > line_len) chunk_end = line_len;
			if (text_col > (int)chunk_end) text_col = (int)chunk_end;
			*out_row = r;
			*out_col = text_col;
			return;
		}
		visual += chunks;
		pos = pos < self.len ? pos + 1 : pos;
	}
	*out_row = last_row;
	*out_col = last_col;
}

// insert inserts a character at the cursor position.
fn void Textarea.insert(&self, char c) {
	if (self.len >= self.buf.len - 1) return;

	if (c == '\n') {
		// Insert newline: shift everything after cursor
		for (sz i = self.len; i > self.cursor_pos; i--) {
			self.buf[i] = self.buf[i - 1];
		}
		self.buf[self.cursor_pos] = '\n';
		self.len++;
		self.cursor_pos++;
		self.cursor_row++;
		self.cursor_col = 0;
		return;
	}

	for (sz i = self.len; i > self.cursor_pos; i--) {
		self.buf[i] = self.buf[i - 1];
	}
	self.buf[self.cursor_pos] = c;
	self.len++;
	self.cursor_pos++;
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

// line_start_at returns the byte offset of the start of the line containing
// `pos` — i.e. one past the preceding newline, or 0.
fn sz Textarea.line_start_at(&self, sz pos) {
	if (pos > self.len) pos = self.len;
	while (pos > 0 && self.buf[pos - 1] != '\n') pos--;
	return pos;
}

// backspace deletes the character before the cursor.
//
// Removes the whole UTF-8 sequence: deleting a single byte of a multi-byte
// character leaves invalid UTF-8 that renders as garbage from there on.
fn void Textarea.backspace(&self) {
	if (self.cursor_pos == 0) return;

	char prev = self.buf[self.cursor_pos - 1];
	sz start  = utf8_prev_boundary(self.buf[:self.len], self.cursor_pos);
	sz n      = self.cursor_pos - start;
	for (sz i = self.cursor_pos; i < self.len; i++) {
		self.buf[i - n] = self.buf[i];
	}
	self.len -= n;
	self.cursor_pos = start;

	if (prev == '\n') {
		if (self.cursor_row > 0) self.cursor_row--;
		// The joined line's column is the distance back to its start.
		self.cursor_col = (int)(self.cursor_pos - self.line_start_at(self.cursor_pos));
	} else {
		self.cursor_col -= (int)n;
		if (self.cursor_col < 0) self.cursor_col = 0;
	}
}

// delete_char deletes the character at the cursor, sequence and all.
fn void Textarea.delete_char(&self) {
	if (self.cursor_pos >= self.len) return;
	sz next = utf8_next_boundary(self.buf[:self.len], self.cursor_pos);
	sz n    = next - self.cursor_pos;
	for (sz i = next; i < self.len; i++) {
		self.buf[i - n] = self.buf[i];
	}
	self.len -= n;
}

// text returns the current content as a String.
fn String Textarea.text(&self) {
	return (String)self.buf[:self.len];
}

fn bool Textarea.handle_key(&self, milktea::KeyMsg k) {
	self.start_blink();
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			if (self.cursor_pos > 0) {
				// Step a whole codepoint, so the cursor never lands inside a
				// multi-byte character and split it on the next edit.
				sz prev = utf8_prev_boundary(self.buf[:self.len], self.cursor_pos);
				if (self.buf[prev] == '\n' && self.cursor_row > 0) self.cursor_row--;
				self.cursor_pos = prev;
				self.cursor_col = (int)(self.cursor_pos - self.line_start_at(self.cursor_pos));
			}
			return true;
		case milktea::KeyCode.RIGHT:
			if (self.cursor_pos < self.len) {
				bool at_newline = self.buf[self.cursor_pos] == '\n';
				sz next = utf8_next_boundary(self.buf[:self.len], self.cursor_pos);
				self.cursor_pos = next;
				if (at_newline) {
					self.cursor_row++;
					self.cursor_col = 0;
				} else {
					self.cursor_col = (int)(self.cursor_pos - self.line_start_at(self.cursor_pos));
				}
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
				self.cursor_pos = pos;
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
				self.cursor_pos = pos;
				self.cursor_row = r;
				self.cursor_col = col;
			}
			return true;
		case milktea::KeyCode.HOME:
			// Move to start of current line



			{
				sz pos = self.cursor_pos;
				while (pos > 0 && self.buf[pos - 1] != '\n') pos--;
				self.cursor_pos = pos;
				self.cursor_col = 0;
			}
			return true;
		case milktea::KeyCode.END:
			// Move to end of current line



			{
				// Find the end of the line, then measure back to its start.
				// This used to read self.cursor_pos *after* assigning it, so the
				// column was always computed as pos - pos == 0 and the
				// rendered cursor jumped to the start of the line.
				sz pos = self.cursor_pos;
				while (pos < self.len && self.buf[pos] != '\n') pos++;
				self.cursor_pos = pos;
				self.cursor_col = (int)(pos - self.line_start_at(pos));
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

// handle_paste inserts pasted text at the cursor, including newlines.
// Each character (including \n) is fed through the existing insert() path
// so cursor_row and cursor_col stay correctly updated.
// \r\n sequences are normalised to a single \n (common from some terminals).
fn void Textarea.handle_paste(&self, String s) {
	sz i = 0;
	while (i < s.len) {
		char c = s[i];
		if (c == '\r') {
			// Convert \r\n → \n; lone \r → \n for consistency.
			self.insert('\n');
			if (i + 1 < s.len && s[i + 1] == '\n') i++; // skip the paired \n
		} else {
			self.insert(c);
		}
		i++;
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
// gutter_width is how many columns the line-number column occupies, before
// the trailing space. Zero when line numbers are off.
fn int Textarea.gutter_width(&self) {
	if (!self.show_line_numbers) return 0;
	int lc = self.line_count();
	if (lc >= 100) return 4;
	if (lc >= 10) return 3;
	return 2;
}

// text_offset is how far in from the left edge the text itself starts: the
// gutter (digits plus one trailing space) and then the prompt. The cursor
// sits this far right of the component's own rect, so view() and cursor()
// both read it from here rather than each recomputing it.
fn int Textarea.text_offset(&self) {
	int gutter = self.gutter_width();
	return (gutter > 0 ? gutter + 1 : 0) + (int)self.prompt.len;
}

// blank_span returns a run of spaces, for padding a styled run out to a
// fixed width.
fn String blank_span(int width) @local {
	DString out = dstring::temp_with_capacity(width);
	for (int i = 0; i < width; i++) out.append_char(' ');
	return out.str_view();
}

fn String Textarea.view(&self) {
	DString out = dstring::temp();
	int lc      = self.line_count();

	int gutter_width = self.gutter_width();
	int gutter_visual = gutter_width > 0 ? gutter_width + 1 : 0;
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
					// Continuation row: the gutter is blank, but it still has to carry
					// the gutter style. Unstyled spaces would drop whatever background
					// the gutter shares with the text and punch a hole in the line.
					out.append_string(self.line_number_style.render(blank_span(gutter_visual)));
				}
			}

			// Render prompt (only on first chunk)
			if (chunk_idx == 0 && self.prompt.len > 0) {
				out.append_string(self.prompt_style.render(self.prompt));
			} else if (chunk_idx > 0 && self.prompt.len > 0) {
				// Blank prompt space on continuation lines, styled for the same
				// reason as the blank gutter above.
				out.append_string(self.prompt_style.render(blank_span(prompt_visual)));
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

// ── layout tree ──────────────────────────────────────────────────────────────

fn String Textarea.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

fn int Textarea.measure(&self, int width) @dynamic {
	int lc = self.line_count();
	return lc < 1 ? 1 : lc;
}

fn int Textarea.measure_width(&self, int height) @dynamic => self.width;

fn xray::ContentCursor Textarea.cursor(&self, xray::Rect r) @dynamic {
	if (!self.focused) return {};
	// The caret's row on screen is its visual row within the view, and its
	// column is its place inside the chunk it is in, past the gutter and
	// prompt the text is drawn after — see caret_visual_pos.
	int row;
	int col;
	self.caret_visual_pos(&row, &col);
	return milktea::place_cursor(r,
		self.text_offset() + col,
		row,
		self.caret);
}

fn xray::Node* Textarea.node(&self) {
	xray::Node* n = xray::content_node(self);
	if (self.on_press_fn != null) {
		PressCtx* pc = mem::tnew(PressCtx);
		pc.t = self;
		n.id_with(pc).on_click(&textarea_press);
	}
	return n;
}

// on_press registers a handler that fires when a mouse press lands inside
// the textarea's rect. The textarea takes care of converting the press cell
// into a (row, col) pair in text coordinates — adjusted for the gutter, the
// prompt and the scroll offset — so the app can move the caret directly
// without any layout math.
//
// ctx is the value the callback receives as its first parameter; typically
// &self of the owning editor. The textarea keeps the address, and since the
// textarea itself outlives the per-frame node tree, the pointer stays valid.
fn void Textarea.on_press(&self, TextareaPressFn cb, void* ctx) {
	self.on_press_fn = cb;
	self.on_press_ctx = ctx;
}

// textarea_press is the bridge between xray's click system (which reports
// rect-relative cell positions) and the textarea's own coordinate system.
// The id pointer the framework forwards carries a fresh PressCtx on tmem
// that holds &self; the static handler does the cast and the conversion.
struct PressCtx { Textarea* t; }

fn void textarea_press(void* id, String id_str, int col, int row) @local {
	PressCtx* pc = (PressCtx*)id;
	Textarea* t = pc.t;
	if (t.on_press_fn == null) return;
	// col / row arrive rect-local (the framework subtracts rect.x / rect.y
	// for us) but still in screen cells. The textarea turns them into the
	// text position the caret belongs at — see text_pos_at — so the app can
	// hand them straight to set_cursor without knowing how the view wraps or
	// where it is scrolled to.
	int text_row;
	int text_col;
	t.text_pos_at(row, col, &text_row, &text_col);
	t.on_press_fn(t.on_press_ctx, text_row, text_col);
}
