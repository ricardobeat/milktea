module xray;

import std::core::dstring;

// ============================================================
// ScreenBuffer — cell grid with diff-based rendering.
// Holds current and previous frame; emits minimal ANSI to
// transform one into the other.
// ============================================================

struct ScreenBuffer {
	Cell[] cells; // flat grid: width * height
	Cell[] prev_cells; // previous frame for diffing
	sz width;
	sz height;
	bool[] dirty_lines; // per-line dirty flag
	bool full_redraw; // force full redraw on next flush
}

// new_screen_buffer allocates a buffer of the given dimensions.
fn ScreenBuffer* new_screen_buffer(sz width, sz height) {
	ScreenBuffer* sb = mem::new(ScreenBuffer);
	sb.width = width;
	sb.height = height;
	sz total = width * height;
	sb.cells = mem::new_array(Cell, total);
	sb.prev_cells = mem::new_array(Cell, total);
	sb.dirty_lines = mem::new_array(bool, height);
	sb.full_redraw = true;

	Cell empty = empty_cell();
	for (sz i = 0; i < total; i++) {
		sb.cells[i] = empty;
		sb.prev_cells[i] = empty;
	}
	for (sz i = 0; i < height; i++) {
		sb.dirty_lines[i] = true;
	}
	return sb;
}

// destroy frees all allocated memory.
fn void ScreenBuffer.destroy(&self) {
	mem::free(self.cells.ptr);
	mem::free(self.prev_cells.ptr);
	mem::free(self.dirty_lines.ptr);
}

// resize reallocates the buffer to new dimensions and clears everything.
fn void ScreenBuffer.resize(&self, sz width, sz height) {
	sz old_total = self.width * self.height;
	sz new_total = width * height;

	Cell[] new_cells = mem::new_array(Cell, new_total);
	Cell[] new_prev  = mem::new_array(Cell, new_total);
	bool[] new_dirty = mem::new_array(bool, height);

	Cell empty = empty_cell();
	for (sz i = 0; i < new_total; i++) {
		new_cells[i] = empty;
		new_prev[i] = empty;
	}
	for (sz i = 0; i < height; i++) {
		new_dirty[i] = true;
	}

	mem::free(self.cells.ptr);
	mem::free(self.prev_cells.ptr);
	mem::free(self.dirty_lines.ptr);

	self.cells = new_cells;
	self.prev_cells = new_prev;
	self.dirty_lines = new_dirty;
	self.width = width;
	self.height = height;
	self.full_redraw = true;
}

// clear sets all cells to empty and marks every line dirty.
fn void ScreenBuffer.clear(&self) {
	Cell empty = empty_cell();
	sz total   = self.width * self.height;
	for (sz i = 0; i < total; i++) {
		self.cells[i] = empty;
	}
	for (sz i = 0; i < self.height; i++) {
		self.dirty_lines[i] = true;
	}
}

// cell_at returns a pointer to the cell at (col, row), or null if out of bounds.
fn Cell* ScreenBuffer.cell_at(&self, sz col, sz row) {
	if (col >= self.width || row >= self.height) return null;
	return &self.cells[row * self.width + col];
}

// set_cell writes a cell at (col, row). Marks the line dirty if
// the new cell differs from what's already there.
fn void ScreenBuffer.set_cell(&self, sz col, sz row, Cell cell) {
	if (col >= self.width || row >= self.height) return;
	sz idx = row * self.width + col;
	if (!self.cells[idx].eq(cell)) {
		self.cells[idx] = cell;
		self.dirty_lines[row] = true;
	}
}

// overlay_char renders text into exactly one cell slot at (col, row).
// Supports ANSI escape sequences (SGR color/style). Neighbors are never
// touched — wide chars occupy one slot visually without shifting anything.
fn void ScreenBuffer.overlay_char(&self, sz col, sz row, String text, Style base_style) {
	if (col >= self.width || row >= self.height || text.len == 0) return;
	// Parse through a 1-wide scratch buffer so ANSI sequences are handled.
	// We only care about the cell at (0,0) of the scratch.
	ScreenBuffer* tmp = new_screen_buffer(2, 1);
	defer {
		tmp.destroy();
		mem::free(tmp);
	}
	tmp.render_ansi_string(0, 0, text, base_style, 1, 2);
	Cell c = tmp.cells[0];
	// If nothing was written (e.g. empty/null string), bail out.



	if (c.content_len == 0 || (c.content_len == 1 && c.content[0] == ' ' && c.style.is_empty())) return;
	self.set_cell(col, row, c);
}

