// inputbox — minimal xray layout input box test.
// 
// Keys: any printable char → append, backspace → delete, q alone → quit, enter → submit
module inputbox;

import milktea;
import glaze;
import xray::layout;
import std::io;
import std::core::dstring;

struct Model {
	DString input;
	DString output;
}

fn milktea::Cmd Model.init(&self) @dynamic {
	self.input.tinit();
	self.output.tinit();
	self.output.append_string("Type something below.\n");
	self.output.append_string("Enter to submit, q (alone) to quit.");
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

fn milktea::View Model.view(&self) @dynamic {
	int w = milktea::screen_width();
	int h = milktea::screen_height();

	String inp_content = string::tformat("> %s█", self.input.str_view());
	String help_text   = string::tformat("  input len: %d chars", (int)self.input.len());

	xray::Rect title_r, output_r, input_r, hint_r;
	layout::vstack(layout::screen(w, h), {
		layout::slot(layout::cells(1),    &title_r),
		layout::slot(layout::fill(1),   &output_r),
		layout::slot(layout::cells(3),    &input_r),
		layout::slot(layout::cells(1),    &hint_r),
	});

	glaze::Style title_s  = glaze::style().foreground(glaze::color_hex("#00ffcc")).bold(true);
	glaze::Style output_s = glaze::style().foreground(glaze::color_hex("#aaaaaa"));
	glaze::Style input_s  = glaze::style().foreground(glaze::color_hex("#ffff00"))
		.border(glaze::rounded_border()).padding(0, 1, 0, 1);
	glaze::Style hint_s   = glaze::style().foreground(glaze::color_hex("#555555"));

	String title_v  = title_r.render(title_s,  "  INPUTBOX TEST");
	String output_v = output_r.render(output_s, self.output.str_view());
	String input_v  = input_r.render(input_s,   inp_content);
	String hint_v   = hint_r.render(hint_s,     help_text);

	String doc = glaze::join_vertical(glaze::Position.LEFT, title_v, output_v);
	doc = glaze::join_vertical(glaze::Position.LEFT, doc, input_v);
	doc = glaze::join_vertical(glaze::Position.LEFT, doc, hint_v);
	return milktea::new_alt_screen_view(doc);
}

fn void Model.on_destroy(&self) @dynamic {
	self.input.free();
	self.output.free();
}

fn int main() {
	Model m = { };
	milktea::@run(&m);
	return 0;
}