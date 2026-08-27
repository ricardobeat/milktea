// GRADIENT exit: a rainbow pulse starts at the ellipse's focus (the bright
// bottom-centre of the background gradient) and expands outward, recolorring
// the gradient from the inside out and eating the word as it crosses each
// cell. Once the pulse has filled the whole screen the blanket of rainbow
// fades back to the original background, and the cycle restarts.
module nanobots;

import xray;
import glaze;
import std::math;

const int GRAD_EXPAND = @dur(90);  // ticks for the pulse to fill the screen
const int GRAD_FADE   = @dur(42);  // ticks the full rainbow fades to the wash
const int GRAD_HOLD   = @dur(20);  // beat on the restored background

// Geometric basis of the scene's elliptical gradient: focus at bottom-centre
// and the radii that shape the iso-colour bands. Shared by the distance test
// and the background lookup so the pulse and the wash agree on geometry.
fn void scene_geom(Model* self, float* cx, float* cy, float* rxi, float* ryi) {
	*cx = (float)self.w * 0.5f;
	*cy = (float)(self.h - 1);
	*rxi = 1.0f / ((float)self.w * 0.65f);
	*ryi = 1.0f / ((float)self.h * 0.95f);
}

// Normalized elliptical distance from the focus, 0 at the centre and growing
// toward 1+ at the far corners. This is the pulse radius coordinate.
fn float scene_t(Model* self, int col, int row, float cx, float cy, float rxi, float ryi) {
	float dx = ((float)col - cx) * rxi;
	float dy = ((float)row - cy) * ryi;
	return math::sqrt(dx * dx + dy * dy);
}

// The original gradient colour at a given distance: bright at the focus
// (t = 0), fading to the dark top/side colour once t reaches 1.
fn xray::Color scene_bg(Model* self, float t) {
	if (t > 1.0f) t = 1.0f;
	if (t < 0.0f) t = 0.0f;
	xray::Color top = xray::color_rgb(4, 4, 10);
	xray::Color bot = xray::color_rgb(38, 16, 54);
	// Blend in CIE LUV, not sRGB: a straight sRGB lerp dips in lightness mid
	// ramp and reads as a seam, especially between close dark hues.
	glaze::Color from = to_glaze(bot);
	glaze::Color to = to_glaze(top);
	glaze::Color mixed = glaze::blend_luv(from, to, (double)t);
	return xray::color_rgb(mixed.r, mixed.g, mixed.b);
}

// Full-saturation rainbow in HSV terms: h in [0,1) goes round the wheel and
// val picks the brightness, so the pulse can carry the vertical shading of the
// gradient it is replacing rather than glowing at a flat intensity.
fn xray::Color rainbow_tint(float h, float val) {
	h -= (float)(int)h;
	float f = h * 6.0f;
	int sector = (int)f;
	float u = f - (float)sector;
	float x = 1.0f - u;
	float r;
	float g;
	float b;
	switch (sector) {
		case 0: r = 1.0f; g = u;   b = 0.0f;
		case 1: r = x;   g = 1.0f; b = 0.0f;
		case 2: r = 0.0f; g = 1.0f; b = u;
		case 3: r = 0.0f; g = x;   b = 1.0f;
		case 4: r = u;   g = 0.0f; b = 1.0f;
		default: r = 1.0f; g = 0.0f; b = x;
	}
	return xray::color_rgb(
		(char)(r * val * 255.0f),
		(char)(g * val * 255.0f),
		(char)(b * val * 255.0f));
}

fn void gradient_setup(void* raw) {
	Model* self = (Model*)raw;
	self.phase = Phase.GRADIENT;
	self.phase_frame = self.frame;
	self.fx_state = null;
}

fn void gradient_step(void* raw) {
	Model* self = (Model*)raw;
	int age = self.frame - self.phase_frame;
	if (age >= GRAD_EXPAND + GRAD_FADE + GRAD_HOLD) self.restart_cycle();
}

