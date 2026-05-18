module textinputs;

import tea;
import lipgloss;
import pearls;
import std::io;
import std::core::string;
import std::core::dstring;

struct InputsModel {
    pearls::TextInput[3] inputs;
    int focus;
    bool submitted;
    int width;
    int height;
    int cursor_blink;
}

fn tea::Cmd InputsModel.init(InputsModel* self) @dynamic {
    self.inputs[0] = pearls::new_text_input().with_placeholder("Nickname");
    self.inputs[0].focused = true;
    self.inputs[1] = pearls::new_text_input().with_placeholder("Email");
    self.inputs[2] = pearls::new_text_input().with_placeholder("Password").with_password();
    return tea::tick(500, &on_blink);
}

fn tea::Msg on_blink() {
    return { .kind = tea::MsgKind.USER, .tag = 10 };
}

fn tea::Cmd InputsModel.update(InputsModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    if (msg.kind == tea::MsgKind.USER && msg.tag == 10) {
        self.cursor_blink = 1 - self.cursor_blink;
        return tea::tick(500, &on_blink);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.TAB:
            self.inputs[self.focus].focused = false;
            if (k.shift) {
                self.focus--;
                if (self.focus < 0) self.focus = 2;
            } else {
                self.focus = (self.focus + 1) % 3;
            }
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
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    if (self.inputs[self.focus].handle_key(k)) return null;
    return null;
}

fn tea::View InputsModel.view(InputsModel* self) @dynamic {
    lipgloss::Style title = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true).padding(0, 0, 1, 0);
    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

    DString out = dstring::temp();
    out.append_string(title.render("Sign Up"));
    out.append_char('\n');
    out.append_char('\n');

    String[3] labels = { "Nickname:", "Email:", "Password:" };
    int[3] label_cols = { 10, 7, 10 };

    int base_row = 3;

    int cursor_x = 0;
    int cursor_y = 0;

    for (int i = 0; i < 3; i++) {
        out.append_string(labels[i]);
        out.append_char(' ');

        if (i == self.focus) {
            cursor_y = base_row + i;
            cursor_x = label_cols[i] + self.inputs[i].cursor_col();
        }

        out.append_string(self.inputs[i].view());
        out.append_char('\n');
    }

    out.append_char('\n');

    if (self.focus == 2) {
        lipgloss::Style btn = lipgloss::new_style().foreground(lipgloss::color_hex("#ffffff")).background(lipgloss::color_hex("#00d7ff")).padding(0, 2, 0, 2).set_bold(true);
        out.append_string(btn.render(" Submit "));
    } else {
        lipgloss::Style btn = lipgloss::new_style().foreground(lipgloss::color_hex("#888888")).padding(0, 2, 0, 2);
        out.append_string(btn.render(" Submit "));
    }
    out.append_char('\n');
    out.append_char('\n');
    out.append_string(hint.render("TAB/Shift+TAB switch | ENTER submit | ESC quit"));

    tea::View v = tea::new_alt_screen_view(out.str_view());
    v.has_cursor = true;
    v.cursor = tea::new_cursor(cursor_x, cursor_y);
    return v;
}

fn int main() {
    InputsModel m = {};

    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

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
