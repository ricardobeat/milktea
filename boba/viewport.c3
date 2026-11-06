module boba;

import milktea;
import xray;
import glaze;
import std::core::dstring;
import std::core::mem;
import std::math;
import std::collections::list;

struct Viewport (xray::Content) {
	sz offset;
	sz width;
	sz height;
	sz total_lines;
	std::collections::list::List{String} lines;
	bool mouse_wheel_enabled;
	bool show_scrollbar;
	glaze::Style content_style;
	glaze::Style track_style;
	glaze::Style thumb_style;

	// Selection state
	bool sel_active;
	sz sel_start_row;
	sz sel_start_col;
	sz sel_end_row;
	sz sel_end_col;
	bool has_selection;
	glaze::Style selection_style;

	// Smooth scrolling in a window: the scroll position in layout units
	// (pixels), of which offset is the whole rows. It can run past either end
	// while a trackpad gesture pulls it there, and springs back after.
	float pos_px;
	bool springing;
	float spring_from;
	long spring_start_ms;
}

// How far a trackpad can pull the content past an end, as a share of the
// viewport's height, and how quickly it springs back (ms per 1/e).
const float OVERSCROLL_SHARE @private = 0.25f;
const float SPRING_MS @private = 70.0f;

fn Viewport new_viewport(sz width, sz height) {
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

fn void Viewport.set_content(&self, sz total_lines) {
	self.total_lines = total_lines;
	sz max_offset = self.total_lines - self.height;
	if (max_offset < 0) max_offset = 0;
	if (self.offset > max_offset) self.offset = max_offset;
}

fn void Viewport.add_line(&self, String line) {
	if (!self.lines.is_initialized()) self.lines.init(mem);
	self.lines.push(line);
	self.total_lines = (sz)self.lines.len();
}

fn void Viewport.set_lines(&self, String[] src) {
	if (!self.lines.is_initialized()) self.lines.init(mem);
	self.lines.clear();
	self.lines.push_all(src);
	self.total_lines = (sz)self.lines.len();
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
	sz max_offset = self.total_lines - self.height;
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
	sz max_offset = self.total_lines - self.height;
	if (max_offset < 0) max_offset = 0;
	if (self.offset > max_offset) self.offset = max_offset;
}

// scroll_to_top scrolls to the beginning.
fn void Viewport.scroll_to_top(&self) {
	self.offset = 0;
}

// scroll_to_bottom scrolls to the end.
fn void Viewport.scroll_to_bottom(&self) {
	sz max_offset = self.total_lines - self.height;
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

// view_line_start and view_line_end give the visible line indices [start, end).
fn sz Viewport.view_line_start(&self) {
	return self.offset;
}

fn sz Viewport.view_line_end(&self) {
	sz end = self.offset + self.height;
	if (end > self.total_lines) end = self.total_lines;
	return end;
}

// handle_mouse_msg processes mouse events: scroll wheel and text selection.
fn bool Viewport.handle_mouse_msg(&self, milktea::MouseMsg msg) {
	// Scrollbar occupies the rightmost 3 chars; don't select if clicking there
	bool has_bar = self.show_scrollbar && self.total_lines > self.height;
	sz text_w = self.width - (has_bar ? 3 : 0);
	if (text_w < 1) text_w = 1;

	bool is_scrollbar_area = has_bar && msg.col >= text_w;

	// A window reports how far the scroll really went, and where a trackpad
	// gesture is; scroll by exactly that.
	if (milktea::layout_metrics().pixels
			&& (msg.scroll_dy != 0 || msg.action == milktea::MouseAction.MOUSE_SCROLL_PHASE)) {
		self.scroll_pixels(msg.scroll_dy, msg.scroll_precise, msg.scroll_phase);
		return true;
	}

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
		sz content_row = self.offset + msg.row;
		sz content_col = msg.col;

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
// ── smooth scrolling ─────────────────────────────────────────────────────────

fn float Viewport.row_px(&self) => (float)milktea::layout_metrics().unit_h();

fn float Viewport.max_px(&self) {
	sz rows = self.total_lines - self.height;
	return rows > 0 ? (float)rows * self.row_px() : 0.0f;
}

// position is the scroll position in pixels, taken from offset when the row
// methods (scroll_down, page_up, ...) moved it since the last pixel scroll.
fn float Viewport.position(&self) {
	float row = self.row_px();
	if ((sz)math::floor(self.pos_px / row) != self.offset) self.pos_px = (float)self.offset * row;
	return self.pos_px;
}

fn void Viewport.set_position(&self, float px) {
	self.pos_px = px;
	self.offset = (sz)math::floor(px / self.row_px());
}

fn float clampf(float v, float lo, float hi) @private => v < lo ? lo : v > hi ? hi : v;

// scroll_pixels moves the content by dy layout units (positive towards the
// start), as a trackpad reports it: exactly, past the ends with growing
// resistance while the gesture lasts, and springing back when it ends. A
// device without precise deltas (a wheel) stays within the content.
fn void Viewport.scroll_pixels(&self, float dy, bool precise, milktea::ScrollPhase phase) {
	float pos = self.position();
	float max = self.max_px();
	float delta = -dy;
	self.springing = false;
	if (!precise) {
		self.set_position(clampf(pos + delta, 0, max));
		return;
	}
	float limit = (float)self.height * self.row_px() * OVERSCROLL_SHARE;
	if (limit < 1) limit = 1;
	float over = pos < 0 ? -pos : pos > max ? pos - max : 0;
	bool outward = (pos <= 0 && delta < 0) || (pos >= max && delta > 0);
	if (outward) {
		// The further out, the less the content follows the fingers.
		float give = 1.0f - over / limit;
		delta *= give > 0 ? give * 0.5f : 0;
	}
	pos += delta;
	self.set_position(pos);
	bool out = pos < 0 || pos > max;
	bool settling = phase == milktea::ScrollPhase.ENDED || phase == milktea::ScrollPhase.MOMENTUM_ENDED
		|| (phase == milktea::ScrollPhase.MOMENTUM && out);
	if (out && settling) {
		self.springing = true;
		self.spring_from = pos;
		self.spring_start_ms = milktea::frame_ms();
	}
}

// settle moves a springing viewport towards the nearest end it ran past.
fn void Viewport.settle(&self) {
	if (!self.springing) return;
	float target = clampf(self.pos_px, 0, self.max_px());
	float t = (float)(milktea::frame_ms() - self.spring_start_ms);
	float pos = target + (self.spring_from - target) * math::exp(-t / SPRING_MS);
	if (math::abs(pos - target) < 0.5f) {
		pos = target;
		self.springing = false;
	}
	self.set_position(pos);
}

fn void Viewport.scroll_by(&self, sz lines) {
	if (lines < 0) {
		for (sz i = 0; i < -lines; i++) self.scroll_up();
	} else {
		for (sz i = 0; i < lines; i++) self.scroll_down();
	}
}

// base64_encode lives in milktea, where the image writer can share it.
alias base64_encode = milktea::base64_encode;

// Selection is a selection range normalized so start comes before end in
// reading order, whichever direction the drag went in.
struct Selection {
	sz start_row;
	sz start_col;
	sz end_row;
	sz end_col;
}

fn Selection Viewport.selection(&self) {
	Selection s = {
		.start_row = self.sel_start_row,
		.start_col = self.sel_start_col,
		.end_row   = self.sel_end_row,
		.end_col   = self.sel_end_col,
	};
	if (s.start_row > s.end_row || (s.start_row == s.end_row && s.start_col > s.end_col)) {
		sz tr = s.start_row;
		sz tc = s.start_col;
		s.start_row = s.end_row;
		s.start_col = s.end_col;
		s.end_row = tr;
		s.end_col = tc;
	}
	return s;
}

// column_to_byte maps a display column to the byte index where that column
// starts in line, clamped to its length. Selection columns come from mouse
// positions and count display columns, so slicing a line by them directly
// lands in the middle of a multi-byte or wide glyph.
fn sz column_to_byte(String line, sz col) @local {
	if (col <= 0) return 0;
	sz w = 0;
	sz i = 0;
	while (i < line.len) {
		sz next = utf8_next_boundary(line, i);
		sz cw   = glaze::string_width(line[i:next - i]);
		if (w + cw > col) break;
		w += cw;
		i = next;
	}
	return i;
}

// get_selected_text extracts the text between sel_start and sel_end (content coordinates).
fn String Viewport.get_selected_text(&self) {
	if (!self.has_selection) return "";

	Selection sel = self.selection();
	sz first      = sel.start_row < 0 ? 0 : sel.start_row;

	DString out = dstring::temp();
	for (sz row = first; row <= sel.end_row && row < self.total_lines; row++) {
		String line  = self.lines[row];
		sz col_start = row == sel.start_row ? column_to_byte(line, sel.start_col) : 0;
		sz col_end   = row == sel.end_row ? column_to_byte(line, sel.end_col) : (sz)line.len;

		if (col_end > (sz)line.len) col_end = (sz)line.len;
		if (col_end < col_start) col_end = col_start;

		if (col_end > col_start) {
			out.append_string(line[col_start:col_end - col_start]);
		}

		if (row < sel.end_row) out.append_char('\n');
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
fn bool Viewport.is_in_selection(&self, sz row, sz col) {
	if (!self.has_selection) return false;

	Selection sel = self.selection();

	if (row < sel.start_row || row > sel.end_row) return false;
	if (row == sel.start_row && col < sel.start_col) return false;
	if (row == sel.end_row && col >= sel.end_col) return false;

	return true;
}
fn String Viewport.view(&self) => self.view_rows(self.height);

// view_rows renders rows lines from offset. Rows before the content or
// past its end (a trackpad pulling past an end, or the extra row a smooth
// scroll asks for) are blank; without either, it stops at the last line.
fn String Viewport.view_rows(&self, sz rows) {
	DString out = dstring::temp();
	sz start = self.offset;
	sz end = start + rows;
	if (start >= 0 && rows == self.height && end > self.total_lines) end = self.total_lines;

	bool has_bar = self.show_scrollbar && self.total_lines > self.height;
	sz text_w = self.width - (has_bar ? 3 : 0); // 2 gap + 1 bar char
	if (text_w < 1) text_w = 1;

	sz thumb_pos = 0;
	if (has_bar && self.total_lines > self.height) {
		thumb_pos = (self.offset * (self.height - 1)) / (self.total_lines - self.height);
	}

	for (sz i = start; i < end; i++) {
		String line = i >= 0 && i < self.total_lines ? self.lines[i] : "";
		sz line_w = glaze::string_width(line);

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
			sz row = i - start;
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
fn String Viewport.render_line_with_selection(&self, sz row, String line, sz pad_to_width) {
	DString out = dstring::temp();
	sz col = 0;

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
	sz line_w = glaze::string_width(line);
	for (sz p = line_w; p < pad_to_width; p++) {
		out.append_char(' ');
	}

	return out.str_view();
}

fn sz Viewport.scroll_percent(&self) {
	if (self.total_lines <= self.height) return 100;
	sz max_offset = self.total_lines - self.height;
	if (max_offset <= 0) return 100;
	return (self.offset * 100) / max_offset;
}

// ── layout tree ──────────────────────────────────────────────────────────────

fn String Viewport.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	// A smooth scroll part-way into a row asks for one more row than fits
	// (see node); the viewport's own height stays the rows that fit.
	bool extra = milktea::layout_metrics().pixels && self.frac_px() > 0;
	self.height = extra ? r.h - 1 : r.h;
	return self.view_rows(r.h);
}

// frac_px is how far into its first row the viewport is scrolled.
fn sz Viewport.frac_px(&self) {
	float row = self.row_px();
	float f = self.pos_px - (float)self.offset * row;
	return f > 0 ? (sz)math::round(f) % (sz)row : 0;
}

fn sz Viewport.measure(&self, sz width) @dynamic => self.height;
fn sz Viewport.measure_width(&self, sz height) @dynamic => self.width;

fn xray::Node* Viewport.node(&self) {
	self.settle();
	xray::Node* n = xray::content_node(self);
	if (milktea::layout_metrics().pixels) {
		self.position();
		n.scroll_shift(self.frac_px());
		if (self.springing) n.animate(60);
	}
	return n;
}
