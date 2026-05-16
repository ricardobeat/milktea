module diff_viewer;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

enum DiffLineKind : int {
    CONTEXT,
    ADDITION,
    DELETION,
    FILE_HEADER,
    HUNK_HEADER,
}

struct DiffLine {
    DiffLineKind kind;
    String content;
    int line_num;
}

struct DiffModel {
    DiffLine[256] lines;
    int line_count;
    int scroll_offset;
    int width;
    int height;
    int cursor;
}

fn tea::Cmd DiffModel.init(DiffModel* self) @dynamic {
    self.scroll_offset = 0;
    self.cursor = 0;
    self.width = 80;
    self.height = 24;
    self.line_count = 0;

    parse_sample_diff(self);

    return null;
}

fn void parse_sample_diff(DiffModel* self) {
    String[] sample_lines = {
        "diff --git a/src/main.c3 b/src/main.c3",
        "index abc123..def456 100644",
        "--- a/src/main.c3",
        "+++ b/src/main.c3",
        "@@ -10,7 +10,8 @@ fn void process(String path) {",
        "     int total = 0;",
        "     // Process each line",
        "-    foreach (line : input) {",
        "+    foreach (idx, line : input) {",
        "+        io::printfn(\"[%d] %s\", idx, line);",
        "     total += line.len;",
        "     }",
        "     return total;",
    };

    foreach (line : sample_lines) {
        if (self.line_count >= 256) break;

        DiffLineKind kind = CONTEXT;

        if (line.starts_with("diff --git")) {
            kind = FILE_HEADER;
        } else if (line.starts_with("@@")) {
            kind = HUNK_HEADER;
        } else if (line.starts_with("+") && !line.starts_with("+++")) {
            kind = ADDITION;
        } else if (line.starts_with("-") && !line.starts_with("---")) {
            kind = DELETION;
        }

        self.lines[self.line_count] = {
            .kind = kind,
            .content = line,
            .line_num = 0,
        };
        self.line_count++;
    }
}

fn tea::Cmd DiffModel.update(DiffModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
            if (k.rune == 'j') {
                if (self.cursor < self.line_count - 1) {
                    self.cursor++;
                    adjust_scroll(self);
                }
            }
            if (k.rune == 'k') {
                if (self.cursor > 0) {
                    self.cursor--;
                    adjust_scroll(self);
                }
            }
        case tea::KeyCode.DOWN:
            if (self.cursor < self.line_count - 1) {
                self.cursor++;
                adjust_scroll(self);
            }
        case tea::KeyCode.UP:
            if (self.cursor > 0) {
                self.cursor--;
                adjust_scroll(self);
            }
        case tea::KeyCode.PAGE_DOWN:
            self.cursor = self.cursor + self.height - 3;
            if (self.cursor >= self.line_count) self.cursor = self.line_count - 1;
            adjust_scroll(self);
        case tea::KeyCode.PAGE_UP:
            self.cursor = self.cursor - self.height + 3;
            if (self.cursor < 0) self.cursor = 0;
            adjust_scroll(self);
        case tea::KeyCode.HOME:
            self.cursor = 0;
            self.scroll_offset = 0;
        case tea::KeyCode.END:
            self.cursor = self.line_count - 1;
            adjust_scroll(self);
        default:
    }

    return null;
}

fn void adjust_scroll(DiffModel* self) {
    int visible_height = self.height - 3;

    if (self.cursor < self.scroll_offset) {
        self.scroll_offset = self.cursor;
    } else if (self.cursor >= self.scroll_offset + visible_height) {
        self.scroll_offset = self.cursor - visible_height + 1;
    }
}

fn tea::View DiffModel.view(DiffModel* self) @dynamic {
    DString out = dstring::temp();

    lipgloss::Style header_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    String header = header_style.render("diff-viewer | j/k or arrows to scroll | q to quit");

    out.append_string(header);
    out.append_char('\n');

    int visible_height = self.height - 3;
    int end_idx = self.scroll_offset + visible_height;
    if (end_idx > self.line_count) end_idx = self.line_count;

    for (int i = self.scroll_offset; i < end_idx; i++) {
        DiffLine* dl = &self.lines[i];
        String line = format_diff_line(self, dl, i == self.cursor);
        out.append_string(line);
        out.append_char('\n');
    }

    out.append_char('\n');
    lipgloss::Style footer_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    String footer = footer_style.render(string::tformat("Line %d / %d", self.cursor + 1, self.line_count));
    out.append_string(footer);

    return tea::new_alt_screen_view(out.str_view());
}

fn String format_diff_line(DiffModel* self, DiffLine* line, bool is_cursor) {
    String prefix = " ";
    lipgloss::Style style = lipgloss::new_style();

    switch (line.kind) {
        case FILE_HEADER:
            style = style.foreground(lipgloss::color_hex("#00d7ff"));
            prefix = " ";
        case HUNK_HEADER:
            style = style.foreground(lipgloss::color_hex("#af87ff"));
            prefix = " ";
        case ADDITION:
            style = style.foreground(lipgloss::color_hex("#00ff00"));
            prefix = "+";
        case DELETION:
            style = style.foreground(lipgloss::color_hex("#ff0000"));
            prefix = "-";
        case CONTEXT:
            style = style.foreground(lipgloss::color_hex("#cccccc"));
            prefix = " ";
    }

    if (is_cursor) {
        style = style.background(lipgloss::color_hex("#444444")).set_bold(true);
    }

    String content = style.render(string::tformat("%s%s", prefix, line.content));
    return content;
}

fn int main() {
    DiffModel model = {};
    if (catch err = tea::@run_program(&model)) {
        io::printfn("Error: %s", err);
        return 1;
    }
    return 0;
}
