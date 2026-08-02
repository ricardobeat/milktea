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

// fill_empty fills `width * height` cells with empty_cell().
//
// empty_cell() is NOT all-zero bytes (content[0]=' ', content_len=1,
// width=1), so mem::set(0) would corrupt the grid. Instead the first row is
// written cell-by-cell and then block-copied across the remaining rows.
// A zero-sized grid is a no-op: mem::new_array yields a null pointer for
// length 0, and mem::copy rejects null.
fn void fill_empty(Cell[] cells, sz width, sz height) @local {
	if (width <= 0 || height <= 0) return;
	Cell empty = empty_cell();
	Cell* row0 = cells.ptr;
	for (sz i = 0; i < width; i++) {
		row0[i] = empty;
	}
	sz row_bytes = width * Cell::size;
	for (sz row = 1; row < height; row++) {
		mem::copy(cells.ptr + row * width, row0, row_bytes);
	}
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

	fill_empty(sb.cells, width, height);
	if (total > 0) mem::copy(sb.prev_cells.ptr, sb.cells.ptr, total * Cell::size);
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
	sz new_total = width * height;

	Cell[] new_cells = mem::new_array(Cell, new_total);
	Cell[] new_prev  = mem::new_array(Cell, new_total);
	bool[] new_dirty = mem::new_array(bool, height);

	fill_empty(new_cells, width, height);
	if (new_total > 0) mem::copy(new_prev.ptr, new_cells.ptr, new_total * Cell::size);
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
	fill_empty(self.cells, self.width, self.height);
	// bool true != 0 in general; keep explicit loop to be safe.
	for (sz i = 0; i < self.height; i++) {
		self.dirty_lines[i] = true;
	}
}

// clear_range clears only rows [start_row, end_row) to empty and marks them dirty.
fn void ScreenBuffer.clear_range(&self, sz start_row, sz end_row) {
	if (start_row < 0) start_row = 0;
	if (start_row >= self.height) return;
	if (end_row > self.height) end_row = self.height;
	Cell empty = empty_cell();
	for (sz row = start_row; row < end_row; row++) {
		sz base = row * self.width;
		for (sz col = 0; col < self.width; col++) {
			self.cells[base + col] = empty;
		}
		self.dirty_lines[row] = true;
	}
}

// cell_at returns a pointer to the cell at (col, row), or null if out of bounds.
fn Cell* ScreenBuffer.cell_at(&self, sz col, sz row) {
	if (col < 0 || row < 0 || col >= self.width || row >= self.height) return null;
	return &self.cells[row * self.width + col];
}

// is_block_char returns true if the cell's content is a Unicode block
// element (U+2580–U+259F). These characters fill the cell visually
// with their fg color, so fg acts as the effective background.
fn bool is_block_char(Cell* cell) @local {
	uint cp;
	utf8_decode(cell.content_str(), &cp);
	return cp >= 0x2580 && cp <= 0x259F;
}

// put_raw_cell writes a cell with no colour compositing and no wide-pair
// repair. Reserved for callers that are placing both halves of a wide glyph
// themselves and must not have the pair torn apart mid-write.
fn void ScreenBuffer.put_raw_cell(&self, sz col, sz row, Cell cell) {
	if (col < 0 || row < 0 || col >= self.width || row >= self.height) return;
	sz idx = row * self.width + col;
	if (!self.cells[idx].eq(cell)) {
		self.cells[idx] = cell;
		self.dirty_lines[row] = true;
	}
}

// split_wide_neighbors repairs the wide-glyph pairings around (col, row)
// before a cell of display width `incoming_width` is written there.
//
// A wide glyph owns two columns: the leading cell (width 2) plus a blank
// placeholder. The renderer skips the column following a width-2 cell, so a
// half-overwritten pair either swallows the new write or leaves the cursor
// addressed mid-glyph. Both halves are therefore normalised here:
//   - writing into a trailing half demotes the orphaned leading half to a blank
//   - replacing a leading half with a narrow cell releases its placeholder
//
// The blank inherits the neighbour's style so clearing a glyph doesn't punch a
// default-coloured hole through a styled background.
fn void ScreenBuffer.split_wide_neighbors(&self, sz col, sz row, char incoming_width) {
	sz idx = row * self.width + col;

	if (col > 0) {
		Cell* left = &self.cells[idx - 1];
		if (left.width == 2) {
			Style keep = left.style;
			*left = empty_cell();
			left.style = keep;
			self.dirty_lines[row] = true;
		}
	}

	if (self.cells[idx].width == 2 && incoming_width != 2 && col + 1 < self.width) {
		Cell* right = &self.cells[idx + 1];
		Cell blank = empty_cell();
		blank.style = right.style;
		if (!right.eq(blank)) {
			*right = blank;
			self.dirty_lines[row] = true;
		}
	}
}

