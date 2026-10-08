module colors;

import milktea;
import glaze;

const sz SWATCH_COLS = 6;

struct ColorsModel {
	char _unused;
}

// colors prints its swatches and quits: the tick fires once the first frame
// is on screen, and an inline program leaves that frame behind.
fn milktea::Cmd ColorsModel.init(ColorsModel* self) @dynamic {
	return milktea::tick(0);
}

fn milktea::Cmd ColorsModel.update(ColorsModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.TICK) return milktea::quit();
	return null;
}

fn milktea::Node* ColorsModel.view(ColorsModel* self) @dynamic {
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

	// Inline, the program is as tall as this grid: four rows of swatches.
	milktea::Node* grid = milktea::vstack();
	for (sz row = 0; row < 4; row++) {
		milktea::Node* r = milktea::hstack();
		for (sz col = 0; col < 4; col++) {
			glaze::Style block = glaze::style().background(glaze::color_hex(colors[row * 4 + col]));
			r.add(milktea::text("", block).width(milktea::cells(SWATCH_COLS)));
		}
		grid.add(r);
	}
	return grid;
}

fn int main() {
	ColorsModel m = { };
	return milktea::@run(&m);
}
