module super_splash;

import tea;
import xray;
import std::io;
import std::math;

extern fn double c3_sin(double x);
extern fn double c3_cos(double x);

// ─── Splash types ───────────────────────────────────────────

struct RgbColor {
    int r;
    int g;
    int b;
}

fn int clamp_color(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
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

// ─── Voxel types ────────────────────────────────────────────

struct Vec3 {
    float x;
    float y;
    float z;
}

struct Voxel {
    Vec3 pos;
    Vec3 normal;
    Vec3 tan_u;
    Vec3 tan_v;
}

struct Pixel {
    char r;
    char g;
    char b;
}

fn Vec3 vec3(float x, float y, float z) => (Vec3) { x, y, z };

fn Vec3 Vec3.rotate_x(&self, float angle) {
    float c = (float)math::cos(angle);
    float s = (float)math::sin(angle);
    return vec3(self.x, self.y * c - self.z * s, self.y * s + self.z * c);
}

fn Vec3 Vec3.rotate_y(&self, float angle) {
    float c = (float)math::cos(angle);
    float s = (float)math::sin(angle);
    return vec3(self.x * c + self.z * s, self.y, -self.x * s + self.z * c);
}

fn Vec3 Vec3.rotate_z(&self, float angle) {
    float c = (float)math::cos(angle);
    float s = (float)math::sin(angle);
    return vec3(self.x * c - self.y * s, self.x * s + self.y * c, self.z);
}

// ─── Combined model ─────────────────────────────────────────

struct SuperSplashModel {
    // Shared
    int width;
    int height;
    int frame;

    // Splash pixel storage for compositing
    Pixel[] splash_top;   // top-half pixel colors per cell (w * h)
    Pixel[] splash_bot;   // bot-half pixel colors per cell (w * h)

    // Voxel
    Voxel[8192] voxels;
    int voxel_count;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    xray::Cell[] cells;
    Pixel[] pixels;
    float[] depth;
    float[] alpha;   // per-pixel alpha: 1.0 for direct hits, partial for AA edges
}

// ─── Voxel grid (C3 text) ───────────────────────────────────

const int GRID_W = 25;
const int GRID_H = 5;

const String[5] ROWS = {
    "████████ ███████  █████  ",
    "   ██    ██      ██   ██ ",
    "   ██    █████   ███████ ",
    "   ██    ██      ██   ██ ",
    "   ██    ███████ ██   ██ ",
};

fn bool grid_set(int x, int y) {
    if (x < 0 || x >= GRID_W || y < 0 || y >= GRID_H) return false;
    String row = ROWS[y];
    int col = 0;
    sz i = 0;
    while (i < row.len && col <= x) {
        char b = row[i];
        if (b == ' ') {
            if (col == x) return false;
            col++;
            i++;
        } else {
            if (col == x) return true;
            col++;
            i += 3;
        }
    }
    return false;
}

fn void push_face(SuperSplashModel* self, float x, float y, float z, Vec3 normal, Vec3 u, Vec3 v) {
    if (self.voxel_count >= 8192) return;
    self.voxels[self.voxel_count++] = {
        .pos    = vec3(x, y, z),
        .normal = normal,
        .tan_u  = u,
        .tan_v  = v,
    };
}

fn bool point_in_triangle(float px, float py, float x0, float y0, float x1, float y1, float x2, float y2) {
    float d1 = (px - x1) * (y0 - y1) - (x0 - x1) * (py - y1);
    float d2 = (px - x2) * (y1 - y2) - (x1 - x2) * (py - y2);
    float d3 = (px - x0) * (y2 - y0) - (x2 - x0) * (py - y0);
    bool has_neg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    bool has_pos = (d1 > 0) || (d2 > 0) || (d3 > 0);
    return !(has_neg && has_pos);
}

fn bool point_in_quad(float px, float py, float[4] sx, float[4] sy) {
    return point_in_triangle(px, py, sx[0], sy[0], sx[1], sy[1], sx[2], sy[2])
        || point_in_triangle(px, py, sx[1], sy[1], sx[2], sy[2], sx[3], sy[3]);
}

const int DEPTH = 3;

fn bool voxel_set(int x, int y, int z) {
    if (z < 0 || z >= DEPTH) return false;
    return grid_set(x, y);
}

fn void create_voxels(SuperSplashModel* self) {
    float ox = -(float)GRID_W / 2.0f;
    float oy =  (float)GRID_H / 2.0f;
    float oz = -(float)DEPTH  / 2.0f;

    for (int gy = 0; gy < GRID_H; gy++) {
        for (int gx = 0; gx < GRID_W; gx++) {
            for (int gz = 0; gz < DEPTH; gz++) {
                if (!voxel_set(gx, gy, gz)) continue;

                float x = (float)gx + ox;
                float y = -(float)gy + oy;
                float z = (float)gz + oz;

                if (!voxel_set(gx, gy, gz + 1)) push_face(self, x, y, z + 0.5f, vec3( 0,  0,  1), vec3(0.5f, 0, 0), vec3(0, 0.5f, 0));
                if (!voxel_set(gx, gy, gz - 1)) push_face(self, x, y, z - 0.5f, vec3( 0,  0, -1), vec3(0.5f, 0, 0), vec3(0, 0.5f, 0));
                if (!voxel_set(gx, gy - 1, gz)) push_face(self, x, y + 0.5f, z, vec3( 0,  1,  0), vec3(0.5f, 0, 0), vec3(0, 0, 0.5f));
                if (!voxel_set(gx, gy + 1, gz)) push_face(self, x, y - 0.5f, z, vec3( 0, -1,  0), vec3(0.5f, 0, 0), vec3(0, 0, 0.5f));
                if (!voxel_set(gx + 1, gy, gz)) push_face(self, x + 0.5f, y, z, vec3( 1,  0,  0), vec3(0, 0.5f, 0), vec3(0, 0, 0.5f));
                if (!voxel_set(gx - 1, gy, gz)) push_face(self, x - 0.5f, y, z, vec3(-1,  0,  0), vec3(0, 0.5f, 0), vec3(0, 0, 0.5f));
            }
        }
    }
}

// ─── Lifecycle ───────────────────────────────────────────────

fn tea::Cmd SuperSplashModel.init(SuperSplashModel* self) @dynamic {
    self.width = 80;
    self.height = 24;
    self.frame = 0;
    self.voxel_count = 0;
    sz total = (sz)(self.width * self.height);
    self.splash_top   = mem::new_array(Pixel, total);
    self.splash_bot   = mem::new_array(Pixel, total);
    self.cells  = mem::new_array(xray::Cell, total);
    self.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
    self.depth  = mem::new_array(float, (sz)(self.width * self.height * 2));
    self.alpha  = mem::new_array(float, (sz)(self.width * self.height * 2));
    create_voxels(self);
    return tea::tick();
}

fn tea::Cmd SuperSplashModel.update(SuperSplashModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        sz total = (sz)(self.width * self.height);
        mem::free(self.splash_top.ptr);
        mem::free(self.splash_bot.ptr);
        mem::free(self.cells.ptr);
        mem::free(self.pixels.ptr);
        mem::free(self.depth.ptr);
        mem::free(self.alpha.ptr);
        self.splash_top   = mem::new_array(Pixel, total);
        self.splash_bot   = mem::new_array(Pixel, total);
        self.cells  = mem::new_array(xray::Cell, total);
        self.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
        self.depth  = mem::new_array(float, (sz)(self.width * self.height * 2));
        self.alpha  = mem::new_array(float, (sz)(self.width * self.height * 2));
        return null;
    }
    if (msg.kind == tea::MsgKind.TICK) {
        self.frame++;
        self.rotation_x = (float)math::sin((float)self.frame * 0.003) * 0.15f;
        self.rotation_y = (float)self.frame * 0.01f;
        self.rotation_z = 0.0f;
        return tea::tick();
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    return tea::quit();
}

fn void SuperSplashModel.on_mount(SuperSplashModel* self) @dynamic {}
fn void SuperSplashModel.on_destroy(SuperSplashModel* self) @dynamic {}
fn void SuperSplashModel.on_focus(SuperSplashModel* self) @dynamic {}
fn void SuperSplashModel.on_blur(SuperSplashModel* self) @dynamic {}

// ─── View ────────────────────────────────────────────────────

fn tea::View SuperSplashModel.view(SuperSplashModel* self) @dynamic {
    int w = self.width;
    int h = self.height;
    if (w < 2) w = 80;
    if (h < 2) h = 24;
    sz total = (sz)(w * h);

    double t = (double)self.frame * 0.03;
    double angle = 0.7854 + t * 0.1;

    // ── Layer 1: render splash background ────────────────────
    xray::Style base_style = xray::default_style();
    int pixel_rows = h * 2;

    for (int y = 0; y < h; y++) {
        int fy_top = y * 2;
        int fy_bot = y * 2 + 1;
        int row_offset = y * w;

        for (int x = 0; x < w; x++) {
            double fx = (double)x / (double)w;

            double ca = c3_cos(angle);
            double sa = c3_sin(angle);

            double yt = (double)fy_top / (double)pixel_rows;
            double proj_t = (fx - 0.5) * ca + (yt - 0.5) * sa + 0.5;
            double vt = 0.6 + 0.4 * c3_sin(fx * 3.0 + t * 0.7 + yt * 2.0);
            double ht = (proj_t * 0.4 + t * 0.1) % 1.0;
            if (ht < 0) ht += 1.0;
            RgbColor top = hsv_to_rgb(ht, 0.8, vt);

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
            self.cells[row_offset + x] = c;
            self.splash_top[row_offset + x] = (Pixel){ (char)top.r, (char)top.g, (char)top.b };
            self.splash_bot[row_offset + x] = (Pixel){ (char)bot.r, (char)bot.g, (char)bot.b };
        }
    }

    // ── Layer 2: render voxel 3D on top ──────────────────────
    int ph = h * 2;
    sz ptotal = (sz)(w * ph);

    for (sz i = 0; i < ptotal; i++) {
        self.pixels[i] = (Pixel){ 0, 0, 0 };
        self.depth[i]  = 1000.0f;
        self.alpha[i]  = 0.0f;
    }

    float fov  = 30.0f;
    float dist = 20.0f;
    float cx   = (float)w / 2.0f;
    float cy   = (float)ph / 2.0f;

    float light_x =  0.4f;
    float light_y =  0.8f;
    float light_z = -0.5f;
    float light_len = (float)math::sqrt(light_x*light_x + light_y*light_y + light_z*light_z);
    light_x /= light_len;
    light_y /= light_len;
    light_z /= light_len;

    for (int v = 0; v < self.voxel_count; v++) {
        Vec3 p = self.voxels[v].pos;
        Vec3 n = self.voxels[v].normal;

        p = p.rotate_x(self.rotation_x);
        p = p.rotate_y(self.rotation_y);
        p = p.rotate_z(self.rotation_z);

        n = n.rotate_x(self.rotation_x);
        n = n.rotate_y(self.rotation_y);
        n = n.rotate_z(self.rotation_z);

        if (n.z > 0.0f) continue;

        float dz = dist + p.z;
        if (dz < 0.1f) continue;

        Vec3 tu = self.voxels[v].tan_u;
        Vec3 tv = self.voxels[v].tan_v;
        tu = tu.rotate_x(self.rotation_x); tu = tu.rotate_y(self.rotation_y); tu = tu.rotate_z(self.rotation_z);
        tv = tv.rotate_x(self.rotation_x); tv = tv.rotate_y(self.rotation_y); tv = tv.rotate_z(self.rotation_z);

        float min_sx =  1e9f;
        float max_sx = -1e9f;
        float min_sy =  1e9f;
        float max_sy = -1e9f;

        float[4] corner_sx = { 0, 0, 0, 0 };
        float[4] corner_sy = { 0, 0, 0, 0 };
        float[4] cu = { -1, -1,  1,  1 };
        float[4] cv = { -1,  1, -1,  1 };
        for (int ci = 0; ci < 4; ci++) {
            float cx3 = p.x + cu[ci] * tu.x + cv[ci] * tv.x;
            float cy3 = p.y + cu[ci] * tu.y + cv[ci] * tv.y;
            float cz3 = p.z + cu[ci] * tu.z + cv[ci] * tv.z;
            float cdz = dist + cz3;
            if (cdz < 0.1f) continue;
            float sc  = fov / cdz;
            float csx = cx3 * sc * 2.0f + cx;
            float csy = -cy3 * sc * 2.0f + cy;
            corner_sx[ci] = csx;
            corner_sy[ci] = csy;
            if (csx < min_sx) min_sx = csx;
            if (csx > max_sx) max_sx = csx;
            if (csy < min_sy) min_sy = csy;
            if (csy > max_sy) max_sy = csy;
        }

        int x0 = (int)min_sx;
        int x1 = (int)max_sx;
        int y0 = (int)min_sy;
        int y1 = (int)max_sy;

        float diff = n.x * light_x + n.y * light_y + n.z * light_z;
        if (diff < 0.0f) diff = 0.0f;
        float brightness = 0.15f + 0.85f * diff;

        char pr = (char)(brightness * 220.0f);
        char pg = (char)(brightness * 180.0f);
        char pb = (char)(brightness * 255.0f);

        for (int py = y0; py <= y1; py++) {
            if (py < 0 || py >= ph) continue;
            for (int px = x0; px <= x1; px++) {
                if (px < 0 || px >= w) continue;
                if (!point_in_quad((float)px + 0.5f, (float)py + 0.5f, corner_sx, corner_sy)) continue;
                sz idx = (sz)(py * w + px);
                if (p.z < self.depth[idx]) {
                    self.depth[idx] = p.z;
                    self.pixels[idx] = (Pixel){ pr, pg, pb };
                    self.alpha[idx] = 1.0f;
                }
            }
        }
    }

    // post-process AA on the pixel buffer
    int[4] adx = { 1, -1, 0,  0 };
    int[4] ady = { 0,  0, 1, -1 };
    for (int py = 0; py < ph; py++) {
        for (int px = 0; px < w; px++) {
            sz idx = (sz)(py * w + px);
            if (self.depth[idx] < 999.0f) continue;

            float sum_r = 0.0f;
            float sum_g = 0.0f;
            float sum_b = 0.0f;
            int count = 0;

            for (int d = 0; d < 4; d++) {
                int nx = px + adx[d];
                int ny = py + ady[d];
                if (nx < 0 || nx >= w || ny < 0 || ny >= ph) continue;
                sz nidx = (sz)(ny * w + nx);
                if (self.depth[nidx] >= 998.0f) continue;
                Pixel src = self.pixels[nidx];
                sum_r += (float)src.r;
                sum_g += (float)src.g;
                sum_b += (float)src.b;
                count++;
            }

            if (count == 0) continue;

            self.pixels[idx] = (Pixel){
                (char)(sum_r / (float)count),
                (char)(sum_g / (float)count),
                (char)(sum_b / (float)count),
            };
            self.alpha[idx] = (float)count / 4.0f;
            self.depth[idx] = 998.0f;
        }
    }

    // ── Combine: alpha-blend voxels over splash ──────────────
    // Splash is already rendered into self.cells — blend voxels on top
    for (int ty = 0; ty < h; ty++) {
        for (int tx = 0; tx < w; tx++) {
            sz top_idx = (sz)((ty * 2)     * w + tx);
            sz bot_idx = (sz)((ty * 2 + 1) * w + tx);
            float top_a = self.alpha[top_idx];
            float bot_a = self.alpha[bot_idx];

            // Fully transparent — splash shows through unchanged
            if (top_a < 0.01f && bot_a < 0.01f) continue;

            sz cidx = (sz)(ty * w + tx);
            xray::Cell cell = self.cells[cidx];

            // Only blend top half if voxel covers it
            if (top_a >= 0.01f) {
                Pixel s_top = self.splash_top[cidx];
                Pixel v_top = self.pixels[top_idx];
                char fg_r = (char)((float)v_top.r * top_a + (float)s_top.r * (1.0f - top_a));
                char fg_g = (char)((float)v_top.g * top_a + (float)s_top.g * (1.0f - top_a));
                char fg_b = (char)((float)v_top.b * top_a + (float)s_top.b * (1.0f - top_a));
                cell.style = cell.style.set_fg(xray::color_rgb(fg_r, fg_g, fg_b));
            }

            // Only blend bottom half if voxel covers it
            if (bot_a >= 0.01f) {
                Pixel s_bot = self.splash_bot[cidx];
                Pixel v_bot = self.pixels[bot_idx];
                char bg_r = (char)((float)v_bot.r * bot_a + (float)s_bot.r * (1.0f - bot_a));
                char bg_g = (char)((float)v_bot.g * bot_a + (float)s_bot.g * (1.0f - bot_a));
                char bg_b = (char)((float)v_bot.b * bot_a + (float)s_bot.b * (1.0f - bot_a));
                cell.style = cell.style.set_bg(xray::color_rgb(bg_r, bg_g, bg_b));
            }

            self.cells[cidx] = cell;
        }
    }

    return tea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

fn int main() {
    SuperSplashModel* m = mem::new(SuperSplashModel);
    if (catch err = tea::@run_program(m)) {
        io::printfn("Error: %s", err);
        return 1;
    }
    mem::free(m);
    return 0;
}
