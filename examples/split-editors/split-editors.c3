module split_editors;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_TICK = 1;
const int MAX_EDITORS = 4;
const int BUF_SIZE = 4096;

struct Editor {
    char[BUF_SIZE] buf;
    usz len;
    int cursor;
    bool focused;
    String label;
}

fn void Editor.insert(Editor* self, char c) {
    if (self.len >= BUF_SIZE - 1) return;
    for (usz i = self.len; i > (usz)self.cursor; i--) {
        self.buf[i] = self.buf[i - 1];
    }
    self.buf[self.cursor] = c;
    self.len++;
    self.cursor++;
}

fn void Editor.backspace(Editor* self) {
    if (self.cursor == 0) return;
    for (usz i = (usz)self.cursor; i < self.len; i++) {
        self.buf[i - 1] = self.buf[i];
    }
    self.len--;
    self.cursor--;
}

fn String Editor.text(Editor* self) {
    return (String)self.buf[:self.len];
}

fn String Editor.view(Editor* self, int height, bool show_cursor) {
    lipgloss::Style focused = lipgloss::new_style()
        .set_border(lipgloss::rounded_border())
        .padding(0, 1, 0, 1);
    lipgloss::Style unfocused = lipgloss::new_style()
        .set_border({ .top="-", .bottom="-", .left="|", .right="|",
                       .top_left="-", .top_right="-", .bottom_left="-", .bottom_right="-" })
        .padding(0, 1, 0, 1);

    lipgloss::Style s = self.focused ? focused : unfocused;

    DString content = dstring::temp();
    content.append_string(self.label);
    content.append_char('\n');

    // Show lines up to height
    String txt = self.text();
    usz line_num = 1;
    usz line_start = 0;
    int lines_shown = 0;
    int max_lines = height - 4;
    if (max_lines < 1) max_lines = 1;

    // Find which line cursor is on for scrolling
    int cursor_line = 0;
    usz pos = 0;
    for (usz i = 0; i < self.len; i++) {
        if (i == (usz)self.cursor) break;
        if (self.buf[i] == '\n') cursor_line++;
    }

    // Skip lines before cursor to keep it visible
    int skip = 0;
    if (cursor_line > max_lines - 2) {
        skip = cursor_line - max_lines + 2;
    }

    for (usz i = 0; i <= txt.len; i++) {
        if (i == txt.len || txt[i] == '\n') {
            if (line_num - 1 >= skip && lines_shown < max_lines) {
                content.append_string(string::tformat("%2d ", line_num));
                content.append_string(txt[line_start:i - line_start]);
                if (self.focused && show_cursor && line_num - 1 == cursor_line && (usz)self.cursor == i) {
                    content.append_string("▎");
                }
                content.append_char('\n');
                lines_shown++;
            }
            line_num++;
            line_start = i + 1;
            if (i == txt.len) break;
        }
    }

    return s.render(content.str_view());
}

struct SplitModel {
    Editor[4] editors;
    int count;
    int focus;
    int height;
    int width;
    int cursor_blink;
}

fn tea::Cmd SplitModel.init(SplitModel* self) @dynamic {
    self.count = 2;
    self.focus = 0;
    self.editors[0].label = "Editor 1";
    self.editors[0].focused = true;
    self.editors[1].label = "Editor 2";
    self.editors[2].label = "Editor 3";
    self.editors[3].label = "Editor 4";
    return tea::tick(500, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd SplitModel.update(SplitModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.cursor_blink = 1 - self.cursor_blink;
        return tea::tick(500, &on_tick);
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.TAB:
            self.editors[self.focus].focused = false;
            self.focus = (self.focus + 1) % self.count;
            self.editors[self.focus].focused = true;
        case tea::KeyCode.BACKSPACE:
            self.editors[self.focus].backspace();
        case tea::KeyCode.ENTER:
            self.editors[self.focus].insert('\n');
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.ctrl) {
                if (k.rune == 'n' - 'a' + 1) {
                    // Ctrl+N - add editor
                    if (self.count < MAX_EDITORS) self.count++;
                }
                if (k.rune == 'w' - 'a' + 1) {
                    // Ctrl+W - remove editor
                    if (self.count > 1) {
                        self.editors[self.focus].focused = false;
                        self.count--;
                        if (self.focus >= self.count) self.focus = self.count - 1;
                        self.editors[self.focus].focused = true;
                    }
                }
            } else {
                self.editors[self.focus].insert(k.rune);
            }
        default:
    }
    return null;
}

fn String SplitModel.view(SplitModel* self) @dynamic {
    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    bool show_cursor = self.cursor_blink != 0;

    int edit_h = self.height - 3;
    if (edit_h < 5) edit_h = 5;

    DString out = dstring::temp();
    String[4] views;
    for (int i = 0; i < self.count; i++) {
        views[i] = self.editors[i].view(edit_h, show_cursor);
    }

    if (self.count == 1) {
        out.append_string(views[0]);
    } else {
        String joined = views[0];
        for (int i = 1; i < self.count; i++) {
            joined = lipgloss::join_horizontal(joined, views[i], 1);
        }
        out.append_string(joined);
    }

    out.append_char('\n');
    out.append_string(hint.render(string::tformat("TAB: switch | Ctrl+N: add | Ctrl+W: close | ESC: quit | Panes: %d", self.count)));
    return out.str_view();
}

fn int main() {
    SplitModel m = {};
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