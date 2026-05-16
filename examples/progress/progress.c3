module progress;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int TOTAL = 100;

struct ProgressModel {
    int progress;
    int speed;
    bool done;
    int width;
    int height;
}

fn tea::Cmd ProgressModel.init(ProgressModel* self) @dynamic {
    self.speed = 1;
    return tea::tick(50);
}


fn tea::Cmd ProgressModel.update(ProgressModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.TICK) {
        if (!self.done) {
            self.progress += self.speed;
            if (self.progress >= TOTAL) {
                self.progress = TOTAL;
                self.done = true;
            }
        }
        return tea::tick(50);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
            if (k.rune == 'f') self.speed = 5;
            if (k.rune == 's') self.speed = 1;
            if (k.rune == 'r') {
                self.progress = 0;
                self.done = false;
                self.speed = 1;
                return tea::tick(50);
            }
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    return null;
}

fn tea::View ProgressModel.view(ProgressModel* self) @dynamic {
    lipgloss::Style title = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00d7ff"))
        .set_bold(true)
        .padding(0, 0, 1, 0);

    lipgloss::Style done_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00ff00"))
        .set_bold(true);

    lipgloss::Style hint = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#666666"));

    lipgloss::Style box_style = lipgloss::new_style()
        .set_border(lipgloss::rounded_border())
        .padding(1, 2, 1, 2);

    int pct = (self.progress * 100) / TOTAL;

    DString content = dstring::temp();
    content.append_string(title.render("Progress Bar"));
    content.append_char('\n');
    content.append_char('\n');

    // Main progress bar
    String bar1 = lipgloss::progress_bar(40, pct, "█", "░", lipgloss::color_hex("#00d7ff"), lipgloss::color_hex("#222222"));

    // Second bar with different style
    String bar2 = lipgloss::progress_bar(40, pct, "■", "□", lipgloss::color_hex("#ff00ff"), lipgloss::color_hex("#222222"));

    // Third bar with gradient feel
    String bar3 = lipgloss::progress_bar(40, pct, "=", "-", lipgloss::color_hex("#00ff88"), lipgloss::color_hex("#333333"));

    content.append_string(string::tformat(" Download %s %d%%\n", bar1, pct));
    content.append_string(string::tformat(" Compile %s %d%%\n", bar2, pct));
    content.append_string(string::tformat(" Deploy   %s %d%%\n", bar3, pct));

    content.append_char('\n');

    if (self.done) {
        content.append_string(done_style.render("✓ Complete!"));
        content.append_string(hint.render("  r to restart"));
    } else {
        String speed_label = self.speed > 1 ? "fast" : "normal";
        content.append_string(hint.render(string::tformat("Speed: %s", speed_label)));
        content.append_string(hint.render("  |  f fast  |  s slow  |  r restart  |  q quit"));
    }

    return tea::new_alt_screen_view(box_style.render(content.str_view()));
}

fn int main() {
    ProgressModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Done!");
    return 0;
}