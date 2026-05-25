module doom_fire;

import milktea;
import xray;
import std::io;
import std::core::string;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

const int MAX_W = 400;
const int MAX_H = 400;

// Canonical DOOM fire palette: 37 RGB colors (from DoomFirePSX)
// Index 0 = coldest (near-black), index 36 = hottest (white)
struct FireColor {
	char r;
	char g;
	char b;
}
FireColor[37] fire_palette = {
	{ 7, 7, 7 }, // 0: near-black
	{ 31, 7, 7 }, // 1: very dark red
	{ 47, 15, 7 }, // 2: dark red
	{ 71, 15, 7 }, // 3: dark red
	{ 87, 23, 7 }, // 4: dark red-orange
	{ 103, 31, 7 }, // 5: dark red-orange
	{ 119, 31, 7 }, // 6: red-orange
	{ 143, 39, 7 }, // 7: red-orange
	{ 159, 47, 7 }, // 8: orange-red
	{ 175, 63, 7 }, // 9: orange-red
	{ 191, 71, 7 }, // 10: orange
	{ 199, 71, 7 }, // 11: orange
	{ 223, 79, 7 }, // 12: bright orange
	{ 223, 87, 7 }, // 13: bright orange
	{ 223, 87, 7 }, // 14: bright orange
	{ 215, 95, 7 }, // 15: orange-yellow
	{ 215, 95, 7 }, // 16: orange-yellow
	{ 215, 103, 15 }, // 17: yellow-orange
	{ 207, 111, 15 }, // 18: yellow-orange
	{ 207, 119, 15 }, // 19: yellow-orange
	{ 207, 127, 15 }, // 20: yellow
	{ 207, 135, 23 }, // 21: yellow
	{ 199, 135, 23 }, // 22: yellow
	{ 199, 143, 23 }, // 23: golden yellow
	{ 199, 151, 31 }, // 24: golden yellow
	{ 191, 159, 31 }, // 25: golden yellow
	{ 191, 159, 31 }, // 26: golden yellow
	{ 191, 167, 39 }, // 27: light golden
	{ 191, 167, 39 }, // 28: light golden
	{ 191, 175, 47 }, // 29: light golden
	{ 183, 175, 47 }, // 30: light golden
	{ 183, 183, 47 }, // 31: light yellow
	{ 183, 183, 55 }, // 32: light yellow
	{ 207, 207, 111 }, // 33: pale yellow
	{ 223, 223, 159 }, // 34: very pale yellow
	{ 239, 239, 199 }, // 35: near-white
	{ 255, 255, 255 }, // 36: white (hottest)
	};

// Pre-built ▀ cell for each palette index — avoids per-frame cell construction.
// Each entry: content = "▀" (U+2580), style.fg = palette color (for top pixel).
xray::Cell[37] fire_cells;

// ============================================================
// TEA watermark — DOS Rebel font, gray top / red→amber bottom
// ============================================================

const int MASK_W = 37;
const int MASK_H = 8;

// Encoded mask: 0=empty, 1=█ full block (U+2588), 2=░ light shade (U+2591)
char[MASK_W][MASK_H] tea_mask_data = {
	{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
	{ 2, 1, 2, 2, 2, 1, 1, 1, 2, 2, 2, 1, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 1, 0, 0, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 1, 0 },
	{ 2, 0, 0, 0, 2, 1, 1, 1, 0, 0, 2, 0, 0, 2, 1, 1, 1, 0, 0, 1, 0, 2, 0, 0, 2, 1, 1, 1, 0, 0, 0, 0, 2, 1, 1, 1, 0 },
	{ 0, 0, 0, 0, 2, 1, 1, 1, 0, 0, 0, 0, 0, 2, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0 },
	{ 0, 0, 0, 0, 2, 1, 1, 1, 0, 0, 0, 0, 0, 2, 1, 1, 1, 2, 2, 1, 0, 0, 0, 0, 2, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 1, 0 },
	{ 0, 0, 0, 0, 2, 1, 1, 1, 0, 0, 0, 0, 0, 2, 1, 1, 1, 0, 2, 0, 0, 0, 1, 0, 2, 1, 1, 1, 0, 0, 0, 0, 2, 1, 1, 1, 0 },
	{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1 },
	{ 0, 0, 0, 2, 2, 2, 2, 2, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 2, 0, 0, 0, 2, 2, 2, 2, 2, 0 },
};

// Pre-built cells for each mask position
xray::Cell[MASK_H * MASK_W] tea_mask_cells;

const int FIRE_MAX = 37;

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
	for (int i = 0; i < FIRE_MAX; i++) {
		FireColor c   = fire_palette[i];
		xray::Style s = xray::default_style().set_fg(xray::color_rgb(c.r, c.g, c.b));
		fire_cells[i] = xray::new_cell("\xe2\x96\x80", 1, s);
	}
}

fn void init_tea_mask() {
	// Gray upper half, red-to-amber gradient lower half
	xray::Color[8] fg = {
		xray::color_rgb(160, 160, 160),
		xray::color_rgb(160, 160, 160),
		xray::color_rgb(160, 160, 160),
		xray::color_rgb(160, 160, 160),
		xray::color_rgb(200, 30, 0),
		xray::color_rgb(220, 90, 0),
		xray::color_rgb(240, 150, 0),
		xray::color_rgb(255, 200, 0),
	};
	xray::Color bg = xray::color_rgb(0, 0, 0);

	for (int row = 0; row < MASK_H; row++) {
		for (int col = 0; col < MASK_W; col++) {
			int idx  = row * MASK_W + col;
			char val = tea_mask_data[row][col];
			if (val == 0) {
				tea_mask_cells[idx] = xray::empty_cell();
			} else {
				xray::Style s = xray::default_style().set_fg(fg[row]).set_bg(bg);
				if (val == 1) {
					tea_mask_cells[idx] = xray::new_cell("\xe2\x96\x88", 1, s);
				} else {
					tea_mask_cells[idx] = xray::new_cell("\xe2\x96\x91", 1, s);
				}
			}
		}
	}
}