fn void gradient_render(void* raw) {
	Model* self = (Model*)raw;
	xray::ScreenBuffer* sb = self.canvas;
	int age = self.frame - self.phase_frame;

	float cx;
	float cy;
	float rxi;
	float ryi;
	scene_geom(self, &cx, &cy, &rxi, &ryi);
	float dx = (float)(self.w / 2) * rxi;
	float dy = (float)(self.h - 1) * ryi;
	float tmax = math::sqrt(dx * dx + dy * dy) * 1.1f;

	// Pulse radius: grows from the focus outward, then holds at full.
	float r = 0.0f;
	float fade_t = 0.0f;
	if (age < GRAD_EXPAND) {
		float p = (float)age / (float)GRAD_EXPAND;
		float e = p * p * (3.0f - 2.0f * p); // smoothstep: ease into the surge
		r = e * tmax;
	} else if (age < GRAD_EXPAND + GRAD_FADE) {
		r = tmax;
		fade_t = (float)(age - GRAD_EXPAND) / (float)GRAD_FADE;
	} else {
		r = tmax;
		fade_t = 1.0f;
	}

	for (int row = 0; row < self.h; row++) {
		for (int col = 0; col < self.w; col++) {
			float t = scene_t(self, col, row, cx, cy, rxi, ryi);
			xray::Color base = scene_bg(self, t);
			xray::Color bgc = base;
			if (t <= r) {
				float agef = (float)age;
				// Hue drifts slowly so the field eases through the spectrum.
				float hue = t / tmax * 0.9f + agef * 0.0007f;
				// Base brightness follows the gradient: bright at the focus,
				// dimming outward.
				float val = 0.85f - 0.45f * (t / tmax);
				// A slow, gentle swell breathes across the field — nothing
				// faster than the eye can track, just a sense of motion.
				float swell = 0.5f + 0.5f * math::sin(t * 6.0f - agef * 0.10f);
				val *= 0.72f + 0.28f * swell;
				// A soft brightening just behind the consuming front.
				float front = r - t;
				if (front < 0.12f) {
					float glow = 1.0f - front / 0.12f;
					val = val + (1.0f - val) * glow * 0.45f;
				}
				if (val < 0.0f) val = 0.0f;
				if (val > 1.0f) val = 1.0f;
				xray::Color rb = rainbow_tint(hue, val);
				if (fade_t > 0.0f && fade_t < 1.0f) {
					bgc = xray::color_rgb(
						(char)((float)rb.r + ((float)base.r - (float)rb.r) * fade_t),
						(char)((float)rb.g + ((float)base.g - (float)rb.g) * fade_t),
						(char)((float)rb.b + ((float)base.b - (float)rb.b) * fade_t));
				} else if (fade_t >= 1.0f) {
					bgc = base;
				} else {
					bgc = rb;
				}
			}
			sb.set_cell((sz)col, (sz)row,
				xray::new_cell(" ", 1, xray::default_style().set_bg(bgc)));
		}
	}

	// Only the still-intact part of the word — cells ahead of the expanding
	// pulse — is drawn, on a transparent background to inherit the wash.
	if (r < tmax) {
		for (int i = 0; i < self.total; i++) {
			Particle* p = &self.particles[i];
			if (p.col < 0 || p.col >= self.w) continue;
			if (p.row < 0 || p.row >= self.h) continue;
			float t = scene_t(self, p.col, p.row, cx, cy, rxi, ryi);
			if (t <= r) continue;   // already eaten by the rainbow
			String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
			xray::Style s2 = xray::default_style()
				.set_fg(gradient_color(self, p.col))
				.set_bg(xray::color_transparent());
			sb.set_cell((sz)p.col, (sz)p.row, xray::new_cell(g, 1, s2));
		}
	}
}

fn Effect gradient_effect() {
	return { .name = "GRADIENT", .setup = &gradient_setup, .step = &gradient_step, .render = &gradient_render };
}