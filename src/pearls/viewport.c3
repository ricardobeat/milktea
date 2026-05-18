module pearls;

import tea;
import lipgloss;
import std::core::dstring;

// Viewport is a scrollable content viewport component.
struct Viewport {
    int offset;      // scroll offset (line index)
    int width;       // viewport width
    int height;      // viewport height
    int total_lines; // total lines of content
    bool mouse_wheel_enabled;
    lipgloss::Style scrollbar_style;
}

// new_viewport creates a viewport with the given dimensions.
fn Viewport new_viewport(int width, int height) {
    Viewport v = {};
    v.width = width;
    v.height = height;
    v.scrollbar_style = lipgloss::new_style().foreground(lipgloss::color_hex("#555555"));
    return v;
}

// with_mouse_wheel returns a copy with mouse wheel scrolling enabled.
fn Viewport Viewport.with_mouse_wheel(self) {
    Viewport v = self;
    v.mouse_wheel_enabled = true;
    return v;
}

// set_content updates the total line count for the viewport.
fn void Viewport.set_content(&self, int total_lines) {
    self.total_lines = total_lines;
    int max_offset = self.total_lines - self.height;
    if (max_offset < 0) max_offset = 0;
    if (self.offset > max_offset) self.offset = max_offset;
}

// scroll_up scrolls up by one line.
fn void Viewport.scroll_up(&self) {
    if (self.offset > 0) self.offset--;
}

// scroll_down scrolls down by one line.
fn void Viewport.scroll_down(&self) {
    int max_offset = self.total_lines - self.height;
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
    int max_offset = self.total_lines - self.height;
    if (max_offset < 0) max_offset = 0;
    if (self.offset > max_offset) self.offset = max_offset;
}

// scroll_to_top scrolls to the beginning.
fn void Viewport.scroll_to_top(&self) {
    self.offset = 0;
}

// scroll_to_bottom scrolls to the end.
fn void Viewport.scroll_to_bottom(&self) {
    int max_offset = self.total_lines - self.height;
    if (max_offset < 0) max_offset = 0;
    self.offset = max_offset;
}

// handle_key processes common scroll keybindings.
// Returns true if the key was consumed.
fn bool Viewport.handle_key(&self, tea::KeyMsg k) {
    switch (k.code) {
        case tea::KeyCode.UP:
            self.scroll_up();
            return true;
        case tea::KeyCode.DOWN:
            self.scroll_down();
            return true;
        case tea::KeyCode.PAGE_UP:
            self.page_up();
            return true;
        case tea::KeyCode.PAGE_DOWN:
            self.page_down();
            return true;
        case tea::KeyCode.HOME:
            self.scroll_to_top();
            return true;
        case tea::KeyCode.END:
            self.scroll_to_bottom();
            return true;
        default:
            return false;
    }
}

// view_line_range returns the visible line indices [start, end).
fn int Viewport.view_line_start(&self) {
    return self.offset;
}

fn int Viewport.view_line_end(&self) {
    int end = self.offset + self.height;
    if (end > self.total_lines) end = self.total_lines;
    return end;
}

// scrollbar returns a vertical scrollbar indicator string.
fn String Viewport.scrollbar(&self) {
    if (self.total_lines <= self.height) return "";

    int bar_height = self.height;
    int thumb_pos = 0;
    if (self.total_lines > self.height) {
        thumb_pos = (self.offset * (bar_height - 1)) / (self.total_lines - self.height);
    }

    DString out = dstring::temp();
    for (int i = 0; i < bar_height; i++) {
        if (i == thumb_pos) {
            out.append_string("\xe2\x96\x88"); // █
        } else {
            out.append_string("\xe2\x94\x82"); // │
        }
        if (i < bar_height - 1) out.append_char('\n');
    }
    return out.str_view();
}

// scroll_percent returns the scroll position as a percentage (0-100).
fn int Viewport.scroll_percent(&self) {
    if (self.total_lines <= self.height) return 100;
    int max_offset = self.total_lines - self.height;
    if (max_offset <= 0) return 100;
    return (self.offset * 100) / max_offset;
}
