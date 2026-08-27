// TOPPLE exit: the word stays rigid and rotates about one bottom corner,
// then shatters into a pile on landing.
module nanobots;

import xray;
import std::math;

struct FxTopple {
	float bar_dir;
	float pivot_x;
	float pivot_y;
	float topple_angle;
	float topple_vel;
	bool topple_shattered;
	int[] stack_top;
	int fade_start;
}

fn FxTopple* topple_data(Model* self) => (FxTopple*)self.fx_state;

fn void tpos(Model* self, FxTopple* s, Particle* p, float* ox, float* oy) {
	float dx = (float)p.col - s.pivot_x;
	float dy = ((float)p.row - s.pivot_y) * 2.0f;
	float a = s.topple_angle * s.bar_dir;
	float ca = math::cos(a);
	float sa = math::sin(a);
	float rx = dx * ca - dy * sa;
	float ry = dx * sa + dy * ca;
	*ox = s.pivot_x + rx;
	*oy = s.pivot_y + ry * 0.5f;
}

fn void tscatter(Model* self, FxTopple* s) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		float rx = 0;
		float ry = 0;
		tpos(self, s, p, &rx, &ry);
		p.x = rx;
		p.y = ry;
		float dx = rx - s.pivot_x;
		p.vx = dx * 0.28f + rand_range(-1.5f, 1.5f);
		p.vy = rand_range(-6.0f, -1.0f);
	}
}

fn void topple_setup(void* raw) {
	Model* self = (Model*)raw;
	FxTopple* s = mem::new(FxTopple);
	s.bar_dir = rand() % 2 == 0 ? 1.0f : -1.0f;
	s.pivot_x = s.bar_dir > 0
		? (float)(self.text_x + self.text_w - 1)
		: (float)self.text_x;
	s.pivot_y = (float)(self.text_y + self.text_h - 1);
	s.topple_angle = 0.0f;
	s.topple_vel = 0.0f;
	s.topple_shattered = false;
	s.fade_start = 0;
	s.stack_top = mem::new_array(int, (sz)self.w);
	for (int c = 0; c < self.w; c++) s.stack_top[c] = self.h * 2;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = 0;
		p.vy = 0;
		p.spawn_tick = self.frame;
	}
	self.fx_state = s;
	self.phase = Phase.TOPPLE;
	self.phase_frame = self.frame;
}

fn void topple_step(void* raw) {
	Model* self = (Model*)raw;
	FxTopple* s = topple_data(self);

	// Before the crash the slab is rigid; the shared angle drives every block.
	if (!s.topple_shattered) {
		// Gravity torque: accelerates as the slab goes over.
		s.topple_vel += (TOPPLE_ACCEL + s.topple_angle * 0.004f) * DT;
		s.topple_angle += s.topple_vel;
		if (s.topple_angle >= 1.5707963f) {
			s.topple_angle = 1.5707963f;
			s.topple_shattered = true;
			tscatter(self, s);
		}
		return;
	}

	// After the crash, blocks behave exactly like the FALL pile.
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (p.resting) continue;
		p.vy += GRAVITY * DT;
		p.vx *= decay(0.98f);
		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;
		float mx = (float)(self.w - 1);
		if (p.x < 0)  { p.x = 0;  p.vx = -p.vx * 0.4f; }
		if (p.x > mx) { p.x = mx; p.vx = -p.vx * 0.4f; }
		int c = (int)p.x;
		if (c < 0) c = 0;
		if (c >= self.w) c = self.w - 1;
		float floor_y = (float)(s.stack_top[c] - 1) * 0.5f;
		if (p.y >= floor_y) {
			p.y = floor_y;
			if (p.vy > 3.0f) {
				p.vy = -p.vy * BOUNCE;
				p.vx *= 0.7f;
			} else {
				p.vy = 0;
				p.vx = 0;
				p.x = (float)c;
				p.resting = true;
				if (s.stack_top[c] > 0) s.stack_top[c]--;
			}
		}
	}
	if (s.fade_start == 0) {
		if (self.all_resting()) s.fade_start = self.frame + @dur(10);
	} else if (self.frame - s.fade_start >= FADE_DURATION) {
		self.restart_cycle();
	}
}

fn void topple_render(void* raw) {
	Model* self = (Model*)raw;
	FxTopple* s = topple_data(self);
	if (s.topple_shattered) {
		float fade = fx_pile_fade(self, s.fade_start);
		fx_draw_moving(self, fade);
		return;
	}
	// Still one rigid slab: draw every block at its rotated position.
	xray::ScreenBuffer* sb = self.canvas;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		float rx = 0;
		float ry = 0;
		tpos(self, s, p, &rx, &ry);
		int col = (int)rx;
		int row = (int)ry;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		xray::Style ts = xray::default_style().set_fg(gradient_color(self, p.col));
		sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, ts));
	}
}

fn void topple_teardown(void* raw) {
	Model* self = (Model*)raw;
	FxTopple* s = topple_data(self);
	mem::free(s.stack_top);
	mem::free(s);
	self.fx_state = null;
}

fn Effect topple_effect() {
	return { .name = "TOPPLE", .setup = &topple_setup, .step = &topple_step,
		.render = &topple_render, .teardown = &topple_teardown };
}