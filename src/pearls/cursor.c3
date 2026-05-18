module pearls;

import tea;

// Cursor represents a position within a text buffer.
struct Cursor {
    int pos;     // current position (0-indexed byte offset)
    int end;     // total length of the content
}

// new_cursor creates a cursor for content of the given length.
fn Cursor new_cursor(int content_len) {
    return { .pos = 0, .end = content_len };
}

// set_pos sets the cursor position, clamping to [0, end].
fn void Cursor.set_pos(&self, int p) {
    if (p < 0) p = 0;
    if (p > self.end) p = self.end;
    self.pos = p;
}

// move_left moves the cursor one position left.
fn void Cursor.move_left(&self) {
    if (self.pos > 0) self.pos--;
}

// move_right moves the cursor one position right.
fn void Cursor.move_right(&self) {
    if (self.pos < self.end) self.pos++;
}

// move_to_start moves the cursor to the beginning.
fn void Cursor.move_to_start(&self) {
    self.pos = 0;
}

// move_to_end moves the cursor to the end.
fn void Cursor.move_to_end(&self) {
    self.pos = self.end;
}

// move_up moves the cursor up by one line in content with the given width.
fn void Cursor.move_up(&self, int width) {
    if (width <= 0) return;
    self.pos -= width;
    if (self.pos < 0) self.pos = 0;
}

// move_down moves the cursor down by one line in content with the given width.
fn void Cursor.move_down(&self, int width) {
    if (width <= 0) return;
    self.pos += width;
    if (self.pos > self.end) self.pos = self.end;
}

// at_start returns true if cursor is at position 0.
fn bool Cursor.at_start(&self) {
    return self.pos == 0;
}

// at_end returns true if cursor is at the end.
fn bool Cursor.at_end(&self) {
    return self.pos == self.end;
}

// to_view_cursor converts this cursor position to a tea::Cursor for rendering.
// width is the line width used to compute row and column.
fn tea::Cursor Cursor.to_view_cursor(&self, int width) {
    if (width <= 0) width = 1;
    int col = self.pos % width;
    int row = self.pos / width;
    return tea::new_cursor(col, row);
}

// blink_cursor creates a blinking cursor at the given position.
fn tea::Cursor Cursor.blink(&self, int width) {
    tea::Cursor c = self.to_view_cursor(width);
    return c;
}
