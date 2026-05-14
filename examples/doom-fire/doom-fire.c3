module doom_fire;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

const int MSG_TICK = 1;
const int FIRE_W = 80;
const int FIRE_H = 36;
const int MAX_FIRE = 36;

// True-color fire palette: index 0..MAX_FIRE
// Maps intensity to smooth black → red → orange → yellow → white
struct FireColor {
    int r;
    int g;
    int b;
}

fn FireColor fire_color(int val) {
    if (val <= 0) return { .r = 0, .g = 0, .b = 0 };
    if (val >= MAX_FIRE) return { .r = 255, .g = 255, .b = 255 };

    // Normalize 1..MAX_FIRE-1 to 0..1
    double t = (double)(val - 1) / (double)(MAX_FIRE - 2);

    int r = 0;
    int g = 0;
    int b = 0;

    if (t < 0.33) {
        // Black to red
        double s = t / 0.33;
        r = (int)(s * 220);
        g = 0;
        b = 0;
    } else if (t < 0.66) {
        // Red to orange/yellow
        double s = (t - 0.33) / 0.33;
        r = 220 + (int)(s * 35);
        g = (int)(s * 200);
        b = 0;
    } else {
        // Yellow to white
        double s = (t - 0.66) / 0.34;
        r = 255;
        g = 200 + (int)(s * 55);
        b = (int)(s * 255);
    }

    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
    return { .r = r, .g = g, .b = b };
}

struct FireModel {
    int[FIRE_W * FIRE_H] fire;
    int width;
    int height;
    int ticks;
}

fn tea::Cmd FireModel.init(FireModel* self) @dynamic {
    ulong seed = (ulong)c3_time_ms_long();
    srand((uint)seed);
    // Bottom row = max intensity
    for (int x = 0; x < FIRE_W; x++) {
        self.fire[(FIRE_H - 1) * FIRE_W + x] = MAX_FIRE;
    }
    return tea::tick(50, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd FireModel.update(FireModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.ticks++;
        // Spread fire upward
        for (int x = 0; x < FIRE_W; x++) {
            for (int y = 1; y < FIRE_H; y++) {
                int src = y * FIRE_W + x;
                int pixel = self.fire[src];
                if (pixel == 0) continue;
                int decay = rand() % 3;
                int dst_y = y - 1;
                int dst_x = x - decay + 1;
                if (dst_x < 0) dst_x = 0;
                if (dst_x >= FIRE_W) dst_x = FIRE_W - 1;
                int dst = dst_y * FIRE_W + dst_x;
                int new_val = pixel - decay;
                if (new_val < 0) new_val = 0;
                self.fire[dst] = new_val;
            }
        }
        return tea::tick(50, &on_tick);
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
    int rows = FIRE_H / 2;
    if (rows > self.height - 2) rows = self.height - 2;
    if (rows < 1) rows = 1;
    int cols = FIRE_W;
    if (cols > self.width) cols = self.width;

    DString out = dstring::temp();

    // Render using half-block ▀: top pixel = foreground, bottom pixel = background
    for (int y = 0; y < rows; y++) {
        int fy_top = y * 2;
        int fy_bot = y * 2 + 1;
        for (int x = 0; x < cols; x++) {
            int top_val = self.fire[fy_top * FIRE_W + x];
            int bot_val = (fy_bot < FIRE_H) ? self.fire[fy_bot * FIRE_W + x] : 0;

            FireColor top_c = fire_color(top_val);
            FireColor bot_c = fire_color(bot_val);

            if (top_val == 0 && bot_val == 0) {
                out.append_string("\x1b[48;5;16m ");
            } else {
                out.append_string(string::tformat("\x1b[38;2;%d;%d;%d;48;2;%d;%d;%dm▀",
                    top_c.r, top_c.g, top_c.b, bot_c.r, bot_c.g, bot_c.b));
            }
        }
        out.append_string("\x1b[0m\n");
    }

    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    out.append_string(hint.render("DOOM Fire | q/ESC quit"));
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    FireModel m = {};
    if (catch err = tea::run((tea::Model)&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}