module boba;

import milktea;
import xray;
import glaze;
import std::core::dstring;

// TextInput is a single-line text input component.
struct TextInput (xray::Content) {
	char[512] buf;
	sz len;
	// Byte offset of the caret within buf.
	sz cursor_pos;
	String placeholder;
	bool focused;
	bool is_password;
	int max_width;
	// Size the rendered box, in cells. Zero means "fit the text", which is
	// what a string-built view wants; the layout tree sets both from the rect
	// it solved so a bordered style is drawn at the size the layout chose.
	int width;
	int height;
	// How this input's cursor is drawn while it is focused. Leaving draw null
	// uses the real terminal cursor with the given shape, blink and color;
	// setting it paints the cursor instead (see xray::DrawCursorFn).
	milktea::CursorShape cursor_shape;
	bool cursor_blink;
	String cursor_color;
	xray::DrawCursorFn cursor_draw;
	int cursor_blink_ms;
	glaze::Style focused_style;
	glaze::Style blurred_style;
	// Only the foreground is taken from this style; the box is drawn by the
	// focused or blurred style, so an empty field still has its frame.
	glaze::Style placeholder_style;
}

// new_text_input creates a text input with no placeholder.
fn TextInput new_text_input() {
	TextInput t = { };
	t.max_width = 512;
	t.cursor_blink = true;
	t.focused_style = glaze::style().foreground(glaze::color_hex("#ffffff"));
	t.blurred_style = glaze::style().foreground(glaze::color_hex("#888888"));
	t.placeholder_style = glaze::style().foreground(glaze::color_hex("#444444"));
	return t;
}

// with_placeholder returns a copy with a placeholder string.
fn TextInput TextInput.with_placeholder(self, String ph) {
	TextInput t = self;
	t.placeholder = ph;
	return t;
}

// with_password returns a copy that masks input.
fn TextInput TextInput.with_password(self) {
	TextInput t = self;
	t.is_password = true;
	return t;
}

// with_styles returns a copy with custom styles.
fn TextInput TextInput.with_styles(self, glaze::Style focused_s, glaze::Style blurred_s) {
	TextInput t = self;
	t.focused_style = focused_s;
	t.blurred_style = blurred_s;
	return t;
}

// clear empties the input.
fn void TextInput.clear(&self) {
	self.len = 0;
	self.cursor_pos = 0;
}

// insert inserts a character at the cursor position.
fn void TextInput.insert(&self, char c) {
	if (self.len >= self.buf.len - 1) return;
	for (sz i = self.len; i > self.cursor_pos; i--) {
		self.buf[i] = self.buf[i - 1];
	}
	self.buf[self.cursor_pos] = c;
	self.len++;
	self.cursor_pos++;
}

// insert_rune encodes a Unicode codepoint as UTF-8 and inserts it at the cursor.
// Checked up front so a full buffer can't truncate a sequence mid-way.
fn void TextInput.insert_rune(&self, uint cp) {
	char[4] enc;
	sz n = milktea::utf8_encode(cp, enc[..]);
	if (self.len + n >= self.buf.len) return;
	for (sz i = 0; i < n; i++) self.insert(enc[i]);
}

// insert_string inserts a string at the cursor position.
fn void TextInput.insert_string(&self, String s) {
	for (sz i = 0; i < s.len; i++) {
		self.insert(s[i]);
	}
}

// backspace deletes the character before the cursor.
//
// The whole UTF-8 sequence is removed, not one byte: deleting a single byte of
// a multi-byte character leaves a dangling lead or continuation byte, which is
// invalid UTF-8 and renders as garbage for the rest of the buffer.
fn void TextInput.backspace(&self) {
	if (self.cursor_pos == 0) return;
	sz start = utf8_prev_boundary(self.buf[:self.len], self.cursor_pos);
	sz n     = self.cursor_pos - start;
	for (sz i = self.cursor_pos; i < self.len; i++) {
		self.buf[i - n] = self.buf[i];
	}
	self.len -= n;
	self.cursor_pos = start;
}

// delete_char deletes the character at the cursor, sequence and all.
fn void TextInput.delete_char(&self) {
	if (self.cursor_pos >= self.len) return;
	sz next = utf8_next_boundary(self.buf[:self.len], self.cursor_pos);
	sz n    = next - self.cursor_pos;
	for (sz i = next; i < self.len; i++) {
		self.buf[i - n] = self.buf[i];
	}
	self.len -= n;
}

// text returns the current input as a String.
fn String TextInput.text(&self) {
	return (String)self.buf[:self.len];
}

// display_text returns the text to render (placeholder if empty, dots if password).
fn String TextInput.display_text(&self) {
	if (self.len == 0) return self.placeholder;
	if (self.is_password) {
		DString hidden = dstring::temp();
		for (sz i = 0; i < self.len; i++) hidden.append_string("\xe2\x80\xa2"); // •
		return hidden.str_view();
	}
	return self.text();
}

// cursor_col returns the column offset of the cursor within the input text.
fn int TextInput.cursor_col(&self) {
	if (self.len > 0 && self.cursor_pos < self.len) {
		return (int)self.cursor_pos;
	}
	return (int)self.len;
}

// handle_key processes a key message and returns true if the input consumed it.
fn bool TextInput.handle_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			// Step a whole codepoint: landing mid-sequence would make the
			// next backspace or insert split a character.
			self.cursor_pos = utf8_prev_boundary(self.buf[:self.len], self.cursor_pos);
			return true;
		case milktea::KeyCode.RIGHT:
			self.cursor_pos = utf8_next_boundary(self.buf[:self.len], self.cursor_pos);
			return true;
		case milktea::KeyCode.HOME:
			self.cursor_pos = 0;
			return true;
		case milktea::KeyCode.END:
			self.cursor_pos = self.len;
			return true;
		case milktea::KeyCode.BACKSPACE:
			self.backspace();
			return true;
		case milktea::KeyCode.DELETE:
			self.delete_char();
			return true;
		case milktea::KeyCode.RUNE:
			self.insert_rune(k.rune);
			return true;
		default:
			return false;
	}
}

// handle_paste inserts pasted text at the cursor.
// TextInput is a single-line widget: paste is truncated at the first newline
// character (\n or \r) so that multi-line pastes never corrupt the buffer.
// The caller is responsible for holding the paste String alive during this call
// (no copy is made here beyond what insert_string stores byte-by-byte).
fn void TextInput.handle_paste(&self, String s) {
	// Find end of first line; single-line semantics — stop before any newline.
	sz end = s.len;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '\n' || s[i] == '\r') {
			end = i;
			break;
		}
	}
	if (end > 0) {
		self.insert_string(s[:end]);
	}
}

// view returns the rendered text input string.
fn String TextInput.view(&self) {
	// The box comes from the focus state, so an empty input still draws the
	// border and padding its style asks for. Only the text color changes when
	// there is nothing to show but the placeholder — otherwise a field would
	// have no frame until the first time it was focused and typed into.
	glaze::Style s = self.focused ? self.focused_style : self.blurred_style;
	if (self.len == 0) {
		s.fg = self.placeholder_style.fg;
	}
	if (self.width > 0) s = s.with_width(self.width);
	if (self.height > 0) s = s.with_height(self.height);
	return s.render(self.display_text());
}