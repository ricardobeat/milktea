// inputbox — text input and submission history.
// 
// Keys: any printable char → append, backspace → delete, q alone → quit, enter → submit
module inputbox;

import milktea;
import glaze;
import std::io;
import std::core::dstring;

struct Model {
	DString input;
	DString output;
}

fn milktea::Cmd Model.init(&self) @dynamic {
	// Model state survives the runtime's temporary allocation pools.
	self.input.init(mem);
	self.output.init(mem);
	self.output.append_string("Type something below.\n");
	self.output.append_string("Enter to submit.");
	return null;
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;

	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.ENTER:
			if (self.input.len() > 0) {
				self.output.append_char('\n');
				self.output.append_string(">> ");
				self.output.append_string(self.input.str_view());
				self.input.clear();
			}
		case milktea::KeyCode.BACKSPACE:
			sz l = self.input.len();
			if (l > 0) self.input.chop(l - 1);
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q' && self.input.len() == 0) return milktea::quit();
			// rune is a codepoint — encode as UTF-8 before appending
			char[4] enc;
			sz n = milktea::utf8_encode(k.rune, enc[..]);
			self.input.append_string((String)enc[:n]);
		default:
	}
	return null;
}

fn milktea::Node* Model.view(&self) @dynamic {
	String input = string::tformat("> %s█", self.input.str_view());
	String hint  = string::tformat("input len: %d chars", self.input.len());

	glaze::Style output_style = glaze::style().foreground(glaze::color_hex("#aaaaaa")).padding(0, 0, 0, 1);
	glaze::Style input_style = glaze::style().foreground(glaze::color_hex("#ffff00")).with_border(glaze::ROUNDED)
		.padding(0, 1, 0, 1);
	glaze::Style hint_style = glaze::style().foreground(glaze::color_hex("#777777")).padding(0, 1, 0, 1);

	glaze::Style title_style = glaze::style().foreground(glaze::color_hex("#00ffcc")).with_bold(true);

	return milktea::vstack()
		.add(milktea::text("Input test", title_style).height(milktea::cells(1)))
		.add(milktea::text(self.output.str_view(), output_style).fill(1))
		.add(milktea::text(input, input_style).height(milktea::cells(3)))
		.add(milktea::text(hint, hint_style).height(milktea::cells(1)))
		.with_gap(1)
		.with_padding(1, 2, 1, 2);
}

fn void Model.on_destroy(&self) @dynamic {
	self.input.free();
	self.output.free();
}

fn int main() {
	Model m = { };
	milktea::@run(&m, { .alt_screen = true });
	return 0;
}