// set_string writes a string starting at (col, row) with the given style.
// Advances col by each character's display width.
fn void ScreenBuffer.set_string(&self, sz col, sz row, String text, Style style) {
	if (row >= self.height) return;

	sz c = col;
	sz i = 0;
	while (i < text.len) {
		if (c >= self.width) break;

		// Decode UTF-8 codepoint to get display width
		uint cp;
		sz char_len = utf8_decode(text[i..], &cp);

		char w = 1;
		if (cp >= 0x2E80) w = 2; // CJK / wide range heuristic
		// Emoji (4-byte codepoints, U+1F300+) are also wide
		if (cp >= 0x1F300u) w = 2;

		Cell cell = new_cell(text[i:char_len], w, style);
		self.set_cell(c, row, cell);
		// Wide cell: write a blank placeholder at c+1 so the renderer
		// doesn't output stale content in the second terminal column.
		if (w == 2 && c + 1 < self.width) {
			self.set_cell(c + 1, row, empty_cell());
		}

		c += w;
		i += char_len;
	}
}

// swap copies current cells into prev_cells for next frame's diff.
// Call this after rendering is complete.
fn void ScreenBuffer.swap(&self) {
	sz total = self.width * self.height;
	for (sz i = 0; i < total; i++) {
		self.prev_cells[i] = self.cells[i];
	}
	for (sz i = 0; i < self.height; i++) {
		self.dirty_lines[i] = false;
	}
	self.full_redraw = false;
}

// needs_redraw returns true if any line is dirty or a full redraw is pending.
fn bool ScreenBuffer.needs_redraw(&self) {
	if (self.full_redraw) return true;
	for (sz i = 0; i < self.height; i++) {
		if (self.dirty_lines[i]) return true;
	}
	return false;
}

// ============================================================
// Diff rendering — emit minimal ANSI to transform prev → current.
// ============================================================

// render_diff writes ANSI escape sequences to `out` that transform
// the previous frame into the current frame. `pen_style` tracks the
// terminal's current SGR state and is updated as styles are emitted.
fn void ScreenBuffer.render_diff(&self, DString* out, Style* pen_style) {
	if (!self.full_redraw) {
		// Check if anything actually changed
		bool any_dirty = false;
		for (sz i = 0; i < self.height; i++) {
			if (self.dirty_lines[i]) {
				any_dirty = true;
				break;
			}
		}
		if (!any_dirty) return;
	}

	if (self.full_redraw) {
		// Full redraw: clear screen, write everything
		out.append_string("\x1b[H\x1b[2J");
		*pen_style = default_style();

		for (sz row = 0; row < self.height; row++) {
			// Move cursor to start of row
			out.append_string(string::tformat("\x1b[%d;1H", row + 1));

			for (sz col = 0; col < self.width; col++) {
				Cell cell = self.cells[row * self.width + col];

				// Emit style diff
				String sgr = cell.style.diff_sgr(*pen_style);
				if (sgr.len > 0) out.append_string(sgr);
				*pen_style = cell.style;

				// Emit cell content
				out.append_string(cell.content_str());

				// Wide cell: skip placeholder in next slot
				if (cell.width == 2) col++;
			}
		}
		self.full_redraw = false;
		return;
	}

	// Differential rendering: only update changed lines/cells
	for (sz row = 0; row < self.height; row++) {
		if (!self.dirty_lines[row]) continue;

		sz line_start = row * self.width;

		// Find the span of changed cells in this line
		sz first_changed = self.width;
		sz last_changed  = 0;
		bool changed     = false;

		for (sz col = 0; col < self.width; col++) {
			sz idx = line_start + col;
			if (!self.cells[idx].eq(self.prev_cells[idx])) {
				if (!changed) {
					first_changed = col;
					changed = true;
				}
				last_changed = col;
			}
		}

		if (!changed) continue;

		// Emit cells in the changed span
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, first_changed + 1));

		for (sz col = first_changed; col <= last_changed; col++) {
			sz idx    = line_start + col;
			Cell cell = self.cells[idx];

			// Style diff
			String sgr = cell.style.diff_sgr(*pen_style);
			if (sgr.len > 0) out.append_string(sgr);
			*pen_style = cell.style;

			// Content
			out.append_string(cell.content_str());

			// Wide cell: the next slot is a blank placeholder that the terminal
			// already advanced past. Skip it so we don't emit a spurious space.
			if (cell.width == 2) col++;
		}
	}
}

