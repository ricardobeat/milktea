module canvas_example;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct CanvasModel {
	bool flip;
	int width;
	int height;
}

fn tea::Cmd CanvasModel.init(CanvasModel* self) @dynamic {
	return null;
}

fn tea::Cmd CanvasModel.update(CanvasModel* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind != tea::MsgKind.KEY) return null;
	tea::KeyMsg k = msg.key;
	switch (k.code) {
		case tea::KeyCode.CTRL_C:
		case tea::KeyCode.ESC:
			return tea::quit();
		case tea::KeyCode.RUNE:
			if (k.rune == 'q') return tea::quit();
		default:
			self.flip = !self.flip;
	}
	return null;
}

fn tea::View CanvasModel.view(CanvasModel* self) @dynamic {
	// Z-order: normally cardA on top, flip swaps
	int z_a = 0;
	int z_b = 1;
	if (self.flip) {
		z_a = 1;
		z_b = 0;
	}

	// Cards: Width(20) Height(10) with rounded border, centered content
	lipgloss::Style card_style = lipgloss::new_style().set_width(20).set_height(10)
		.set_border(lipgloss::rounded_border())
		.set_border_fg(lipgloss::color_hex("#7c3aed"))
		.foreground(lipgloss::color_hex("#ffffff"))
		.set_bold(true);

	String card_a_content = lipgloss::place_pos(16, 6, lipgloss::Position.CENTER, lipgloss::Position.CENTER, "Hello");
	String card_b_content = lipgloss::place_pos(16, 6, lipgloss::Position.CENTER, lipgloss::Position.CENTER, "Goodbye");

	lipgloss::Layer* card_a = lipgloss::new_layer(card_style.render(card_a_content)).set_z(z_a);
	lipgloss::Layer* card_b = lipgloss::new_layer(card_style.render(card_b_content)).set_x(10).set_y(2).set_z(z_b);

	// Footer
	lipgloss::Style footer_style = lipgloss::new_style().set_height(3).foreground(lipgloss::color_hex("#a0a0a0"));
	String footer_text           = "Press any key to swap the cards, or q to quit.";
	lipgloss::Layer* footer      = lipgloss::new_layer(footer_style.render(footer_text));

	// Compose
	lipgloss::Compositor* comp = lipgloss::new_compositor();
	comp.add_layer(footer);
	comp.add_layer(card_a);
	comp.add_layer(card_b);

	return tea::new_alt_screen_view(comp.render());
}

fn int main() {
	CanvasModel m = { };
	if (catch err = tea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}