module splash;

import tea;
import xray;
import lipgloss;
import std::io;
import std::core::string;

extern fn double c3_sin(double x);
extern fn double c3_cos(double x);


struct SplashModel {
    int frame;
    int width;
    int height;
    // Cell grid for direct rendering
    xray::Cell[] view_cells;
    sz view_cells_len;
}

fn tea::Cmd SplashModel.init(SplashModel* self) @dynamic {
    return tea::tick();
}


fn tea::Cmd SplashModel.update(SplashModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        // Reallocate cell grid
        mem::free(self.view_cells.ptr);
        int rows = self.height;
        self.view_cells_len = (sz)self.width * (sz)rows;
        self.view_cells = mem::new_array(xray::Cell, self.view_cells_len);
        return null;
    }
    if (msg.kind == tea::MsgKind.TICK) {
        self.frame++;
        return tea::tick();
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    return tea::quit();
}

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
    double angle = 0.7854 + t * 0.1;

    int rows = h;

    // Reallocate if size changed
    sz needed = (sz)w * (sz)rows;
    if (needed != self.view_cells_len) {
        mem::free(self.view_cells.ptr);
        self.view_cells_len = needed;
        self.view_cells = mem::new_array(xray::Cell, needed);
    }

    xray::Style base_style = xray::default_style();

    int pixel_rows = h * 2;
    for (int y = 0; y < rows; y++) {
        int fy_top = y * 2;
        int fy_bot = y * 2 + 1;
        int row_offset = y * w;

        for (int x = 0; x < w; x++) {
            double fx = (double)x / (double)w;

            double ca = c3_cos(angle);
            double sa = c3_sin(angle);

            // Top pixel color
            double yt = (double)fy_top / (double)pixel_rows;
            double proj_t = (fx - 0.5) * ca + (yt - 0.5) * sa + 0.5;
            double vt = 0.6 + 0.4 * c3_sin(fx * 3.0 + t * 0.7 + yt * 2.0);
            double ht = (proj_t * 0.4 + t * 0.1) % 1.0;
            if (ht < 0) ht += 1.0;
            RgbColor top = hsv_to_rgb(ht, 0.8, vt);

            // Bottom pixel color
            double yb = (double)fy_bot / (double)pixel_rows;
            double proj_b = (fx - 0.5) * ca + (yb - 0.5) * sa + 0.5;
            double vb = 0.6 + 0.4 * c3_sin(fx * 3.0 + t * 0.7 + yb * 2.0);
            double hb = (proj_b * 0.4 + t * 0.1) % 1.0;
            if (hb < 0) hb += 1.0;
            RgbColor bot = hsv_to_rgb(hb, 0.8, vb);

            xray::Cell c;
            c.content[0] = 0xe2;
            c.content[1] = 0x96;
            c.content[2] = 0x80;
            c.content_len = 3;
            c.width = 1;
            c.style = base_style
                .set_fg(xray::color_rgb((char)top.r, (char)top.g, (char)top.b))
                .set_bg(xray::color_rgb((char)bot.r, (char)bot.g, (char)bot.b));
            self.view_cells[row_offset + x] = c;
        }
    }

    return tea::new_alt_cell_view(self.view_cells, (sz)w, (sz)rows);
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
