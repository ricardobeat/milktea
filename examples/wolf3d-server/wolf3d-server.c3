module wolf3d_server;

import tea;
import xray;
import lipgloss;
import std::io;
import std::math;
import std::os;
import std::net;
import std::net::tcp;
import std::thread;

// ── Types ──────────────────────────────────────────────────────────────────

struct Pixel {
    char r, g, b;
}

const int MAP_WIDTH = 16;
const int MAP_HEIGHT = 16;

const char[MAP_WIDTH*MAP_HEIGHT] MAP = {
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,0,2,2,2,2,0,0,0,3,3,3,0,0,1,
    1,0,0,2,0,0,2,0,0,0,3,0,3,0,0,1,
    1,0,0,2,0,0,2,0,0,0,3,0,3,0,0,1,
    1,0,0,2,2,0,2,0,0,0,3,3,3,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,0,4,4,4,4,0,0,0,0,0,0,0,0,1,
    1,0,0,4,0,0,4,0,0,0,5,5,5,0,0,1,
    1,0,0,4,0,0,4,0,0,0,5,0,5,0,0,1,
    1,0,0,4,4,4,4,0,0,0,5,5,5,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1
};

struct Wolf3D {
    float pos_x, pos_y;
    float dir_x, dir_y;
    float plane_x, plane_y;
    int width, height;
    int tick_count;
    xray::Cell[] cells;
    Pixel[] pixels;
    int key_w, key_s, key_a, key_d, key_left, key_right;
}

fn tea::Cmd Wolf3D.init(Wolf3D* self) @dynamic {
    self.width = 80;
    self.height = 24;
    self.pos_x = 3.0f; self.pos_y = 3.0f;
    self.dir_x = 1.0f; self.dir_y = 0.0f;
    self.plane_x = 0.0f; self.plane_y = 0.66f;
    self.allocate_buffers();
    return tea::tick();
}

fn void Wolf3D.allocate_buffers(Wolf3D* self) {
    sz ptotal = (sz)(self.width * self.height * 2);
    self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
    self.pixels = mem::new_array(Pixel, ptotal);
}

fn tea::Cmd Wolf3D.update(Wolf3D* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        if (self.width == msg.window_size.width && self.height == msg.window_size.height) return null;
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        mem::free(self.cells.ptr);
        mem::free(self.pixels.ptr);
        self.allocate_buffers();
        return null;
    }
    if (msg.kind == tea::MsgKind.KEY) {
        tea::KeyMsg k = msg.key;
        if (k.code == tea::KeyCode.RUNE) {
            switch (k.rune) {
                case 'w': self.key_w = self.tick_count;
                case 's': self.key_s = self.tick_count;
                case 'a': self.key_left = self.tick_count;
                case 'd': self.key_right = self.tick_count;
            }
        }
        if (k.code == tea::KeyCode.LEFT)  self.key_left  = self.tick_count;
        if (k.code == tea::KeyCode.RIGHT) self.key_right = self.tick_count;
    }
    if (msg.kind == tea::MsgKind.TICK) {
        self.tick_count++;
        float move_speed = 0.25f;
        float rot_speed = 0.12f;
        int thresh = self.tick_count - 5;
        if (self.key_w >= thresh) {
            if (MAP[(int)(self.pos_x + self.dir_x * move_speed) + (int)(self.pos_y) * MAP_WIDTH] == 0) self.pos_x += self.dir_x * move_speed;
            if (MAP[(int)(self.pos_x) + (int)(self.pos_y + self.dir_y * move_speed) * MAP_WIDTH] == 0) self.pos_y += self.dir_y * move_speed;
            self.key_w = 0;
        }
        if (self.key_s >= thresh) {
            if (MAP[(int)(self.pos_x - self.dir_x * move_speed) + (int)(self.pos_y) * MAP_WIDTH] == 0) self.pos_x -= self.dir_x * move_speed;
            if (MAP[(int)(self.pos_x) + (int)(self.pos_y - self.dir_y * move_speed) * MAP_WIDTH] == 0) self.pos_y -= self.dir_y * move_speed;
            self.key_s = 0;
        }
        if (self.key_right >= thresh) {
            float old_dir_x = self.dir_x;
            self.dir_x = self.dir_x * (float)math::cos(rot_speed) - self.dir_y * (float)math::sin(rot_speed);
            self.dir_y = old_dir_x * (float)math::sin(rot_speed) + self.dir_y * (float)math::cos(rot_speed);
            float old_plane_x = self.plane_x;
            self.plane_x = self.plane_x * (float)math::cos(rot_speed) - self.plane_y * (float)math::sin(rot_speed);
            self.plane_y = old_plane_x * (float)math::sin(rot_speed) + self.plane_y * (float)math::cos(rot_speed);
            self.key_right = 0;
        }
        if (self.key_left >= thresh) {
            float old_dir_x = self.dir_x;
            self.dir_x = self.dir_x * (float)math::cos(-rot_speed) - self.dir_y * (float)math::sin(-rot_speed);
            self.dir_y = old_dir_x * (float)math::sin(-rot_speed) + self.dir_y * (float)math::cos(-rot_speed);
            float old_plane_x = self.plane_x;
            self.plane_x = self.plane_x * (float)math::cos(-rot_speed) - self.plane_y * (float)math::sin(-rot_speed);
            self.plane_y = old_plane_x * (float)math::sin(-rot_speed) + self.plane_y * (float)math::cos(-rot_speed);
            self.key_left = 0;
        }
        return tea::tick();
    }
    return null;
}

