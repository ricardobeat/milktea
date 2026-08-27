// SHEAR exit: a gust builds from one side and tears blocks loose column by
// column, so they streak and flutter rather than fly clean.
module nanobots;

import xray;
import std::math;

struct FxShear {
	float bar_dir;
}

fn FxShear* shear_data(Model* self) => (FxShear*)self.fx_state;

fn void shear_setup(void* raw) {
	Model* self = (Model*)raw;
	FxShear* s = mem::new(FxShear);
	s.bar_dir = rand() % 2 == 0 ? 1.0f : -1.0f;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = 0;
		p.vy = 0;
		int band = s.bar_dir > 0
			? p.col - self.text_x
			: self.text_x + self.text_w - p.col;
		p.spawn_tick = self.frame + @dur(band * 2 + rand() % 8);
		p.wander = rand_range(0.0f, 6.2831853f);
		p.wander_rate = rand_range(-0.30f, 0.30f);
	}
	self.fx_state = s;
	self.phase = Phase.SHEAR;
	self.phase_frame = self.frame;
}

fn void shear_step(void* raw) {
	Model* self = (Model*)raw;
	FxShear* s = shear_data(self);
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue; // not torn loose yet
		p.vx += WIND_ACCEL * s.bar_dir * DT;
		p.wander += p.wander_rate * DT;
		p.vy += math::sin(p.wander) * 0.55f * DT;
		p.vx *= decay(0.88f);
		p.vy *= decay(0.86f);
		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;
		if (p.x < -4.0f || p.x > (float)self.w + 4.0f) p.alive = false;
	}
	if (!self.any_alive()) self.restart_cycle();
}

fn void shear_render(void* raw) {
	Model* self = (Model*)raw;
	xray::ScreenBuffer* sb = self.canvas;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		int col = (int)p.x;
		int row = (int)p.y;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		xray::Style ss = xray::default_style().set_fg(gradient_color(self, p.col)).set_bg(xray::color_transparent());
		String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
		sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, ss));
	}
}

fn void shear_teardown(void* raw) {
	Model* self = (Model*)raw;
	mem::free(shear_data(self));
	self.fx_state = null;
}

fn Effect shear_effect() {
	return { .name = "SHEAR", .setup = &shear_setup, .step = &shear_step,
		.render = &shear_render, .teardown = &shear_teardown };
}