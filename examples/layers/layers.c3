module layers_example;

import milktea;
import glaze;
import xray;
import std::io;
import std::core::string;

struct LayersModel {
	sz[3] order;
}

fn milktea::Cmd LayersModel.update(LayersModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	sz focused = (self.order[2] + 1) % 3;
	for (sz i = 0; i < 3; i++) {
		if (self.order[i] != focused) continue;
		for (sz j = i; j < 2; j++) self.order[j] = self.order[j + 1];
		self.order[2] = focused;
		break;
	}
	return null;
}

fn milktea::Node* LayersModel.view(LayersModel* self) @dynamic {
	glaze::Style card_style = glaze::style().with_width(20).with_height(10)
		.with_border(glaze::ROUNDED)
		.border_fg(glaze::color_hex("#7c3aed"))
		.foreground(glaze::color_hex("#ffffff"))
		.background(glaze::color_hex("#000000"))
		.with_bold(true);

	String a = card_style.render(
		glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "good afternoon"));
	String b = card_style.render(
		glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "good evening"));

	glaze::Style footer_style = glaze::style().foreground(glaze::color_hex("#a0a0a0"));
	sz last_row = milktea::screen_height() > 1 ? milktea::screen_height() - 1 : 0;
	sz x = (milktea::screen_width() - 40) / 2;
	sz y = (milktea::screen_height() - 14) / 2;
	if (x < 0) x = 0;
	if (y < 0) y = 0;

	milktea::Node* screen = milktea::root()
		.add(milktea::text("Press any key to focus the next card, or q to quit.", footer_style).at(0, last_row));

	glaze::Style third_style = card_style.background(xray::color_rgba(24, 24, 24, 180));
	milktea::Node*[3] cards = {
		milktea::text(a).at(x + 20, y + 4),
		milktea::text(b).at(x + 10, y + 2),
		milktea::root()
			.style(third_style).width(xray::cells(20)).height(xray::cells(10)).at(x, y)
			.add(milktea::text("good night",
				glaze::style().foreground(glaze::color_hex("#ffffff")).with_bold(true)).center()),
	};
	foreach (i : self.order) screen.add(cards[i]);

	return screen;
}

fn int main() {
	LayersModel m = { .order = { 2, 1, 0 } };
	return milktea::@run(&m, { .alt_screen = true });
}
