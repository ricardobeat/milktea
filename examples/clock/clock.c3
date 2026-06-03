module clock;

import milktea;
import xray;
import std::io;

extern fn long c3_time_ms_long();

const String BLK   = "\xe2\x96\x88";
const String HBLK  = "\xe2\x96\x80";
const String LHB   = "\xe2\x96\x84";
const String LSH   = "\xe2\x96\x91";
const String STAR  = "\xc2\xb7";
const String STAR2 = "\xe2\x98\x86";

const int GLYPH_ROWS = 7;

const String[GLYPH_ROWS] DIGIT_1 = {
	"   ░██",
	" ░████",
	"   ░██",
	"   ░██",
	"   ░██",
	"   ░██",
	" ░██████",
};

const String[GLYPH_ROWS] DIGIT_2 = {
	" ░██████",
	"░██   ░██",
	"      ░██",
	"  ░█████",
	" ░██",
	"░██",
	"░████████",
};

const String[GLYPH_ROWS] DIGIT_3 = {
	" ░██████",
	"░██   ░██",
	"      ░██",
	"  ░█████",
	"      ░██",
	"░██   ░██",
	" ░██████",
};

const String[GLYPH_ROWS] DIGIT_4 = {
	"   ░████",
	"  ░██ ██",
	" ░██  ██",
	"░██   ██",
	"░█████████",
	"     ░██",
	"     ░██",
};

const String[GLYPH_ROWS] DIGIT_5 = {
	"░████████",
	"░██",
	"░███████",
	"      ░██",
	"░██   ░██",
	"░██   ░██",
	" ░██████",
};

const String[GLYPH_ROWS] DIGIT_6 = {
	" ░██████",
	"░██   ░██",
	"░██",
	"░███████",
	"░██   ░██",
	"░██   ░██",
	" ░██████",
};

const String[GLYPH_ROWS] DIGIT_7 = {
	"░█████████",
	"░██    ░██",
	"      ░██",
	"     ░██",
	"    ░██",
	"    ░██",
	"    ░██",
};

const String[GLYPH_ROWS] DIGIT_8 = {
	" ░██████",
	"░██   ░██",
	"░██   ░██",
	" ░██████",
	"░██   ░██",
	"░██   ░██",
	" ░██████",
};

const String[GLYPH_ROWS] DIGIT_9 = {
	" ░██████",
	"░██   ░██",
	"░██   ░██",
	" ░███████",
	"      ░██",
	"░██   ░██",
	" ░██████",
};

const String[GLYPH_ROWS] DIGIT_0 = {
	"  ░████",
	" ░██ ░██",
	"░██ ░████",
	"░██░██░██",
	"░████ ░██",
	" ░██ ░██",
	"  ░████",
};

const String[GLYPH_ROWS] COLON = { "", "", "", "░██", "", "", "░██", };

struct Cloud {
	int x;
	int y;
	int w;
	int speed;
	int phase;
}

struct ClockModel {
	xray::ScreenBuffer* canvas;
	int w;
	int h;
	long frame;
	Cloud[3] clouds;
}

fn String[GLYPH_ROWS] glyph(char c) {
	if (c >= '0' && c <= '9') {
		int idx = (int)c - (int)'0';
		switch (idx) {
			case 0: return DIGIT_0;
			case 1: return DIGIT_1;
			case 2: return DIGIT_2;
			case 3: return DIGIT_3;
			case 4: return DIGIT_4;
			case 5: return DIGIT_5;
			case 6: return DIGIT_6;
			case 7: return DIGIT_7;
			case 8: return DIGIT_8;
			case 9: return DIGIT_9;
			default:
		}
	}
	if (c == ':') return COLON;
	String[GLYPH_ROWS] empty;
	return empty;
}

fn void draw_glyph(
	xray::ScreenBuffer* sb,
	char ch,
	int dx,
	int dy,
	xray::Color fg_color,
	xray::Color shadow_color
) @local {
	String[GLYPH_ROWS] rows = glyph(ch);
	for (int row = 0; row < GLYPH_ROWS; row++) {
		String r = rows[row];
		int abs_y = dy + row;
		if (abs_y < 0 || (sz)abs_y >= sb.height) continue;
		int col = 0;
		sz i = 0;
		while (i < r.len) {
			if (r[i] == ' ') {
				i++;
				col++;
				continue;
			}
			if (r[i] == '\xe2' && i + 2 < r.len) {
				xray::Color fc = fg_color;
				if (r[i + 1] == '\x96' && r[i + 2] == '\x91') fc = shadow_color;
				int abs_x = dx + col;
				if (abs_x >= 0 && (sz)abs_x < sb.width) {
					xray::Style s = xray::default_style().set_fg(fc);
					sb.set_cell((sz)abs_x, (sz)abs_y, xray::new_cell(BLK, 1, s));
				}
				col++;
				i += 3;
				continue;
			}
			i++;
		}
	}
}

