module batch;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;
const int MSG_TICK = 2;
const int MSG_STEP = 3;

struct Model {
	int spin_frame;
	int seconds;
	int step;
	int width;
	int height;
}

fn milktea::Msg on_spin() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_SPIN };
}

fn milktea::Msg on_tick() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_TICK };
}

fn milktea::Msg on_step() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_STEP };
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.spin_frame = 0;
	self.seconds = 0;
	self.step = 0;
	// Start three independent timers using batch
	milktea::Cmd spin_cmd = milktea::tick(80, &on_spin);
	milktea::Cmd tick_cmd = milktea::tick(1000, &on_tick);
	milktea::Cmd step_cmd = milktea::tick(500, &on_step);
	milktea::Cmd[3] cmds  = { spin_cmd, tick_cmd, step_cmd };
	return milktea::batch(cmds[..]);
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_SPIN) {
		self.spin_frame++;
		return milktea::tick(80, &on_spin);
	}

	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_TICK) {
		self.seconds++;
		return milktea::tick(1000, &on_tick);
	}

	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_STEP) {
		self.step++;
		return milktea::tick(500, &on_step);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View Model.view(Model* self) @dynamic {
	String[8] frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" };
	String spin      = frames[self.spin_frame % 8];

	glaze::Style spin_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(1, 2, 1, 2)
		.set_border(glaze::rounded_border());

	glaze::Style timer_style = glaze::new_style().foreground(glaze::color_hex("#ff00ff")).set_bold(true)
		.padding(1, 2, 1, 2)
		.set_border(glaze::rounded_border());

	glaze::Style step_style = glaze::new_style().foreground(glaze::color_hex("#00ff88")).set_bold(true)
		.padding(1, 2, 1, 2)
		.set_border(glaze::rounded_border());

	glaze::Style hint = glaze::new_style().foreground(glaze::color_hex("#666666"));

	String spin_view  = spin_style.render(string::tformat("%s Spinning...", spin));
	String timer_view = timer_style.render(string::tformat("Timer\n%02d seconds", self.seconds));
	String step_view  = step_style.render(string::tformat("Steps\n%d half-seconds", self.step));

	String top_row   = glaze::join_horizontal(spin_view, timer_view, 2);
	String main_view = glaze::join_vertical(glaze::Position.LEFT, top_row, step_view);
	DString out      = dstring::temp();
	out.append_string(main_view);
	out.append_char('\n');
	out.append_string(hint.render("q to quit"));
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