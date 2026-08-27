// VORTEX exit: a hole opens somewhere and spirals every block into it. The
// ring irises open, feeds, then pinches shut once the last block is gone.
module nanobots;

import xray;
import std::math;

struct FxVortex {
	float hole_x;
	float hole_y;
	float hole_r;
}

fn FxVortex* vortex_data(Model* self) => (FxVortex*)self.fx_state;

fn void vortex_setup(void* raw) {
	Model* self = (Model*)raw;
	FxVortex* s = mem::new(FxVortex);
	s.hole_x = rand_range(8.0f, (float)self.w - 8.0f);
	s.hole_y = rand_range(4.0f, (float)self.h - 4.0f);
	s.hole_r = 0.0f;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = rand_range(-1.0f, 1.0f);
		p.vy = rand_range(-0.5f, 0.5f);
		p.spawn_tick = self.frame + @dur(rand() % 12);
	}
	self.fx_state = s;
	self.phase = Phase.VORTEX;
	self.phase_frame = self.frame;
}

fn void vortex_step(void* raw) {
	Model* self = (Model*)raw;
	FxVortex* s = vortex_data(self);
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue;
		float dx = s.hole_x - p.x;
		float dy = (s.hole_y - p.y) * 2.0f; // cells are ~2x tall
		float d = math::sqrt(dx * dx + dy * dy);
		if (d < 0.9f) { p.alive = false; continue; }
		float nx = dx / d;
		float ny = dy / d;
		float pull = 26.0f / d;
		if (pull > 5.0f) pull = 5.0f;
		p.vx += nx * pull * DT;
		p.vy += ny * pull * 0.5f * DT;
		float swirl = d / 14.0f;
		if (swirl > 1.0f) swirl = 1.0f;
		p.vx += -ny * pull * 0.55f * swirl * DT;
		p.vy += nx * pull * 0.28f * swirl * DT;
		p.x += nx * 0.10f;
		p.y += ny * 0.05f;
		p.vx *= decay(0.90f);
		p.vy *= decay(0.90f);
		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;
	}
	// The ring irises open, feeds, then pinches shut and ends the cycle.
	if (self.any_alive()) {
		if (s.hole_r < 2.0f) s.hole_r += 0.2f * DT;
	} else {
		s.hole_r -= 0.12f * DT;
		if (s.hole_r <= 0.0f) {
			s.hole_r = 0.0f;
			self.restart_cycle();
		}
	}
}

fn void vortex_render(void* raw) {
	Model* self = (Model*)raw;
	FxVortex* s = vortex_data(self);
	xray::ScreenBuffer* sb = self.canvas;
	fx_draw_moving(self, 1.0f);
	// The disc, drawn after the blocks so anything still spiralling passes
	// behind it. The ellipse is squashed 2:1 for the cell aspect.
	if (s.hole_r > 0.05f) {
		xray::Color ring = xray::color_rgb(255, 64, 160);
		xray::Style ring_s = xray::default_style().set_fg(ring).set_bg(xray::color_transparent());
		xray::Style void_s = xray::default_style().set_fg(xray::color_rgb(10, 4, 14)).set_bg(xray::color_transparent());
		int span = (int)s.hole_r + 2;
		for (int dy = -span; dy <= span; dy++) {
			for (int dx = -span * 2; dx <= span * 2; dx++) {
				int col = (int)s.hole_x + dx;
				int row = (int)s.hole_y + dy;
				if (col < 0 || col >= self.w) continue;
				if (row < 0 || row >= self.h) continue;
				float fx = (float)dx * 0.5f;
				float fy = (float)dy;
				float d = math::sqrt(fx * fx + fy * fy);
				if (d > s.hole_r) continue;
				if (d > s.hole_r - 0.45f) {
					sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, ring_s));
				} else {
					sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, void_s));
				}
			}
		}
	}
}

fn void vortex_teardown(void* raw) {
	Model* self = (Model*)raw;
	mem::free(vortex_data(self));
	self.fx_state = null;
}

fn Effect vortex_effect() {
	return { .name = "VORTEX", .setup = &vortex_setup, .step = &vortex_step,
		.render = &vortex_render, .teardown = &vortex_teardown };
}