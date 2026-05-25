module focus_blur;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

struct FocusModel {
	bool focused;
	bool reporting;
	int width;
	int height;
}

fn milktea::Cmd FocusModel.init(FocusModel* self) @dynamic {
	self.focused = true;
	self.reporting = true;
	return null;
}

fn milktea::Cmd FocusModel.update(FocusModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.FOCUS) {
		self.focused = true;
		return null;
	}
	if (msg.kind == milktea::MsgKind.BLUR) {
		self.focused = false;
		return null;
	}
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 't') {
				self.reporting = !self.reporting;
				if (self.reporting) {
					milktea::enable_focus();
				} else {
					milktea::disable_focus();
				}
			}
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View FocusModel.view(FocusModel* self) @dynamic {
	glaze::Style focused_style = glaze::new_style().foreground(glaze::color_hex("#00ff00")).set_bold(true)
		.padding(2, 4, 2, 4)
		.set_border(glaze::rounded_border());

	glaze::Style blurred_style = glaze::new_style().foreground(glaze::color_hex("#666666")).padding(2, 4, 2, 4)
		.set_border(glaze::rounded_border());

	glaze::Style hint = glaze::new_style().foreground(glaze::color_hex("#888888"));

	String label      = self.focused ? "FOCUSED" : "BLURRED";
	String desc       = self.focused ? "Terminal window is active" : "Terminal window is inactive";
	glaze::Style s = self.focused ? focused_style : blurred_style;

	DString out = dstring::temp();
	out.append_string(s.render(string::tformat("%s\n%s", label, desc)));
	out.append_char('\n');
	out.append_char('\n');
	out.append_string(
		hint.render(
			string::tformat("Focus reporting: %s\nPress t to toggle | q to quit", self.reporting ? "ON" : "OFF")
		)
	);
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	FocusModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}