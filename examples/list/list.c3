module list_example;

import tea;
import lipgloss;
import pearls;
import std::io;
import std::core::string;
import std::core::dstring;

struct ListModel {
	pearls::List lst;
}

fn tea::Cmd ListModel.init(ListModel* self) @dynamic {
	self.lst = pearls::new_list();
	self.lst.add_item("Buy milk", "");
	self.lst.add_item("Clean the house", "");
	self.lst.add_item("Write C3 code", "");
	self.lst.add_item("Read a book", "");
	self.lst.add_item("Play video games", "");
	self.lst.add_item("Go for a walk", "");
	self.lst.add_item("Call mom", "");
	self.lst.add_item("Cook dinner", "");
	self.lst.add_item("Fix the bug", "");
	self.lst.add_item("Deploy to prod", "");
	self.lst.add_item("Review PRs", "");
	self.lst.add_item("Update docs", "");
	self.lst.add_item("Refactor module", "");
	self.lst.add_item("Write tests", "");
	self.lst.add_item("Celebration dinner", "");
	return null;
}

fn tea::Cmd ListModel.update(ListModel* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		self.lst.set_size(msg.window_size.width, msg.window_size.height);
		return null;
	}

	if (msg.kind != tea::MsgKind.KEY) return null;
	tea::KeyMsg k = msg.key;

	if (self.lst.handle_key(k)) return null;

	switch (k.code) {
		case tea::KeyCode.CTRL_C:
			return tea::quit();
		case tea::KeyCode.RUNE:
			if (k.rune == 'q') return tea::quit();
		case tea::KeyCode.ESC:
			return tea::quit();
		default:
	}
	return null;
}

fn tea::View ListModel.view(ListModel* self) @dynamic {
	lipgloss::Style title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
	lipgloss::Style hint_style  = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title_style.render("Select an item:"));
	out.append_char('\n');
	out.append_string(self.lst.view_with_pagination());
	out.append_char('\n');
	out.append_string(hint_style.render("Up/Down navigate | Enter select | q quit"));

	return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
	ListModel m = { };
	if (catch err = tea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	if (m.lst.selected >= 0) {
		io::printfn("You selected: %s", m.lst.items[m.lst.selected].title);
	}
	io::printn("Bye!");
	return 0;
}