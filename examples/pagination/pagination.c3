module pagination;

import milktea;
import glaze;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

const int TOTAL_ITEMS = 50;

struct PaginationModel {
	boba::Pagination pg;
	int cursor;
	int width;
	int height;
	bool[1000] selected;
}

fn milktea::Cmd PaginationModel.init(PaginationModel* self) @dynamic {
	self.pg = boba::new_pagination(8, TOTAL_ITEMS);
	return null;
}

fn milktea::Cmd PaginationModel.update(PaginationModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	if (self.pg.handle_key(k)) return null;

	int page_start = self.pg.page_start();
	int page_end   = self.pg.page_end();

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.UP:
			if (self.cursor > page_start) self.cursor--;
		case milktea::KeyCode.DOWN:
			if (self.cursor < page_end - 1) self.cursor++;
		case milktea::KeyCode.HOME:
			self.cursor = page_start;
		case milktea::KeyCode.END:
			self.cursor = page_end - 1;
		case milktea::KeyCode.ENTER:
			self.selected[self.cursor] = !self.selected[self.cursor];
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'j') {
				if (self.cursor < page_end - 1) self.cursor++;
			}
			if (k.rune == 'k') {
				if (self.cursor > page_start) self.cursor--;
			}
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View PaginationModel.view(PaginationModel* self) @dynamic {
	glaze::Style title_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(0, 0, 1, 0);
	glaze::Style cursor_style = glaze::new_style().foreground(glaze::color_hex("#ff00ff")).set_bold(true);
	glaze::Style check_style  = glaze::new_style().foreground(glaze::color_hex("#00ff00"));
	glaze::Style dim_style    = glaze::new_style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	int tp      = self.pg.total_pages();
	out.append_string(title_style.render(string::tformat("Items (page %d of %d)", self.pg.page + 1, tp)));
	out.append_char('\n');

	int page_start = self.pg.page_start();
	int page_end   = self.pg.page_end();

	for (int i = page_start; i < page_end; i++) {
		String check     = self.selected[i] ? "\xe2\x9c\x93" : " ";
		String marker    = (i == self.cursor) ? "> " : "  ";
		String item_text = string::tformat("Item %03d", i + 1);

		if (i == self.cursor) {
			out.append_string(cursor_style.render(string::tformat("%s%s %s", marker, check, item_text)));
		} else if (self.selected[i]) {
			out.append_string(check_style.render(string::tformat("%s%s %s", marker, check, item_text)));
		} else {
			out.append_string(dim_style.render(string::tformat("%s%s %s", marker, check, item_text)));
		}
		out.append_char('\n');
	}

	out.append_char('\n');
	out.append_string(dim_style.render(string::tformat("%d-%d of %d", page_start + 1, page_end, TOTAL_ITEMS)));
	out.append_string(dim_style.render("  |  "));
	out.append_string(self.pg.view());
	out.append_string(dim_style.render("  |  ↑↓ j/k navigate  |  ENTER toggle  |  ←→ pages  |  q quit"));

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	PaginationModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	int count = 0;
	for (int i = 0; i < TOTAL_ITEMS; i++) {
		if (m.selected[i]) count++;
	}
	io::printfn("\nSelected %d items.", count);
	return 0;
}