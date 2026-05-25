module spinners;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;

struct SpinnersModel {
	int frame;
	int width;
	int height;
}

fn milktea::Cmd SpinnersModel.init(SpinnersModel* self) @dynamic {
	return milktea::tick(80, &on_spin);
}

fn milktea::Msg on_spin() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_SPIN };
}

fn milktea::Cmd SpinnersModel.update(SpinnersModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

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
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

struct SpinnerDef {
	String name;
	String[8] frames;
	int count;
}

fn milktea::View SpinnersModel.view(SpinnersModel* self) @dynamic {
	SpinnerDef[6] spinners;
	spinners[0] = { .name = "Dots", .frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }, .count = 8 };
	spinners[1] = { .name = "Lines", .frames = { "-", "\\", "|", "/", "-", "\\", "|", "/" }, .count = 4 };
	spinners[2] = { .name = "Arrow", .frames = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" }, .count = 8 };
	spinners[3] = {
		.name = "Blocks",
		.frames = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" },
		.count = 8
	};
	spinners[4] = {
		.name = "Moon",
		.frames = { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" },
		.count = 8
	};
	spinners[5] = {
		.name = "Pulse",
		.frames = {
			"∙∙∙",
			"●∙∙",
			"∙●∙",
			"∙∙●",
			"∙∙∙",
			"∙∙∙",
			"∙∙∙",
			"∙∙∙"
		},
		.count = 5
	};

	glaze::Style title = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(0, 0, 1, 0);

	glaze::Style label = glaze::new_style().foreground(glaze::color_hex("#888888"));

	glaze::Style active = glaze::new_style().foreground(glaze::color_hex("#ff00ff")).set_bold(true);

	glaze::Style box_style = glaze::new_style().set_border(glaze::rounded_border()).padding(1, 2, 1, 2);

	DString content = dstring::temp();
	content.append_string(title.render("Spinner Gallery"));
	content.append_char('\n');

	String[6] spin_views;
	for (int i = 0; i < 6; i++) {
		int idx     = self.frame % spinners[i].count;
		String spin = spinners[i].frames[idx];
		String name = spinners[i].name;
		spin_views[i] = string::tformat(
			"%s%s",
			active.render(string::tformat("  %s", spin)),
			label.render(string::tformat("  %s", name))
		);
	}
	content.append_string(glaze::join_horizontal_arr(glaze::Position.TOP, spin_views[..], 3));

	content.append_char('\n');
	content.append_string(label.render("Press q or ESC to quit"));

	return milktea::new_alt_screen_view(box_style.render(content.str_view()));
}

fn int main() {
	SpinnersModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}