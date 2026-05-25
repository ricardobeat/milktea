module xray;

import std::core::dstring;

// ============================================================
// Cell — a single terminal cell with character content and style.
// ============================================================

bitstruct Attrs : char {
	bool bold : 0;
	bool dim : 1;
	bool italic : 2;
	bool underline : 3;
	bool blink : 4;
	bool reverse : 5;
	bool strikethrough : 6;
}

struct Style {
	Color fg;
	Color bg;
	Color underline_color;
	Attrs attrs;
}

// Style constructors and builders

fn Style default_style() {
	return { };
}

fn bool Style.is_empty(&self) {
	return self.fg.is_none() && self.bg.is_none() && self.underline_color.is_none() && !self.attrs.bold
		&& !self.attrs.dim
		&& !self.attrs.italic
		&& !self.attrs.underline
		&& !self.attrs.blink
		&& !self.attrs.reverse
		&& !self.attrs.strikethrough;
}

fn bool Style.eq(&self, Style other) {
	return self.fg.eq(other.fg) && self.bg.eq(other.bg) && self.underline_color.eq(other.underline_color)
		&& self.attrs == other.attrs;
}

fn Style Style.set_fg(self, Color c) {
	Style s = self;
	s.fg = c;
	return s;
}

fn Style Style.set_bg(self, Color c) {
	Style s = self;
	s.bg = c;
	return s;
}

fn Style Style.set_bold(self, bool on) {
	Style s = self;
	s.attrs.bold = on;
	return s;
}

fn Style Style.set_dim(self, bool on) {
	Style s = self;
	s.attrs.dim = on;
	return s;
}

fn Style Style.set_italic(self, bool on) {
	Style s = self;
	s.attrs.italic = on;
	return s;
}

fn Style Style.set_underline(self, bool on) {
	Style s = self;
	s.attrs.underline = on;
	return s;
}

fn Style Style.set_blink(self, bool on) {
	Style s = self;
	s.attrs.blink = on;
	return s;
}

fn Style Style.set_reverse(self, bool on) {
	Style s = self;
	s.attrs.reverse = on;
	return s;
}

fn Style Style.set_strikethrough(self, bool on) {
	Style s = self;
	s.attrs.strikethrough = on;
	return s;
}

// Style.to_sgr emits a complete SGR sequence for this style.
// Starts with \x1b[0m to reset, then sets all active attributes.
fn String Style.to_sgr(&self) {
	if (self.is_empty()) return "";

	DString ds = dstring::temp();
	ds.append_string("\x1b[0");

	if (self.attrs.bold) ds.append_string(";1");
	if (self.attrs.dim) ds.append_string(";2");
	if (self.attrs.italic) ds.append_string(";3");
	if (self.attrs.underline) ds.append_string(";4");
	if (self.attrs.blink) ds.append_string(";5");
	if (self.attrs.reverse) ds.append_string(";7");
	if (self.attrs.strikethrough) ds.append_string(";9");

	ds.append_char('m');

	if (!self.fg.is_none()) {
		ds.append_string(self.fg.to_sgr_fg());
	}
	if (!self.bg.is_none()) {
		ds.append_string(self.bg.to_sgr_bg());
	}

	return ds.str_view();
}

// Style.diff_sgr emits ONLY the SGR codes that differ from `prev`.
// This is the key optimization for the diff renderer — avoids
// re-emitting unchanged attributes.
fn String Style.diff_sgr(&self, Style prev) {
	if (self.eq(prev)) return "";

	DString ds      = dstring::temp();
	bool need_reset = false;

	// Check if we need a full reset: attributes changed, or colors changed.
	bool attrs_changed = self.attrs.bold != prev.attrs.bold || self.attrs.dim != prev.attrs.dim
		|| self.attrs.italic != prev.attrs.italic
		|| self.attrs.underline != prev.attrs.underline
		|| self.attrs.blink != prev.attrs.blink
		|| self.attrs.reverse != prev.attrs.reverse
		|| self.attrs.strikethrough != prev.attrs.strikethrough;

	if (attrs_changed) {
		need_reset = true;
	}

	if (!prev.fg.is_none() && (self.fg.is_none() || !self.fg.eq(prev.fg))) {
		need_reset = true;
	}
	if (!prev.bg.is_none() && (self.bg.is_none() || !self.bg.eq(prev.bg))) {
		need_reset = true;
	}

	if (need_reset) {
		ds.append_string("\x1b[0");
		// Re-enable active attributes
		if (self.attrs.bold) ds.append_string(";1");
		if (self.attrs.dim) ds.append_string(";2");
		if (self.attrs.italic) ds.append_string(";3");
		if (self.attrs.underline) ds.append_string(";4");
		if (self.attrs.blink) ds.append_string(";5");
		if (self.attrs.reverse) ds.append_string(";7");
		if (self.attrs.strikethrough) ds.append_string(";9");
		ds.append_char('m');
		// Re-apply colors
		if (!self.fg.is_none()) {
			ds.append_string(self.fg.to_sgr_fg());
		}
		if (!self.bg.is_none()) {
			ds.append_string(self.bg.to_sgr_bg());
		}
	} else {
		// Only new attributes turned on (no attrs went off)
		if (!prev.attrs.bold && self.attrs.bold) ds.append_string("\x1b[1m");
		if (!prev.attrs.dim && self.attrs.dim) ds.append_string("\x1b[2m");
		if (!prev.attrs.italic && self.attrs.italic) ds.append_string("\x1b[3m");
		if (!prev.attrs.underline && self.attrs.underline) ds.append_string("\x1b[4m");
		if (!prev.attrs.blink && self.attrs.blink) ds.append_string("\x1b[5m");
		if (!prev.attrs.reverse && self.attrs.reverse) ds.append_string("\x1b[7m");
		if (!prev.attrs.strikethrough && self.attrs.strikethrough) ds.append_string("\x1b[9m");

		// Colors changed but no reset needed
		if (!self.fg.eq(prev.fg) && !self.fg.is_none()) {
			ds.append_string(self.fg.to_sgr_fg());
		}
		if (!self.bg.eq(prev.bg) && !self.bg.is_none()) {
			ds.append_string(self.bg.to_sgr_bg());
		}
	}

	return ds.str_view();
}

// ============================================================
// Cell — a single terminal cell.
// ============================================================

const sz CELL_MAX_BYTES = 8;

struct Cell {
	char[CELL_MAX_BYTES] content;
	char content_len;
	char width; // display width: 0=zero-width, 1=normal, 2=wide/CJK
	Style style;
}

fn Cell empty_cell() {
	Cell c;
	c.content[0] = ' ';
	c.content_len = 1;
	c.width = 1;
	return c;
}

fn Cell new_cell(String ch, char w, Style style) {
	Cell c;
	sz copy_len = ch.len;
	if (copy_len > CELL_MAX_BYTES) copy_len = CELL_MAX_BYTES;
	for (sz i = 0; i < copy_len; i++) {
		c.content[i] = ch[i];
	}
	c.content_len = (char)copy_len;
	c.width = w;
	c.style = style;
	return c;
}

fn bool Cell.eq(&self, Cell other) {
	if (self.width != other.width) return false;
	if (self.content_len != other.content_len) return false;
	if (!self.style.eq(other.style)) return false;
	for (char i = 0; i < self.content_len; i++) {
		if (self.content[i] != other.content[i]) return false;
	}
	return true;
}

fn String Cell.content_str(&self) {
	return (String)((char*)&self.content)[:self.content_len];
}