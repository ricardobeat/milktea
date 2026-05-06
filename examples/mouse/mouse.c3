module mouse;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct Model {
    int width;
    int height;
    int mouse_row;
    int mouse_col;
    tea::MouseButton last_button;
    tea::MouseAction last_action;
    bool dragging;
    String[32] trail;
    int trail_count;
}

fn tea::Cmd Model.init(Model* self) @dynamic {
    self.mouse_row = 0;
    self.mouse_col = 0;
    self.last_button = tea::MouseButton.MOUSE_NONE;
    self.last_action = tea::MouseAction.MOUSE_PRESS;
    self.dragging = false;
    self.trail_count = 0;
    return null;
}

fn tea::Cmd Model.update(Model* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.MOUSE) {
        self.mouse_row = msg.mouse.row;
        self.mouse_col = msg.mouse.col;
        self.last_button = msg.mouse.button;
        self.last_action = msg.mouse.action;
        if (msg.mouse.action == tea::MouseAction.MOUSE_PRESS && msg.mouse.button == tea::MouseButton.MOUSE_LEFT) {
            self.dragging = true;
            if (self.trail_count < self.trail.len) {
                self.trail[self.trail_count] = string::tformat("(%d,%d)", msg.mouse.col, msg.mouse.row);
                self.trail_count++;
            }
        }
        if (msg.mouse.action == tea::MouseAction.MOUSE_RELEASE) {
            self.dragging = false;
        }
        if (msg.mouse.action == tea::MouseAction.MOUSE_MOTION && self.dragging) {
            if (self.trail_count < self.trail.len) {
                self.trail[self.trail_count] = string::tformat("(%d,%d)", msg.mouse.col, msg.mouse.row);
                self.trail_count++;
            }
        }
        return null;
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
            if (k.rune == 'c') {
                self.trail_count = 0;
            }
        default:
    }
    return null;
}

fn String Model.view(Model* self) @dynamic {
    lipgloss::Style title_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00d7ff"))
        .set_bold(true);

    lipgloss::Style info_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ff00ff"));

    lipgloss::Style hint_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#666666"));

    DString out = dstring::temp();
    out.append_string(title_style.render("Mouse Event Viewer"));
    out.append_string("\n\n");

    String button_name = "none";
    switch (self.last_button) {
        case tea::MouseButton.MOUSE_LEFT: { button_name = "left"; }
        case tea::MouseButton.MOUSE_MIDDLE: { button_name = "middle"; }
        case tea::MouseButton.MOUSE_RIGHT: { button_name = "right"; }
        default: {}
    }

    String action_name = "press";
    switch (self.last_action) {
        case tea::MouseAction.MOUSE_PRESS: { action_name = "press"; }
        case tea::MouseAction.MOUSE_RELEASE: { action_name = "release"; }
        case tea::MouseAction.MOUSE_MOTION: { action_name = "motion"; }
        default: {}
    }

    out.append_string(info_style.render(string::tformat("Position: (%d, %d)", self.mouse_col, self.mouse_row)));
    out.append_char('\n');
    out.append_string(info_style.render(string::tformat("Button: %s  Action: %s", button_name, action_name)));
    out.append_char('\n');
    out.append_string(info_style.render(string::tformat("Dragging: %s", self.dragging ? "yes" : "no")));
    out.append_char('\n');

    if (self.trail_count > 0) {
        out.append_char('\n');
        out.append_string(title_style.render("Click Trail:"));
        out.append_char('\n');
        for (int i = 0; i < self.trail_count; i++) {
            out.append_string(self.trail[i]);
            if (i < self.trail_count - 1) {
                out.append_string(" -> ");
            }
        }
    }

    out.append_string("\n\n");
    out.append_string(hint_style.render("Click/drag to track  |  c to clear  |  q to quit"));
    return out.str_view();
}

fn int main() {
    Model m = {};
    tea::enter_alt_screen();
    tea::enable_mouse();

    if (catch err = tea::run((tea::Model)&m)) {
        tea::disable_mouse();
        tea::exit_alt_screen();
        io::printfn("Error: %s", err);
        return 1;
    }

    tea::disable_mouse();
    tea::exit_alt_screen();
    io::printn("Bye!");
    return 0;
}