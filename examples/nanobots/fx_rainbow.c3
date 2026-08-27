// RAINBOW exit: a wave of bright colour washes over the word from top-left to
// bottom-right. Each glyph lights up as a solid rainbow cell, but the palette
// is hashed by position so neighbouring glyphs get clashing/complementary hues
// rather than a contiguous gradient. When the wave reaches the last glyph the
// cells fade out again, in the same top-left-first order.
module nanobots;

import xray;

const int RAINBOW_LEN = 8;          // distinct hues in the wave palette
const int RAINBOW_WAVE = @dur(40);  // ticks for the wave to cross the word
const int RAINBOW_HOLD = @dur(8);   // brief beat at full colour before fading
const int RAINBOW_FADE = @dur(40);  // ticks a cell takes to fade out

fn xray::Color rainbow_color(int h) {
	switch (h) {
		case 0: return xray::color_rgb(255, 45, 45);    // red
		case 1: return xray::color_rgb(255, 140, 20);   // orange
		case 2: return xray::color_rgb(255, 245, 15);   // yellow
		case 3: return xray::color_rgb(35, 255, 90);    // green
		case 4: return xray::color_rgb(0, 235, 255);    // cyan
		case 5: return xray::color_rgb(65, 110, 255);   // blue
		case 6: return xray::color_rgb(165, 75, 255);   // violet
		default: return xray::color_rgb(255, 50, 225);  // magenta
	}
}

// The scene's vertical background gradient at a given row, so glyphs sit on
// the right backdrop (no black) and the fade melts into the scene.
fn xray::Color rainbow_bg(Model* self, int row) {
	float b = self.h > 1 ? (float)row / (float)(self.h - 1) : 0.0f;
	return xray::color_rgb(
		(char)(6.0f + 12.0f * b),
		(char)(8.0f + 14.0f * b),
		(char)(22.0f + 16.0f * b));
}

// Scan order from the top-left glyph to the bottom-right one. Row-major over
// the text box, so the wave always starts at the top-left.
fn int rainbow_order(Model* self, Particle* p) {
	return (p.row - self.text_y) * self.text_w + (p.col - self.text_x);
}

// A position-hashed hue so adjacent cells are far apart on the wheel: a
// column/row step of 5 or 3 hues (mod the palette) is never contiguous.
fn int rainbow_hue(Model* self, Particle* p) {
	int h = (p.row - self.text_y) * 11 + (p.col - self.text_x) * 5;
	return h % RAINBOW_LEN;
}

fn void rainbow_setup(void* raw) {
	Model* self = (Model*)raw;
	self.phase = Phase.RAINBOW;
	self.phase_frame = self.frame;
	self.fx_state = null;
}

fn void rainbow_step(void* raw) {
	Model* self = (Model*)raw;
	int age = self.frame - self.phase_frame;
	int max_o = (self.text_h - 1) * self.text_w + (self.text_w - 1);
	if (max_o < 1) max_o = 1;
	float fade_dw = (float)RAINBOW_FADE / (float)max_o;
	int last_fade_start = RAINBOW_WAVE + RAINBOW_HOLD + (int)((float)max_o * fade_dw);
	if (age >= last_fade_start + RAINBOW_FADE) self.restart_cycle();
}

fn void rainbow_render(void* raw) {
	Model* self = (Model*)raw;
	xray::ScreenBuffer* sb = self.canvas;
	int age = self.frame - self.phase_frame;
	int max_o = (self.text_h - 1) * self.text_w + (self.text_w - 1);
	if (max_o < 1) max_o = 1;
	float dw = (float)RAINBOW_WAVE / (float)max_o;
	float fade_dw = (float)RAINBOW_FADE / (float)max_o;

	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		int col = p.col;
		int row = p.row;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		int o = rainbow_order(self, p);
		String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
		xray::Color bg = rainbow_bg(self, row);

		if ((float)age < (float)o * dw) {
			// Still ahead of the wave: the word shows as itself, on its
			// background so the holey glyphs don't leave black behind.
			sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1,
				xray::default_style().set_fg(gradient_color(self, p.col)).set_bg(bg)));
			continue;
		}

		// The glyph keeps its shape; only its colour changes.
		xray::Color c = rainbow_color(rainbow_hue(self, p));
		int fade_start = RAINBOW_WAVE + RAINBOW_HOLD + (int)((float)o * fade_dw);
		if (age >= fade_start) {
			// Fade toward the background colour, not black, so the cell
			// melts into the scene as it goes.
			float t = (float)(age - fade_start) / (float)RAINBOW_FADE;
			if (t > 1.0f) t = 1.0f;
			c = xray::color_rgb(
				(char)((float)c.r * (1.0f - t) + (float)bg.r * t),
				(char)((float)c.g * (1.0f - t) + (float)bg.g * t),
				(char)((float)c.b * (1.0f - t) + (float)bg.b * t));
		}
		sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1,
			xray::default_style().set_fg(c).set_bg(bg)));
	}
}

fn Effect rainbow_effect() {
	return { .name = "RAINBOW", .setup = &rainbow_setup, .step = &rainbow_step, .render = &rainbow_render };
}