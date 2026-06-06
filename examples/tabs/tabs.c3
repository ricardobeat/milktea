module tabs;

import milktea;
import glaze;
import std::io;

struct TabsModel {
	int active_tab;
}

fn milktea::Cmd TabsModel.init(TabsModel* self) @dynamic {
	return null;
}

fn milktea::Cmd TabsModel.update(TabsModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C: return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'h') { if (self.active_tab > 0) self.active_tab--; }
			if (k.rune == 'l') { if (self.active_tab < 2) self.active_tab++; }
		case milktea::KeyCode.LEFT:  if (self.active_tab > 0) self.active_tab--;
		case milktea::KeyCode.RIGHT: if (self.active_tab < 2) self.active_tab++;
		default:
	}
	return null;
}

const String[3] TAB_NAMES    = { "Home", "About", "Settings" };
const String[3] TAB_CONTENTS = {
	"Welcome to milktea!\n\nA Bubble Tea-inspired TUI framework for C3.\nUse ← → or h/l to switch tabs.",
	"milktea  event loop and TTY management\nglaze    styling and layout\nboba     reusable widgets",
	"Theme     Default\nBorder    Rounded\nColors    True color",
};

fn milktea::View TabsModel.view(TabsModel* self) @dynamic {
	glaze::Style active_style = glaze::new_style()
		.foreground(glaze::color_hex("#ffffff"))
		.set_border(glaze::rounded_border())
		.set_border_fg(glaze::color_hex("#874bfc"))
		.padding(0, 1, 0, 1)
		.set_bold(true);

	glaze::Style inactive_style = glaze::new_style()
		.foreground(glaze::color_hex("#626262"))
		.set_border(glaze::rounded_border())
		.set_border_fg(glaze::color_hex("#3c3c3c"))
		.padding(0, 1, 0, 1);

	glaze::Style content_style = glaze::new_style()
		.foreground(glaze::color_hex("#dddddd"))
		.set_border(glaze::rounded_border())
		.set_border_fg(glaze::color_hex("#874bfc"))
		.padding(1, 2, 1, 2)
		.set_width(50)
		.set_height(8)
		.align(glaze::Position.LEFT, glaze::Position.TOP);

	String[3] tab_views;
	for (int i = 0; i < 3; i++) {
		tab_views[i] = i == self.active_tab
			? active_style.render(TAB_NAMES[i])
			: inactive_style.render(TAB_NAMES[i]);
	}

	String tabbar  = glaze::join_horizontal_arr(glaze::Position.BOTTOM, tab_views[..], 0);
	String content = content_style.render(TAB_CONTENTS[self.active_tab]);
	String hint    = "\n  ← → / h l  switch tabs    q  quit";

	return milktea::new_view(
		glaze::join_vertical(glaze::Position.LEFT, tabbar,
			glaze::join_vertical(glaze::Position.LEFT, content, hint)));
}

fn int main() {
	TabsModel m = { };
	return milktea::@run(&m);
}
