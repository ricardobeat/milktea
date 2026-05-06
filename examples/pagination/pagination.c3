module pagination;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct PaginationModel {
    int cursor;
    int page;
    int per_page;
    int width;
    int height;
    bool[1000] selected;
}

const int TOTAL_ITEMS = 50;
const int MSG_TICK = 1;

fn tea::Cmd PaginationModel.init(PaginationModel* self) @dynamic {
    self.per_page = 8;
    self.page = 0;
    self.cursor = 0;
    return null;
}

fn tea::Cmd PaginationModel.update(PaginationModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    int page_start = self.page * self.per_page;
    int page_end = page_start + self.per_page;
    if (page_end > TOTAL_ITEMS) page_end = TOTAL_ITEMS;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.UP:
            if (self.cursor > page_start) self.cursor--;
        case tea::KeyCode.DOWN:
            if (self.cursor < page_end - 1) self.cursor++;
        case tea::KeyCode.PAGE_UP:
            if (self.page > 0) {
                self.page--;
                self.cursor = self.page * self.per_page;
            }
        case tea::KeyCode.PAGE_DOWN:
            if ((self.page + 1) * self.per_page < TOTAL_ITEMS) {
                self.page++;
                self.cursor = self.page * self.per_page;
            }
        case tea::KeyCode.HOME:
            self.cursor = page_start;
        case tea::KeyCode.END:
            self.cursor = page_end - 1;
        case tea::KeyCode.ENTER:
            self.selected[self.cursor] = !self.selected[self.cursor];
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
            if (k.rune == 'j') {
                if (self.cursor < page_end - 1) self.cursor++;
            }
            if (k.rune == 'k') {
                if (self.cursor > page_start) self.cursor--;
            }
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    return null;
}

fn String PaginationModel.view(PaginationModel* self) @dynamic {
    lipgloss::Style title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true).padding(0, 0, 1, 0);
    lipgloss::Style cursor_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true);
    lipgloss::Style check_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00ff00"));
    lipgloss::Style dim_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    lipgloss::Style num_style = lipgloss::new_style().foreground(lipgloss::color_hex("#888888"));

    DString out = dstring::temp();
    out.append_string(title_style.render(string::tformat("Items (page %d of %d)", self.page + 1, (TOTAL_ITEMS + self.per_page - 1) / self.per_page)));
    out.append_char('\n');

    int page_start = self.page * self.per_page;
    int page_end = page_start + self.per_page;
    if (page_end > TOTAL_ITEMS) page_end = TOTAL_ITEMS;

    for (int i = page_start; i < page_end; i++) {
        String check = self.selected[i] ? "✓" : " ";
        String marker = (i == self.cursor) ? "> " : "  ";
        String item_text = string::tformat("Item %03d", i + 1);

        if (i == self.cursor) {
            out.append_string(cursor_style.render(string::tformat("%s%s %s", marker, check, item_text)));
        } else if (self.selected[i]) {
            out.append_string(check_style.render(string::tformat("%s%s %s", marker, check, item_text)));
        } else {
            out.append_string(dim_style.render(string::tformat("%s%s %s", marker, check, item_text)));
        }
        out.append_char('\n');
    }

    out.append_char('\n');
    out.append_string(num_style.render(string::tformat("%d-%d of %d", page_start + 1, page_end, TOTAL_ITEMS)));
    out.append_string(dim_style.render("  |  ↑↓ j/k navigate  |  ENTER toggle  |  PgUp/PgDn pages  |  q quit"));

    return out.str_view();
}

fn int main() {
    PaginationModel m = {};
    tea::enter_alt_screen();

    if (catch err = tea::run((tea::Model)&m)) {
        tea::exit_alt_screen();
        io::printfn("Error: %s", err);
        return 1;
    }

    tea::exit_alt_screen();

    int count = 0;
    for (int i = 0; i < TOTAL_ITEMS; i++) {
        if (m.selected[i]) count++;
    }
    io::printfn("\nSelected %d items.", count);
    return 0;
}