module viewport;

import milktea;
import glaze;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

const int TOTAL_LINES = 80;

struct ViewportModel {
	boba::Viewport vp;
}

fn milktea::Cmd ViewportModel.init(ViewportModel* self) @dynamic {
	self.vp = boba::new_viewport(80, 10);
	self.vp.set_content(TOTAL_LINES);
	return null;
}

fn milktea::Cmd ViewportModel.update(ViewportModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.vp.width = msg.window_size.width;
		self.vp.height = msg.window_size.height - 6;
		if (self.vp.height < 3) self.vp.height = 3;
		self.vp.set_content(TOTAL_LINES);
		return null;
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	if (self.vp.handle_key(k)) return null;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'j') self.vp.scroll_down();
			if (k.rune == 'k') self.vp.scroll_up();
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

fn String lorem_line(int i) {
	String[10] fragments = {
		"The quick brown fox jumps over the lazy dog.",
		"Pack my box with five dozen liquor jugs.",
		"How vexingly quick daft zebras jump.",
		"The five boxing wizards jump quickly.",
		"Sphinx of black quartz, judge my vow.",
		"Two driven jocks help fax my big quiz.",
		"Bright vixens jump; dozy fowl quack.",
		"Quick zephyrs blow, vexing daft Jim.",
		"Jived fox nymph grabs quick walwart.",
		"Crazy Frederick bought many very opal jewels."
	};
	return fragments[i % 10];
}

fn milktea::View ViewportModel.view(ViewportModel* self) @dynamic {
	glaze::Style title_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(0, 2, 0, 0);
	glaze::Style line_style = glaze::new_style().foreground(glaze::color_hex("#cccccc"));
	glaze::Style dim_style  = glaze::new_style().foreground(glaze::color_hex("#444444"));
	glaze::Style highlight_style = glaze::new_style().background(glaze::color_hex("#333355"))
		.foreground(glaze::color_hex("#ffffff"));
	glaze::Style box_style = glaze::new_style().set_border(glaze::rounded_border()).padding(0, 1, 0, 1);

	DString out = dstring::temp();
	out.append_string(title_style.render("Scrollable Viewport"));
	out.append_char('\n');

	int start   = self.vp.view_line_start();
	int end     = self.vp.view_line_end();
	int visible = end - start;

	DString body = dstring::temp();
	for (int i = 0; i < visible; i++) {
		int line_num = start + i;

		String num     = string::tformat("%4d ", line_num + 1);
		String content = lorem_line(line_num);

		if (i == visible / 2) {
			body.append_string(highlight_style.render(string::tformat("%s%s", num, content)));
		} else {
			body.append_string(dim_style.render(num));
			body.append_string(line_style.render(content));
		}
		body.append_char('\n');
	}

	out.append_string(box_style.render(body.str_view()));

	int pct = self.vp.scroll_percent();
	String bar = glaze::progress_bar(
		20,
		pct,
		"█",
		"░",
		glaze::color_hex("#00d7ff"),
		glaze::color_hex("#333333")
	);
	out.append_char('\n');
	out.append_string(
		dim_style.render(
			string::tformat(" %s %d%%  |  ↑↓ j/k scroll  |  PgUp/PgDn  |  Home/End  |  q quit", bar, pct)
		)
	);

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	ViewportModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}