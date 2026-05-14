module space_example;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

const int MSG_TICK = 1;
const int STAR_COUNT = 200;

struct Star {
    int x;
    int y;
    int brightness;
    char ch;
}

struct SpaceModel {
    Star[STAR_COUNT] stars;
    int width;
    int height;
    int offset;
}

fn tea::Cmd SpaceModel.init(SpaceModel* self) @dynamic {
    ulong seed = (ulong)c3_time_ms_long();
    srand((uint)seed);
    self.width = 80;
    self.height = 24;
    self.offset = 0;

    for (int i = 0; i < STAR_COUNT; i++) {
        self.stars[i].x = rand() % 300;
        self.stars[i].y = rand() % 100;
        self.stars[i].brightness = rand() % 24; // 0-23 grayscale level
        // Pick character based on brightness
        int b = self.stars[i].brightness;
        if (b < 4) {
            self.stars[i].ch = '.';
        } else if (b < 8) {
            self.stars[i].ch = ':';
        } else if (b < 12) {
            self.stars[i].ch = '+';
        } else if (b < 16) {
            self.stars[i].ch = '*';
        } else if (b < 20) {
            self.stars[i].ch = '#';
        } else {
            self.stars[i].ch = '@';
        }
    }
    return tea::tick(80, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd SpaceModel.update(SpaceModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.offset++;
        return tea::tick(80, &on_tick);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;
    switch (k.code) {
        case tea::KeyCode.CTRL_C:
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
        default:
    }
    return null;
}

// Grayscale ANSI 256-color: 232=very dark, 255=white
fn String gray_fg(int level) {
    int idx = 232 + level;
    if (idx < 232) idx = 232;
    if (idx > 255) idx = 255;
    return string::tformat("\x1b[38;5;%dm", idx);
}

fn tea::View SpaceModel.view(SpaceModel* self) @dynamic {
    int w = self.width;
    int h = self.height - 1;
    if (w < 10) w = 80;
    if (h < 5) h = 24;

    // Build a 2D grid. For each cell, check if a star is there.
    // Use a simple hash or direct lookup. Since stars are sparse,
    // we'll iterate stars and mark them.

    // Mark star positions using temp allocator for large grids
    @pool() {
        int cols = w;
        if (cols > 200) cols = 200;
        int rows = h;
        if (rows > 60) rows = 60;

        char[60][200] grid_chars;
        int[60][200] grid_bright;
        for (int y = 0; y < rows; y++) {
            for (int x = 0; x < cols; x++) {
                grid_chars[y][x] = ' ';
                grid_bright[y][x] = -1;
            }
        }

        for (int i = 0; i < STAR_COUNT; i++) {
            Star s = self.stars[i];
            int sx = (s.x + self.offset) % cols;
            int sy = s.y % rows;
            if (sy < 0) sy = 0;
            if (sy >= rows) sy = rows - 1;
            if (sx < 0) sx = 0;
            if (sx >= cols) sx = cols - 1;
            grid_chars[sy][sx] = s.ch;
            grid_bright[sy][sx] = s.brightness;
        }

        lipgloss::Style title = lipgloss::new_style()
            .foreground(lipgloss::color_hex("#00d7ff"))
            .set_bold(true);

        DString out = dstring::temp();

        for (int y = 0; y < rows; y++) {
            for (int x = 0; x < cols; x++) {
                if (grid_bright[y][x] >= 0) {
                    out.append_string(gray_fg(grid_bright[y][x]));
                    out.append_char(grid_chars[y][x]);
                } else {
                    out.append_string("\x1b[38;5;233m ");
                }
            }
            out.append_string("\x1b[0m");
            if (y < rows - 1) out.append_char('\n');
        }

        out.append_char('\n');
        out.append_string(title.render("SPACE   q/ESC quit"));
        return tea::new_alt_screen_view(out.str_view());
    };
}

fn int main() {
    SpaceModel m = {};
    if (catch err = tea::run((tea::Model)&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}
