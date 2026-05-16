module textinputs;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct TextInput {
    char[256] buf;
    sz len;
    sz cursor;
    String placeholder;
    bool focused;
    bool is_password;
}

fn void TextInput.clear(TextInput* self) {
    self.len = 0;
    self.cursor = 0;
}

fn void TextInput.insert(TextInput* self, char c) {
    if (self.len >= self.buf.len - 1) return;
    for (sz i = self.len; i > self.cursor; i--) {
        self.buf[i] = self.buf[i - 1];
    }
    self.buf[self.cursor] = c;
    self.len++;
    self.cursor++;
}

fn void TextInput.backspace(TextInput* self) {
    if (self.cursor == 0) return;
    for (sz i = self.cursor; i < self.len; i++) {
        self.buf[i - 1] = self.buf[i];
    }
    self.len--;
    self.cursor--;
}

fn void TextInput.delete_char(TextInput* self) {
    if (self.cursor >= self.len) return;
    for (sz i = self.cursor; i < self.len - 1; i++) {
        self.buf[i] = self.buf[i + 1];
    }
    self.len--;
}

fn String TextInput.text(TextInput* self) {
    return (String)self.buf[:self.len];
}

fn String TextInput.display_text(TextInput* self) {
    if (self.len == 0) return self.placeholder;
    if (self.is_password) {
        DString hidden = dstring::temp();
        for (sz i = 0; i < self.len; i++) hidden.append_string("•");
        return hidden.str_view();
    }
    return self.text();
}

// cursor_x returns the 0-indexed column offset of the cursor within the
// input's rendered text. This is relative to where the input text starts,
// NOT relative to the line start.
fn int TextInput.cursor_x(TextInput* self) {
    if (self.len > 0 && self.cursor < self.len) {
        return (int)self.cursor;
    }
    return (int)self.len;
}

fn String TextInput.view(TextInput* self, bool focused) {
    String display = self.display_text();

    // Color based on state
    lipgloss::Style s = lipgloss::new_style();
    if (self.len > 0 && focused) {
        s = s.foreground(lipgloss::color_hex("#ffffff"));  // white for focused with text
    } else if (self.len > 0) {
        s = s.foreground(lipgloss::color_hex("#888888")); // gray for blurred with text
    } else {
        s = s.foreground(lipgloss::color_hex("#444444")); // dim for placeholder
    }

    return s.render(display);
}

struct InputsModel {
    TextInput[3] inputs;
    int focus;
    bool submitted;
    int width;
    int height;
    int cursor_blink;
}

fn tea::Cmd InputsModel.init(InputsModel* self) @dynamic {
    self.inputs[0].placeholder = "Nickname";
    self.inputs[0].focused = true;
    self.inputs[1].placeholder = "Email";
    self.inputs[2].placeholder = "Password";
    self.inputs[2].is_password = true;
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

fn tea::View InputsModel.view(InputsModel* self) @dynamic {
    lipgloss::Style title = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true).padding(0, 0, 1, 0);
    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

    DString out = dstring::temp();
    out.append_string(title.render("Sign Up"));
    out.append_char('\n');
    out.append_char('\n');

    String[3] labels = { "Nickname:", "Email:", "Password:" };
    // 0-indexed column where each input's text begins (label chars + trailing space)
    int[3] label_cols = { 10, 7, 10 };

    // Title.render with bottom padding (pad_bottom=1) produces 2 lines,
    // plus 2 explicit newlines → lines 0,1,2 are occupied,
    // so inputs start at content row 3 (0-indexed).
    int base_row = 3;

    int cursor_x = 0;
    int cursor_y = 0;

    for (int i = 0; i < 3; i++) {
        out.append_string(labels[i]);
        out.append_char(' ');

        if (i == self.focus) {
            cursor_y = base_row + i;
            cursor_x = label_cols[i] + self.inputs[i].cursor_x();
        }

        out.append_string(self.inputs[i].view(self.inputs[i].focused));
        out.append_char('\n');
    }

    out.append_char('\n');

    // Submit button
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
