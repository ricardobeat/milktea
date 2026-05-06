module file_picker;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

extern fn int c3_list_dir(char* path, char* names, int* is_dirs, int max_entries);

const int MAX_ENTRIES = 64;

struct PickerModel {
    char[64][MAX_ENTRIES] names;
    int[MAX_ENTRIES] name_lens;
    bool[MAX_ENTRIES] is_dirs;
    int count;
    int cursor;
    int scroll;
    String current_dir;
    String selected;
    int width;
    int height;
    bool has_error;
}

fn void load_dir(PickerModel* self, String path) {
    self.selected = "";
    self.has_error = false;
    self.count = 0;
    self.cursor = 0;
    self.scroll = 0;
    self.current_dir = path;

    @pool() {
        char[512] path_buf;
        for (usz i = 0; i < path.len && i < 511; i++) {
            path_buf[i] = path[i];
            path_buf[i + 1] = 0;
        }
        path_buf[path.len] = 0;

        char[64 * MAX_ENTRIES] name_buf;
        int[MAX_ENTRIES] dir_flags;

        int n = c3_list_dir(&path_buf[0], &name_buf[0], &dir_flags[0], MAX_ENTRIES);

        for (int i = 0; i < n && self.count < MAX_ENTRIES; i++) {
            self.is_dirs[self.count] = (dir_flags[i] != 0);

            int offset = i * 64;
            usz j = 0;
            while (j < 63 && name_buf[offset + j] != 0) {
                self.names[self.count][j] = name_buf[offset + j];
                j++;
            }
            self.names[self.count][j] = 0;
            self.name_lens[self.count] = (int)j;

            if (j > 0 && self.names[self.count][0] == '.' &&
                !(j == 1 || (j == 2 && self.names[self.count][1] == '.'))) {
                continue;
            }

            self.count++;
        }
    };
}

fn tea::Cmd PickerModel.init(PickerModel* self) @dynamic {
    load_dir(self, ".");
    return null;
}

fn tea::Cmd PickerModel.update(PickerModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.UP:
            if (self.cursor > 0) self.cursor--;
        case tea::KeyCode.DOWN:
            if (self.cursor < self.count - 1) self.cursor++;
        case tea::KeyCode.ENTER:
            if (self.cursor < self.count && self.is_dirs[self.cursor]) {
                if (self.name_lens[self.cursor] == 1 && self.names[self.cursor][0] == '.') {
                    // Stay
                } else {
                    DString new_path = dstring::temp();
                    new_path.append_string(self.current_dir);
                    new_path.append_char('/');
                    new_path.append_string((String)self.names[self.cursor][:self.name_lens[self.cursor]]);
                    load_dir(self, new_path.str_view());
                }
            } else {
                self.selected = (String)self.names[self.cursor][:self.name_lens[self.cursor]];
                return tea::quit();
            }
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
            if (k.rune == 'b') {
                if (self.current_dir.len > 1) {
                    usz last_slash = self.current_dir.len - 1;
                    while (last_slash > 0 && self.current_dir[last_slash] != '/') last_slash--;
                    if (last_slash > 0) {
                        load_dir(self, (String)self.current_dir[:last_slash]);
                    } else {
                        load_dir(self, "/");
                    }
                }
            }
        default:
    }

    int visible = self.height - 4;
    if (visible < 1) visible = 1;
    if (self.cursor < self.scroll) self.scroll = self.cursor;
    if (self.cursor >= self.scroll + visible) self.scroll = self.cursor - visible + 1;

    return null;
}

fn String PickerModel.view(PickerModel* self) @dynamic {
    lipgloss::Style title = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true).padding(0, 0, 1, 0);
    lipgloss::Style cursor_s = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true);
    lipgloss::Style dir_s = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff"));
    lipgloss::Style file_s = lipgloss::new_style().foreground(lipgloss::color_hex("#cccccc"));
    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));

    DString out = dstring::temp();
    out.append_string(title.render(string::tformat("Files: %s", self.current_dir)));
    out.append_char('\n');

    if (self.has_error) {
        out.append_string("Error reading directory");
        return out.str_view();
    }

    int visible = self.height - 5;
    if (visible < 1) visible = 1;
    int end = self.scroll + visible;
    if (end > self.count) end = self.count;

    for (int i = self.scroll; i < end; i++) {
        String name = (String)self.names[i][:self.name_lens[i]];
        String marker = (i == self.cursor) ? "> " : "  ";
        String suffix = self.is_dirs[i] ? "/" : "";

        if (i == self.cursor) {
            out.append_string(cursor_s.render(string::tformat("%s%s%s", marker, name, suffix)));
        } else if (self.is_dirs[i]) {
            out.append_string(dir_s.render(string::tformat("%s%s%s", marker, name, suffix)));
        } else {
            out.append_string(file_s.render(string::tformat("%s%s%s", marker, name, suffix)));
        }
        out.append_char('\n');
    }

    out.append_char('\n');
    out.append_string(hint.render("Enter: open/select | b: back | q: quit"));
    return out.str_view();
}

fn int main() {
    PickerModel m = {};
    tea::enter_alt_screen();

    if (catch err = tea::run((tea::Model)&m)) {
        tea::exit_alt_screen();
        io::printfn("Error: %s", err);
        return 1;
    }

    tea::exit_alt_screen();
    if (m.selected.len > 0) {
        io::printfn("Selected: %s", m.selected);
    } else {
        io::printn("No file selected.");
    }
    return 0;
}