// set_cell writes a cell at (col, row). Marks the line dirty if
// the new cell differs from what's already there.
// Channels set to TRANSPARENT inherit from the existing cell —
// the new cell's content and fg are written, but the bg (or fg)
// that was already in the buffer is preserved.
// For block characters whose bg is NONE, the fg is used instead,
// since block glyphs fill the cell with their foreground color.
fn void ScreenBuffer.set_cell(&self, sz col, sz row, Cell cell) {
	// sz is signed: negative coordinates must be rejected explicitly, or they
	// index before the buffer (a trap in safe builds, silent heap corruption
	// in the -Os/-O3 example targets).
	if (col < 0 || row < 0 || col >= self.width || row >= self.height) return;
	sz idx = row * self.width + col;
	if (cell.style.bg.kind == ColorKind.TRANSPARENT) {
		Cell* existing = &self.cells[idx];
		if (existing.style.bg.kind == ColorKind.NONE && is_block_char(existing)) {
			cell.style.bg = existing.style.fg;
		} else {
			cell.style.bg = existing.style.bg;
		}
	} else if (cell.style.bg.kind == ColorKind.TRUECOLOR && cell.style.bg.effective_alpha() < 255) {
		cell.style.bg = cell.style.bg.blend_over(self.cells[idx].style.bg);
	}
	if (cell.style.fg.kind == ColorKind.TRANSPARENT) {
		cell.style.fg = self.cells[idx].style.fg;
	} else if (cell.style.fg.kind == ColorKind.TRUECOLOR && cell.style.fg.effective_alpha() < 255) {
		cell.style.fg = cell.style.fg.blend_over(self.cells[idx].style.fg);
	}
	self.split_wide_neighbors(col, row, cell.width);

	if (!self.cells[idx].eq(cell)) {
		self.cells[idx] = cell;
		self.dirty_lines[row] = true;
	}
}

// overlay_char renders text into exactly one cell slot at (col, row).
// Supports ANSI escape sequences (SGR color/style). Neighbors are never
// touched — wide chars occupy one slot visually without shifting anything.
fn void ScreenBuffer.overlay_char(&self, sz col, sz row, String text, Style base_style) {
	if (col < 0 || row < 0 || col >= self.width || row >= self.height || text.len == 0) return;
	// Parse through a stack-allocated 2x1 scratch buffer so ANSI sequences
	// are handled without any heap allocation. render_ansi_string only reads
	// width/height and writes into cells[]/dirty_lines[] — it never resizes,
	// frees, or escapes the buffer pointer, so a stack instance is safe.
	// We only care about the cell at (0,0) of the scratch.
	Cell[2] scratch_cells;
	Cell[2] scratch_prev;
	bool[1] scratch_dirty;
	scratch_cells[0] = empty_cell();
	scratch_cells[1] = empty_cell();
	scratch_prev[0]  = empty_cell();
	scratch_prev[1]  = empty_cell();
	scratch_dirty[0] = true;
	ScreenBuffer tmp = {
		.cells       = scratch_cells[..],
		.prev_cells  = scratch_prev[..],
		.dirty_lines = scratch_dirty[..],
		.width       = 2,
		.height      = 1,
	};
	tmp.render_ansi_string(0, 0, text, base_style, 1, 2);
	Cell c = tmp.cells[0];
	// If nothing was written (e.g. empty/null string), bail out.
	if (c.content_len == 0 || (c.content_len == 1 && c.content[0] == ' ' && c.style.is_empty())) return;
	self.set_cell(col, row, c);
}