fn tea::View Wolf3D.view(Wolf3D* self) @dynamic {
    int w = self.width;
    int h = self.height;
    int ph = h * 2;
    for (int x = 0; x < w; x++) {
        for (int sub = 0; sub < 2; sub++) {
            float camera_x = 2.0f * ((float)x + (sub == 0 ? 0.25f : 0.75f)) / (float)w - 1.0f;
            float ray_dir_x = self.dir_x + self.plane_x * camera_x;
            float ray_dir_y = self.dir_y + self.plane_y * camera_x;
            int map_x = (int)self.pos_x;
            int map_y = (int)self.pos_y;
            float delta_dist_x = (float)math::abs(1.0f / ray_dir_x);
            float delta_dist_y = (float)math::abs(1.0f / ray_dir_y);
            float side_dist_x, side_dist_y;
            int step_x, step_y;
            int hit = 0;
            int side;
            if (ray_dir_x < 0) { step_x = -1; side_dist_x = (self.pos_x - (float)map_x) * delta_dist_x; }
            else { step_x = 1; side_dist_x = ((float)map_x + 1.0f - self.pos_x) * delta_dist_x; }
            if (ray_dir_y < 0) { step_y = -1; side_dist_y = (self.pos_y - (float)map_y) * delta_dist_y; }
            else { step_y = 1; side_dist_y = ((float)map_y + 1.0f - self.pos_y) * delta_dist_y; }
            while (hit == 0) {
                if (side_dist_x < side_dist_y) { side_dist_x += delta_dist_x; map_x += step_x; side = 0; }
                else { side_dist_y += delta_dist_y; map_y += step_y; side = 1; }
                if (MAP[map_x + map_y * MAP_WIDTH] > 0) hit = 1;
            }
            float perp_wall_dist = (side == 0) ? (side_dist_x - delta_dist_x) : (side_dist_y - delta_dist_y);
            int line_height = (int)((float)ph / perp_wall_dist);
            int draw_start = -line_height / 2 + ph / 2;
            if (draw_start < 0) draw_start = 0;
            int draw_end = line_height / 2 + ph / 2;
            if (draw_end >= ph) draw_end = ph - 1;
            Pixel color;
            switch (MAP[map_x + map_y * MAP_WIDTH]) {
                case 1: color = (Pixel){ 255, 0, 0 };
                case 2: color = (Pixel){ 0, 255, 0 };
                case 3: color = (Pixel){ 0, 0, 255 };
                case 4: color = (Pixel){ 255, 255, 0 };
                default: color = (Pixel){ 255, 255, 255 };
            }
            if (side == 1) { color.r /= 2; color.g /= 2; color.b /= 2; }
            for (int y = 0; y < ph; y++) {
                sz idx = (sz)(y * w + x);
                Pixel sample_col;
                if (y < draw_start) { sample_col = { 40, 40, 40 }; }
                else if (y < draw_end) { sample_col = color; }
                else { sample_col = { 80, 80, 80 }; }
                if (sub == 0) { self.pixels[idx] = sample_col; }
                else {
                    self.pixels[idx].r = (char)(((int)self.pixels[idx].r + (int)sample_col.r) / 2);
                    self.pixels[idx].g = (char)(((int)self.pixels[idx].g + (int)sample_col.g) / 2);
                    self.pixels[idx].b = (char)(((int)self.pixels[idx].b + (int)sample_col.b) / 2);
                }
            }
        }
    }
    for (int ty = 0; ty < h; ty++) {
        for (int tx = 0; tx < w; tx++) {
            sz top_idx = (sz)((ty * 2) * w + tx);
            sz bot_idx = (sz)((ty * 2 + 1) * w + tx);
            Pixel top = self.pixels[top_idx];
            Pixel bot = self.pixels[bot_idx];
            xray::Style style = xray::default_style()
                .set_fg(xray::color_rgb(top.r, top.g, top.b))
                .set_bg(xray::color_rgb(bot.r, bot.g, bot.b));
            self.cells[ty * w + tx] = xray::new_cell("\xe2\x96\x80", 1, style);
        }
    }
    return tea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

// ── Server Implementation ──────────────────────────────────────────────────

struct Client {
    TcpSocket socket;
}

fn void write_socket(TcpSocket* s, char[] data) {
    (void)s.write(data);
}

fn sz byte_to_str(char b, char* buf) {
    if (b >= 100) {
        buf[0] = (char)('0' + b / 100);
        buf[1] = (char)('0' + (b / 10) % 10);
        buf[2] = (char)('0' + b % 10);
        return 3;
    } else if (b >= 10) {
        buf[0] = (char)('0' + b / 10);
        buf[1] = (char)('0' + b % 10);
        return 2;
    }
    buf[0] = (char)('0' + b);
    return 1;
}

fn void write_sgr(TcpSocket* s, xray::Color fg, xray::Color bg) {
    char[48] buf;
    sz pos = 0;
    buf[pos++] = '\x1b'; buf[pos++] = '['; buf[pos++] = '0'; buf[pos++] = 'm';
    if (fg.kind == xray::ColorKind.TRUECOLOR) {
        buf[pos++] = '\x1b'; buf[pos++] = '['; buf[pos++] = '3'; buf[pos++] = '8'; buf[pos++] = ';'; buf[pos++] = '2'; buf[pos++] = ';';
        pos += byte_to_str(fg.r, &buf[pos]); buf[pos++] = ';';
        pos += byte_to_str(fg.g, &buf[pos]); buf[pos++] = ';';
        pos += byte_to_str(fg.b, &buf[pos]); buf[pos++] = 'm';
    }
    if (bg.kind == xray::ColorKind.TRUECOLOR) {
        buf[pos++] = '\x1b'; buf[pos++] = '['; buf[pos++] = '4'; buf[pos++] = '8'; buf[pos++] = ';'; buf[pos++] = '2'; buf[pos++] = ';';
        pos += byte_to_str(bg.r, &buf[pos]); buf[pos++] = ';';
        pos += byte_to_str(bg.g, &buf[pos]); buf[pos++] = ';';
        pos += byte_to_str(bg.b, &buf[pos]); buf[pos++] = 'm';
    }
    write_socket(s, buf[:pos]);
}

fn void render_cells_to(xray::Cell[] cells, sz width, sz height, TcpSocket* s) {
    write_socket(s, (char[])"\x1b[H");
    xray::Style pen = xray::default_style();
    for (sz y = 0; y < height; y++) {
        for (sz x = 0; x < width; x++) {
            xray::Cell cell = cells[y * width + x];
            if (!cell.style.eq(pen)) {
                write_sgr(s, cell.style.fg, cell.style.bg);
                pen = cell.style;
            }
            write_socket(s, (char[])cell.content_str());
        }
        if (y < height - 1) {
            write_socket(s, (char[])"\x1b[K\r\n");
        } else {
            write_socket(s, (char[])"\x1b[K");
        }
    }
    write_socket(s, (char[])"\x1b[0m");
}

fn int handle_client(void* arg) {
    Client* c = (Client*)arg;
    TcpSocket s = c.socket;
    Wolf3D* app = mem::new(Wolf3D);
    app.init();
    write_socket(&s, (char[])"\x1b[?1049h\x1b[?25l");
    tea::View v = app.view();
    render_cells_to(v.cells, v.cells_width, v.cells_height, &s);
    char[1024] buf;
    while (true) {
        sz? read_result = s.read(buf[..]);
        if (catch err = read_result) {
            break;
        }
        sz n = read_result;
        if (n > 0) {
            tea::ParseResult pr = tea::parse_key(buf[:n]);
            if (pr.consumed > 0) {
                if (pr.key.code == tea::KeyCode.ESC || (pr.key.code == tea::KeyCode.RUNE && pr.key.rune == 'q')) { break; }
                app.update({ .kind = tea::MsgKind.KEY, .key = pr.key });
            }
        }
        app.update(tea::tick_msg());
        v = app.view();
        render_cells_to(v.cells, v.cells_width, v.cells_height, &s);
        thread::sleep_ms(16);
    }
    write_socket(&s, (char[])"\x1b[?1049l\x1b[?25h");
    (void)s.close();
    mem::free(app);
    mem::free(c);
    return 0;
}

fn int main(String[] args) {
    TcpServerSocket server = tcp::listen("0.0.0.0", 8080, 10) !!;
    io::printfn("Wolf3D Server listening on :8080");
    while (true) {
        if (try client = tcp::accept(&server)) {
            Client* c = mem::new(Client);
            c.socket = client;
            thread::Thread t;
            thread::Thread.create(&t, &handle_client, c)!!;
            t.detach();
        }
    }
}
