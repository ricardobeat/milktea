module splash;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

extern fn double c3_sin(double x);
extern fn double c3_cos(double x);

const int MSG_TICK = 1;

struct SplashModel {
    int frame;
    int width;
    int height;
}

fn tea::Cmd SplashModel.init(SplashModel* self) @dynamic {
    return tea::tick(16, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd SplashModel.update(SplashModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.frame++;
        return tea::tick(16, &on_tick);
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    return tea::quit();
}

// HSV to RGB. h in [0,1], s in [0,1], v in [0,1]
fn int clamp_color(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

struct RgbColor {
    int r;
    int g;
    int b;
}

fn RgbColor hsv_to_rgb(double h, double s, double v) {
    double hh = h * 6.0;
    if (hh < 0) hh = 0;
    int i = (int)hh;
    double ff = hh - (double)i;
    double p = v * (1.0 - s);
    double q = v * (1.0 - s * ff);
    double t = v * (1.0 - s * (1.0 - ff));

    double r = 0;
    double g = 0;
    double b = 0;

    switch (i % 6) {
        case 0: r = v; g = t; b = p;
        case 1: r = q; g = v; b = p;
        case 2: r = p; g = v; b = t;
        case 3: r = p; g = q; b = v;
        case 4: r = t; g = p; b = v;
        case 5: r = v; g = p; b = q;
        default: r = v; g = p; b = p;
    }

    return { .r = clamp_color((int)(r * 255)), .g = clamp_color((int)(g * 255)), .b = clamp_color((int)(b * 255)) };
}

fn void SplashModel.on_mount(SplashModel* self) @dynamic {
}

fn void SplashModel.on_destroy(SplashModel* self) @dynamic {
}

fn void SplashModel.on_focus(SplashModel* self) @dynamic {
}

fn void SplashModel.on_blur(SplashModel* self) @dynamic {
}

fn tea::View SplashModel.view(SplashModel* self) @dynamic {
    int w = self.width;
    int h = self.height;
    if (w < 2) w = 80;
    if (h < 2) h = 24;

    double t = (double)self.frame * 0.03;

    // We render at half-height using ▀ blocks (top pixel = fg, bottom pixel = bg)
    int rows = (h - 1) / 2;
    if (rows < 1) rows = 1;

    DString out = dstring::temp();

    for (int y = 0; y < rows; y++) {
        int fy_top = y * 2;
        int fy_bot = y * 2 + 1;

        for (int x = 0; x < w; x++) {
            double fx = (double)x / (double)w;

            // Top pixel color
            double yt = (double)fy_top / (double)h;
            double vt = 0.5 + 0.5 * c3_sin(fx * 3.0 + t * 0.7 + yt * 2.0);
            double ht = (fx + t * 0.1 + yt * 0.3) % 1.0;
            if (ht < 0) ht += 1.0;
            RgbColor top = hsv_to_rgb(ht, 0.8, vt);

            // Bottom pixel color
            double yb = (double)fy_bot / (double)h;
            double vb = 0.5 + 0.5 * c3_sin(fx * 3.0 + t * 0.7 + yb * 2.0);
            double hb = (fx + t * 0.1 + yb * 0.3) % 1.0;
            if (hb < 0) hb += 1.0;
            RgbColor bot = hsv_to_rgb(hb, 0.8, vb);

            out.append_string(string::tformat("\x1b[38;2;%d;%d;%d;48;2;%d;%d;%dm▀",
                top.r, top.g, top.b, bot.r, bot.g, bot.b));
        }
        out.append_string("\x1b[0m\n");
    }

    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#ffffff")).set_bold(true);
    out.append_string(hint.render("Press any key to quit"));
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    SplashModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}