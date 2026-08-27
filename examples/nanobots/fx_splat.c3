// SPLAT exit: the word is hurled at a side wall, hits as a slab, shatters in
// a splash along the wall, then gravity takes the bits down into a pile.
module nanobots;

import xray;
import std::math;

struct FxSplat {
	float splat_wall;
	bool splat_falling;
	int splat_launch;
	int[] stack_top;
	int fade_start;
}

// Spring-loaded throw. The wind-up drags the slab back and stores tension;
// on release a spring accelerates it into the wall, so the impact is the
// fastest moment and reads as a real fling rather than a constant glide.
const float SPRING_ACCEL = 5.4f;           // spring thrust toward the wall
const float SPLAT_PULL = 5.0f;             // how hard the wind-up drags back
const float SPLAT_GRAV = GRAVITY * 0.62f;  // a touch closer to floating

fn FxSplat* splat_data(Model* self) => (FxSplat*)self.fx_state;

fn bool splat_hit(Model* self, FxSplat* s) {
	// Nothing lands while the slab is still winding up.
	if (self.frame < s.splat_launch) return false;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (p.y <= 0.0f || p.y >= (float)(self.h - 1)) return true;
		if (s.splat_wall > 0.0f) {
			if (p.x >= s.splat_wall) return true;
		} else {
			if (p.x <= 0.0f) return true;
		}
	}
	return false;
}

fn void splash_from_wall(Model* self, FxSplat* s) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		p.x = s.splat_wall;
		if (p.y < 0.0f) p.y = 0.0f;
		if (p.y > (float)(self.h - 1)) p.y = (float)(self.h - 1);
		float away = s.splat_wall > 0.0f ? -1.0f : 1.0f;
		p.vx = away * rand_range(1.0f, SPLAT_SPLASH);
		p.vy = rand_range(-SPLAT_SPLASH, SPLAT_SPLASH * 0.6f);
	}
}

fn void splat_setup(void* raw) {
	Model* self = (Model*)raw;
	FxSplat* s = mem::new(FxSplat);
	bool to_right = rand() % 2 == 0;
	s.splat_wall = to_right ? (float)(self.w - 1) : 0.0f;
	s.splat_falling = false;
	s.fade_start = 0;
	s.stack_top = mem::new_array(int, (sz)self.w);
	for (int c = 0; c < self.w; c++) s.stack_top[c] = self.h * 2;
	float angle = rand_range(-0.25f, 0.25f);
	float dir = to_right ? 1.0f : -1.0f;
	s.splat_launch = self.frame + SPLAT_WINDUP;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = math::cos(angle) * SPLAT_SPEED * dir;
		p.vy = math::sin(angle) * SPLAT_SPEED * 0.5f;
		p.spawn_tick = self.frame;
	}
	self.fx_state = s;
	self.phase = Phase.SPLAT;
	self.phase_frame = self.frame;
}

fn void splat_step(void* raw) {
	Model* self = (Model*)raw;
	FxSplat* s = splat_data(self);

	if (!s.splat_falling) {
		// Spring-loaded throw. The wind-up drags the slab back while it
		// stores tension; on release a spring accelerates it into the wall,
		// so the impact is the fastest moment rather than a constant glide.
		float dir = s.splat_wall > 0.0f ? 1.0f : -1.0f;
		for (int i = 0; i < self.total; i++) {
			Particle* p = &self.particles[i];
			if (!p.alive) continue;
			int rel = self.frame - s.splat_launch;
			if (rel < 0) {
				// Loading: ease back away from the wall, tapering to a
				// standstill exactly at the turn.
				float u = (float)(-rel) / (float)SPLAT_WINDUP;
				p.vx = dir * (-SPLAT_PULL * u * u);
				p.vy *= decay(0.90f);
			} else {
				// Release: the spring thrusts the slab forward, building
				// speed up to the cap so it whips into the wall.
				p.vx += dir * SPRING_ACCEL * DT;
				if (dir * p.vx > SPLAT_SPEED) p.vx = dir * SPLAT_SPEED;
				p.vy += dir * 0.10f * DT; // springy arc straightens out
			}
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;
		}
		// The leading edge reaching the wall triggers the whole slab at once.
		if (splat_hit(self, s)) {
			s.splat_falling = true;
			splash_from_wall(self, s);
		}
		return;
	}

	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (p.resting) continue;
		p.vy += SPLAT_GRAV * DT;
		p.vx *= decay(0.94f); // scrubbing along the wall bleeds sideways speed
		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;
		float mx = (float)(self.w - 1);
		if (p.x < 0)  { p.x = 0;  p.vx = -p.vx * 0.3f; }
		if (p.x > mx) { p.x = mx; p.vx = -p.vx * 0.3f; }
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

fn void splat_render(void* raw) {
	Model* self = (Model*)raw;
	FxSplat* s = splat_data(self);
	float fade = fx_pile_fade(self, s.fade_start);
	xray::ScreenBuffer* sb = self.canvas;
	// Keep the word's own glyphs throughout — the slab flies in as intact
	// letters, and the splash sprays the letters rather than generic blocks.
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		int col = (int)p.x;
		int row = (int)p.y;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		xray::Color c = gradient_color(self, p.col);
		if (fade < 1.0f) {
			c = xray::color_rgb(
				(char)((float)c.r * fade),
				(char)((float)c.g * fade),
				(char)((float)c.b * fade));
		}
		xray::Style ss = xray::default_style().set_fg(c);
		String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
		sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, ss));
	}
}

fn void splat_teardown(void* raw) {
	Model* self = (Model*)raw;
	FxSplat* s = splat_data(self);
	mem::free(s.stack_top);
	mem::free(s);
	self.fx_state = null;
}

fn Effect splat_effect() {
	return { .name = "SPLAT", .setup = &splat_setup, .step = &splat_step,
		.render = &splat_render, .teardown = &splat_teardown };
}