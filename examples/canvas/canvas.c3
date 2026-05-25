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

	// Cards: Width(20) Height(10) with rounded border, centered content
	glaze::Style card_style = glaze::new_style().set_width(20).set_height(10)
		.set_border(glaze::rounded_border())
		.set_border_fg(glaze::color_hex("#7c3aed"))
		.foreground(glaze::color_hex("#ffffff"))
		.set_bold(true);

	String card_a_content = glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "Hello");
	String card_b_content = glaze::place_pos(16, 6, glaze::Position.CENTER, glaze::Position.CENTER, "Goodbye");

	glaze::Layer* card_a = glaze::new_layer(card_style.render(card_a_content)).set_z(z_a);
	glaze::Layer* card_b = glaze::new_layer(card_style.render(card_b_content)).set_x(10).set_y(2).set_z(z_b);

	// Footer
	glaze::Style footer_style = glaze::new_style().set_height(3).foreground(glaze::color_hex("#a0a0a0"));
	String footer_text           = "Press any key to swap the cards, or q to quit.";
	glaze::Layer* footer      = glaze::new_layer(footer_style.render(footer_text));

	// Compose
	glaze::Compositor* comp = glaze::new_compositor();
	comp.add_layer(footer);
	comp.add_layer(card_a);
	comp.add_layer(card_b);

	return milktea::new_alt_screen_view(comp.render());
}

fn int main() {
	CanvasModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}