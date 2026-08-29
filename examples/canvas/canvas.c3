module canvas_example;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

struct CanvasModel {
	bool flip;
	// Compositor and layers are created once and reused every frame —
	// creating them inside view() would leak heap memory on every render.
	milktea::Compositor* comp;
	milktea::Layer* card_a;
	milktea::Layer* card_b;
	milktea::Layer* footer;
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
	// Z-order: normally cardA on top, flip swaps
	int z_a = 0;
	int z_b = 1;
	if (self.flip) {
		z_a = 1;
		z_b = 0;
	}

	// Lazily build the layer tree on the first frame; reuse it afterwards.
	if (self.comp == null) {
		// Opaque: the cards keep the terminal's default background but
		// still fully occlude whatever is underneath them.
		self.card_a = milktea::new_layer("").set_opaque();
		self.card_b = milktea::new_layer("").set_x(10).set_y(2).set_opaque();
		self.footer = milktea::new_layer("");
		self.comp = milktea::new_compositor(milktea::screen_width(), milktea::screen_height());
		self.comp.add_layer(self.footer);
		self.comp.add_layer(self.card_a);
		self.comp.add_layer(self.card_b);
	}

	// Cards: Width(20) Height(10) with rounded border, centered content
	glaze::Style card_style = glaze::style().with_width(20).with_height(10)
		.with_border(glaze::ROUNDED)
		.border_fg(glaze::color_hex("#7c3aed"))
		.foreground(glaze::color_hex("#ffffff"))
		.with_bold(true);

	String card_a_content = glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "Hello");
	String card_b_content = glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "Goodbye");

	// Content strings are temp-allocated per frame; reassign them each time.
	self.card_a.content = card_style.render(card_a_content);
	self.card_a.z = z_a;
	self.card_b.content = card_style.render(card_b_content);
	self.card_b.z = z_b;

	// Footer sits on the bottom row, below both cards.
	glaze::Style footer_style = glaze::style().foreground(glaze::color_hex("#a0a0a0"));
	self.footer.content = footer_style.render("Press any key to swap the cards, or q to quit.");
	self.footer.y = milktea::screen_height() > 1 ? milktea::screen_height() - 1 : 0;
	self.footer.z = 2;

	// Track terminal size and re-sort layers after the z changes.
	self.comp.width = milktea::screen_width();
	self.comp.height = milktea::screen_height();
	self.comp.refresh();

	return self.comp.render();
}

fn int main() {
	CanvasModel m = { };
	return milktea::@run(&m);
}
