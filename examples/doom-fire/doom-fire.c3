module doom_fire;

import tea;
import xray;
import std::io;
import std::core::string;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

const int MAX_W = 400;
const int MAX_H = 400;

// Classic DOOM fire palette: 26 xterm-256 color indices
int[26] fire_palette = { 0, 233, 234, 52, 53, 88, 89, 94, 95, 96, 130, 131, 132, 133, 172, 214, 215, 220, 220, 221, 3, 226, 227, 230, 231, 7 };

// Pre-built ▀ cell for each palette index — avoids per-frame cell construction.
// Each entry: content = "▀" (U+2580), style.fg = palette color (for top pixel).
xray::Cell[26] fire_cells;

struct FireModel {
    int* fire;
    int width;
    int height;
    long startTime;
    // Pre-allocated cell grid for direct rendering
    xray::Cell[] view_cells;
    int view_cols;
    int view_rows;
}

fn void init_fire_cells() {
    for (int i = 0; i < 26; i++) {
        xray::Style s = xray::default_style().set_fg(xray::color_256((char)fire_palette[i]));
        fire_cells[i] = xray::new_cell("\xe2\x96\x80", 1, s);
    }
}

fn tea::Cmd FireModel.init(FireModel* self) @dynamic {
    ulong seed = (ulong)c3_time_ms_long();
    srand((uint)seed);
    self.startTime = c3_time_ms_long();
    self.width = 80;
    self.height = 48;
    self.fire = mem::new_array(int, MAX_W * MAX_H);
    for (int i = 0; i < MAX_W * MAX_H; i++) self.fire[i] = 0;
    for (int x = 0; x < self.width; x++) {
        self.fire[(self.height - 1) * self.width + x] = 25;
    }
    self.view_cols = self.width;
    self.view_rows = self.height / 2;
    self.view_cells = mem::new_array(xray::Cell, (sz)(self.view_cols * self.view_rows));

    init_fire_cells();

    return tea::tick();
}


fn void spread_pixel(FireModel* m, int idx) {
    if (idx < m.width) return;
    int pixel = m.fire[idx];
    if (pixel == 0) {
        m.fire[idx - m.width] = 0;
        return;
    }
    int rnd = rand() % 4;
    int dst = idx - rnd + 1;
    int buf_len = m.width * m.height;
    if (dst - m.width >= 0 && dst - m.width < buf_len) {
        int decay = rnd & 1;
        int new_val = pixel - decay;
        if (new_val < 0) new_val = 0;
        m.fire[dst - m.width] = new_val;
    }
}

fn tea::Cmd FireModel.update(FireModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        int new_w = msg.window_size.width;
        int new_h = msg.window_size.height * 2;
        if (new_w > MAX_W) new_w = MAX_W;
        if (new_h > MAX_H) new_h = MAX_H;
        self.width = new_w;
        self.height = new_h;
        for (int i = 0; i < self.width * self.height; i++) {
            self.fire[i] = 0;
        }
        for (int x = 0; x < self.width; x++) {
            self.fire[(self.height - 1) * self.width + x] = 25;
        }
        // Reallocate view cell grid
        mem::free(self.view_cells.ptr);
        self.view_cols = self.width;
        self.view_rows = self.height / 2;
        self.view_cells = mem::new_array(xray::Cell, (sz)(self.view_cols * self.view_rows));
        return null;
    }

    if (msg.kind == tea::MsgKind.TICK) {
        for (int x = 0; x < self.width; x++) {
            for (int y = 0; y < self.height; y++) {
                spread_pixel(self, y * self.width + x);
            }
        }
        return tea::tick();
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

fn tea::View FireModel.view(FireModel* self) @dynamic {
    if (self.width == 0) return tea::new_view("Initializing...");

    // Build cell grid directly — no string, no ANSI, no parsing.
    // xray's diff engine handles minimal output.
    int view_w = self.view_cols;
    int view_h = self.view_rows;

    for (int vy = 0; vy < view_h; vy++) {
        int fire_y = vy * 2;
        int row_offset = vy * view_w;
        for (int vx = 0; vx < view_w; vx++) {
            int top_val = self.fire[fire_y * self.width + vx];
            int bot_val = self.fire[(fire_y + 1) * self.width + vx];

            // Start with the pre-built cell for the top pixel's fg color.
            // Set the bg to the bottom pixel's color.
            xray::Cell c = fire_cells[top_val];
            c.style = c.style.set_bg(xray::color_256((char)fire_palette[bot_val]));
            self.view_cells[row_offset + vx] = c;
        }
    }

    return tea::new_alt_cell_view(self.view_cells, (sz)view_w, (sz)view_h);
}

fn int main() {
    FireModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }
    io::printn("Bye!");
    return 0;
}
