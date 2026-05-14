module fullscreen;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_TICK = 1;

struct FullscreenModel {
    int countdown;
    int width;
    int height;
}

fn tea::Cmd FullscreenModel.init(FullscreenModel* self) @dynamic {
    return tea::tick(1000, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd FullscreenModel.update(FullscreenModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.countdown--;
        if (self.countdown <= 0) {
            return tea::quit();
        }
        return tea::tick(1000, &on_tick);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
        default:
    }
    return null;
}

fn tea::View FullscreenModel.view(FullscreenModel* self) @dynamic {
    lipgloss::Style number = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ff5555"))
        .set_bold(true);

    lipgloss::Style label = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#888888"));

    DString out = dstring::temp();
    String num_str = string::tformat("%d", self.countdown);
    out.append_string(number.render(num_str));

    if (self.countdown == 1) {
        out.append_string(label.render(" second remaining"));
    } else {
        out.append_string(label.render(" seconds remaining"));
    }

    out.append_char('\n');
    out.append_string(label.render("Press ESC or q to quit"));
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    FullscreenModel m = { .countdown = 10 };
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Time's up!");
    return 0;
}