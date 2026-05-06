module spinner;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;

struct SpinnerModel {
    int frame;
    int width;
    int height;
}

fn tea::Cmd SpinnerModel.init(SpinnerModel* self) @dynamic {
    self.frame = 0;
    return tea::tick(80, &on_spin);
}

fn tea::Msg on_spin() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_SPIN };
}

fn tea::Cmd SpinnerModel.update(SpinnerModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_SPIN) {
        self.frame++;
        return tea::tick(80, &on_spin);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
        default:
    }
    return null;
}

fn String SpinnerModel.view(SpinnerModel* self) @dynamic {
    String[12] frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "⠋", "⠙" };
    String spin = frames[self.frame % 12];

    lipgloss::Style title = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00d7ff"))
        .set_bold(true);

    lipgloss::Style subtle = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#666666"));

    DString out = dstring::temp();
    out.append_string(title.render(string::tformat("%s  Loading...", spin)));
    out.append_char('\n');
    out.append_string(subtle.render("Press q to quit"));
    return out.str_view();
}

fn int main() {
    SpinnerModel m = {};
    tea::enter_alt_screen();

    if (catch err = tea::run((tea::Model)&m)) {
        tea::exit_alt_screen();
        io::printfn("Error: %s", err);
        return 1;
    }

    tea::exit_alt_screen();
    io::printn("Done!");
    return 0;
}