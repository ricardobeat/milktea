module boba;

import milktea;
import glaze;
import std::core::dstring;

// PaginatorType selects the pagination style.
enum PaginatorType {
	DOTS,    // • • ◉ • •
	NUMBERS, // 1 2 [3] 4 5
	ARABIC,  // Page 3 of 10
}

// Pagination is a page navigation component.
struct Pagination {
	int page; // current page (0-indexed)
	int per_page; // items per page
	int total_items; // total number of items
	PaginatorType kind;
	glaze::Style active_style;
	glaze::Style inactive_style;
	glaze::Style subtle_style;
}

// new_pagination creates a pagination component.
fn Pagination new_pagination(int per_page, int total_items) {
	Pagination p = { };
	p.per_page = per_page;
	p.total_items = total_items;
	p.kind = DOTS;
	p.active_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true);
	p.inactive_style = glaze::new_style().foreground(glaze::color_hex("#555555"));
	p.subtle_style = glaze::new_style().foreground(glaze::color_hex("#666666"));
	return p;
}

// with_kind returns a copy with the given pagination style.
fn Pagination Pagination.with_kind(self, PaginatorType kind) {
	Pagination p = self;
	p.kind = kind;
	return p;
}

// total_pages returns the total number of pages.
fn int Pagination.total_pages(&self) {
	if (self.per_page <= 0) return 1;
	int tp = (self.total_items + self.per_page - 1) / self.per_page;
	if (tp < 1) tp = 1;
	return tp;
}

// page_start returns the index of the first item on the current page.
fn int Pagination.page_start(&self) {
	return self.page * self.per_page;
}

// page_end returns the index past the last item on the current page.
fn int Pagination.page_end(&self) {
	int end = self.page * self.per_page + self.per_page;
	if (end > self.total_items) end = self.total_items;
	return end;
}

// prev_page goes to the previous page.
fn void Pagination.prev_page(&self) {
	if (self.page > 0) self.page--;
}

// next_page goes to the next page.
fn void Pagination.next_page(&self) {
	if (self.page < self.total_pages() - 1) self.page++;
}

// goto_page jumps to a specific page (0-indexed).
fn void Pagination.goto_page(&self, int p) {
	int tp = self.total_pages();
	if (p < 0) p = 0;
	if (p >= tp) p = tp - 1;
	self.page = p;
}

// handle_key processes common pagination keybindings.
// Returns true if the key was consumed.
fn bool Pagination.handle_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			self.prev_page();
			return true;
		case milktea::KeyCode.RIGHT:
			self.next_page();
			return true;
		case milktea::KeyCode.HOME:
			self.page = 0;
			return true;
		case milktea::KeyCode.END:
			self.page = self.total_pages() - 1;
			return true;
		default:
			return false;
	}
}

// view returns the rendered pagination string.
fn String Pagination.view(&self) {
	int tp      = self.total_pages();
	DString out = dstring::temp();

	switch (self.kind) {
		case DOTS:
			for (int i = 0; i < tp; i++) {
				if (i > 0) out.append_char(' ');
				if (i == self.page) {
					out.append_string(self.active_style.render("\xe2\x97\x89")); // ◉
				} else {
					out.append_string(self.inactive_style.render("\xe2\x80\xa2")); // •
				}
			}
		case NUMBERS:
			for (int i = 0; i < tp; i++) {
				if (i > 0) out.append_char(' ');
				String num = string::tformat("%d", i + 1);
				if (i == self.page) {
					out.append_string(self.active_style.render(string::tformat("[%s]", num)));
				} else {
					out.append_string(self.inactive_style.render(num));
				}
			}
		case ARABIC:
			out.append_string(self.subtle_style.render(string::tformat("Page %d of %d", self.page + 1, tp)));
		default:
	}
	return out.str_view();
}