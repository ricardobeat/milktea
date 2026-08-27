// COLLAPSE (FALL) exit: blocks drop under gravity and pile up column by
// column at the bottom of the screen, then the heap fades out.
module nanobots;

import xray;

struct FxCollapse {
	int[] stack_top;
	int fade_start;
}

fn FxCollapse* collapse_data(Model* self) => (FxCollapse*)self.fx_state;

fn void collapse_setup(void* raw) {
	Model* self = (Model*)raw;
	FxCollapse* s = mem::new(FxCollapse);
	s.stack_top = mem::new_array(int, (sz)self.w);
	s.fade_start = 0;
	for (int c = 0; c < self.w; c++) s.stack_top[c] = self.h * 2;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.fall_col = p.col;
		p.vx = rand_range(-1.2f, 1.2f);
		p.vy = rand_range(-2.0f, 1.0f);
	}
	self.fx_state = s;
	self.phase = Phase.FALL;
	self.phase_frame = self.frame;
}

fn void collapse_step(void* raw) {
	Model* self = (Model*)raw;
	FxCollapse* s = collapse_data(self);
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue;
		if (p.resting) continue;
		p.vy += GRAVITY * DT;
		p.vx *= decay(0.98f);
		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;
		float max_x = (float)(self.w - 1);
		if (p.x < 0)     { p.x = 0;     p.vx = -p.vx * 0.4f; }
		if (p.x > max_x) { p.x = max_x; p.vx = -p.vx * 0.4f; }
		int c = (int)p.x;
		if (c < 0) c = 0;
		if (c >= self.w) c = self.w - 1;
		p.fall_col = c;
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

fn void collapse_render(void* raw) {
	Model* self = (Model*)raw;
	FxCollapse* s = collapse_data(self);
	float fade = fx_pile_fade(self, s.fade_start);
	fx_draw_moving(self, fade);
}

fn void collapse_teardown(void* raw) {
	Model* self = (Model*)raw;
	FxCollapse* s = collapse_data(self);
	mem::free(s.stack_top);
	mem::free(s);
	self.fx_state = null;
}

fn Effect collapse_effect() {
	return { .name = "COLLAPSE", .setup = &collapse_setup, .step = &collapse_step,
		.render = &collapse_render, .teardown = &collapse_teardown };
}