fn void draw_cloud(
	xray::ScreenBuffer* sb,
	Cloud* c
) @local {
	xray::Color c_white = xray::color_rgb(255, 255, 255);
	xray::Color c_light = xray::color_rgb(210, 218, 240);
	xray::Color c_mid   = xray::color_rgb(160, 172, 210);

	int n_bumps = 5;
	int[5] bro = {
		c.w / 5 + (c.phase % 2),
		c.w / 4 + ((c.phase * 3) % 2),
		c.w / 5 + ((c.phase * 5) % 2),
		c.w / 4 + ((c.phase * 7) % 2),
		c.w / 5 + ((c.phase * 11) % 2),
	};
	int[5] bxo = {
		-(c.w / 2 - bro[0] * 2) + (c.phase * 2) % 3,
		-(c.w / 6) + (c.phase * 3) % 4,
		0 + (c.phase * 5) % 3,
		c.w / 6 + (c.phase * 7) % 3,
		c.w / 2 - bro[4] * 2 + (c.phase * 11) % 3,
	};
	int[5] byo = {
		-(c.w * 3 / 20) - (c.phase % 2),
		-(c.w / 5) - ((c.phase * 3) % 2),
		-(c.w / 4) - ((c.phase * 5) % 2),
		-(c.w / 5) - ((c.phase * 7) % 2),
		-(c.w * 3 / 20) - ((c.phase * 11) % 2),
	};

	int cx = c.x;
	int cy = c.y;
	int sp_y = cy * 2;
	int span_x0 = cx - c.w / 2;
	int span_x1 = cx + c.w / 2;

	// Find vertical sub-pixel extent across all bumps
	int min_sy = sp_y + byo[0] - bro[0];
	int max_sy = sp_y + byo[0] + bro[0];
	for (int b = 1; b < n_bumps; b++) {
		int lo = sp_y + byo[b] - bro[b];
		int hi = sp_y + byo[b] + bro[b];
		if (lo < min_sy) min_sy = lo;
		if (hi > max_sy) max_sy = hi;
	}

	// Process pairs of sub-pixel rows → one terminal cell via half-blocks
	for (int sy = min_sy; sy <= max_sy; sy += 2) {
		int screen_row = sy / 2;
		if (screen_row < 0 || (sz)screen_row >= sb.height) continue;

		for (int x = span_x0; x <= span_x1; x++) {
			if (x < 0 || (sz)x >= sb.width) continue;

			// Check circle membership for top (sy) and bot (sy+1) sub-rows
			bool top_in = false;
			bool bot_in = false;
			bool prev_in = false;
			bool next_in = false;

			for (int b = 0; b < n_bumps; b++) {
				int dx = x - (cx + bxo[b]);
				int dx2 = dx * dx;
				int r2 = bro[b] * bro[b];
				int base = sp_y + byo[b];
				int d_prev = (sy - 1) - base;
				int d_top  = sy - base;
				int d_bot  = (sy + 1) - base;
				int d_next = (sy + 2) - base;
				if (dx2 + d_prev * d_prev <= r2) prev_in = true;
				if (dx2 + d_top * d_top <= r2) top_in = true;
				if (dx2 + d_bot * d_bot <= r2) bot_in = true;
				if (dx2 + d_next * d_next <= r2) next_in = true;
				if (top_in && bot_in && prev_in && next_in) break;
			}

			if (!top_in && !bot_in) continue;

			bool top_edge = top_in && !prev_in;
			bool bot_edge = bot_in && !next_in;

			xray::Color tc;
			if (top_in) {
				tc = top_edge ? c_white : c_light;
			}
			xray::Color bc;
			if (bot_in) {
				bc = bot_edge ? c_mid : c_light;
			}

			if (top_in && bot_in) {
				if (tc.r == bc.r && tc.g == bc.g && tc.b == bc.b) {
					xray::Style s = xray::default_style().set_fg(tc);
					sb.set_cell((sz)x, (sz)screen_row, xray::new_cell(BLK, 1, s));
				} else {
					xray::Style s = xray::default_style().set_fg(tc).set_bg(bc);
					sb.set_cell((sz)x, (sz)screen_row, xray::new_cell(HBLK, 1, s));
				}
			} else if (top_in) {
				xray::Style s = xray::default_style().set_fg(tc).set_bg(xray::color_transparent());
				sb.set_cell((sz)x, (sz)screen_row, xray::new_cell(HBLK, 1, s));
			} else {
				xray::Style s = xray::default_style().set_fg(bc).set_bg(xray::color_transparent());
				sb.set_cell((sz)x, (sz)screen_row, xray::new_cell(LHB, 1, s));
			}
		}
	}
}

