module dots;

import milktea;
import xray;
import std::io;
import std::math;

// Every cell is a braille glyph: a 2x4 grid of sub-dots. Each sub-dot is lit
// by dithering a bell curve at sub-cell resolution, so a cell can show one dot
// up to eight. The cell's grey level follows the same bell, with a faint warm
// tint at the centre.
struct Model {
	xray::ScreenBuffer* canvas;
	bool has_mouse;
	// target is where the mouse last was; cur is where the field is drawn.
	float target_x;
	float target_y;
	float cur_x;
	float cur_y;
	// started is false until the first tick, which snaps cur onto target.
	bool started;
	// glyphs holds the UTF-8 bytes of U+2800 + n for n in 0..255, three per
	// glyph, filled once in init so cells can point at stable storage.
	char[768] glyphs;
}

// ease is the fraction of the remaining distance covered each frame. At 16ms
// frames this settles in roughly a second.
const float EASE = 0.06f;

// spread divides the screen's larger extent to give the bell's sigma. Larger
// values give a smaller, tighter spot.
const float SPREAD = 9.0f;

// cell_aspect is how much taller a terminal cell is than it is wide. Vertical
// distances are scaled by it so the bell stays round on screen.
const float CELL_ASPECT = 2.0f;

// base is the sub-dots every cell always shows (a short centred pair), so the
// grid stays visible away from the cursor.
const sz BASE = 0x12;

// braille_bit maps a sub-dot at (sx, sy) to its braille bit, indexed by
// sx * 4 + sy. Braille numbers its dots column-first, so this is not a plain
// row-major bit order.
const sz[8] BRAILLE_BIT = { 0x01, 0x02, 0x04, 0x40, 0x08, 0x10, 0x20, 0x80 };

// bayer is a 4x4 ordered-dither matrix, indexed by (gx % 4) + 4 * (gy % 4).
// Applied over the global sub-dot grid, it turns the bell into a halftone
// with no visible cell boundaries.
const int[16] BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

// Grey runs from FLOOR at the edge to PEAK at the centre.
const float FLOOR = 30.0f;
const float PEAK  = 230.0f;

// The centre leans toward WARM by at most WARM_MIX, and only where the bell is
// strong, because the tint is cubed.
const float WARM_R   = 255.0f;
const float WARM_G   = 220.0f;
const float WARM_B   = 90.0f;
const float WARM_MIX = 0.25f;

fn milktea::Cmd Model.init(Model* self) @dynamic {
	for (sz n = 0; n < 256; n++) {
		sz cp = 0x2800 + n;
		self.glyphs[n * 3] = (char)(0xE0 | (cp >> 12));
		self.glyphs[n * 3 + 1] = (char)(0x80 | ((cp >> 6) & 0x3F));
		self.glyphs[n * 3 + 2] = (char)(0x80 | (cp & 0x3F));
	}
	return milktea::tick(16);
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.TICK) {
		self.follow_target();
		return milktea::tick(16);
	}

	if (msg.kind == milktea::MsgKind.MOUSE) {
		self.has_mouse = true;
		self.target_x = (float)msg.mouse.col;
		self.target_y = (float)msg.mouse.row;
		return null;
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

// follow_target eases the drawn centre toward the mouse. Until the mouse moves
// the target is the middle of the screen.
fn void Model.follow_target(Model* self) {
	if (!self.has_mouse) {
		self.target_x = (float)milktea::screen_width() / 2.0f;
		self.target_y = (float)milktea::screen_height() / 2.0f;
	}
	if (!self.started) {
		self.cur_x = self.target_x;
		self.cur_y = self.target_y;
		self.started = true;
		return;
	}
	self.cur_x += (self.target_x - self.cur_x) * EASE;
	self.cur_y += (self.target_y - self.cur_y) * EASE;
}

// intensity is the bell evaluated at a point in cell coordinates, with the
// vertical axis scaled by the cell aspect ratio.
fn float intensity(Model* self, float x, float y, float sigma) {
	float dx = x - self.cur_x;
	float dy = (y - self.cur_y) * CELL_ASPECT;
	return math::exp(-(dx * dx + dy * dy) / (2.0f * sigma * sigma));
}

// braille_bits picks the sub-dots of cell (x, y). Each sub-dot is lit when the
// bell at its centre beats its dither threshold.
fn sz braille_bits(Model* self, sz x, sz y, float sigma) {
	sz bits = BASE;
	for (sz sx = 0; sx < 2; sx++) {
		for (sz sy = 0; sy < 4; sy++) {
			// Sub-dot centres: columns are half a cell wide, rows a quarter.
			float px    = (float)x + ((float)sx - 0.5f) * 0.5f;
			float py    = (float)y + ((float)sy - 1.5f) * 0.25f;
			float level = intensity(self, px, py, sigma);

			sz gx           = x * 2 + sx;
			sz gy           = y * 4 + sy;
			float threshold = ((float)BAYER[(gx % 4) + 4 * (gy % 4)] + 0.5f) / 16.0f;
			if (level > threshold) bits |= BRAILLE_BIT[sx * 4 + sy];
		}
	}
	return bits;
}

// mix_channel moves a grey channel toward a target by k in [0, 1].
fn char mix_channel(float grey, float target, float k) @inline {
	return (char)(grey + (target - grey) * k);
}

// tone maps a centre intensity in [0, 1] to a colour: grey, leaning warm in the
// core.
fn xray::Color tone(float t) {
	float grey = FLOOR + t * (PEAK - FLOOR);
	float warm = t * t * t * WARM_MIX;
	return xray::color_rgb(
		mix_channel(grey, WARM_R, warm),
		mix_channel(grey, WARM_G, warm),
		mix_channel(grey, WARM_B, warm)
	);
}

fn milktea::View Model.view(Model* self) @dynamic {
	sz w = milktea::screen_width();
	sz h = milktea::screen_height();
	if (w < 1 || h < 1) return milktea::view("");

	if (self.canvas == null) {
		self.canvas = xray::new_screen_buffer(w, h);
	} else if (self.canvas.width != w || self.canvas.height != h) {
		self.canvas.resize(w, h);
	}

	float extent = (float)(w > h * 2 ? w : h * 2);
	float sigma  = extent / SPREAD;

	for (sz y = 0; y < h; y++) {
		for (sz x = 0; x < w; x++) {
			float centre = intensity(self, (float)x, (float)y, sigma);
			sz bits      = braille_bits(self, x, y, sigma);

			xray::Style style = xray::default_style().set_fg(tone(centre));
			String glyph      = (String)self.glyphs[bits * 3:3];
			self.canvas.set_cell(x, y, xray::new_cell(glyph, 1, style));
		}
	}

	return self.canvas.view();
}

fn int main() {
	Model m = { };
	milktea::enable_mouse(true);

	if (catch err = milktea::@run_program(&m, { .alt_screen = true })) {
		milktea::disable_mouse(true);
		io::printfn("Error: %s", err);
		return 1;
	}

	milktea::disable_mouse(true);
	return 0;
}