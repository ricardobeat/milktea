module list_example;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

struct ListModel {
    String[] items;
    int cursor;
    int selected;
    int width;
    int height;
    int scroll_offset;
}

fn tea::Cmd ListModel.init(ListModel* self) @dynamic {
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
            if (self.cursor < (int)self.items.len - 1) self.cursor++;
        case tea::KeyCode.HOME:
            self.cursor = 0;
        case tea::KeyCode.END:
            self.cursor = (int)self.items.len - 1;
        case tea::KeyCode.PAGE_UP:
            self.cursor = self.cursor - 5;
            if (self.cursor < 0) self.cursor = 0;
        case tea::KeyCode.PAGE_DOWN:
            self.cursor = self.cursor + 5;
            if (self.cursor > (int)self.items.len - 1) self.cursor = (int)self.items.len - 1;
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

    // Reserve space: title (2 lines), hint (2 lines)
    int available = self.height - 4;
    if (available < 3) available = 3;

    // Compute scroll offset to keep cursor visible
    if (self.cursor < self.scroll_offset) {
        self.scroll_offset = self.cursor;
    }
    if (self.cursor >= self.scroll_offset + available) {
        self.scroll_offset = self.cursor - available + 1;
    }

    DString out = dstring::temp();
    out.append_string(title_style.render("Select an item:"));
    out.append_char('\n');

    int end = self.scroll_offset + available;
    if (end > (int)self.items.len) end = (int)self.items.len;

    for (int i = self.scroll_offset; i < end; i++) {
        String cursor_str = "  ";
        if (self.cursor == i) {
            cursor_str = "> ";
        }
        
        String item = self.items[i];
        String rendered_item;
        
        if (self.cursor == i) {
            rendered_item = cursor_style.render(string::tformat("%s%s", cursor_str, item));
        } else if (self.selected == i) {
            rendered_item = selected_style.render(string::tformat("%s%s ✓", cursor_str, item));
        } else {
            rendered_item = dim_style.render(string::tformat("%s%s", cursor_str, item));
        }
        
        out.append_string(rendered_item);
        out.append_char('\n');
    }

    out.append_char('\n');
    out.append_string(hint_style.render("↑↓ navigate  |  ENTER select  |  q/ESC quit"));
    
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    String[] items = {
        "Buy milk",
        "Clean the house",
        "Write C3 code",
        "Read a book",
        "Play video games",
        "Go for a walk",
        "Call mom",
        "Cook dinner",
        "Fix the bug",
        "Deploy to prod",
        "Review PRs",
        "Update docs",
        "Refactor module",
        "Write tests",
        "Celebration dinner"
    };
    
    ListModel m = { .items = items, .cursor = 0, .selected = -1 };
    
    tea::enter_alt_screen();
    
    if (catch err = tea::run((tea::Model)&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }
    
    
    if (m.selected >= 0) {
        io::printfn("\nYou selected: %s\n", m.items[m.selected]);
    } else {
        io::printn("\nYou didn't select anything.\n");
    }
    
    return 0;
}