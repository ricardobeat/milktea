module batch;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;
const int MSG_TICK = 2;
const int MSG_STEP = 3;

struct Model {
    int spin_frame;
    int seconds;
    int step;
    int width;
    int height;
}

fn tea::Msg on_spin() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_SPIN };
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Msg on_step() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_STEP };
}

fn tea::Cmd Model.init(Model* self) @dynamic {
    self.spin_frame = 0;
    self.seconds = 0;
    self.step = 0;
    // Start three independent timers using batch
    tea::Cmd spin_cmd = tea::tick(80, &on_spin);
    tea::Cmd tick_cmd = tea::tick(1000, &on_tick);
    tea::Cmd step_cmd = tea::tick(500, &on_step);
    tea::Cmd[3] cmds = { spin_cmd, tick_cmd, step_cmd };
    return tea::batch(cmds[..]);
}

fn tea::Cmd Model.update(Model* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_SPIN) {
        self.spin_frame++;
        return tea::tick(80, &on_spin);
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.seconds++;
        return tea::tick(1000, &on_tick);
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_STEP) {
        self.step++;
        return tea::tick(500, &on_step);
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

fn String Model.view(Model* self) @dynamic {
    String[8] frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" };
    String spin = frames[self.spin_frame % 8];

    lipgloss::Style spin_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00d7ff"))
        .set_bold(true)
        .padding(1, 2, 1, 2)
        .set_border(lipgloss::rounded_border());

    lipgloss::Style timer_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ff00ff"))
        .set_bold(true)
        .padding(1, 2, 1, 2)
        .set_border(lipgloss::rounded_border());

    lipgloss::Style step_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00ff88"))
        .set_bold(true)
        .padding(1, 2, 1, 2)
        .set_border(lipgloss::rounded_border());

    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

    String spin_view = spin_style.render(string::tformat("%s Spinning...", spin));
    String timer_view = timer_style.render(string::tformat("Timer\n%02d seconds", self.seconds));
    String step_view = step_style.render(string::tformat("Steps\n%d half-seconds", self.step));

    String joined = lipgloss::join_horizontal(spin_view, timer_view, 2);
    DString out = dstring::temp();
    out.append_string(joined);
    out.append_char('\n');
    out.append_string(step_view);
    out.append_char('\n');
    out.append_string(hint.render("q to quit"));
    return out.str_view();
}

fn int main() {
    Model m = {};
    tea::enter_alt_screen();

    if (catch err = tea::run((tea::Model)&m)) {
        tea::exit_alt_screen();
        io::printfn("Error: %s", err);
        return 1;
    }

    tea::exit_alt_screen();
    io::printn("Bye!");
    return 0;
}