// ============================================================
// UTF-8 decode helper
// ============================================================

fn sz utf8_decode(String s, uint* out_cp) {
	if (s.len == 0) {
		*out_cp = 0;
		return 0;
	}

	char b0 = s[0];
	if (b0 < 0x80) {
		*out_cp = (uint)b0;
		return 1;
	} else if ((b0 & 0xE0) == 0xC0) {
		if (s.len < 2) {
			*out_cp = '?';
			return 1;
		}
		*out_cp = ((uint)(b0 & 0x1F) << 6) | (uint)(s[1] & 0x3F);
		return 2;
	} else if ((b0 & 0xF0) == 0xE0) {
		if (s.len < 3) {
			*out_cp = '?';
			return 1;
		}
		*out_cp = ((uint)(b0 & 0x0F) << 12) | ((uint)(s[1] & 0x3F) << 6) | (uint)(s[2] & 0x3F);
		return 3;
	} else if ((b0 & 0xF8) == 0xF0) {
		if (s.len < 4) {
			*out_cp = '?';
			return 1;
		}
		*out_cp = ((uint)(b0 & 0x07) << 18) | ((uint)(s[1] & 0x3F) << 12) | ((uint)(s[2] & 0x3F) << 6)
			| (uint)(s[3] & 0x3F);
		return 4;
	}
	*out_cp = '?';
	return 1;
}

// ============================================================
// ANSI escape sequence parser — renders styled strings into
// the screen buffer. Handles SGR (colors, attributes) and
// basic cursor movement. All other CSI sequences are skipped.
// ============================================================

fn void ScreenBuffer.render_ansi_string(
	&self,
	sz col,
	sz row,
	String text,
	Style start_style,
	sz max_row = 0,
	sz max_col = 0
) {
	if (max_row == 0) max_row = self.height;
	if (max_col == 0) max_col = self.width;
	sz c        = col;
	sz r        = row;
	Style style = start_style;
	sz i        = 0;

	while (i < text.len) {
		// Check for ESC
		if (text[i] == '\x1b') {
			if (i + 1 >= text.len) {
				i++;
				break;
			}

			if (text[i + 1] == ']') {
				// OSC sequence: ESC ] ... ST  (ST = ESC \ or BEL)
				i += 2;
				while (i < text.len) {
					if (text[i] == '\x07') {
						i++;
						break;
					} // BEL terminator
					if (text[i] == '\x1b' && i + 1 < text.len && text[i + 1] == '\\') {
						i += 2;
						break;
					}
					i++;
				}
				continue;
			}

			if (text[i + 1] != '[') {
				i += 2;
				continue;
			} // unknown ESC sequence — skip 2 bytes

			// Parse CSI sequence: ESC [
			i += 2; // skip ESC [
			sz param_start = i;
			// Collect parameter bytes (digits, semicolons, colon)



			while (i < text.len && ((text[i] >= '0' && text[i] <= '9') || text[i] == ';' || text[i] == ':')) {
				i++;
			}
			String params = text[param_start:i - param_start];
			if (i >= text.len) break;

			char final_byte = text[i];
			i++; // consume final byte

			if (final_byte == 'm') {
				// SGR — parse parameters and update style
				style = apply_sgr(params, style);
			} else if (final_byte == 'H') {
				// CUP — cursor position (row;col), 1-indexed
				sz semicolon = 0;
				for (sz s = 0; s < params.len; s++) {
					if (params[s] == ';') {
						semicolon = s;
						break;
					}
				}
				if (semicolon > 0 && params.len > 0) {
					// Parse row and col from "row;col"
					sz row_val = 0;
					sz col_val = 0;
					for (sz s = 0; s < semicolon; s++) {
						if (params[s] >= '0' && params[s] <= '9') {
							row_val = row_val * 10 + (sz)(params[s] - '0');
						}
					}
					for (sz s = semicolon + 1; s < params.len; s++) {
						if (params[s] >= '0' && params[s] <= '9') {
							col_val = col_val * 10 + (sz)(params[s] - '0');
						}
					}
					r = (row_val > 0) ? row_val - 1 : 0;
					c = (col_val > 0) ? col_val - 1 : 0;
				}
			}
			// Other CSI sequences (cursor move, erase, etc.) — skip
			continue;
		}

		// Regular character
		if (text[i] == '\n') {
			r++;
			c = col;
			i++;
			continue;
		}
		if (text[i] == '\r') {
			c = col;
			i++;
			continue;
		}
		if (text[i] == '\t') {
			// Tab: advance to next 8-column boundary
			sz next_tab = (c / 8 + 1) * 8;
			while (c < next_tab && c < self.width) {
				Cell cell = new_cell(" ", 1, style);
				self.set_cell(c, r, cell);
				c++;
			}
			i++;
			continue;
		}

		// Decode UTF-8
		if (r >= max_row) {
			i++;
			continue;
		}

		uint cp;
		sz char_len = utf8_decode(text[i..], &cp);
		if (char_len == 0) break;

		char w = 1;
		if (cp >= 0x2E80) w = 2; // CJK / wide range heuristic
		if (cp >= 0x1F300u) w = 2; // emoji (4-byte, U+1F300+)

		if (c < max_col) {
			Cell cell = new_cell(text[i:char_len], w, style);
			self.set_cell(c, r, cell);
			// Wide cell: slot c+1 is consumed by the second terminal column.
			// Write a blank placeholder so the diff renderer doesn't output
			// the stale content that was there before.
			if (w == 2 && c + 1 < max_col) {
				self.set_cell(c + 1, r, empty_cell());
			}
		}
		c += w;
		i += char_len;
	}
}