// set_string writes a string starting at (col, row) with the given style.
// Advances col by each character's display width.
fn void ScreenBuffer.set_string(&self, sz col, sz row, String text, Style style) {
	if (row < 0 || row >= self.height) return;

	sz c = col;
	sz i = 0;
	while (i < text.len) {
		if (c >= self.width) break;

		// Decode UTF-8 codepoint to get display width
		uint cp;
		sz char_len = utf8_decode(text[i..], &cp);

		int cw = char_width(cp);

		// Zero-width codepoint (combining mark, variation selector, etc.):
		// append its bytes to the previous cell so the terminal can render
		// it as a composed glyph. Only append if there is a previous cell
		// and the combined byte count still fits in CELL_MAX_BYTES.
		// If there is no prior cell or no room, skip silently — dropping a
		// combining mark is far less disruptive than shifting every following
		// cell by one column.
		if (cw == 0) {
			if (c > col && c > 0) {
				Cell* prev_cell = &self.cells[row * self.width + (c - 1)];
				sz available = CELL_MAX_BYTES - (sz)prev_cell.content_len;
				if (char_len <= available) {
					for (sz bi = 0; bi < char_len; bi++) {
						prev_cell.content[(sz)prev_cell.content_len + bi] = text[i + bi];
					}
					prev_cell.content_len = (char)((sz)prev_cell.content_len + char_len);
					self.dirty_lines[row] = true;
				}
				// else: no room — drop the combining mark silently
			}
			// else: no previous cell in this row — drop silently
			i += char_len;
			continue;
		}

		char w = (char)cw;
		if (w == 2 && c + 1 >= self.width) {
			// A wide glyph needs two columns; only one is left. Emitting it
			// would make the terminal wrap or truncate, desyncing our column
			// accounting from the display. Write a space instead.
			self.set_cell(c, row, new_cell(" ", 1, style));
			break;
		}
		Cell cell = new_cell(text[i:char_len], w, style);
		self.set_cell(c, row, cell);
		// Wide cell: write a blank placeholder at c+1 so the renderer doesn't
		// output stale content in the second terminal column. This is the
		// glyph's own trailing half, so it must bypass the wide-pair repair —
		// otherwise it would demote the leading half we just wrote.
		if (w == 2) {
			self.put_raw_cell(c + 1, row, empty_cell());
		}

		c += w;
		i += char_len;
	}
}

// swap copies current cells into prev_cells for next frame's diff.
// Call this after rendering is complete.
fn void ScreenBuffer.swap(&self) {
	sz total = self.width * self.height;
	// Bulk copy the entire cell grid in one operation.
	mem::copy(self.prev_cells.ptr, self.cells.ptr, total * Cell::size);
	// bool false == 0, so memset is safe here.
	mem::set(self.dirty_lines.ptr, 0, self.height * bool::size);
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
				// Update pen — skip TRANSPARENT channels so they don't
				// overwrite the terminal's current state.
				if (cell.style.fg.kind != ColorKind.TRANSPARENT) pen_style.fg = cell.style.fg;
				if (cell.style.bg.kind != ColorKind.TRANSPARENT) pen_style.bg = cell.style.bg;
				pen_style.attrs = cell.style.attrs;
				pen_style.underline_color = cell.style.underline_color;

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
			// Update pen — skip TRANSPARENT channels
			if (cell.style.fg.kind != ColorKind.TRANSPARENT) pen_style.fg = cell.style.fg;
			if (cell.style.bg.kind != ColorKind.TRANSPARENT) pen_style.bg = cell.style.bg;
			pen_style.attrs = cell.style.attrs;
			pen_style.underline_color = cell.style.underline_color;

			// Content
			out.append_string(cell.content_str());

			// Wide cell: the next slot is a blank placeholder that the terminal
			// already advanced past. Skip it so we don't emit a spurious space.
			if (cell.width == 2) col++;
		}
	}
}

