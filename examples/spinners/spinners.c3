module spinners;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;

struct SpinnersModel {
    int frame;
    int width;
    int height;
}

fn tea::Cmd SpinnersModel.init(SpinnersModel* self) @dynamic {
    return tea::tick(80, &on_spin);
}

fn tea::Msg on_spin() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_SPIN };
}

fn tea::Cmd SpinnersModel.update(SpinnersModel* self, tea::Msg msg) @dynamic {
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
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    return null;
}

struct SpinnerDef {
    String name;
    String[8] frames;
    int count;
}

fn tea::View SpinnersModel.view(SpinnersModel* self) @dynamic {
    SpinnerDef[6] spinners;
    spinners[0] = { .name = "Dots",    .frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }, .count = 8 };
    spinners[1] = { .name = "Lines",   .frames = { "-", "\\", "|", "/", "-", "\\", "|", "/" }, .count = 4 };
    spinners[2] = { .name = "Arrow",   .frames = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" }, .count = 8 };
    spinners[3] = { .name = "Blocks",  .frames = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" }, .count = 8 };
    spinners[4] = { .name = "Moon",    .frames = { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" }, .count = 8 };
    spinners[5] = { .name = "Pulse",   .frames = { "∙∙∙", "●∙∙", "∙●∙", "∙∙●", "∙∙∙", "∙∙∙", "∙∙∙", "∙∙∙" }, .count = 5 };

    lipgloss::Style title = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00d7ff"))
        .set_bold(true)
        .padding(0, 0, 1, 0);

    lipgloss::Style label = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#888888"));

    lipgloss::Style active = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ff00ff"))
        .set_bold(true);

    lipgloss::Style box_style = lipgloss::new_style()
        .set_border(lipgloss::rounded_border())
        .padding(1, 2, 1, 2);

    DString content = dstring::temp();
    content.append_string(title.render("Spinner Gallery"));
    content.append_char('\n');

    for (int i = 0; i < 6; i++) {
        int idx = self.frame % spinners[i].count;
        String spin = spinners[i].frames[idx];
        String name = spinners[i].name;
        content.append_string(active.render(string::tformat("  %s", spin)));
        content.append_string(label.render(string::tformat("  %s", name)));
        content.append_string("   ");
    }

    content.append_char('\n');
    content.append_string(label.render("Press q or ESC to quit"));

    return tea::new_alt_screen_view(box_style.render(content.str_view()));
}

fn int main() {
    SpinnersModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}