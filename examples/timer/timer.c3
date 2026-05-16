module timer;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;


struct TimerModel {
    int seconds;
    int width;
    int height;
    bool running;
    bool done;
}

fn tea::Cmd TimerModel.init(TimerModel* self) @dynamic {
    return tea::tick(1000);
}


fn tea::Cmd TimerModel.update(TimerModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.TICK) {
        if (self.running) {
            self.seconds--;
            if (self.seconds <= 0) {
                self.seconds = 0;
                self.running = false;
                self.done = true;
                return null;
            }
        }
        return tea::tick(1000);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
            if (k.rune == ' ') self.running = !self.running;
            if (k.rune == 'r') {
                self.seconds = 60;
                self.running = true;
                self.done = false;
                return tea::tick(1000);
            }
        default:
    }
    return null;
}

fn tea::View TimerModel.view(TimerModel* self) @dynamic {
    int minutes = self.seconds / 60;
    int secs = self.seconds % 60;

    lipgloss::Style box_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ff00ff"))
        .set_bold(true)
        .padding(2, 4, 2, 4)
        .set_border(lipgloss::rounded_border());

    lipgloss::Style subtle = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#666666"));

    DString out = dstring::temp();
    String time_str = string::tformat("%02d:%02d", minutes, secs);
    out.append_string(box_style.render(time_str));
    out.append_char('\n');

    if (self.done) {
        lipgloss::Style done_style = lipgloss::new_style()
            .foreground(lipgloss::color_hex("#00ff00"))
            .set_bold(true);
        out.append_string(done_style.render("Time's up!"));
    } else if (self.running) {
        out.append_string(subtle.render("SPACE to pause"));
    } else {
        lipgloss::Style pause_style = lipgloss::new_style()
            .foreground(lipgloss::color_hex("#ffff00"));
        out.append_string(pause_style.render("PAUSED"));
        out.append_string(subtle.render("  SPACE to resume"));
    }

    out.append_char('\n');
    out.append_string(subtle.render("r to reset  |  q to quit"));
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    TimerModel m = { .seconds = 60, .running = true };
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}