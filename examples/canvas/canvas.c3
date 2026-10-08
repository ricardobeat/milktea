module canvas_example;

import milktea;
import glaze;
import std::io;
import std::core::string;

struct CanvasModel {
	bool flip;
}

fn milktea::Cmd CanvasModel.init(CanvasModel* self) @dynamic {
	return null;
}

fn milktea::Cmd CanvasModel.update(CanvasModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			// Any other letter swaps too — C3 switches don't fall through,
			// so the flip must happen here as well as in default.
			self.flip = !self.flip;
		default:
			self.flip = !self.flip;
	}
	return null;
}

fn milktea::View CanvasModel.view(CanvasModel* self) @dynamic {
	glaze::Style card_style = glaze::style().with_width(20).with_height(10)
		.with_border(glaze::ROUNDED)
		.border_fg(glaze::color_hex("#7c3aed"))
		.foreground(glaze::color_hex("#ffffff"))
		.with_bold(true);

	String a = card_style.render(
		glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "Hello"));
	String b = card_style.render(
		glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "Goodbye"));

	glaze::Style footer_style = glaze::style().foreground(glaze::color_hex("#a0a0a0"));
	sz last_row = milktea::screen_height() > 1 ? milktea::screen_height() - 1 : 0;

	// root is a zstack, so children paint in the order they are added and
	// .at() pins each one at an absolute cell. Swapping which card is added
	// last is the whole of the z-order flip.
	milktea::Node* screen = milktea::root()
		.add(milktea::text("Press any key to swap the cards, or q to quit.", footer_style).at(0, last_row));

	if (self.flip) {
		screen.add(milktea::text(b, card_style).at(10, 2));
		screen.add(milktea::text(a, card_style).at(0, 0));
	} else {
		screen.add(milktea::text(a, card_style).at(0, 0));
		screen.add(milktea::text(b, card_style).at(10, 2));
	}

	return milktea::draw(screen);
}

fn int main() {
	CanvasModel m = { };
	return milktea::@run(&m, { .alt_screen = true });
}
