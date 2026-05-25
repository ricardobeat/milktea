module timer;

import tea;
import lipgloss;
import pearls;
import std::io;
import std::core::string;
import std::core::dstring;

struct TimerModel {
	pearls::Timer timer;
	int width;
	int height;
}

fn tea::Cmd TimerModel.init(TimerModel* self) @dynamic {
	self.timer = pearls::new_timer(60);
	return self.timer.init_cmd();
}

fn tea::Cmd TimerModel.update(TimerModel* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == tea::MsgKind.TICK) {
		return self.timer.tick();
	}

	if (msg.kind != tea::MsgKind.KEY) return null;
	tea::KeyMsg k = msg.key;

	switch (k.code) {
		case tea::KeyCode.CTRL_C:
			return tea::quit();
		case tea::KeyCode.RUNE:
			if (k.rune == 'q') return tea::quit();
			if (k.rune == ' ') self.timer.toggle();
			if (k.rune == 'r') {
				self.timer.reset();
				return self.timer.init_cmd();
			}
		default:
	}
	return null;
}

fn tea::View TimerModel.view(TimerModel* self) @dynamic {
	lipgloss::Style box_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true)
		.padding(2, 4, 2, 4)
		.set_border(lipgloss::rounded_border());

	lipgloss::Style subtle = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

	DString out     = dstring::temp();
	int minutes     = self.timer.remaining_seconds / 60;
	int secs        = self.timer.remaining_seconds % 60;
	String time_str = string::tformat("%02d:%02d", minutes, secs);
	out.append_string(box_style.render(time_str));
	out.append_char('\n');

	if (self.timer.done) {
		lipgloss::Style done_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00ff00")).set_bold(true);
		out.append_string(done_style.render("Time's up!"));
	} else if (self.timer.running) {
		out.append_string(subtle.render("SPACE to pause"));
	} else {
		lipgloss::Style pause_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ffff00"));
		out.append_string(pause_style.render("PAUSED"));
		out.append_string(subtle.render("  SPACE to resume"));
	}

	out.append_char('\n');
	out.append_string(subtle.render("r to reset  |  q to quit"));
	return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
	TimerModel m = { };
	if (catch err = tea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}