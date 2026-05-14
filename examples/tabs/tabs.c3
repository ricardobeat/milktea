module tabs;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct TabsModel {
    int active_tab;
    int width;
    int height;
}

fn tea::Cmd TabsModel.init(TabsModel* self) @dynamic {
    return null;
}

fn tea::Cmd TabsModel.update(TabsModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
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
        case tea::KeyCode.LEFT:
            if (self.active_tab > 0) self.active_tab--;
        case tea::KeyCode.RIGHT:
            if (self.active_tab < 3) self.active_tab++;
        case tea::KeyCode.ESC:
            return tea::quit();
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

fn tea::View TabsModel.view(TabsModel* self) @dynamic {
    lipgloss::Style active_tab = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ffffff"))
        .background(lipgloss::color_hex("#00d7ff"))
        .padding(0, 2, 0, 2)
        .set_bold(true);

    lipgloss::Style inactive_tab = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#888888"))
        .padding(0, 2, 0, 2);

    lipgloss::Style content_style = lipgloss::new_style()
        .padding(1, 2, 1, 2)
        .set_border(lipgloss::rounded_border());

    lipgloss::Style hint_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#666666"));

    String[4] tab_names = { "Home", "About", "Keys", "Config" };

    DString out = dstring::temp();

    // Tab bar
    for (int i = 0; i < 4; i++) {
        if (i == self.active_tab) {
            out.append_string(active_tab.render(tab_names[i]));
        } else {
            out.append_string(inactive_tab.render(tab_names[i]));
        }
    }

    out.append_char('\n');

    // Content - use height to limit content area
    String content = tab_content(self.active_tab);
    String clipped = lipgloss::clip_lines(content, self.height - 4);
    out.append_string(content_style.render(clipped));
    out.append_char('\n');
    out.append_string(hint_style.render("← → switch tabs | q quit"));

    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    TabsModel m = {};
    if (catch err = tea::run((tea::Model)&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}