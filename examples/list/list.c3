module list_example;

import milktea;
import glaze;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

struct ListModel {
	boba::List lst;
}

fn milktea::Cmd ListModel.init(ListModel* self) @dynamic {
	self.lst = boba::new_list();
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

fn milktea::Cmd ListModel.update(ListModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.lst.set_size(msg.window_size.width, msg.window_size.height);
		return null;
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	if (self.lst.handle_key(k)) return null;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View ListModel.view(ListModel* self) @dynamic {
	glaze::Style title_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true);
	glaze::Style hint_style  = glaze::new_style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title_style.render("Select an item:"));
	out.append_char('\n');
	out.append_string(self.lst.view_with_pagination());
	out.append_char('\n');
	out.append_string(hint_style.render("Up/Down navigate | Enter select | q quit"));

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	ListModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	if (m.lst.selected >= 0) {
		io::printfn("You selected: %s", m.lst.items[m.lst.selected].title);
	}
	io::printn("Bye!");
	return 0;
}