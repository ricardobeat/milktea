module clock;

import milktea;
import xray;
import std::io;
import std::core::string;

extern fn long c3_time_ms_long();

const String BLK  = "\xe2\x96\x88"; // █
const String HBLK = "\xe2\x96\x80"; // ▀
const String LHB  = "\xe2\x96\x84"; // ▄
const String STAR = "\xc2\xb7"; // ·

const int DW = 5;
const int DH = 5;

struct Cloud {
	int x;
	int y;
	int w;
	int speed;
}

struct ClockModel {
	xray::ScreenBuffer* canvas;
	int w;
	int h;
	long frame;
	Cloud[3] clouds;
}

fn void draw_digit(int d, int dx, int dy, xray::ScreenBuffer* sb, xray::Style s) @local {
	for (int row = 0; row < DH; row++) {
		int mask = digit(d, row);
		for (int col = 0; col < DW; col++) {
			if (mask & (1 << (DW - 1 - col))) {
				sb.set_cell((sz)(dx + col), (sz)(dy + row), xray::new_cell(BLK, 1, s));
			}
		}
	}
}

fn void draw_colon(int cx, int cy, xray::ScreenBuffer* sb, xray::Style s) @local {
	sb.set_cell((sz)cx, (sz)(cy + 1), xray::new_cell(BLK, 1, s));
	sb.set_cell((sz)(cx + 1), (sz)(cy + 1), xray::new_cell(BLK, 1, s));
	sb.set_cell((sz)cx, (sz)(cy + 3), xray::new_cell(BLK, 1, s));
	sb.set_cell((sz)(cx + 1), (sz)(cy + 3), xray::new_cell(BLK, 1, s));
}

fn bool is_star(int col, int row, long frame) @local {
	uint h = (uint)(col * 1103515245 + row * 12345 + (int)(frame / 20));
	return h % 71 == 0;
}

fn void draw_cloud(xray::ScreenBuffer* sb, Cloud* c, xray::Style top_s, xray::Style mid_s, xray::Style bot_s) @local {
	int cx = c.x;
	int cy = c.y;
	int tw = c.w * 3 / 5;
	for (int i = 0; i < tw; i++) {
		int px = cx - tw / 2 + i;
		if (px >= 0 && (sz)px < sb.width && cy >= 0 && (sz)cy < sb.height) {
			sb.set_cell((sz)px, (sz)cy, xray::new_cell(HBLK, 1, top_s));
		}
	}
	for (int i = 0; i < c.w; i++) {
		int px = cx - c.w / 2 + i;
		if (px >= 0 && (sz)px < sb.width && cy + 1 >= 0 && (sz)(cy + 1) < sb.height) {
			sb.set_cell((sz)px, (sz)(cy + 1), xray::new_cell(BLK, 1, mid_s));
		}
	}
	int bw = c.w * 4 / 5;
	for (int i = 0; i < bw; i++) {
		int px = cx - bw / 2 + i;
		if (px >= 0 && (sz)px < sb.width && cy + 2 >= 0 && (sz)(cy + 2) < sb.height) {
			sb.set_cell((sz)px, (sz)(cy + 2), xray::new_cell(LHB, 1, bot_s));
		}
	}
}

fn milktea::Cmd ClockModel.init(ClockModel* self) @dynamic {
	self.clouds[0] = { .x = 10, .y = 5, .w = 16, .speed = 2 };
	self.clouds[1] = { .x = 50, .y = 2, .w = 22, .speed = 4 };
	self.clouds[2] = { .x = 30, .y = 8, .w = 12, .speed = 1 };
	self.frame = 0;
	return milktea::tick(50);
}

fn milktea::Cmd ClockModel.update(ClockModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.w = msg.window_size.width;
		self.h = msg.window_size.height;
		if (self.canvas != null) self.canvas.destroy();
		self.canvas = xray::new_screen_buffer((sz)self.w, (sz)self.h);
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.frame++;
		for (int i = 0; i < 3; i++) {
			Cloud* c = &self.clouds[i];
			if (self.frame % c.speed == 0) {
				c.x--;
				if (c.x + c.w < 0) {
					long mod_y = (long)(self.h - 12);
					long fi    = (long)self.frame;
					c.x = self.w + c.w + (int)(fi * (long)(i + 7) % 20);
					c.y = 2 + (int)((fi * (long)(i + 1) + (long)(i * 17)) % mod_y);
					if (c.y < 2) c.y = 2;
				}
			}
		}
		return milktea::tick(50);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C: return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q' || k.rune == 'Q') return milktea::quit();
		case milktea::KeyCode.ESC: return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View ClockModel.view(ClockModel* self) @dynamic {
	xray::ScreenBuffer* sb = self.canvas;
	sb.clear();

	xray::Rect full = xray::new_rect(0, 0, self.w, self.h);
	sb.fill_gradient_v(full, xray::color_rgb(8, 8, 36), xray::color_rgb(28, 18, 62));

	xray::Style star_s = xray::default_style().set_fg(xray::color_rgb(255, 255, 180));
	int sky_end = self.h / 2;
	for (int row = 1; row < sky_end; row++) {
		for (int col = 0; col < self.w; col++) {
			if (is_star(col, row, self.frame)) {
				sb.set_cell((sz)col, (sz)row, xray::new_cell(STAR, 1, star_s));
			}
		}
	}

	long now  = c3_time_ms_long();
	long secs = now / 1000;
	int h     = ((int)(secs / 3600)) % 24;
	int m     = ((int)(secs / 60)) % 60;
	int s     = (int)(secs % 60);

	int h0 = h / 10; int h1 = h % 10;
	int m0 = m / 10; int m1 = m % 10;
	int s0 = s / 10; int s1 = s % 10;

	int time_w = 42;
	int time_x = (self.w - time_w) / 2;
	int time_y = (self.h - DH) / 2 - 2;

	xray::Style digit_s = xray::default_style().set_fg(xray::color_rgb(255, 255, 255));
	xray::Style colon_s = xray::default_style().set_fg(xray::color_rgb(255, 80, 180));

	draw_digit(h0, time_x, time_y, sb, digit_s);
	draw_digit(h1, time_x + 6, time_y, sb, digit_s);
	draw_colon(time_x + 12, time_y, sb, colon_s);
	draw_digit(m0, time_x + 15, time_y, sb, digit_s);
	draw_digit(m1, time_x + 21, time_y, sb, digit_s);
	draw_colon(time_x + 27, time_y, sb, colon_s);
	draw_digit(s0, time_x + 30, time_y, sb, digit_s);
	draw_digit(s1, time_x + 36, time_y, sb, digit_s);

	xray::Style cloud_top = xray::default_style().set_fg(xray::color_rgb(200, 210, 255));
	xray::Style cloud_mid = xray::default_style().set_fg(xray::color_rgb(170, 185, 240));
	xray::Style cloud_bot = xray::default_style().set_fg(xray::color_rgb(130, 145, 210));

	for (int i = 0; i < 3; i++) {
		draw_cloud(sb, &self.clouds[i], cloud_top, cloud_mid, cloud_bot);
	}

	return milktea::new_alt_cell_view(sb.cells[0:(sz)(self.w * self.h)], (sz)self.w, (sz)self.h);
}

fn int main() {
	ClockModel m = { };
	m.w = 80;
	m.h = 24;
	m.canvas = xray::new_screen_buffer(80, 24);
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Goodbye!");
	return 0;
}