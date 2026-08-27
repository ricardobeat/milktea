// IMPLODE exit: a CRT losing power. The picture snaps to a hot horizontal
// line, burns, collapses to a dot that flares and fades.
module nanobots;

import xray;

struct FxImplode {
	float line_y;
	int line_frame;
	int crt_stage;
	int crt_stage_frame;
	float crt_dot;
	float crt_swell;
}

fn FxImplode* implode_data(Model* self) => (FxImplode*)self.fx_state;

fn bool impl_on_line(Model* self, FxImplode* s) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		float dy = p.y - s.line_y;
		if (dy > 0.3f || dy < -0.3f) return false;
	}
	return true;
}

fn void implode_setup(void* raw) {
	Model* self = (Model*)raw;
	FxImplode* s = mem::new(FxImplode);
	s.line_y = (float)self.text_y + (float)self.text_h * 0.5f;
	s.line_frame = 0;
	s.crt_stage = 0;
	s.crt_stage_frame = self.frame;
	s.crt_dot = 0.0f;
	s.crt_swell = 1.0f;
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
		// Rows further from the centreline arrive with more speed, so the
		// squash reads as the whole frame being yanked inward at once.
		p.wander = rand_range(-0.35f, 0.35f);
	}
	self.fx_state = s;
	self.phase = Phase.IMPLODE;
	self.phase_frame = self.frame;
}

fn void implode_step(void* raw) {
	Model* self = (Model*)raw;
	FxImplode* s = implode_data(self);

	// Stage timings are what make this a shutdown rather than a collapse.
	int held = self.frame - s.crt_stage_frame;
	if (s.crt_stage == 0) {
		float t = (float)held / (float)SWELL_DURATION;
		if (t > 1.0f) t = 1.0f;
		s.crt_swell = 1.0f + (SWELL_MAX - 1.0f) * (t * (2.0f - t));
		if (held >= SWELL_DURATION) {
			s.crt_stage = 1;
			s.crt_stage_frame = self.frame;
		}
	} else if (s.crt_stage == 1) {
		if (impl_on_line(self, s) && held > @dur(6)) {
			s.crt_stage = 2;
			s.crt_stage_frame = self.frame;
			s.line_frame = self.frame;
		}
	} else if (s.crt_stage == 2) {
		if (held >= LINE_HOLD) {
			s.crt_stage = 3;
			s.crt_stage_frame = self.frame;
		}
	} else if (s.crt_stage == 3) {
		if (!self.any_alive()) {
			s.crt_stage = 4;
			s.crt_stage_frame = self.frame;
			s.crt_dot = 1.0f; // flare at full white
		}
	} else {
		s.crt_dot -= 1.0f / (float)DOT_HOLD;
		if (s.crt_dot <= 0.0f) {
			s.crt_dot = 0.0f;
			self.restart_cycle();
			return;
		}
	}

	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (s.crt_stage == 0) {
			// Swelling: blocks hold their rows; the render stretches.
		} else if (s.crt_stage == 1) {
			// A stiff, underdamped spring slams into the line and rings.
			float dy = s.line_y - p.y;
			p.vy += dy * 0.55f * DT;
			p.vy *= decay(0.72f);
			p.y += p.vy * 0.25f * DT;
		} else if (s.crt_stage == 2) {
			// The line burns; blocks jitter so it looks live.
			p.y = s.line_y + p.wander * 0.15f;
		} else if (s.crt_stage == 3) {
			// Horizontal collapse, accelerating toward the centre.
			float cx = (float)self.text_x + (float)self.text_w * 0.5f;
			float dx = cx - p.x;
			p.vx += dx * 0.42f * DT;
			p.vx *= decay(0.74f);
			p.x += p.vx * 0.25f * DT;
			p.y = s.line_y;
			if (dx > -0.8f && dx < 0.8f) p.alive = false;
		} else {
			p.y = s.line_y;
		}
	}
}

fn void implode_render(void* raw) {
	Model* self = (Model*)raw;
	FxImplode* s = implode_data(self);
	xray::ScreenBuffer* sb = self.canvas;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		float px = p.x;
		if (s.crt_stage == 0) {
			float scx = (float)self.text_x + (float)self.text_w * 0.5f;
			px = scx + (p.x - scx) * s.crt_swell;
		}
		int col = (int)px;
		int row = (int)p.y;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		xray::Color c = gradient_color(self, p.col);
		float heat;
		if (s.crt_stage == 0) {
			heat = 0.30f + 0.45f * (s.crt_swell - 1.0f) / (SWELL_MAX - 1.0f);
		} else {
			heat = 0.85f;
		}
		c = xray::color_rgb(
			(char)((float)c.r + (255.0f - (float)c.r) * heat),
			(char)((float)c.g + (255.0f - (float)c.g) * heat),
			(char)((float)c.b + (255.0f - (float)c.b) * heat));
		xray::Style is = xray::default_style().set_fg(c);
		String g = s.crt_stage >= 2 ? "\u2580" : "\u2588";
		sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, is));
	}
	if (s.crt_dot > 0.0f) {
		int dc = (int)((float)self.text_x + (float)self.text_w * 0.5f);
		int dr = (int)s.line_y;
		if (dc >= 0 && dc < self.w && dr >= 0 && dr < self.h) {
			float v = s.crt_dot;
			xray::Color dcol = xray::color_rgb(
				(char)(255.0f * v), (char)(255.0f * v), (char)(235.0f * v));
			xray::Style ds2 = xray::default_style().set_fg(dcol);
			sb.set_cell((sz)dc, (sz)dr, xray::new_cell("\u25AA", 1, ds2));
		}
	}
}

fn void implode_teardown(void* raw) {
	Model* self = (Model*)raw;
	mem::free(implode_data(self));
	self.fx_state = null;
}

fn Effect implode_effect() {
	return { .name = "IMPLODE", .setup = &implode_setup, .step = &implode_step,
		.render = &implode_render, .teardown = &implode_teardown };
}