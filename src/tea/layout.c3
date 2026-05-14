module tea;

import std::core::dstring;

// Layout tracks rows and auto-computes cursor position for View construction.
// Eliminates manual row counting and cursor arithmetic.
//
// Example:
//   Layout l = new_layout();
//   l.write_line(title.render("Sign Up"));
//   l.write_line("");
//   l.write_input_line("Nickname:", input.view(), focused, input.cursor_x());
//   l.write_line("");
//   l.write_line(hint.render("TAB to switch"));
//   return l.view();
struct Layout {
    DString out;
    int row;        // current row (0-indexed, incremented by writeln)
    int cur_row;    // cursor row (-1 = no cursor)
    int cur_col;    // cursor column
    bool alt_screen;
}

// new_layout creates a Layout for inline mode.
fn Layout new_layout() {
    return { .out = dstring::temp(), .row = 0, .cur_row = -1, .cur_col = 0 };
}

// new_alt_layout creates a Layout for alt-screen mode.
fn Layout new_alt_layout() {
    return { .out = dstring::temp(), .row = 0, .cur_row = -1, .cur_col = 0, .alt_screen = true };
}

// write appends content without advancing the row counter.
// Use for partial line content.
fn Layout* Layout.write(Layout* self, String s) {
    self.out.append_string(s);
    return self;
}

// write_line appends content followed by a newline, advancing the row.
fn Layout* Layout.write_line(Layout* self, String s) {
    self.out.append_string(s);
    self.out.append_char('\n');
    self.row++;
    return self;
}

// write_input_line writes a label + value pair, tracking cursor if focused.
// label_width is the visual width of the label (use lipgloss::string_width or hardcode).
// cursor_offset is the cursor position within the value (0 = start).
fn Layout* Layout.write_input_line(Layout* self, String label, String value, bool focused, int cursor_offset, int label_width) {
    self.out.append_string(label);
    self.out.append_char(' ');
    self.out.append_string(value);
    if (focused) {
        self.cur_row = self.row;
        self.cur_col = label_width + 1 + cursor_offset;
    }
    self.out.append_char('\n');
    self.row++;
    return self;
}

// view builds the final View from the accumulated layout.
fn View Layout.view(Layout* self) {
    View v;
    if (self.alt_screen) {
        v = new_alt_screen_view(self.out.str_view());
    } else {
        v = new_view(self.out.str_view());
    }
    if (self.cur_row >= 0) {
        v.has_cursor = true;
        v.cursor = new_cursor(self.cur_col, self.cur_row);
    }
    return v;
}
