module focus_blur;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct FocusModel {
    bool focused;
    bool reporting;
    int width;
    int height;
}

fn tea::Cmd FocusModel.init(FocusModel* self) @dynamic {
    self.focused = true;
    self.reporting = true;
    return null;
}

fn tea::Cmd FocusModel.update(FocusModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.FOCUS) {
        self.focused = true;
        return null;
    }
    if (msg.kind == tea::MsgKind.BLUR) {
        self.focused = false;
        return null;
    }
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
            if (k.rune == 't') {
                self.reporting = !self.reporting;
                if (self.reporting) {
                    tea::enable_focus();
                } else {
                    tea::disable_focus();
                }
            }
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    return null;
}

fn tea::View FocusModel.view(FocusModel* self) @dynamic {
    lipgloss::Style focused_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00ff00"))
        .set_bold(true)
        .padding(2, 4, 2, 4)
        .set_border(lipgloss::rounded_border());

    lipgloss::Style blurred_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#666666"))
        .padding(2, 4, 2, 4)
        .set_border(lipgloss::rounded_border());

    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#888888"));

    String label = self.focused ? "FOCUSED" : "BLURRED";
    String desc = self.focused ? "Terminal window is active" : "Terminal window is inactive";
    lipgloss::Style s = self.focused ? focused_style : blurred_style;

    DString out = dstring::temp();
    out.append_string(s.render(string::tformat("%s\n%s", label, desc)));
    out.append_char('\n');
    out.append_char('\n');
    out.append_string(hint.render(string::tformat("Focus reporting: %s\nPress t to toggle | q to quit", self.reporting ? "ON" : "OFF")));
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    FocusModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}