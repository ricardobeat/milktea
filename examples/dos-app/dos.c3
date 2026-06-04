module dos_app;

import milktea;
import glaze;
import std::io;

const String DOS_BLUE   = "#0000aa";
const String DOS_CYAN   = "#00aaaa";
const String DOS_WHITE  = "#ffffff";
const String DOS_GRAY   = "#aaaaaa";
const String DOS_DARK   = "#000055";
const String DOS_YELLOW = "#ffff55";

struct TabsModel {
	int active_tab;
	int width;
	int height;
}

fn milktea::Cmd TabsModel.init(TabsModel* self) @dynamic {
	return null;
}

fn milktea::Cmd TabsModel.update(TabsModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C: return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == '1') self.active_tab = 0;
			if (k.rune == '2') self.active_tab = 1;
			if (k.rune == '3') self.active_tab = 2;
			if (k.rune == '4') self.active_tab = 3;
			if (k.rune == 'h') { if (self.active_tab > 0) self.active_tab--; }
			if (k.rune == 'l') { if (self.active_tab < 3) self.active_tab++; }
		case milktea::KeyCode.LEFT:  if (self.active_tab > 0) self.active_tab--;
		case milktea::KeyCode.RIGHT: if (self.active_tab < 3) self.active_tab++;
		case milktea::KeyCode.ESC:   return milktea::quit();
		default:
	}
	return null;
}

struct TabContent { String title; String body; }

fn TabContent tab_content(int tab) {
	switch (tab) {
		case 0: return { "Welcome",
			"milktea\n\nAn event-driven TUI framework\nfor the C3 programming language.\n\nUse arrow keys or h/l to navigate.\nPress 1-4 to jump to a tab." };
		case 1: return { "About",
			"C3 Programming Language\n\nA modern systems language with\nC interop and memory safety.\n\nThis demo uses:\n  milktea  TUI runtime\n  glaze    styling & layout\n  xray     cell renderer" };
		case 2: return { "Keyboard Shortcuts",
			"Navigation\n\n  Left / Right   Switch tabs\n  h / l          Switch tabs\n  1 - 4          Jump to tab\n  q / ESC        Quit\n  Ctrl+C         Force quit" };
		default: return { "Settings",
			"Configuration\n\n  Theme        DOS Classic\n  Colors       16-color ANSI\n  Border       Double\n  Animations   Enabled\n\n  (Placeholder)" };
	}
}

fn milktea::View TabsModel.view(TabsModel* self) @dynamic {
	int w = self.width;
	int h = self.height;
	if (w < 20) w = 80;
	if (h < 6)  h = 24;

	// screen: full terminal, blue bg, 2-col horizontal margin
	glaze::Style screen = glaze::new_style()
		.background(glaze::color_hex(DOS_BLUE))
		.set_width(w)
		.set_height(h)
		.padding(0, 2, 0, 2);

	// box fills the available width inside screen padding
	int box_w = w - 4;
	int box_h = h - 4;  // tabbar(1) + hint(1) + top/bottom margin(2)
	if (box_w < 10) box_w = 10;
	if (box_h < 4)  box_h = 4;

	glaze::Style active_tab_style = glaze::new_style()
		.foreground(glaze::color_hex(DOS_BLUE))
		.background(glaze::color_hex(DOS_CYAN))
		.padding(0, 2, 0, 2)
		.set_bold(true);

	glaze::Style inactive_tab_style = glaze::new_style()
		.foreground(glaze::color_hex(DOS_GRAY))
		.background(glaze::color_hex(DOS_DARK))
		.padding(0, 2, 0, 2);

	glaze::Style box_style = glaze::new_style()
		.foreground(glaze::color_hex(DOS_WHITE))
		.background(glaze::color_hex(DOS_BLUE))
		.set_border(glaze::double_border())
		.set_border_fg(glaze::color_hex(DOS_CYAN))
		.set_width(box_w)
		.set_height(box_h)
		.padding(1, 2, 1, 2)
		.align(glaze::Position.LEFT, glaze::Position.TOP);

	glaze::Style title_style = glaze::new_style()
		.foreground(glaze::color_hex(DOS_YELLOW))
		.set_bold(true);

	glaze::Style hint_style = glaze::new_style()
		.foreground(glaze::color_hex(DOS_GRAY))
		.background(glaze::color_hex(DOS_BLUE))
		.set_width(box_w);

	// ── Tab bar ───────────────────────────────────────────────────────────────

	String[4] tab_names = { " Home ", " About ", " Keys ", " Config " };
	String[4] tab_views;
	for (int i = 0; i < 4; i++) {
		tab_views[i] = i == self.active_tab
			? active_tab_style.render(tab_names[i])
			: inactive_tab_style.render(tab_names[i]);
	}
	glaze::Style tabbar_style = glaze::new_style()
		.background(glaze::color_hex(DOS_BLUE))
		.set_width(box_w);
	String tabbar = tabbar_style.render(glaze::join_horizontal_arr(glaze::Position.BOTTOM, tab_views[..], 0));

	// ── Content ───────────────────────────────────────────────────────────────

	TabContent tc = tab_content(self.active_tab);
	String title  = title_style.render(tc.title);
	String inner  = glaze::join_vertical(glaze::Position.LEFT, title, (String)tc.body);
	String box    = box_style.render(inner);

	// ── Hint bar ─────────────────────────────────────────────────────────────

	glaze::Style key_style = glaze::new_style()
		.foreground(glaze::color_hex(DOS_WHITE))
		.set_bold(true);

	String hint = hint_style.render(string::tformat("  %s  switch tabs    %s  jump    %s  quit",
		key_style.render("← →"),
		key_style.render("1-4"),
		key_style.render("q")));

	// ── Compose ───────────────────────────────────────────────────────────────

	String composed = glaze::join_vertical_arr(glaze::Position.LEFT, { tabbar, box, hint });
	return milktea::new_alt_screen_view(screen.render(composed));
}

fn int main() {
	TabsModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
