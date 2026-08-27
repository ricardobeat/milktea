// DISSOLVE exit: nothing moves. Each block flickers through a few noise
// glyphs then blanks out, staggered so the word decays raggedly.
module nanobots;

import xray;

fn void dissolve_setup(void* raw) {
	Model* self = (Model*)raw;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = 0;
		p.vy = 0;
		p.spawn_tick = self.frame + @dur(rand() % 55);
		p.noise_seed = rand_range(0.0f, 1000.0f);
	}
	self.phase = Phase.DISSOLVE;
	self.phase_frame = self.frame;
	self.fx_state = null;
}

fn void dissolve_step(void* raw) {
	Model* self = (Model*)raw;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		// Purely visual — the block stays put and the view decides the glyph.
		// It retires once its flicker sequence is done.
		int age = self.frame - p.spawn_tick;
		if (age >= DISSOLVE_FLICKERS * DISSOLVE_STEP) p.alive = false;
	}
	if (!self.any_alive()) self.restart_cycle();
}

fn void dissolve_render(void* raw) {
	Model* self = (Model*)raw;
	xray::ScreenBuffer* sb = self.canvas;
	String[5] noise = { "\u2591", "\u2593", "\u2592", "\u2588", "\u2591" };
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (p.col < 0 || p.col >= self.w) continue;
		if (p.row < 0 || p.row >= self.h) continue;
		int age = self.frame - p.spawn_tick;
		xray::Color base = gradient_color(self, p.col);
		String g;
		if (age < 0) {
			g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
		} else {
			int step = age / DISSOLVE_STEP;
			if (step >= DISSOLVE_FLICKERS) continue;
			int ni = (step + (int)p.noise_seed) % 5;
			g = noise[ni];
			float f = 1.0f - (float)step / (float)DISSOLVE_FLICKERS;
			base = xray::color_rgb(
				(char)((float)base.r * f),
				(char)((float)base.g * f),
				(char)((float)base.b * f));
		}
		xray::Style ds = xray::default_style().set_fg(base);
		sb.set_cell((sz)p.col, (sz)p.row, xray::new_cell(g, 1, ds));
	}
}

fn Effect dissolve_effect() {
	return { .name = "DISSOLVE", .setup = &dissolve_setup, .step = &dissolve_step, .render = &dissolve_render };
}