fn milktea::Cmd FireModel.init(FireModel* self) @dynamic {
	ulong seed = (ulong)c3_time_ms_long();
	srand((uint)seed);
	self.startTime = c3_time_ms_long();
	self.width = 80;
	self.height = 48;
	self.fire = mem::new_array(int, MAX_W * MAX_H);
	for (int i = 0; i < MAX_W * MAX_H; i++) self.fire[i] = 0;
	for (int x = 0; x < self.width; x++) {
		self.fire[(self.height / 2 - 1) * self.width + x] = 36;
	}
	self.view_cols = self.width;
	self.view_rows = self.height / 2;
	self.view_cells = mem::new_array(xray::Cell, (sz)(self.view_cols * self.view_rows));

	init_fire_cells();
	init_tea_mask();

	return milktea::tick();
}

fn void spread_pixel(FireModel* m, int idx) {
	if (idx < m.width) return;
	int pixel = m.fire[idx];
	if (pixel == 0) {
		m.fire[idx - m.width] = 0;
		return;
	}
	int rnd     = rand() % 5;
	int dst     = idx - rnd + 1;
	int buf_len = m.width * m.height;
	float ratio = 2 - (float)m.height / 80;
	if (dst - m.width >= 0 && dst - m.width < buf_len) {
		float r     = (float)(rand() % 2) + (float)(rand() % 2);
		int decay   = (int)(r * ratio + 0.4f);
		int new_val = pixel - decay;
		if (new_val < 0) new_val = 0;
		m.fire[dst - m.width] = new_val;
	}
}

fn milktea::Cmd FireModel.update(FireModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
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
			self.fire[(self.height - 1) * self.width + x] = 36;
		}
		// Reallocate view cell grid
		mem::free(self.view_cells.ptr);
		self.view_cols = self.width;
		self.view_rows = self.height / 2;
		self.view_cells = mem::new_array(xray::Cell, (sz)(self.view_cols * self.view_rows));
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		for (int x = 0; x < self.width; x++) {
			for (int y = 0; y < self.height; y++) {
				spread_pixel(self, y * self.width + x);
			}
		}
		return milktea::tick();
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View FireModel.view(FireModel* self) @dynamic {
	if (self.width == 0) return milktea::new_view("Initializing...");

	// Build cell grid directly — no string, no ANSI, no parsing.
	// xray's diff engine handles minimal output.
	int view_w = self.view_cols;
	int view_h = self.view_rows;

	for (int vy = 0; vy < view_h; vy++) {
		int fire_y     = vy * 2;
		int row_offset = vy * view_w;
		for (int vx = 0; vx < view_w; vx++) {
			int top_val = self.fire[fire_y * self.width + vx];
			int bot_val = self.fire[(fire_y + 1) * self.width + vx];

			// Start with the pre-built cell for the top pixel's fg color.
			// Set the bg to the bottom pixel's color.
			xray::Cell c        = fire_cells[top_val];
			FireColor bot_color = fire_palette[bot_val];
			c.style = c.style.set_bg(xray::color_rgb(bot_color.r, bot_color.g, bot_color.b));
			self.view_cells[row_offset + vx] = c;
		}
	}

	// Overlay TEA watermark where fire is cold
	int mask_x = (view_w - MASK_W) / 2;
	int mask_y = (view_h - MASK_H) / 2 - 1;

	for (int my = 0; my < MASK_H; my++) {
		int vy = mask_y + my;
		if (vy < 0 || vy >= view_h) continue;
		int fire_y_top = vy * 2;
		int fire_y_bot = fire_y_top + 1;
		if (fire_y_bot >= self.height) continue;

		for (int mx = 0; mx < MASK_W; mx++) {
			int vx = mask_x + mx;
			if (vx < 0 || vx >= view_w) continue;

			xray::Cell mc = tea_mask_cells[my * MASK_W + mx];
			if (mc.content_len > 0 && mc.content[0] != ' ') {
				int idx = vy * view_w + vx;
				bool cold = self.fire[fire_y_top * self.width + vx] == 0
					&& self.fire[fire_y_bot * self.width + vx] == 0;
				if (cold) {
					self.view_cells[idx] = mc;
				} else {
					xray::Cell c   = self.view_cells[idx];
					char mr        = mc.style.fg.r >> 2;
					char mg        = mc.style.fg.g >> 2;
					char mb        = mc.style.fg.b >> 2;
					xray::Color cf = c.style.fg;
					xray::Color cb = c.style.bg;
					char fr        = cf.r + mr;
					if (fr < cf.r) fr = 255;
					char fg = cf.g + mg;
					if (fg < cf.g) fg = 255;
					char fb = cf.b + mb;
					if (fb < cf.b) fb = 255;
					char br = cb.r + mr;
					if (br < cb.r) br = 255;
					char bg = cb.g + mg;
					if (bg < cb.g) bg = 255;
					char bb = cb.b + mb;
					if (bb < cb.b) bb = 255;
					c.style = c.style.set_fg(xray::color_rgb(fr, fg, fb)).set_bg(xray::color_rgb(br, bg, bb));
					self.view_cells[idx] = c;
				}
			}
		}
	}

	return milktea::new_alt_cell_view(self.view_cells, (sz)view_w, (sz)view_h);
}

fn int main() {
	FireModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Bye!");
	return 0;
}