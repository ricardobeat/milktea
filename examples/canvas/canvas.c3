module canvas_example;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_TICK = 1;

struct CanvasModel {
    bool flip;
    int width;
    int height;
    int ticks;
}

fn tea::Cmd CanvasModel.init(CanvasModel* self) @dynamic {
    return tea::tick(1000, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd CanvasModel.update(CanvasModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.ticks++;
        return tea::tick(1000, &on_tick);
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;
    switch (k.code) {
        case tea::KeyCode.CTRL_C:
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
        default:
            self.flip = !self.flip;
    }
    return null;
}

fn tea::View CanvasModel.view(CanvasModel* self) @dynamic {
    lipgloss::Color front_color = self.flip ? lipgloss::color_hex("#ff00ff") : lipgloss::color_hex("#00d7ff");
    lipgloss::Color back_color = self.flip ? lipgloss::color_hex("#00d7ff") : lipgloss::color_hex("#ff00ff");

    lipgloss::Style front_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ffffff"))
        .set_bold(true)
        .padding(1, 2, 1, 2)
        .set_border(lipgloss::rounded_border());
    front_style = front_style.foreground(front_color);

    lipgloss::Style back_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#888888"))
        .padding(1, 2, 1, 2)
        .set_border({
            .top="-", .bottom="-", .left="|", .right="|",
            .top_left="+", .top_right="+", .bottom_left="+", .bottom_right="+"
        });

    String front_view = front_style.render("Hello");
    String back_view = back_style.render("Goodbye");

    // The "flip" swaps which card is drawn first (and thus appears underneath)
    String joined;
    if (self.flip) {
        joined = lipgloss::join_horizontal(back_view, front_view, 4);
    } else {
        joined = lipgloss::join_horizontal(front_view, back_view, 4);
    }

    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

    DString out = dstring::temp();
    out.append_string(joined);
    out.append_char('\n');
    out.append_string(hint.render("Press any key to swap layers | q quit"));
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    CanvasModel m = {};
    if (catch err = tea::run((tea::Model)&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}