fn milktea::Cmd ClockModel.init(ClockModel* self) @dynamic {
	self.clouds[0] = { .x = 10, .y = 5, .w = 22, .speed = 2, .phase = 3 };
	self.clouds[1] = { .x = 50, .y = 2, .w = 28, .speed = 4, .phase = 11 };
	self.clouds[2] = { .x = 30, .y = 8, .w = 18, .speed = 1, .phase = 23 };
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
					long fi = (long)self.frame;
					c.x = self.w + c.w + (int)(fi * (long)(i + 7) % 20);
					c.y = 2 + (int)((fi * (long)(i + 1) + (long)(i * 17)) % (long)(self.h - 12));
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

	xray::Style star_s = xray::default_style().set_fg(xray::color_rgb(255, 255, 200)).set_bg(xray::color_transparent());
	xray::Style star_dim = xray::default_style().set_fg(xray::color_rgb(180, 180, 220))
		.set_bg(xray::color_transparent());
	xray::Style star_bright = xray::default_style().set_fg(xray::color_rgb(255, 255, 255))
		.set_bg(xray::color_transparent());

	for (int row = 1; row < self.h; row++) {
		for (int col = 0; col < self.w; col++) {
			uint h  = (uint)(col * 1103515245 + row * 12345);
			int mod = (int)(h % 97);
			if (mod == 0) {
				if ((self.frame / 8 + (int)(h >> 8)) % 7 == 0) {
					sb.set_cell((sz)col, (sz)row, xray::new_cell(STAR2, 1, star_bright));
				} else {
					sb.set_cell((sz)col, (sz)row, xray::new_cell(STAR, 1, star_s));
				}
			} else if (mod == 3 || mod == 17) {
				sb.set_cell((sz)col, (sz)row, xray::new_cell(STAR, 1, star_dim));
			}
		}
	}

	long now  = c3_time_ms_long();
	long secs = now / 1000;
	int h     = ((int)(secs / 3600)) % 24;
	int m     = ((int)(secs / 60)) % 60;
	int s     = (int)(secs % 60);

	char h0_c = (char)('0' + h / 10);
	char h1_c = (char)('0' + h % 10);
	char m0_c = (char)('0' + m / 10);
	char m1_c = (char)('0' + m % 10);
	char s0_c = (char)('0' + s / 10);
	char s1_c = (char)('0' + s % 10);

	int digit_w   = 10;
	int colon_w   = 4;
	int colon_gap = 1;
	int pair_gap  = 2;
	int total_w   = digit_w * 2 + colon_w + colon_gap * 2 + digit_w * 2 + colon_w + colon_gap * 2 + digit_w * 2;
	total_w += pair_gap * 2;

	int time_x = (self.w - total_w) / 2;
	int time_y = (self.h - GLYPH_ROWS) / 2 - 1;

	xray::Color fg_color     = xray::color_rgb(255, 255, 255);
	xray::Color shadow_color = xray::color_rgb(255, 90, 180);
	xray::Color colon_color  = xray::color_rgb(255, 200, 100);

	draw_glyph(sb, h0_c, time_x, time_y, fg_color, shadow_color);
	draw_glyph(sb, h1_c, time_x + digit_w, time_y, fg_color, shadow_color);
	draw_glyph(sb, ':', time_x + digit_w * 2 + colon_gap, time_y, colon_color, shadow_color);
	draw_glyph(sb, m0_c, time_x + digit_w * 2 + colon_w + colon_gap, time_y, fg_color, shadow_color);
	draw_glyph(sb, m1_c, time_x + digit_w * 3 + colon_w + colon_gap, time_y, fg_color, shadow_color);
	draw_glyph(sb, ':', time_x + digit_w * 4 + colon_w + colon_gap + pair_gap, time_y, colon_color, shadow_color);
	draw_glyph(sb, s0_c, time_x + digit_w * 4 + colon_w * 2 + colon_gap + pair_gap, time_y, fg_color, shadow_color);
	draw_glyph(sb, s1_c, time_x + digit_w * 5 + colon_w * 2 + colon_gap + pair_gap, time_y, fg_color, shadow_color);

	for (int i = 0; i < 3; i++) {
		draw_cloud(sb, &self.clouds[i]);
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
