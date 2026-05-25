module counter;

import tea;
import lipgloss;
import std::io;

struct Counter {
	int value;
}

fn tea::Cmd Counter.init(Counter* self) @dynamic {
	return null;
}

fn tea::Cmd Counter.update(Counter* self, tea::Msg msg) @dynamic {
	if (msg.kind != tea::MsgKind.KEY) return null;
	tea::KeyMsg k = msg.key;
	switch (k.code) {
		case tea::KeyCode.UP:
			self.value++;
		case tea::KeyCode.DOWN:
			self.value--;
		case tea::KeyCode.CTRL_C:
			return tea::quit();
		case tea::KeyCode.RUNE:
			if (k.rune == 'q') return tea::quit();
		default:
	}
	return null;
}

fn tea::View Counter.view(Counter* self) @dynamic {
	lipgloss::Style box = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true)
		.padding(1, 3, 1, 3)
		.set_border(lipgloss::rounded_border());

	String label   = string::tformat("Counter: %d", self.value);
	String hint    = "\nUse ↑↓ to change, q to quit";
	String content = string::tformat("%s%s", label, hint);
	return tea::new_view(box.render(content));
}

fn int main() {
	Counter c = { };
	if (catch err = tea::@run_program(&c)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("\nBye!");
	return 0;
}