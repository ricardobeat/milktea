module boba;

import milktea;
import glaze;
import std::core::dstring;

// TextInput is a single-line text input component.
struct TextInput {
	char[512] buf;
	sz len;
	sz cursor;
	String placeholder;
	bool focused;
	bool is_password;
	int max_width;
	glaze::Style focused_style;
	glaze::Style blurred_style;
	glaze::Style placeholder_style;
}

// new_text_input creates a text input with no placeholder.
fn TextInput new_text_input() {
	TextInput t = { };
	t.max_width = 512;
	t.focused_style = glaze::new_style().foreground(glaze::color_hex("#ffffff"));
	t.blurred_style = glaze::new_style().foreground(glaze::color_hex("#888888"));
	t.placeholder_style = glaze::new_style().foreground(glaze::color_hex("#444444"));
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
	self.cursor = 0;
}

// insert inserts a character at the cursor position.
fn void TextInput.insert(&self, char c) {
	if (self.len >= self.buf.len - 1) return;
	for (sz i = self.len; i > self.cursor; i--) {
		self.buf[i] = self.buf[i - 1];
	}
	self.buf[self.cursor] = c;
	self.len++;
	self.cursor++;
}

// insert_string inserts a string at the cursor position.
fn void TextInput.insert_string(&self, String s) {
	for (sz i = 0; i < s.len; i++) {
		self.insert(s[i]);
	}
}

// backspace deletes the character before the cursor.
fn void TextInput.backspace(&self) {
	if (self.cursor == 0) return;
	for (sz i = self.cursor; i < self.len; i++) {
		self.buf[i - 1] = self.buf[i];
	}
	self.len--;
	self.cursor--;
}

// delete_char deletes the character at the cursor.
fn void TextInput.delete_char(&self) {
	if (self.cursor >= self.len) return;
	for (sz i = self.cursor; i < self.len - 1; i++) {
		self.buf[i] = self.buf[i + 1];
	}
	self.len--;
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
	if (self.len > 0 && self.cursor < self.len) {
		return (int)self.cursor;
	}
	return (int)self.len;
}

// handle_key processes a key message and returns true if the input consumed it.
fn bool TextInput.handle_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			if (self.cursor > 0) self.cursor--;
			return true;
		case milktea::KeyCode.RIGHT:
			if (self.cursor < self.len) self.cursor++;
			return true;
		case milktea::KeyCode.HOME:
			self.cursor = 0;
			return true;
		case milktea::KeyCode.END:
			self.cursor = self.len;
			return true;
		case milktea::KeyCode.BACKSPACE:
			self.backspace();
			return true;
		case milktea::KeyCode.DELETE:
			self.delete_char();
			return true;
		case milktea::KeyCode.RUNE:
			self.insert(k.rune);
			return true;
		default:
			return false;
	}
}

// view returns the rendered text input string.
fn String TextInput.view(&self) {
	String display = self.display_text();

	glaze::Style s;
	if (self.len > 0 && self.focused) {
		s = self.focused_style;
	} else if (self.len > 0) {
		s = self.blurred_style;
	} else {
		s = self.placeholder_style;
	}
	return s.render(display);
}