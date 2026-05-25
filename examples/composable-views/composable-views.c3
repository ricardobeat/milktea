module composable_views;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;
const int MSG_TICK = 2;

struct Model {
	int spin_frame;
	int seconds;
	int focus; // 0 = timer, 1 = spinner
	int width;
	int height;
}

fn tea::Cmd Model.init(Model* self) @dynamic {
	self.spin_frame = 0;
	self.seconds = 0;
	self.focus = 0;
	return tea::tick(100, &on_tick);
}

fn tea::Msg on_tick() {
	return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd Model.update(Model* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
		self.spin_frame++;
		self.seconds++;
		return tea::tick(100, &on_tick);
	}

	if (msg.kind != tea::MsgKind.KEY) return null;
	tea::KeyMsg k = msg.key;

	switch (k.code) {
		case tea::KeyCode.CTRL_C:
			return tea::quit();
		case tea::KeyCode.TAB:
			self.focus = 1 - self.focus;
		case tea::KeyCode.RUNE:
			if (k.rune == 'q') return tea::quit();
			if (k.rune == 'n') {
				self.seconds = 0;
				self.spin_frame = 0;
			}
		case tea::KeyCode.ESC:
			return tea::quit();
		default:
	}
	return null;
}

fn tea::View Model.view(Model* self) @dynamic {
	String[8] frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" };
	String spin      = frames[self.spin_frame % 8];
	int mins         = self.seconds / 60;
	int secs         = self.seconds % 60;

	lipgloss::Border active_border = lipgloss::rounded_border();
	lipgloss::Border inactive_border = {
		.top = " ",
		.bottom = " ",
		.left = " ",
		.right = " ",
		.top_left = " ",
		.top_right = " ",
		.bottom_left = " ",
		.bottom_right = " "
	};

	lipgloss::Border timer_border = (self.focus == 0) ? active_border : inactive_border;
	lipgloss::Border spin_border  = (self.focus == 1) ? active_border : inactive_border;

	lipgloss::Style timer_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true)
		.padding(1, 2, 1, 2)
		.set_border(timer_border);

	lipgloss::Style spin_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true)
		.padding(1, 2, 1, 2)
		.set_border(spin_border);

	lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

	String timer_raw = timer_style.render(string::tformat("Timer\n%02d:%02d", mins, secs));
	String spin_raw  = spin_style.render(string::tformat("Spinner\n%s Loading...", spin));

	String timer_view = lipgloss::place_pos(15, 5, lipgloss::Position.CENTER, lipgloss::Position.CENTER, timer_raw);
	String spin_view  = lipgloss::place_pos(15, 5, lipgloss::Position.CENTER, lipgloss::Position.CENTER, spin_raw);
	String joined     = lipgloss::join_horizontal_pos(lipgloss::Position.TOP, timer_view, spin_view, 2);

	DString out = dstring::temp();
	out.append_string(joined);
	out.append_char('\n');
	out.append_string(hint.render("TAB switch focus | n reset | q quit"));
	return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
	Model m = { };
	if (catch err = tea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}