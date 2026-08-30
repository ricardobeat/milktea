module colors;

import milktea;
import glaze;

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
		"#FFFFFF"  // Bright White
		};

	milktea::Node* grid = milktea::vstack();
	for (int row = 0; row < 4; row++) {
		milktea::Node* r = milktea::hstack().fill(1);
		for (int col = 0; col < 4; col++) {
			glaze::Style block = glaze::style().background(glaze::color_hex(colors[row * 4 + col]));
			r.add(milktea::text(block, "").fill(1));
		}
		grid.add(r);
	}

	return milktea::draw(milktea::root().add(grid));
}

fn int main() {
	ColorsModel m = { };
	return milktea::@run(&m);
}
