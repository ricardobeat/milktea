module boba;

import milktea;
import xray;
import glaze;
import std::core::dstring;

// ListItem represents a single item in a list.
// Rows the list reserves for its own chrome rather than items: a title row
// and the pagination row beneath.
const int LIST_CHROME_ROWS = 2;

struct ListItem {
	String title;
	String description;
	int id;
}

// List is a scrollable list component with optional selection.
struct List (xray::Content) {
	ListItem[64] items;
	int item_count;
	int cursor;
	int selected; // index of selected item (-1 if none)
	bool selectable; // if true, Enter sets selected; off by default
	int width;
	int height;
	int scroll_offset;
	glaze::Style cursor_style;
	glaze::Style selected_style;
	glaze::Style item_style;
	glaze::Style title_style;
	glaze::Style dim_style;
	String cursor_prefix;
	String item_prefix;
	String selected_suffix;
}

// new_list creates an empty list.
fn List new_list() {
	List l = { };
	l.selected = -1;
	l.cursor_style = glaze::style().foreground(glaze::color_hex("#ff00ff")).with_bold(true);
	l.selected_style = glaze::style().foreground(glaze::color_hex("#00ff00"));
	l.item_style = glaze::style().foreground(glaze::color_hex("#cccccc"));
	l.title_style = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);
	l.dim_style = glaze::style().foreground(glaze::color_hex("#666666"));
	l.cursor_prefix = "▌ ";
	l.item_prefix = "  ";
	l.selected_suffix = " ✓";
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
fn bool List.handle_key(&self, milktea::KeyMsg k) {
	int available = self.height - 2;
	if (available < 1) available = 1;

	switch (k.code) {
		case milktea::KeyCode.UP:
			if (self.cursor > 0) self.cursor--;
			return true;
		case milktea::KeyCode.DOWN:
			if (self.cursor < self.item_count - 1) self.cursor++;
			return true;
		case milktea::KeyCode.HOME:
			self.cursor = 0;
			return true;
		case milktea::KeyCode.END:
			// item_count == 0 would leave cursor at -1, which view() then
			// indexes with.
			self.cursor = self.item_count > 0 ? self.item_count - 1 : 0;
			return true;
		case milktea::KeyCode.PAGE_UP:
			self.cursor -= available;
			if (self.cursor < 0) self.cursor = 0;
			return true;
		case milktea::KeyCode.PAGE_DOWN:
			self.cursor += available;
			if (self.cursor >= self.item_count) self.cursor = self.item_count > 0 ? self.item_count - 1 : 0;
			return true;
		case milktea::KeyCode.ENTER:
			if (!self.selectable) return false;
			self.selected = self.cursor;
			return true;
		default:
			return false;
	}
}

// view returns the rendered list string.
// visible_rows is how many items fit in the list's height, leaving room for
// the chrome the view draws around them.
fn int List.visible_rows(&self) {
	int n = self.height - LIST_CHROME_ROWS;
	return n < 1 ? 1 : n;
}

fn String List.view(&self) {
	int available = self.visible_rows();

	// Adjust scroll offset
	if (self.cursor < self.scroll_offset) self.scroll_offset = self.cursor;
	if (self.cursor >= self.scroll_offset + available) self.scroll_offset = self.cursor - available + 1;

	DString out = dstring::temp();

	int end = self.scroll_offset + available;
	if (end > self.item_count) end = self.item_count;

	for (int i = self.scroll_offset; i < end; i++) {
		ListItem item = self.items[i];
		if (self.cursor == i) {
			out.append_string(self.cursor_style.render(string::tformat("%s%s", self.cursor_prefix, item.title)));
		} else if (self.selectable && self.selected == i) {
			out.append_string(self.selected_style.render(string::tformat("%s%s%s", self.item_prefix, item.title, self.selected_suffix)));
		} else {
			out.append_string(self.item_style.render(string::tformat("%s%s", self.item_prefix, item.title)));
		}
		out.append_char('\n');
	}

	return out.str_view();
}

// view_with_pagination returns the list with pagination dots at the bottom.
fn String List.view_with_pagination(&self) {
	DString out = dstring::temp();
	out.append_string(self.view());

	int available = self.visible_rows();
	int total_pages  = (self.item_count + available - 1) / available;
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