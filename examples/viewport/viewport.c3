module viewport;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int TOTAL_LINES = 80;
const int MSG_TICK = 1;

struct ViewportModel {
    int offset;
    int width;
    int height;
    int visible_lines;
}

fn tea::Cmd ViewportModel.init(ViewportModel* self) @dynamic {
    self.offset = 0;
    self.visible_lines = 10;
    return null;
}

fn tea::Cmd ViewportModel.update(ViewportModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        self.visible_lines = msg.window_size.height - 6;
        if (self.visible_lines < 3) self.visible_lines = 3;
        return null;
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    int max_offset = TOTAL_LINES - self.visible_lines;
    if (max_offset < 0) max_offset = 0;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.UP:
            if (self.offset > 0) self.offset--;
        case tea::KeyCode.DOWN:
            if (self.offset < max_offset) self.offset++;
        case tea::KeyCode.PAGE_UP:
            self.offset -= self.visible_lines;
            if (self.offset < 0) self.offset = 0;
        case tea::KeyCode.PAGE_DOWN:
            self.offset += self.visible_lines;
            if (self.offset > max_offset) self.offset = max_offset;
        case tea::KeyCode.HOME:
            self.offset = 0;
        case tea::KeyCode.END:
            self.offset = max_offset;
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
            if (k.rune == 'j') {
                if (self.offset < max_offset) self.offset++;
            }
            if (k.rune == 'k') {
                if (self.offset > 0) self.offset--;
            }
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    return null;
}

fn String lorem_line(int i) {
    String[10] fragments = {
        "The quick brown fox jumps over the lazy dog.",
        "Pack my box with five dozen liquor jugs.",
        "How vexingly quick daft zebras jump.",
        "The five boxing wizards jump quickly.",
        "Sphinx of black quartz, judge my vow.",
        "Two driven jocks help fax my big quiz.",
        "Bright vixens jump; dozy fowl quack.",
        "Quick zephyrs blow, vexing daft Jim.",
        "Jived fox nymph grabs quick walwart.",
        "Crazy Frederick bought many very opal jewels."
    };
    return fragments[i % 10];
}

fn tea::View ViewportModel.view(ViewportModel* self) @dynamic {
    lipgloss::Style title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true).padding(0, 2, 0, 0);
    lipgloss::Style line_style = lipgloss::new_style().foreground(lipgloss::color_hex("#cccccc"));
    lipgloss::Style dim_style = lipgloss::new_style().foreground(lipgloss::color_hex("#444444"));
    lipgloss::Style highlight_style = lipgloss::new_style().background(lipgloss::color_hex("#333355")).foreground(lipgloss::color_hex("#ffffff"));
    lipgloss::Style box_style = lipgloss::new_style()
        .set_border(lipgloss::rounded_border())
        .padding(0, 1, 0, 1);

    DString out = dstring::temp();
    out.append_string(title_style.render("Scrollable Viewport"));
    out.append_char('\n');

    DString body = dstring::temp();
    for (int i = 0; i < self.visible_lines; i++) {
        int line_num = self.offset + i;
        if (line_num >= TOTAL_LINES) break;

        String num = string::tformat("%4d ", line_num + 1);
        String content = lorem_line(line_num);

        // Highlight middle line as cursor
        if (i == self.visible_lines / 2) {
            body.append_string(highlight_style.render(string::tformat("%s%s", num, content)));
        } else {
            body.append_string(dim_style.render(num));
            body.append_string(line_style.render(content));
        }
        body.append_char('\n');
    }

    out.append_string(box_style.render(body.str_view()));

    int pct = TOTAL_LINES > 0 ? ((self.offset + self.visible_lines) * 100) / TOTAL_LINES : 100;
    if (pct > 100) pct = 100;
    String bar = lipgloss::progress_bar(20, pct, "█", "░", lipgloss::color_hex("#00d7ff"), lipgloss::color_hex("#333333"));
    out.append_char('\n');
    out.append_string(dim_style.render(string::tformat(" %s %d%%  |  ↑↓ j/k scroll  |  PgUp/PgDn  |  Home/End  |  q quit", bar, pct)));

    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    ViewportModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}