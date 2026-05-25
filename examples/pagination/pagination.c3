module pagination;

import tea;
import lipgloss;
import pearls;
import std::io;
import std::core::string;
import std::core::dstring;

const int TOTAL_ITEMS = 50;

struct PaginationModel {
	pearls::Pagination pg;
	int cursor;
	int width;
	int height;
	bool[1000] selected;
}

fn tea::Cmd PaginationModel.init(PaginationModel* self) @dynamic {
	self.pg = pearls::new_pagination(8, TOTAL_ITEMS);
	return null;
}

fn tea::Cmd PaginationModel.update(PaginationModel* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind != tea::MsgKind.KEY) return null;
	tea::KeyMsg k = msg.key;

	if (self.pg.handle_key(k)) return null;

	int page_start = self.pg.page_start();
	int page_end   = self.pg.page_end();

	switch (k.code) {
		case tea::KeyCode.CTRL_C:
			return tea::quit();
		case tea::KeyCode.UP:
			if (self.cursor > page_start) self.cursor--;
		case tea::KeyCode.DOWN:
			if (self.cursor < page_end - 1) self.cursor++;
		case tea::KeyCode.HOME:
			self.cursor = page_start;
		case tea::KeyCode.END:
			self.cursor = page_end - 1;
		case tea::KeyCode.ENTER:
			self.selected[self.cursor] = !self.selected[self.cursor];
		case tea::KeyCode.RUNE:
			if (k.rune == 'q') return tea::quit();
			if (k.rune == 'j') {
				if (self.cursor < page_end - 1) self.cursor++;
			}
			if (k.rune == 'k') {
				if (self.cursor > page_start) self.cursor--;
			}
		case tea::KeyCode.ESC:
			return tea::quit();
		default:
	}
	return null;
}

fn tea::View PaginationModel.view(PaginationModel* self) @dynamic {
	lipgloss::Style title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true)
		.padding(0, 0, 1, 0);
	lipgloss::Style cursor_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true);
	lipgloss::Style check_style  = lipgloss::new_style().foreground(lipgloss::color_hex("#00ff00"));
	lipgloss::Style dim_style    = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

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

	return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
	PaginationModel m = { };
	if (catch err = tea::@run_program(&m)) {
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