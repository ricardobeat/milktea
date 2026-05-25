module counter;

import milktea;
import glaze;
import std::io;

struct Counter {
	int value;
}

fn milktea::Cmd Counter.init(Counter* self) @dynamic {
	return null;
}

fn milktea::Cmd Counter.update(Counter* self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.UP:
			self.value++;
		case milktea::KeyCode.DOWN:
			self.value--;
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View Counter.view(Counter* self) @dynamic {
	glaze::Style box = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(1, 3, 1, 3)
		.set_border(glaze::rounded_border());

	String label   = string::tformat("Counter: %d", self.value);
	String hint    = "\nUse ↑↓ to change, q to quit";
	String content = string::tformat("%s%s", label, hint);
	return milktea::new_view(box.render(content));
}

fn int main() {
	Counter c = { };
	if (catch err = milktea::@run_program(&c)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("\nBye!");
	return 0;
}