// apply_sgr parses SGR parameters and returns the updated style.
fn Style apply_sgr(String params, Style current) @local {
	Style s = current;
	if (params.len == 0) {
		return default_style(); // bare \x1b[m = reset
	}

	sz i = 0;
	while (i < params.len) {
		// Parse one numeric parameter
		int val      = 0;
		bool has_val = false;
		while (i < params.len && params[i] >= '0' && params[i] <= '9') {
			val = val * 10 + (params[i] - '0');
			has_val = true;
			i++;
		}
		if (i < params.len && params[i] == ';') i++;
		if (!has_val) continue;

		// Handle sub-sequences: 38;... (fg extended) and 48;... (bg extended)
		if (val == 38 && i < params.len && params[i] >= '0' && params[i] <= '9') {
			int sub = 0;
			while (i < params.len && params[i] >= '0' && params[i] <= '9') {
				sub = sub * 10 + (params[i] - '0');
				i++;
			}
			if (i < params.len && params[i] == ';') i++;
			if (sub == 5) {
				// 38;5;N — 256-color foreground
				int idx = 0;
				while (i < params.len && params[i] >= '0' && params[i] <= '9') {
					idx = idx * 10 + (params[i] - '0');
					i++;
				}
				if (i < params.len && params[i] == ';') i++;
				s.fg = color_256((char)idx);
			} else if (sub == 2) {
				// 38;2;R;G;B — truecolor foreground
				int r = 0;
				int g = 0;
				int b = 0;
				for (int ch = 0; ch < 3; ch++) {
					int v = 0;
					while (i < params.len && params[i] >= '0' && params[i] <= '9') {
						v = v * 10 + (params[i] - '0');
						i++;
					}
					if (i < params.len && params[i] == ';') i++;
					if (ch == 0) {
						r = v;
					} else if (ch == 1) {
						g = v;
					} else {
						b = v;
					}
				}
				s.fg = color_rgb((char)r, (char)g, (char)b);
			}
			continue;
		}

		if (val == 48 && i < params.len && params[i] >= '0' && params[i] <= '9') {
			int sub = 0;
			while (i < params.len && params[i] >= '0' && params[i] <= '9') {
				sub = sub * 10 + (params[i] - '0');
				i++;
			}
			if (i < params.len && params[i] == ';') i++;
			if (sub == 5) {
				// 48;5;N — 256-color background
				int idx = 0;
				while (i < params.len && params[i] >= '0' && params[i] <= '9') {
					idx = idx * 10 + (params[i] - '0');
					i++;
				}
				if (i < params.len && params[i] == ';') i++;
				s.bg = color_256((char)idx);
			} else if (sub == 2) {
				// 48;2;R;G;B — truecolor background
				int r = 0;
				int g = 0;
				int b = 0;
				for (int ch = 0; ch < 3; ch++) {
					int v = 0;
					while (i < params.len && params[i] >= '0' && params[i] <= '9') {
						v = v * 10 + (params[i] - '0');
						i++;
					}
					if (i < params.len && params[i] == ';') i++;
					if (ch == 0) {
						r = v;
					} else if (ch == 1) {
						g = v;
					} else {
						b = v;
					}
				}
				s.bg = color_rgb((char)r, (char)g, (char)b);
			}
			continue;
		}

		apply_sgr_code(&s, val);
	}
	return s;
}

