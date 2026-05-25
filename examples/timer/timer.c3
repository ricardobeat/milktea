module timer;

import milktea;
import glaze;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

struct TimerModel {
	boba::Timer timer;
	int width;
	int height;
}

fn milktea::Cmd TimerModel.init(TimerModel* self) @dynamic {
	self.timer = boba::new_timer(60);
	return self.timer.init_cmd();
}

fn milktea::Cmd TimerModel.update(TimerModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		return self.timer.tick();
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == ' ') self.timer.toggle();
			if (k.rune == 'r') {
				self.timer.reset();
				return self.timer.init_cmd();
			}
		default:
	}
	return null;
}

fn milktea::View TimerModel.view(TimerModel* self) @dynamic {
	glaze::Style box_style = glaze::new_style().foreground(glaze::color_hex("#ff00ff")).set_bold(true)
		.padding(2, 4, 2, 4)
		.set_border(glaze::rounded_border());

	glaze::Style subtle = glaze::new_style().foreground(glaze::color_hex("#666666"));

	DString out     = dstring::temp();
	int minutes     = self.timer.remaining_seconds / 60;
	int secs        = self.timer.remaining_seconds % 60;
	String time_str = string::tformat("%02d:%02d", minutes, secs);
	out.append_string(box_style.render(time_str));
	out.append_char('\n');

	if (self.timer.done) {
		glaze::Style done_style = glaze::new_style().foreground(glaze::color_hex("#00ff00")).set_bold(true);
		out.append_string(done_style.render("Time's up!"));
	} else if (self.timer.running) {
		out.append_string(subtle.render("SPACE to pause"));
	} else {
		glaze::Style pause_style = glaze::new_style().foreground(glaze::color_hex("#ffff00"));
		out.append_string(pause_style.render("PAUSED"));
		out.append_string(subtle.render("  SPACE to resume"));
	}

	out.append_char('\n');
	out.append_string(subtle.render("r to reset  |  q to quit"));
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	TimerModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}