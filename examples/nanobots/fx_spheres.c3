// SPHERES exit: every glyph turns into a ball and drops. They release one by
// one and bounce high, scattering sideways across the floor before settling.
module nanobots;

import xray;
import std::math;

struct FxSpheres {
	int fade_start;
}

fn FxSpheres* spheres_data(Model* self) => (FxSpheres*)self.fx_state;

// Push overlapping balls apart and exchange momentum along the line of
// centres; a settled ball is never woken so the pile always comes to rest.
fn void spheres_collide(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* a = &self.particles[i];
		if (!a.alive || self.frame < a.spawn_tick) continue;
		for (int j = i + 1; j < self.total; j++) {
			Particle* b = &self.particles[j];
			if (!b.alive || self.frame < b.spawn_tick) continue;
			float dx = (b.x - a.x) * 0.5f;
			float dy = b.y - a.y;
			float d2 = dx * dx + dy * dy;
			if (d2 >= BALL_RADIUS * BALL_RADIUS || d2 < 0.0001f) continue;
			float d = math::sqrt(d2);
			float nx = dx / d;
			float ny = dy / d;
			float overlap = BALL_RADIUS - d;
			float share_a = b.resting ? 1.0f : 0.5f;
			float share_b = a.resting ? 1.0f : 0.5f;
			if (!a.resting) {
				a.x -= nx * overlap * share_a * 2.0f;
				a.y -= ny * overlap * share_a;
			}
			if (!b.resting) {
				b.x += nx * overlap * share_b * 2.0f;
				b.y += ny * overlap * share_b;
			}
			float rvx = (b.vx - a.vx) * 0.5f;
			float rvy = b.vy - a.vy;
			float sep = rvx * nx + rvy * ny;
			if (sep > 0.0f) continue;
			float imp = -(1.0f + BALL_BOUNCE) * sep * 0.5f;
			if (!a.resting) {
				a.vx -= nx * imp * 2.0f;
				a.vy -= ny * imp;
			}
			if (!b.resting) {
				b.vx += nx * imp * 2.0f;
				b.vy += ny * imp;
			}
		}
	}
}

// True when a ball is in contact with a resting ball below it — that counts
// as ground, so balls stacked on the pile can settle without touching the floor.
fn bool spheres_on_resting(Model* self, Particle* p) {
	for (int i = 0; i < self.total; i++) {
		Particle* q = &self.particles[i];
		if (!q.alive || !q.resting || q == p) continue;
		float dx = (q.x - p.x) * 0.5f;
		float dy = q.y - p.y;
		if (dy <= 0.0f || dy > BALL_RADIUS) continue;
		if (dx * dx + dy * dy <= BALL_RADIUS * BALL_RADIUS * 1.1f) return true;
	}
	return false;
}

fn void spheres_setup(void* raw) {
	Model* self = (Model*)raw;
	FxSpheres* s = mem::new(FxSpheres);
	s.fade_start = 0;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = rand_range(-2.2f, 2.2f);
		p.vy = 0;
		// Released in list order (bottom-up) so the word trickles apart;
		// spread over a fixed ~4s regardless of word size.
		int span = @dur(80);
		int slot = self.total > 1 ? i * span / (self.total - 1) : 0;
		p.spawn_tick = self.frame + slot + @dur(rand() % 4);
	}
	self.fx_state = s;
	self.phase = Phase.SPHERES;
	self.phase_frame = self.frame;
}

fn void spheres_step(void* raw) {
	Model* self = (Model*)raw;
	FxSpheres* s = spheres_data(self);
	spheres_collide(self);
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue;
		if (p.resting) continue;
		p.vy += GRAVITY * DT;
		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;
		float mx = (float)(self.w - 1);
		if (p.x < 0)  { p.x = 0;  p.vx = -p.vx * 0.7f; }
		if (p.x > mx) { p.x = mx; p.vx = -p.vx * 0.7f; }
		float floor_y = (float)(self.h - 1);
		bool landed = false;
		if (p.y >= floor_y) {
			p.y = floor_y;
			landed = true;
		} else if (p.vy >= 0 && spheres_on_resting(self, p)) {
			landed = true;
		}
		if (landed) {
			if (p.vy > BALL_REST) {
				p.vy = -p.vy * BALL_BOUNCE;
				p.vx *= 0.94f;
			} else {
				p.vy = 0;
				p.vx *= 0.7f;
				if (p.vx > -0.25f && p.vx < 0.25f) {
					p.vx = 0;
					p.resting = true;
				}
			}
		}
	}
	// All released and still enough to count as finished — collisions can
	// keep knocking balls awake, so this has a hard cap as well.
	bool done = self.all_resting()
			|| self.frame - self.phase_frame > @dur(320);
	if (self.frame > self.phase_frame + @dur(90) && done) {
		if (s.fade_start == 0) s.fade_start = self.frame + @dur(10);
		if (self.frame - s.fade_start >= FADE_DURATION) {
			self.restart_cycle();
		}
	}
}

fn void spheres_render(void* raw) {
	Model* self = (Model*)raw;
	FxSpheres* s = spheres_data(self);
	xray::ScreenBuffer* sb = self.canvas;
	float fade = fx_pile_fade(self, s.fade_start);
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		xray::Color bc = gradient_color(self, p.col);
		if (fade < 1.0f) {
			bc = xray::color_rgb(
				(char)((float)bc.r * fade),
				(char)((float)bc.g * fade),
				(char)((float)bc.b * fade));
		}
		xray::Style bs = xray::default_style().set_fg(bc);
		if (self.frame < p.spawn_tick) {
			// Not dropped yet — still part of the word.
			if (p.col < 0 || p.col >= self.w) continue;
			if (p.row < 0 || p.row >= self.h) continue;
			String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
			sb.set_cell((sz)p.col, (sz)p.row, xray::new_cell(g, 1, bs));
			continue;
		}
		int col = (int)p.x;
		int row = (int)p.y;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		sb.set_cell((sz)col, (sz)row, xray::new_cell("\u25CF", 1, bs));
	}
}

fn void spheres_teardown(void* raw) {
	Model* self = (Model*)raw;
	mem::free(spheres_data(self));
	self.fx_state = null;
}

fn Effect spheres_effect() {
	return { .name = "SPHERES", .setup = &spheres_setup, .step = &spheres_step,
		.render = &spheres_render, .teardown = &spheres_teardown };
}