// render_ansi converts the entire cell grid to a flat ANSI string.
// Unlike render_diff, this produces inline output with no cursor positioning —
// suitable for returning from a view() function.
fn String ScreenBuffer.render_ansi(&self) {
	DString out = dstring::temp();
	Style pen = default_style();

	for (sz row = 0; row < self.height; row++) {
		if (row > 0) out.append_char('\n');
		sz line_start = row * self.width;
		for (sz col = 0; col < self.width; col++) {
			Cell cell = self.cells[line_start + col];
			String sgr = cell.style.diff_sgr(pen);
			if (sgr.len > 0) out.append_string(sgr);
			// Update pen — skip TRANSPARENT channels
			if (cell.style.fg.kind != ColorKind.TRANSPARENT) pen.fg = cell.style.fg;
			if (cell.style.bg.kind != ColorKind.TRANSPARENT) pen.bg = cell.style.bg;
			pen.attrs = cell.style.attrs;
			pen.underline_color = cell.style.underline_color;
			out.append_string(cell.content_str());
			if (cell.width == 2) col++;
		}
	}
	// Reset at end so trailing state doesn't leak
	if (!pen.is_empty()) out.append_string("\x1b[0m");
	return out.copy_str(tmem);
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

		int cw = char_width(cp);

		// Zero-width codepoint: append combining bytes to previous cell if room.
		// See set_string for the full rationale.
		if (cw == 0) {
			if (c > (sz)col) {
				Cell* prev_cell = &self.cells[r * self.width + (c - 1)];
				sz available = CELL_MAX_BYTES - (sz)prev_cell.content_len;
				if (char_len <= available) {
					for (sz bi = 0; bi < char_len; bi++) {
						prev_cell.content[(sz)prev_cell.content_len + bi] = text[i + bi];
					}
					prev_cell.content_len = (char)((sz)prev_cell.content_len + char_len);
					self.dirty_lines[r] = true;
				}
			}
			i += char_len;
			continue;
		}

		char w = (char)cw;
		if (c < max_col) {
			Cell cell = new_cell(text[i:char_len], w, style);
			self.set_cell(c, r, cell);
			// Wide cell: slot c+1 is consumed by the second terminal column.
			// Write a blank placeholder so the diff renderer doesn't output
			// the stale content that was there before.
			if (w == 2 && c + 1 < max_col) {
				self.put_raw_cell(c + 1, r, empty_cell());
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

		char w = (char)char_width(cp);
		// Zero-width marks don't advance; treat as width 1 for wrapping
		// purposes (they'll be appended to the previous cell's bytes, or
		// dropped if there's no room — same policy as set_string).
		if (w == 0) {
			if (col > 0) {
				// Append combining bytes to the cell we just wrote, if room.
				sz abs_col = (sz)r.x + col - 1;
				sz abs_row = (sz)r.y + row;
				if (abs_col >= 0 && abs_row >= 0 && abs_col < self.width && abs_row < self.height) {
					Cell* prev_cell = &self.cells[abs_row * self.width + abs_col];
					sz available = CELL_MAX_BYTES - (sz)prev_cell.content_len;
					if (char_len <= available) {
						for (sz bi = 0; bi < char_len; bi++) {
							prev_cell.content[(sz)prev_cell.content_len + bi] = text[i + bi];
						}
						prev_cell.content_len = (char)((sz)prev_cell.content_len + char_len);
						self.dirty_lines[abs_row] = true;
					}
				}
			}
			i += char_len;
			continue;
		}

		if (col + (sz)w > (sz)r.w) {
			row++;
			col = 0;
			if (row >= (sz)r.h) break;
		}

		Cell cell = new_cell(text[i:char_len], w, style);
		self.set_cell((sz)r.x + col, (sz)r.y + row, cell);
		// Wide glyph: claim its trailing column so the diff renderer doesn't
		// emit stale content there. Bypasses the wide-pair repair, as this is
		// the glyph's own second half.
		if (w == 2) {
			self.put_raw_cell((sz)r.x + col + 1, (sz)r.y + row, empty_cell());
		}
		col += (sz)w;
		i += char_len;
	}
}

// ============================================================
// Border drawing
// ============================================================

struct Border {
	String top_left;
	String top;
	String top_right;
	String left;
	String right;
	String bottom_left;
	String bottom;
	String bottom_right;
}

fn Border rounded_border() {
	return {
		.top_left = "╭", .top = "─", .top_right = "╮",
		.left = "│", .right = "│",
		.bottom_left = "╰", .bottom = "─", .bottom_right = "╯",
	};
}

fn Border normal_border() {
	return {
		.top_left = "┌", .top = "─", .top_right = "┐",
		.left = "│", .right = "│",
		.bottom_left = "└", .bottom = "─", .bottom_right = "┘",
	};
}

// draw_border draws border characters around rect r into the screen buffer
// using the given style, and returns the inner rect (r inset by 1 on all sides).
fn Rect ScreenBuffer.draw_border(&self, Rect r, Border b, Style style) {
	if (r.w < 2 || r.h < 2) return r;

	sz x0 = (sz)r.x;
	sz y0 = (sz)r.y;
	sz x1 = (sz)(r.x + r.w - 1);
	sz y1 = (sz)(r.y + r.h - 1);

	// Top row
	DString top = dstring::temp();
	top.append_string(b.top_left);
	for (int i = 0; i < r.w - 2; i++) top.append_string(b.top);
	top.append_string(b.top_right);
	self.set_string(x0, y0, top.str_view(), style);

	// Bottom row
	DString bot = dstring::temp();
	bot.append_string(b.bottom_left);
	for (int i = 0; i < r.w - 2; i++) bot.append_string(b.bottom);
	bot.append_string(b.bottom_right);
	self.set_string(x0, y1, bot.str_view(), style);

	// Left and right sides
	for (sz row = y0 + 1; row < y1; row++) {
		self.set_string(x0, row, b.left, style);
		self.set_string(x1, row, b.right, style);
	}

	return new_rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2);
}

