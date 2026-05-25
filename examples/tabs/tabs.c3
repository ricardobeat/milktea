module tabs;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

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
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == '1') self.active_tab = 0;
			if (k.rune == '2') self.active_tab = 1;
			if (k.rune == '3') self.active_tab = 2;
			if (k.rune == '4') self.active_tab = 3;
			if (k.rune == 'h') {
				if (self.active_tab > 0) self.active_tab--;
			}
			if (k.rune == 'l') {
				if (self.active_tab < 3) self.active_tab++;
			}
		case milktea::KeyCode.LEFT:
			if (self.active_tab > 0) self.active_tab--;
		case milktea::KeyCode.RIGHT:
			if (self.active_tab < 3) self.active_tab++;
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	return null;
}

fn String tab_content(int tab) {
	switch (tab) {
		case 0: return "Welcome to the Tabs example!\n\nThis demonstrates a tabbed interface\nbuilt with milktea.\n\nUse left/right arrows or h/l to switch.\nPress 1-4 to jump to a tab.";
		case 1: return "About\n\nAn event-driven TUI framework for\nthe C3 programming language.\n\nFeatures:\n  - Event-driven architecture\n  - Lipgloss styling & layout\n  - Terminal raw mode\n  - Keyboard & window events\n  - Timer-based animations";
		case 2: return "Shortcuts\n\n  Left/Right  Switch tabs\n  1-4         Jump to tab\n  q / ESC     Quit\n  Ctrl+C      Force quit";
		default: return "Settings\n\n  Theme:       Dark\n  Language:    English\n  Font size:   12\n  Animations:  On\n\n(Placeholder settings)";
	}
}

fn milktea::View TabsModel.view(TabsModel* self) @dynamic {
	glaze::Style active_tab = glaze::new_style().foreground(glaze::color_hex("#ffffff"))
		.background(glaze::color_hex("#00d7ff"))
		.padding(0, 2, 0, 2)
		.set_bold(true);

	glaze::Style inactive_tab = glaze::new_style().foreground(glaze::color_hex("#888888")).padding(0, 2, 0, 2);

	glaze::Style content_style = glaze::new_style().padding(1, 2, 1, 2).set_border(glaze::rounded_border());

	glaze::Style hint_style = glaze::new_style().foreground(glaze::color_hex("#666666"));

	String[4] tab_names = { "Home", "About", "Keys", "Config" };

	DString out = dstring::temp();

	// Tab bar
	String[4] tab_views;
	for (int i = 0; i < 4; i++) {
		if (i == self.active_tab) {
			tab_views[i] = active_tab.render(tab_names[i]);
		} else {
			tab_views[i] = inactive_tab.render(tab_names[i]);
		}
	}
	out.append_string(glaze::join_horizontal_arr(glaze::Position.BOTTOM, tab_views[..], 0));

	out.append_char('\n');

	// Content - use height to limit content area
	String content = tab_content(self.active_tab);
	String clipped = glaze::clip_lines(content, self.height - 4);
	out.append_string(content_style.render(clipped));
	out.append_char('\n');
	out.append_string(hint_style.render("← → switch tabs | q quit"));

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	TabsModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}