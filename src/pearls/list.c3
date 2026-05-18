module pearls;

import tea;
import lipgloss;
import std::core::dstring;

// ListItem represents a single item in a list.
struct ListItem {
    String title;
    String description;
    int    id;
}

// List is a scrollable list component with selection.
struct List {
    ListItem[64] items;
    int item_count;
    int cursor;
    int selected;       // index of selected item (-1 if none)
    int width;
    int height;
    int scroll_offset;
    lipgloss::Style cursor_style;
    lipgloss::Style selected_style;
    lipgloss::Style item_style;
    lipgloss::Style title_style;
    lipgloss::Style dim_style;
}

// new_list creates an empty list.
fn List new_list() {
    List l = {};
    l.selected = -1;
    l.cursor_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true);
    l.selected_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00ff00"));
    l.item_style = lipgloss::new_style().foreground(lipgloss::color_hex("#cccccc"));
    l.title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
    l.dim_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    return l;
}

// add_item appends an item to the list.
fn void List.add_item(&self, String title, String description) {
    if (self.item_count >= 64) return;
    self.items[self.item_count] = { .title = title, .description = description, .id = self.item_count };
    self.item_count++;
}

// set_size updates the viewport dimensions.
fn void List.set_size(&self, int width, int height) {
    self.width = width;
    self.height = height;
}

// handle_key processes list navigation keybindings.
// Returns true if the key was consumed.
fn bool List.handle_key(&self, tea::KeyMsg k) {
    int available = self.height - 2;
    if (available < 1) available = 1;

    switch (k.code) {
        case tea::KeyCode.UP:
            if (self.cursor > 0) self.cursor--;
            return true;
        case tea::KeyCode.DOWN:
            if (self.cursor < self.item_count - 1) self.cursor++;
            return true;
        case tea::KeyCode.HOME:
            self.cursor = 0;
            return true;
        case tea::KeyCode.END:
            self.cursor = self.item_count - 1;
            return true;
        case tea::KeyCode.PAGE_UP:
            self.cursor -= available;
            if (self.cursor < 0) self.cursor = 0;
            return true;
        case tea::KeyCode.PAGE_DOWN:
            self.cursor += available;
            if (self.cursor >= self.item_count) self.cursor = self.item_count - 1;
            return true;
        case tea::KeyCode.ENTER:
            self.selected = self.cursor;
            return true;
        default:
            return false;
    }
}

// view returns the rendered list string.
fn String List.view(&self) {
    int available = self.height - 2;
    if (available < 1) available = 1;

    // Adjust scroll offset
    if (self.cursor < self.scroll_offset) self.scroll_offset = self.cursor;
    if (self.cursor >= self.scroll_offset + available) self.scroll_offset = self.cursor - available + 1;

    DString out = dstring::temp();

    int end = self.scroll_offset + available;
    if (end > self.item_count) end = self.item_count;

    for (int i = self.scroll_offset; i < end; i++) {
        ListItem item = self.items[i];
        if (self.cursor == i) {
            out.append_string(self.cursor_style.render(string::tformat("> %s", item.title)));
        } else if (self.selected == i) {
            out.append_string(self.selected_style.render(string::tformat("  %s \xe2\x9c\x93", item.title)));
        } else {
            out.append_string(self.item_style.render(string::tformat("  %s", item.title)));
        }
        out.append_char('\n');
    }

    return out.str_view();
}

// view_with_pagination returns the list with pagination dots at the bottom.
fn String List.view_with_pagination(&self) {
    DString out = dstring::temp();
    out.append_string(self.view());

    int available = self.height - 2;
    if (available < 1) available = 1;
    int total_pages = (self.item_count + available - 1) / available;
    int current_page = self.scroll_offset / available;

    out.append_char('\n');
    for (int p = 0; p < total_pages; p++) {
        if (p > 0) out.append_char(' ');
        if (p == current_page) {
            out.append_string(self.cursor_style.render("\xe2\x80\xa2")); // •
        } else {
            out.append_string(self.dim_style.render("\xe2\x97\xa5")); // ◥
        }
    }
    return out.str_view();
}