// ============================================================
// Gradient drawing
// ============================================================

fn char lerp_u8(char a, char b, int t, int max_t) @local {
	if (max_t <= 0) return a;
	return (char)(((int)a * (max_t - t) + (int)b * t) / max_t);
}

fn Color lerp_color(Color a, Color b, int t, int max_t) @local {
	return color_rgb(lerp_u8(a.r, b.r, t, max_t), lerp_u8(a.g, b.g, t, max_t), lerp_u8(a.b, b.b, t, max_t));
}

// fill_gradient_v sets the background of every cell in r to a vertical
// gradient from c1 (top) to c2 (bottom). Call after content is drawn so
// text cells keep their foreground but gain the gradient background.
fn void ScreenBuffer.fill_gradient_v(&self, Rect r, Color c1, Color c2) {
	if (r.w <= 0 || r.h <= 0) return;
	int max_t = r.h > 1 ? r.h - 1 : 1;
	for (int row = 0; row < r.h; row++) {
		int abs_row = r.y + row;
		if (abs_row < 0 || (sz)abs_row >= self.height) continue;
		Color c = lerp_color(c1, c2, row, max_t);
		for (int col = 0; col < r.w; col++) {
			int abs_col = r.x + col;
			if (abs_col < 0 || (sz)abs_col >= self.width) continue;
			self.cells[(sz)abs_row * self.width + (sz)abs_col].style.bg = c;
		}
	}
}

// draw_gradient_border draws a rounded border whose colour interpolates
// vertically from c1 (top) to c2 (bottom). Returns the inner rect.
fn Rect ScreenBuffer.draw_gradient_border(&self, Rect r, Border b, Color c1, Color c2) {
	if (r.w < 2 || r.h < 2) return r;
	sz x0 = (sz)r.x;
	sz y0 = (sz)r.y;
	sz x1 = (sz)(r.x + r.w - 1);
	sz y1 = (sz)(r.y + r.h - 1);
	int max_t = r.h > 1 ? r.h - 1 : 1;

	// Top row: c1
	DString top = dstring::temp();
	top.append_string(b.top_left);
	for (int i = 0; i < r.w - 2; i++) top.append_string(b.top);
	top.append_string(b.top_right);
	self.set_string(x0, y0, top.str_view(), (Style){ .fg = c1 });

	// Bottom row: c2
	DString bot = dstring::temp();
	bot.append_string(b.bottom_left);
	for (int i = 0; i < r.w - 2; i++) bot.append_string(b.bottom);
	bot.append_string(b.bottom_right);
	self.set_string(x0, y1, bot.str_view(), (Style){ .fg = c2 });

	// Sides: interpolate per row
	for (sz row = y0 + 1; row < y1; row++) {
		Color c = lerp_color(c1, c2, (int)(row - y0), max_t);
		Style sty = { .fg = c };
		self.set_string(x0, row, b.left, sty);
		self.set_string(x1, row, b.right, sty);
	}

	return new_rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2);
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
// Cells with TRANSPARENT bg or fg are always skipped — they inherit from the destination.
fn void ScreenBuffer.blit(&self, sz dst_x, sz dst_y, ScreenBuffer* src, bool transparent) {
	for (sz row = 0; row < src.height; row++) {
		for (sz col = 0; col < src.width; col++) {
			Cell c = src.cells[row * src.width + col];
			// Always skip TRANSPARENT cells — they mean "keep what's underneath"
			if (c.style.bg.kind == ColorKind.TRANSPARENT || c.style.fg.kind == ColorKind.TRANSPARENT) continue;
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