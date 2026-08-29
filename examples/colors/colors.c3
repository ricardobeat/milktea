module colors;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

// The model is stateless: the palette is drawn from the terminal size, which
// milktea tracks internally (see milktea::screen_width/screen_height).
// C3 does not permit zero-sized structs, hence the placeholder field.
struct ColorsModel {
	char _unused;
}

fn milktea::Cmd ColorsModel.init(ColorsModel* self) @dynamic {
	return null;
}

fn milktea::Cmd ColorsModel.update(ColorsModel* self, milktea::Msg msg) @dynamic {
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

	int block_width  = milktea::screen_width() / 4;
	int block_height = milktea::screen_height() / 4;

	DString out = dstring::temp();

	for (int row = 0; row < 4; row++) {
		for (int line = 0; line < block_height; line++) {
			for (int col = 0; col < 4; col++) {
				int idx      = row * 4 + col;
				String color = colors[idx];

				glaze::Style block = glaze::style().background(glaze::color_hex(color));

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
	return milktea::@run(&m);
}