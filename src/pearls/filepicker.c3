module pearls;

import tea;
import lipgloss;
import std::io;
import std::core::dstring;

// FilePicker is a file browser component.
struct FilePicker {
    char[64][64] names;
    int[64]      name_lens;
    bool[64]     is_dirs;
    int          count;
    int          cursor;
    int          scroll;
    String       current_dir;
    String       selected;
    int          width;
    int          height;
    lipgloss::Style cursor_style;
    lipgloss::Style dir_style;
    lipgloss::Style file_style;
    lipgloss::Style title_style;
    lipgloss::Style hint_style;
    lipgloss::Style error_style;
}

// new_file_picker creates a file picker starting in the given directory.
fn FilePicker new_file_picker(String start_dir) {
    FilePicker fp = {};
    fp.current_dir = start_dir;
    fp.cursor_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true);
    fp.dir_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff"));
    fp.file_style = lipgloss::new_style().foreground(lipgloss::color_hex("#cccccc"));
    fp.title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
    fp.hint_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    fp.error_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff0000"));
    return fp;
}

// load_dir loads the contents of a directory.
fn void FilePicker.load_dir(&self, String path) {
    self.selected = "";
    self.count = 0;
    self.cursor = 0;
    self.scroll = 0;
    self.current_dir = path;

    @pool() {
        char[512] path_buf;
        for (sz i = 0; i < path.len && i < 511; i++) {
            path_buf[i] = path[i];
            path_buf[i + 1] = 0;
        }
        path_buf[path.len] = 0;

        char[64 * 64] name_buf;
        int[64] dir_flags;

        int n = c3_list_dir(&path_buf[0], &name_buf[0], &dir_flags[0], 64);

        for (int i = 0; i < n && self.count < 64; i++) {
            self.is_dirs[self.count] = (dir_flags[i] != 0);

            int offset = i * 64;
            sz j = 0;
            while (j < 63 && name_buf[offset + j] != 0) {
                self.names[self.count][j] = name_buf[offset + j];
                j++;
            }
            self.names[self.count][j] = 0;
            self.name_lens[self.count] = (int)j;

            // Skip hidden files (except . and ..)
            if (j > 0 && self.names[self.count][0] == '.' &&
                !(j == 1 || (j == 2 && self.names[self.count][1] == '.'))) {
                continue;
            }

            self.count++;
        }
    };
}

extern fn int c3_list_dir(char* path, char* names, int* is_dirs, int max_entries);

// handle_key processes file picker keybindings.
// Returns true if the key was consumed.
fn bool FilePicker.handle_key(&self, tea::KeyMsg k) {
    switch (k.code) {
        case tea::KeyCode.UP:
            if (self.cursor > 0) self.cursor--;
            return true;
        case tea::KeyCode.DOWN:
            if (self.cursor < self.count - 1) self.cursor++;
            return true;
        case tea::KeyCode.ENTER:
            if (self.cursor < self.count && self.is_dirs[self.cursor]) {
                // Don't navigate into "."
                if (self.name_lens[self.cursor] == 1 && self.names[self.cursor][0] == '.') {
                    return true;
                }
                DString new_path = dstring::temp();
                new_path.append_string(self.current_dir);
                new_path.append_char('/');
                new_path.append_string((String)self.names[self.cursor][:self.name_lens[self.cursor]]);
                self.load_dir(new_path.str_view());
            } else if (self.cursor < self.count) {
                self.selected = (String)self.names[self.cursor][:self.name_lens[self.cursor]];
            }
            return true;
        case tea::KeyCode.BACKSPACE:
        case tea::KeyCode.LEFT:
            // Go to parent directory
            if (self.current_dir.len > 1) {
                sz last_slash = self.current_dir.len - 1;
                while (last_slash > 0 && self.current_dir[last_slash] != '/') last_slash--;
                if (last_slash > 0) {
                    self.load_dir((String)self.current_dir[:last_slash]);
                } else {
                    self.load_dir("/");
                }
            }
            return true;
        default:
            return false;
    }
}

// view returns the rendered file picker string.
fn String FilePicker.view(&self) {
    DString out = dstring::temp();
    out.append_string(self.title_style.render(string::tformat("Files: %s", self.current_dir)));
    out.append_char('\n');

    int visible = self.height - 4;
    if (visible < 1) visible = 1;

    // Adjust scroll
    if (self.cursor < self.scroll) self.scroll = self.cursor;
    if (self.cursor >= self.scroll + visible) self.scroll = self.cursor - visible + 1;

    int end = self.scroll + visible;
    if (end > self.count) end = self.count;

    for (int i = self.scroll; i < end; i++) {
        String name = (String)self.names[i][:self.name_lens[i]];
        String suffix = self.is_dirs[i] ? "/" : "";
        String marker = (i == self.cursor) ? "> " : "  ";

        if (i == self.cursor) {
            out.append_string(self.cursor_style.render(string::tformat("%s%s%s", marker, name, suffix)));
        } else if (self.is_dirs[i]) {
            out.append_string(self.dir_style.render(string::tformat("%s%s%s", marker, name, suffix)));
        } else {
            out.append_string(self.file_style.render(string::tformat("%s%s%s", marker, name, suffix)));
        }
        out.append_char('\n');
    }

    out.append_char('\n');
    out.append_string(self.hint_style.render("Enter: open | Backspace: parent | q: quit"));
    return out.str_view();
}
