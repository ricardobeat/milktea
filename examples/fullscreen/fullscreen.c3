module fullscreen;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;


struct FullscreenModel {
	int countdown;
	int width;
	int height;
}

fn milktea::Cmd FullscreenModel.init(FullscreenModel* self) @dynamic {
	return milktea::tick(1000);
}


fn milktea::Cmd FullscreenModel.update(FullscreenModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.countdown--;
		if (self.countdown <= 0) {
			return milktea::quit();
		}
		return milktea::tick(1000);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View FullscreenModel.view(FullscreenModel* self) @dynamic {
	glaze::Style number = glaze::new_style().foreground(glaze::color_hex("#ff5555")).set_bold(true);

	glaze::Style label = glaze::new_style().foreground(glaze::color_hex("#888888"));

	DString out    = dstring::temp();
	String num_str = string::tformat("%d", self.countdown);
	out.append_string(number.render(num_str));

	if (self.countdown == 1) {
		out.append_string(label.render(" second remaining"));
	} else {
		out.append_string(label.render(" seconds remaining"));
	}

	out.append_char('\n');
	out.append_string(label.render("Press ESC or q to quit"));
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	FullscreenModel m = { .countdown = 10 };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Time's up!");
	return 0;
}