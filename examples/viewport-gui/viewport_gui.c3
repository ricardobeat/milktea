// viewport-gui: a boba::Viewport in a window, to try smooth scrolling. A
// trackpad scrolls it by the pixel and with the platform's momentum, pulls
// past either end with resistance and springs back; a mouse wheel and the
// keys (↑↓, PgUp/PgDn, Home/End) scroll by rows.
module viewport_gui;

import milktea;
import milktea_gui;
import boba;
import glaze;
import xray;
import std::core::string;

const sz LINES = 400;

struct Model {
	boba::Viewport vp;
}

const String[10] FRAGMENTS = {
	"The quick brown fox jumps over the lazy dog.",
	"Pack my box with five dozen liquor jugs.",
	"How vexingly quick daft zebras jump.",
	"The five boxing wizards jump quickly.",
	"Sphinx of black quartz, judge my vow.",
	"Two driven jocks help fax my big quiz.",
	"Bright vixens jump; dozy fowl quack.",
	"Quick zephyrs blow, vexing daft Jim.",
	"Jived fox nymph grabs quick walwart.",
	"Crazy Frederick bought many very opal jewels.",
};

fn milktea::Cmd Model.init(&self) @dynamic {
	self.vp = boba::new_viewport(80, 20);
	// The viewport's lines are plain text; content_style colours them.
	for (sz i = 0; i < LINES; i++) {
		self.vp.add_line(string::format(mem, "%4d  %s", i + 1, FRAGMENTS[i % FRAGMENTS.len]));
	}
	self.vp.set_content(LINES);
	return null;
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case milktea::MsgKind.MOUSE:
			self.vp.handle_mouse_msg(msg.mouse);
		case milktea::MsgKind.KEY:
			if (msg.key.code == milktea::KeyCode.CTRL_C || msg.key.code == milktea::KeyCode.ESC) return milktea::quit();
			if (msg.key.code == milktea::KeyCode.RUNE && msg.key.rune == 'q') return milktea::quit();
			self.vp.handle_key(msg.key);
		default:
	}
	return null;
}

fn milktea::Node* Model.view(&self) @dynamic {
	glaze::Style bar = glaze::style().foreground(glaze::color_hex("#00d7ff")).background(glaze::color_hex("#1c1f26"));
	return milktea::vstack()
		.add(milktea::text(string::tformat(" Smooth scrolling  —  %d%%", self.vp.scroll_percent()), bar)
			.height(milktea::cells(1)))
		.add(self.vp.node().fill(1));
}

fn int main() {
	Model m = { };
	milktea_gui::run((milktea::Model)&m, {
		.title = "viewport (gui)",
		.cols = 80, .rows = 30,
		.cell_w = 10, .cell_h = 19,
		.font_size = 17,
	});
	return 0;
}
