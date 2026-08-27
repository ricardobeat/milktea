// EXPLODE exit: radial shatter. The word blasts outward from its middle and
// coasts off screen. No extra state beyond the shared particle board.
module nanobots;

import xray;
import std::math;

fn void explode_setup(void* raw) {
	Model* self = (Model*)raw;
	float cx = (float)self.text_x + (float)self.text_w * 0.5f;
	float cy = (float)self.text_y + (float)self.text_h * 0.5f;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		float dx = p.x - cx;
		float dy = (p.y - cy) * 2.0f; // cells are ~2x taller than wide
		float angle = math::atan2(dy, dx) + rand_range(-0.5f, 0.5f);
		float speed = rand_range(9.0f, 22.0f);
		p.vx = math::cos(angle) * speed;
		p.vy = math::sin(angle) * speed * 0.55f;
	}
	self.phase = Phase.BLOW;
	self.phase_frame = self.frame;
	self.fx_state = null;
}

fn void explode_step(void* raw) {
	Model* self = (Model*)raw;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue;
		// No pull, no walls — coast outward until off screen, then retire.
		p.vx *= decay(0.995f);
		p.vy *= decay(0.995f);
		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;
		if (p.x < -4.0f || p.x > (float)self.w + 4.0f
				|| p.y < -4.0f || p.y > (float)self.h + 4.0f) {
			p.alive = false;
		}
	}
	if (!self.any_alive()) self.restart_cycle();
}

fn void explode_render(void* raw) {
	fx_draw_moving((Model*)raw, 1.0f);
}

fn Effect explode_effect() {
	return { .name = "EXPLODE", .setup = &explode_setup, .step = &explode_step, .render = &explode_render };
}