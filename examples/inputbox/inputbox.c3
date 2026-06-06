// inputbox — minimal xray layout input box test.
// 
// Keys: any printable char → append, backspace → delete, q alone → quit, enter → submit
module inputbox;

import milktea;
import glaze;
import xray;
import xray::layout;
import std::io;
import std::core::dstring;

struct Model {
	DString input;
	DString output;
	int width;
	int height;
}

fn milktea::Cmd Model.init(&self) @dynamic {
	self.input.tinit();
	self.output.tinit();
	self.output.append_string("Type something below.\n");
	self.output.append_string("Enter to submit, q (alone) to quit.");
	return null;
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
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
			self.input.append_char(k.rune);
		default:
	}
	return null;
}

fn milktea::View Model.view(&self) @dynamic {
	int w = self.width > 0 ? self.width : 80;
	int h = self.height > 0 ? self.height : 24;

	xray::Rect full = xray::new_rect(0, 0, w, h);

	String inp_content = string::tformat("> %s█", self.input.str_view());
	String help_text   = string::tformat("  input len: %d chars", (int)self.input.len());

	xray::Rect title_r, output_r, input_r, hint_r;
	layout::vstack(layout::screen(w, h), {
		layout::slot(layout::len(1),    &title_r),
		layout::slot(layout::fill(1),   &output_r),
		layout::slot(layout::len(3),    &input_r),
		layout::slot(layout::len(1),    &hint_r),
	});

	String title_v  = glaze::new_style().foreground(glaze::color_hex("#00ffcc")).set_bold(true).render_in(title_r, "  INPUTBOX TEST");
	String output_v = glaze::new_style().foreground(glaze::color_hex("#aaaaaa")).render_in(output_r, self.output.str_view());
	String input_v  = glaze::new_style().foreground(glaze::color_hex("#ffff00"))
		.set_border(glaze::rounded_border()).padding(0, 1, 0, 1)
		.render_in(input_r, inp_content);
	String hint_v   = glaze::new_style().foreground(glaze::color_hex("#555555")).render_in(hint_r, help_text);

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
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}