fn void apply_sgr_code(Style* s, int code) @local {
	switch (code) {
		case 0: *s = default_style();
		case 1: s.attrs.bold = true;
		case 2: s.attrs.dim = true;
		case 3: s.attrs.italic = true;
		case 4: s.attrs.underline = true;
		case 5: s.attrs.blink = true;
		case 7: s.attrs.reverse = true;
		case 9: s.attrs.strikethrough = true;
		case 22: s.attrs.bold = false; s.attrs.dim = false;
		case 23: s.attrs.italic = false;
		case 24: s.attrs.underline = false;
		case 25: s.attrs.blink = false;
		case 27: s.attrs.reverse = false;
		case 29: s.attrs.strikethrough = false;
		// Foreground: basic 8
		case 30: s.fg = color_ansi(0);
		case 31: s.fg = color_ansi(1);
		case 32: s.fg = color_ansi(2);
		case 33: s.fg = color_ansi(3);
		case 34: s.fg = color_ansi(4);
		case 35: s.fg = color_ansi(5);
		case 36: s.fg = color_ansi(6);
		case 37: s.fg = color_ansi(7);
		case 39: s.fg = color_none();  // default fg
		// Background: basic 8
		case 40: s.bg = color_ansi(0);
		case 41: s.bg = color_ansi(1);
		case 42: s.bg = color_ansi(2);
		case 43: s.bg = color_ansi(3);
		case 44: s.bg = color_ansi(4);
		case 45: s.bg = color_ansi(5);
		case 46: s.bg = color_ansi(6);
		case 47: s.bg = color_ansi(7);
		case 49: s.bg = color_none();  // default bg
		// Foreground: bright 8
		case 90: s.fg = color_ansi(8);
		case 91: s.fg = color_ansi(9);
		case 92: s.fg = color_ansi(10);
		case 93: s.fg = color_ansi(11);
		case 94: s.fg = color_ansi(12);
		case 95: s.fg = color_ansi(13);
		case 96: s.fg = color_ansi(14);
		case 97: s.fg = color_ansi(15);
		// Background: bright 8
		case 100: s.bg = color_ansi(8);
		case 101: s.bg = color_ansi(9);
		case 102: s.bg = color_ansi(10);
		case 103: s.bg = color_ansi(11);
		case 104: s.bg = color_ansi(12);
		case 105: s.bg = color_ansi(13);
		case 106: s.bg = color_ansi(14);
		case 107: s.bg = color_ansi(15);
		default:
		// Ignore unrecognized codes (e.g., 38;5;N, 48;2;R;G;B are
		// handled by a sub-parser below — TODO for future enhancement)
	}
}

// ============================================================
// Rect-based drawing operations
// ============================================================

// fill_rect fills a rectangle in the screen buffer with a space cell using the given style.
fn void ScreenBuffer.fill_rect(&self, Rect r, Style style) {
	if (r.w <= 0 || r.h <= 0) return;
	int x0 = r.x < 0 ? 0 : r.x;
	int y0 = r.y < 0 ? 0 : r.y;
	int x1 = r.x + r.w;
	int y1 = r.y + r.h;
	if (x1 > (int)self.width) x1 = (int)self.width;
	if (y1 > (int)self.height) y1 = (int)self.height;
	if (x0 >= x1 || y0 >= y1) return;

	for (int row = y0; row < y1; row++) {
		for (int col = x0; col < x1; col++) {
			self.set_cell((sz)col, (sz)row, new_cell(" ", 1, style));
		}
	}
}

