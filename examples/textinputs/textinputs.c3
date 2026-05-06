module textinputs;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_TICK = 1;

struct TextInput {
    char[256] buf;
    usz len;
    usz cursor;
    String placeholder;
    bool focused;
}

fn void TextInput.clear(TextInput* self) {
    self.len = 0;
    self.cursor = 0;
}

fn void TextInput.insert(TextInput* self, char c) {
    if (self.len >= self.buf.len - 1) return;
    for (usz i = self.len; i > self.cursor; i--) {
        self.buf[i] = self.buf[i - 1];
    }
    self.buf[self.cursor] = c;
    self.len++;
    self.cursor++;
}

fn void TextInput.backspace(TextInput* self) {
    if (self.cursor == 0) return;
    for (usz i = self.cursor; i < self.len; i++) {
        self.buf[i - 1] = self.buf[i];
    }
    self.len--;
    self.cursor--;
}

fn void TextInput.delete_char(TextInput* self) {
    if (self.cursor >= self.len) return;
    for (usz i = self.cursor; i < self.len - 1; i++) {
        self.buf[i] = self.buf[i + 1];
    }
    self.len--;
}

fn String TextInput.text(TextInput* self) {
    return (String)self.buf[:self.len];
}

fn String TextInput.view(TextInput* self, bool show_cursor) {
    lipgloss::Style focused_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ffffff"))
        .padding(0, 1, 0, 1)
        .set_border(lipgloss::rounded_border());
    lipgloss::Style unfocused_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#888888"))
        .padding(0, 1, 0, 1)
        .set_border(lipgloss::normal_border());

    lipgloss::Style s = self.focused ? focused_style : unfocused_style;
    lipgloss::Style placeholder_style = lipgloss::new_style().foreground(lipgloss::color_hex("#444444"));

    String display;
    if (self.len > 0) {
        display = self.text();
    } else {
        display = placeholder_style.render(self.placeholder);
    }

    DString out = dstring::temp();
    out.append_string(display);
    if (self.focused && show_cursor) {
        out.append_string("▎");
    }
    return s.render(out.str_view());
}

struct InputsModel {
    TextInput[3] inputs;
    int focus;
    bool submitted;
    int width;
    int height;
    int cursor_visible;
}

fn tea::Cmd InputsModel.init(InputsModel* self) @dynamic {
    self.inputs[0].placeholder = "Nickname";
    self.inputs[0].focused = true;
    self.inputs[1].placeholder = "Email";
    self.inputs[2].placeholder = "Password";
    self.cursor_visible = 1;
    return tea::tick(500, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd InputsModel.update(InputsModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.cursor_visible = 1 - self.cursor_visible;
        return tea::tick(500, &on_tick);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.TAB:
            self.inputs[self.focus].focused = false;
            self.focus = (self.focus + 1) % 3;
            self.inputs[self.focus].focused = true;
        case tea::KeyCode.UP:
            self.inputs[self.focus].focused = false;
            self.focus = (self.focus - 1 + 3) % 3;
            self.inputs[self.focus].focused = true;
        case tea::KeyCode.DOWN:
            self.inputs[self.focus].focused = false;
            self.focus = (self.focus + 1) % 3;
            self.inputs[self.focus].focused = true;
        case tea::KeyCode.ENTER:
            if (self.focus < 2) {
                self.inputs[self.focus].focused = false;
                self.focus++;
                self.inputs[self.focus].focused = true;
            } else {
                self.submitted = true;
                return tea::quit();
            }
        case tea::KeyCode.BACKSPACE:
            self.inputs[self.focus].backspace();
        case tea::KeyCode.LEFT:
            if (self.inputs[self.focus].cursor > 0) self.inputs[self.focus].cursor--;
        case tea::KeyCode.RIGHT:
            if (self.inputs[self.focus].cursor < self.inputs[self.focus].len) self.inputs[self.focus].cursor++;
        case tea::KeyCode.RUNE:
            if (k.rune == 'q' && self.focus == 0) return tea::quit();
            self.inputs[self.focus].insert(k.rune);
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    return null;
}

fn String InputsModel.view(InputsModel* self) @dynamic {
    lipgloss::Style title = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true).padding(0, 0, 1, 0);
    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

    bool show = self.cursor_visible != 0;

    DString out = dstring::temp();
    out.append_string(title.render("Sign Up"));
    out.append_char('\n');
    out.append_char('\n');

    String[3] labels = { "Nickname:", "Email:", "Password:" };
    for (int i = 0; i < 3; i++) {
        out.append_string(labels[i]);
        out.append_char(' ');
        out.append_string(self.inputs[i].view(show));
        out.append_char('\n');
    }

    out.append_char('\n');
    out.append_string(hint.render("TAB/↑↓ switch fields | ENTER submit | ESC quit"));

    return out.str_view();
}

fn int main() {
    InputsModel m = {};
    tea::enter_alt_screen();

    if (catch err = tea::run((tea::Model)&m)) {
        tea::exit_alt_screen();
        io::printfn("Error: %s", err);
        return 1;
    }

    tea::exit_alt_screen();
    if (m.submitted) {
        io::printfn("Submitted!");
        io::printfn("  Nickname: %s", m.inputs[0].text());
        io::printfn("  Email: %s", m.inputs[1].text());
        io::printfn("  Password: %s", m.inputs[2].text());
    } else {
        io::printn("Cancelled.");
    }
    return 0;
}