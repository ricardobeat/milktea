module progress;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

const int TOTAL = 100;

struct ProgressModel {
	int progress;
	int speed;
	bool done;
	int width;
	int height;
}

fn milktea::Cmd ProgressModel.init(ProgressModel* self) @dynamic {
	self.speed = 1;
	return milktea::tick(50);
}


fn milktea::Cmd ProgressModel.update(ProgressModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		if (!self.done) {
			self.progress += self.speed;
			if (self.progress >= TOTAL) {
				self.progress = TOTAL;
				self.done = true;
			}
		}
		return milktea::tick(50);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'f') self.speed = 5;
			if (k.rune == 's') self.speed = 1;
			if (k.rune == 'r') {
				self.progress = 0;
				self.done = false;
				self.speed = 1;
				return milktea::tick(50);
			}
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View ProgressModel.view(ProgressModel* self) @dynamic {
	glaze::Style title = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(0, 0, 1, 0);

	glaze::Style done_style = glaze::new_style().foreground(glaze::color_hex("#00ff00")).set_bold(true);

	glaze::Style hint = glaze::new_style().foreground(glaze::color_hex("#666666"));

	glaze::Style box_style = glaze::new_style().set_border(glaze::rounded_border()).padding(1, 2, 1, 2);

	int pct = (self.progress * 100) / TOTAL;

	DString content = dstring::temp();
	content.append_string(title.render("Progress Bar"));
	content.append_char('\n');
	content.append_char('\n');

	// Main progress bar
	String bar1 = glaze::progress_bar(
		40,
		pct,
		"█",
		"░",
		glaze::color_hex("#00d7ff"),
		glaze::color_hex("#222222")
	);

	// Second bar with different style
	String bar2 = glaze::progress_bar(
		40,
		pct,
		"■",
		"□",
		glaze::color_hex("#ff00ff"),
		glaze::color_hex("#222222")
	);

	// Third bar with gradient feel
	String bar3 = glaze::progress_bar(
		40,
		pct,
		"=",
		"-",
		glaze::color_hex("#00ff88"),
		glaze::color_hex("#333333")
	);

	content.append_string(string::tformat(" Download %s %d%%\n", bar1, pct));
	content.append_string(string::tformat(" Compile %s %d%%\n", bar2, pct));
	content.append_string(string::tformat(" Deploy   %s %d%%\n", bar3, pct));

	content.append_char('\n');

	if (self.done) {
		content.append_string(done_style.render("✓ Complete!"));
		content.append_string(hint.render("  r to restart"));
	} else {
		String speed_label = self.speed > 1 ? "fast" : "normal";
		content.append_string(hint.render(string::tformat("Speed: %s", speed_label)));
		content.append_string(hint.render("  |  f fast  |  s slow  |  r restart  |  q quit"));
	}

	return milktea::new_alt_screen_view(box_style.render(content.str_view()));
}

fn int main() {
	ProgressModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Done!");
	return 0;
}