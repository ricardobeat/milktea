module spinner;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;

struct SpinnerModel {
	int frame;
}

fn milktea::Cmd SpinnerModel.init(SpinnerModel* self) @dynamic {
	self.frame = 0;
	return milktea::tick(80, &on_spin);
}

fn milktea::Msg on_spin() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_SPIN };
}

fn milktea::Cmd SpinnerModel.update(SpinnerModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_SPIN) {
		self.frame++;
		return milktea::tick(80, &on_spin);
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

fn milktea::View SpinnerModel.view(SpinnerModel* self) @dynamic {
	String[12] frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "⠋", "⠙" };
	String spin       = frames[self.frame % 12];

	glaze::Style title = glaze::style().foreground(glaze::color_hex("#00d7ff")).bold(true);

	glaze::Style subtle = glaze::style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title.render(string::tformat("%s  Loading...", spin)));
	out.append_char('\n');
	out.append_string(subtle.render("Press q to quit"));
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	SpinnerModel m = { };
	milktea::@run(&m);
	return 0;
}