// draw_string_in_rect draws a plain (no ANSI) string into a rectangle, wrapping at r.w, clipping at r.h.
// Each \n in text or when a line exceeds r.w advances to the next row.
fn void ScreenBuffer.draw_string_in_rect(&self, Rect r, String text, Style style) {
	if (r.w <= 0 || r.h <= 0) return;
	sz col = 0;
	sz row = 0;
	sz i   = 0;

	while (i < text.len && row < (sz)r.h) {
		if (text[i] == '\n') {
			row++;
			col = 0;
			i++;
			continue;
		}

		uint cp;
		sz char_len = utf8_decode(text[i..], &cp);
		if (char_len == 0) break;

		char w = 1;
		if (cp >= 0x2E80) w = 2;

		if (col + (sz)w > (sz)r.w) {
			row++;
			col = 0;
			if (row >= (sz)r.h) break;
		}

		Cell cell = new_cell(text[i:char_len], w, style);
		self.set_cell((sz)r.x + col, (sz)r.y + row, cell);
		col += (sz)w;
		i += char_len;
	}
}

// ============================================================
// Debug helpers
// ============================================================

// render_frame returns a plain-text snapshot of the screen buffer,
// one row per line, cell content concatenated with no ANSI escapes.
// Wide cells (width=2) emit their content once; their neighbour slot
// (which holds an empty placeholder) emits nothing, preserving column
// alignment so the output matches what the terminal would display.
// Useful for writing render tests without a real terminal.
fn String ScreenBuffer.render_frame(&self) {
	DString out = dstring::temp();
	for (sz row = 0; row < self.height; row++) {
		sz col = 0;
		while (col < self.width) {
			Cell* cell = &self.cells[row * self.width + col];
			if (cell.width == 2 && col + 1 < self.width) {
				// Wide cell: emit content, skip the placeholder slot
				out.append_string(cell.content_str());
				col += 2;
			} else {
				out.append_string(cell.content_str());
				col++;
			}
		}
		out.append_char('\n');
	}
	return out.str_view();
}

// render_frame_row returns a plain-text snapshot of a single row.
fn String ScreenBuffer.render_frame_row(&self, sz row) {
	DString out = dstring::temp();
	if (row >= self.height) return out.str_view();
	sz col = 0;
	while (col < self.width) {
		Cell* cell = &self.cells[row * self.width + col];
		if (cell.width == 2 && col + 1 < self.width) {
			out.append_string(cell.content_str());
			col += 2;
		} else {
			out.append_string(cell.content_str());
			col++;
		}
	}
	return out.str_view();
}

// render_diff_str is a convenience wrapper: runs render_diff into a temp
// DString and returns the raw escape sequence output as a string.
// Useful for asserting that specific ANSI sequences are (or aren't) emitted.
fn String ScreenBuffer.render_diff_str(&self) {
	DString out = dstring::temp();
	Style pen   = default_style();
	self.render_diff(&out, &pen);
	return out.str_view();
}

// blit composites src ScreenBuffer onto self at (dst_x, dst_y).
// If transparent is true, skip src cells where content is ' ' (space, 0x20) AND bg is ColorKind.NONE.
fn void ScreenBuffer.blit(&self, sz dst_x, sz dst_y, ScreenBuffer* src, bool transparent) {
	for (sz row = 0; row < src.height; row++) {
		for (sz col = 0; col < src.width; col++) {
			Cell c = src.cells[row * src.width + col];
			if (transparent) {
				// Skip if content is space AND bg is NONE
				if (c.content_len == 1 && c.content[0] == ' ' && c.style.bg.kind == ColorKind.NONE) continue;
			}
			sz dx = dst_x + col;
			sz dy = dst_y + row;
			self.set_cell(dx, dy, c);
		}
	}
}

// blit_ansi parses an ANSI string into a temporary ScreenBuffer of size (w, h), then blits it onto self at (dst_x, dst_y).
// This is a convenience wrapper for the "render glaze → overlay on xray canvas" pattern.
fn void ScreenBuffer.blit_ansi(&self, sz dst_x, sz dst_y, sz w, sz h, String ansi_text, bool transparent) {
	// Allocate a temporary ScreenBuffer on the heap
	ScreenBuffer* tmp = new_screen_buffer(w, h);
	defer {
		tmp.destroy();
		mem::free(tmp);
	}
	// Parse the ANSI string into the tmp buffer
	tmp.render_ansi_string(0, 0, ansi_text, default_style());
	// Blit tmp onto self
	self.blit(dst_x, dst_y, tmp, transparent);
}