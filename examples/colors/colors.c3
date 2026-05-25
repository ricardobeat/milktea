module colors;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

struct ColorsModel {
	int width;
	int height;
}

fn milktea::Cmd ColorsModel.init(ColorsModel* self) @dynamic {
	return null;
}

fn milktea::Cmd ColorsModel.update(ColorsModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
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

fn milktea::View ColorsModel.view(ColorsModel* self) @dynamic {
	String[16] colors = {
		"#000000", // Black
		"#CD3131", // Red
		"#0DBA48", // Green
		"#CDCD00", // Yellow
		"#0225C4", // Blue
		"#BC3FBC", // Magenta
		"#0DCDCD", // Cyan
		"#E5E5E5", // White
		"#666666", // Bright Black
		"#FF5555", // Bright Red
		"#55FF55", // Bright Green
		"#FFFF55", // Bright Yellow
		"#5555FF", // Bright Blue
		"#FF55FF", // Bright Magenta
		"#55FFFF", // Bright Cyan
		"#FFFFFF" // Bright White
		};

	int block_width  = self.width / 4;
	int block_height = self.height / 4;

	DString out = dstring::temp();

	for (int row = 0; row < 4; row++) {
		for (int line = 0; line < block_height; line++) {
			for (int col = 0; col < 4; col++) {
				int idx      = row * 4 + col;
				String color = colors[idx];

				glaze::Style block = glaze::new_style().background(glaze::color_hex(color));

				DString filler = dstring::temp();
				for (int i = 0; i < block_width; i++) {
					filler.append_char(' ');
				}

				out.append_string(block.render(filler.str_view()));
			}
			out.append_char('\n');
		}
	}

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	ColorsModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}