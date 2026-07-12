module canvas_example;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

struct CanvasModel {
	bool flip;
	int width;
	int height;
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
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
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
		self.card_a = milktea::new_layer("");
		self.card_b = milktea::new_layer("").set_x(10).set_y(2);
		self.footer = milktea::new_layer("");
		self.comp = milktea::new_compositor(self.width, self.height);
		self.comp.add_layer(self.footer);
		self.comp.add_layer(self.card_a);
		self.comp.add_layer(self.card_b);
	}

	// Cards: Width(20) Height(10) with rounded border, centered content
	// The background fill matters: the compositor treats unstyled space
	// cells as transparent, so without an explicit background the lower
	// card would show through this card's interior.
	glaze::Style card_style = glaze::style().width(20).height(10)
		.border(glaze::rounded_border())
		.border_fg(glaze::color_hex("#7c3aed"))
		.border_bg(glaze::color_hex("#1e1e2e"))
		.background(glaze::color_hex("#1e1e2e"))
		.foreground(glaze::color_hex("#ffffff"))
		.bold(true);

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
	self.footer.y = self.height > 1 ? self.height - 1 : 0;
	self.footer.z = 2;

	// Track terminal size and re-sort layers after the z changes.
	self.comp.width = self.width;
	self.comp.height = self.height;
	self.comp.refresh();

	return self.comp.render();
}

fn int main() {
	CanvasModel m = { };
	return milktea::@run(&m);
}
