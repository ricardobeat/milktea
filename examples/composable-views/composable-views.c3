module composable_views;

import milktea;
import glaze;
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

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.spin_frame = 0;
	self.seconds = 0;
	self.focus = 0;
	return milktea::tick(100, &on_tick);
}

fn milktea::Msg on_tick() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_TICK };
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_TICK) {
		self.spin_frame++;
		self.seconds++;
		return milktea::tick(100, &on_tick);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.TAB:
			self.focus = 1 - self.focus;
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'n') {
				self.seconds = 0;
				self.spin_frame = 0;
			}
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View Model.view(Model* self) @dynamic {
	String[8] frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" };
	String spin      = frames[self.spin_frame % 8];
	int mins         = self.seconds / 60;
	int secs         = self.seconds % 60;

	glaze::Border active_border = glaze::rounded_border();
	glaze::Border inactive_border = {
		.top = " ",
		.bottom = " ",
		.left = " ",
		.right = " ",
		.top_left = " ",
		.top_right = " ",
		.bottom_left = " ",
		.bottom_right = " "
	};

	glaze::Border timer_border = (self.focus == 0) ? active_border : inactive_border;
	glaze::Border spin_border  = (self.focus == 1) ? active_border : inactive_border;

	glaze::Style timer_style = glaze::new_style().foreground(glaze::color_hex("#ff00ff")).set_bold(true)
		.padding(1, 2, 1, 2)
		.set_border(timer_border);

	glaze::Style spin_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(1, 2, 1, 2)
		.set_border(spin_border);

	glaze::Style hint = glaze::new_style().foreground(glaze::color_hex("#666666"));

	String timer_raw = timer_style.render(string::tformat("Timer\n%02d:%02d", mins, secs));
	String spin_raw  = spin_style.render(string::tformat("Spinner\n%s Loading...", spin));

	String timer_view = glaze::place_pos(15, 5, glaze::Position.CENTER, glaze::Position.CENTER, timer_raw);
	String spin_view  = glaze::place_pos(15, 5, glaze::Position.CENTER, glaze::Position.CENTER, spin_raw);
	String joined     = glaze::join_horizontal_pos(glaze::Position.TOP, timer_view, spin_view, 2);

	DString out = dstring::temp();
	out.append_string(joined);
	out.append_char('\n');
	out.append_string(hint.render("TAB switch focus | n reset | q quit"));
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	Model m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}