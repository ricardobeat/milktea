module doom_fire_donut;

import milktea;
import xray;
import glb;
import std::io;
import std::math;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

// ── Fire ─────────────────────────────────────────────────────────────────────

struct FireColor {
	char r;
	char g;
	char b;
}

FireColor[37] fire_palette = {
	{ 7, 7, 7 }, { 31, 7, 7 }, { 47, 15, 7 }, { 71, 15, 7 },
	{ 87, 23, 7 }, { 103, 31, 7 }, { 119, 31, 7 }, { 143, 39, 7 },
	{ 159, 47, 7 }, { 175, 63, 7 }, { 191, 71, 7 }, { 199, 71, 7 },
	{ 223, 79, 7 }, { 223, 87, 7 }, { 223, 87, 7 }, { 215, 95, 7 },
	{ 215, 95, 7 }, { 215, 103, 15 }, { 207, 111, 15 }, { 207, 119, 15 },
	{ 207, 127, 15 }, { 207, 135, 23 }, { 199, 135, 23 }, { 199, 143, 23 },
	{ 199, 151, 31 }, { 191, 159, 31 }, { 191, 159, 31 }, { 191, 167, 39 },
	{ 191, 167, 39 }, { 191, 175, 47 }, { 183, 175, 47 }, { 183, 183, 47 },
	{ 183, 183, 55 }, { 207, 207, 111 }, { 223, 223, 159 }, { 239, 239, 199 },
	{ 255, 255, 255 },
	};

const int FIRE_MAX_W = 400;
const int FIRE_MAX_H = 400;

struct Model {
	glb::GlbModel* donut;
	int* fire;
	int fire_w;
	int fire_h;
	int tick;
	xray::Cell[] cells;
}

fn void spread_pixel(Model* m, int idx) {
	if (idx < m.fire_w) return;
	int pixel = m.fire[idx];
	if (pixel == 0) {
		m.fire[idx - m.fire_w] = 0;
		return;
	}
	int rnd     = rand() % 4;
	int dst     = idx - rnd + 1;
	int buf_len = m.fire_w * m.fire_h;
	if (dst - m.fire_w >= 0 && dst - m.fire_w < buf_len) {
		int decay   = (rand() & 1) ? 0 : 1;
		int new_val = pixel - decay;
		if (new_val < 0) new_val = 0;
		m.fire[dst - m.fire_w] = new_val;
	}
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	ulong seed = (ulong)c3_time_ms_long();

	srand((uint)seed);

	self.donut = glb::load_glb("examples/doom-fire-donut/donut.glb")!!;
	self.donut.width = 80;
	self.donut.height = 24;
	self.donut.cam_pz = -20.0f;
	self.donut.cam_yaw = 0.0f;
	self.donut.cam_pitch = 0.0f;

	self.fire_w = 80;
	self.fire_h = 48;
	self.fire = mem::new_array(int, FIRE_MAX_W * FIRE_MAX_H);
	self.tick = 0;
	for (int i = 0; i < FIRE_MAX_W * FIRE_MAX_H; i++) self.fire[i] = 0;

	self.cells = mem::new_array(xray::Cell, (sz)(self.fire_w * (self.fire_h / 2)));

	return milktea::tick();
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		int new_w = msg.window_size.width;
		int new_h = msg.window_size.height * 2;
		if (new_w > FIRE_MAX_W) new_w = FIRE_MAX_W;
		if (new_h > FIRE_MAX_H) new_h = FIRE_MAX_H;
		self.fire_w = new_w;
		self.fire_h = new_h;
		self.donut.resize(new_w, new_h / 2);
		for (int i = 0; i < self.fire_w * self.fire_h; i++) self.fire[i] = 0;
		mem::free(self.cells.ptr);
		self.cells = mem::new_array(xray::Cell, (sz)(self.fire_w * (self.fire_h / 2)));
		return null;
	}

	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg k = msg.key;
		if (k.code == milktea::KeyCode.CTRL_C || k.code == milktea::KeyCode.ESC) return milktea::quit();
		if (k.code == milktea::KeyCode.RUNE && k.rune == 'q') return milktea::quit();
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.tick++;

		// Animate donut — rotate + wobble
		self.donut.frame++;
		self.donut.model_yaw = (float)self.donut.frame * 0.025f;
		self.donut.model_pitch = (float)math::sin((float)self.donut.frame * 0.007f) * 0.5f;
		self.donut.cam_px = 0.0f;
		self.donut.cam_py = (float)math::sin((float)self.donut.frame * 0.02f) * 1.5f;
		self.donut.cam_pz = -18.0f;
		self.donut.render();

		// Seed bottom fire row
		for (int x = 0; x < self.fire_w; x++) {
			self.fire[(self.fire_h - 1) * self.fire_w + x] = 36;
		}
		// Spread fire upward
		for (int x = 0; x < self.fire_w; x++) {
			for (int y = 0; y < self.fire_h; y++) {
				spread_pixel(self, y * self.fire_w + x);
			}
		}
		return milktea::tick();
	}

	return null;
}

fn milktea::View Model.view(Model* self) @dynamic {
	int w  = self.fire_w;
	int h  = self.fire_h;
	int vh = h / 2;

	for (int vy = 0; vy < vh; vy++) {
		int fire_y_top = vy * 2;
		int fire_y_bot = vy * 2 + 1;
		int row_off    = vy * w;
		for (int vx = 0; vx < w; vx++) {
			int f_top = self.fire[fire_y_top * w + vx];
			int f_bot = self.fire[fire_y_bot * w + vx];

			glb::Pixel d_top = self.donut.pixels[fire_y_top * w + vx];
			glb::Pixel d_bot = self.donut.pixels[fire_y_bot * w + vx];

			char tr, tg, tb, br, bg, bb;
			if (f_top >= 8) {
				FireColor fc = fire_palette[f_top];
				tr = fc.r;
				tg = fc.g;
				tb = fc.b;
			} else {
				tr = d_top.r;
				tg = d_top.g;
				tb = d_top.b;
			}
			if (f_bot >= 8) {
				FireColor fc = fire_palette[f_bot];
				br = fc.r;
				bg = fc.g;
				bb = fc.b;
			} else {
				br = d_bot.r;
				bg = d_bot.g;
				bb = d_bot.b;
			}

			xray::Style s = xray::default_style().set_fg(xray::color_rgb(tr, tg, tb))
				.set_bg(xray::color_rgb(br, bg, bb));
			self.cells[row_off + vx] = xray::new_cell("\xe2\x96\x80", 1, s);
		}
	}

	return milktea::new_alt_cell_view(self.cells, (sz)w, (sz)vh);
}

fn int main() {
	Model* m = mem::new(Model);
	if (catch err = milktea::@run_program(m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	mem::free(m);
	return 0;
}
