module spinner;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

// The spinner has no state of its own: which frame shows is a function of the
// clock, and the view asks to be painted again when the next one is due.
const sz SPIN_MS = 80;
const String[*] FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

struct SpinnerModel {
	String label;
}

fn milktea::Cmd SpinnerModel.init(SpinnerModel* self) @dynamic {
	self.label = "Loading...";
	return null;
}

fn milktea::Cmd SpinnerModel.update(SpinnerModel* self, milktea::Msg msg) @dynamic {
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
	String spin = FRAMES[milktea::now() / SPIN_MS % FRAMES.len];

	glaze::Style title = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);

	glaze::Style subtle = glaze::style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title.render(string::tformat("%s  %s", spin, self.label)));
	out.append_char('\n');
	out.append_string(subtle.render("Press q to quit"));
	return milktea::view(out.str_view()).repaint_after(SPIN_MS);
}

fn int main() {
	SpinnerModel m = { };
	milktea::@run(&m, { .alt_screen = true });
	return 0;
}