module list_example;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct ListModel {
    String[16] items;
    int item_count;
    int cursor;
    int selected;
    int width;
    int height;
    int scroll_offset;
}

fn tea::Cmd ListModel.init(ListModel* self) @dynamic {
    self.items[0] = "Buy milk";
    self.items[1] = "Clean the house";
    self.items[2] = "Write C3 code";
    self.items[3] = "Read a book";
    self.items[4] = "Play video games";
    self.items[5] = "Go for a walk";
    self.items[6] = "Call mom";
    self.items[7] = "Cook dinner";
    self.items[8] = "Fix the bug";
    self.items[9] = "Deploy to prod";
    self.items[10] = "Review PRs";
    self.items[11] = "Update docs";
    self.items[12] = "Refactor module";
    self.items[13] = "Write tests";
    self.items[14] = "Celebration dinner";
    self.item_count = 15;
    return null;
}

fn tea::Cmd ListModel.update(ListModel* self, tea::Msg msg) @dynamic {
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
        case tea::KeyCode.UP:
            if (self.cursor > 0) self.cursor--;
        case tea::KeyCode.DOWN:
            if (self.cursor < self.item_count - 1) self.cursor++;
        case tea::KeyCode.HOME:
            self.cursor = 0;
        case tea::KeyCode.END:
            self.cursor = self.item_count - 1;
        case tea::KeyCode.PAGE_UP:
            self.cursor -= 5;
            if (self.cursor < 0) self.cursor = 0;
        case tea::KeyCode.PAGE_DOWN:
            self.cursor += 5;
            if (self.cursor >= self.item_count) self.cursor = self.item_count - 1;
        case tea::KeyCode.ENTER:
            self.selected = self.cursor;
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
        case tea::KeyCode.ESC:
            return tea::quit();
        default:
    }
    return null;
}

fn tea::View ListModel.view(ListModel* self) @dynamic {
    lipgloss::Style cursor_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true);
    lipgloss::Style selected_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00ff00"));
    lipgloss::Style dim_style = lipgloss::new_style().foreground(lipgloss::color_hex("#888888"));
    lipgloss::Style title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
    lipgloss::Style hint_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    lipgloss::Style dot_on = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
    lipgloss::Style dot_off = lipgloss::new_style().foreground(lipgloss::color_hex("#555555"));

    int available = self.height - 4;
    if (available < 3) available = 3;

    if (self.cursor < self.scroll_offset) self.scroll_offset = self.cursor;
    if (self.cursor >= self.scroll_offset + available) self.scroll_offset = self.cursor - available + 1;

    DString out = dstring::temp();
    out.append_string(title_style.render("Select an item:"));
    out.append_char('\n');

    int end = self.scroll_offset + available;
    if (end > self.item_count) end = self.item_count;

    for (int i = self.scroll_offset; i < end; i++) {
        String item = self.items[i];
        if (self.cursor == i) {
            out.append_string(cursor_style.render(string::tformat("> %s", item)));
        } else if (self.selected == i) {
            out.append_string(selected_style.render(string::tformat("  %s \xe2\x9c\x93", item)));
        } else {
            out.append_string(dim_style.render(string::tformat("  %s", item)));
        }
        out.append_char('\n');
    }

    // Pagination dots
    int total_pages = (self.item_count + available - 1) / available;
    int current_page = self.scroll_offset / available;
    out.append_char('\n');
    for (int p = 0; p < total_pages; p++) {
        if (p > 0) out.append_char(' ');
        if (p == current_page) {
            out.append_string(dot_on.render("\xe2\x80\xa2"));
        } else {
            out.append_string(dot_off.render("\xe2\x97\xa5"));
        }
    }

    out.append_char('\n');
    out.append_string(hint_style.render("Up/Down navigate | Enter select | q quit"));

    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    ListModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }
    if (m.selected >= 0) {
        io::printfn("You selected: %s", m.items[m.selected]);
    }
    io::printn("Bye!");
    return 0;
}
