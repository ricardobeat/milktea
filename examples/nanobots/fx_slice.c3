// SLICE exit: horizontal strips peel off opposite sides. A whole row moves
// as one rigid slab — every block in it shares the exact same eased
// trajectory — so the word reads as slices sliding apart, not particles
// trickling out. Rows alternate sides and launch in sequence.
module nanobots;

import xray;
import std::math;

// A row eases off with an ease-out so it launches gently, accelerates, and
// decelerates as it clears the edge, rather than gliding at constant speed.
const int SLICE_STAGGER = @dur(6);  // ticks between rows peeling off
const int SLICE_DUR = @dur(32);     // ticks a row takes to travel clear

struct FxSlice {
	int flip;   // which way the topmost row goes; rows alternate from there
}

fn FxSlice* slice_data(Model* self) => (FxSlice*)self.fx_state;

fn void slice_setup(void* raw) {
	Model* self = (Model*)raw;
	FxSlice* s = mem::new(FxSlice);
	s.flip = rand() % 2 == 0 ? 1 : -1;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = 0;
		p.vy = 0;
		// Launch frame per row; direction is derived from the row band, so
		// every block in a row shares one launch and one direction.
		int band = p.row - self.text_y;
		p.spawn_tick = self.frame + SLICE_STAGGER * band;
	}
	self.fx_state = s;
	self.phase = Phase.SLICE;
	self.phase_frame = self.frame;
}

// A per-row eased offset: 0 before launch, rising over SLICE_DUR to a
// full travel that clears the row off screen.
fn float slice_offset(Model* self, int band, int frame) {
	int lauch = self.phase_frame + SLICE_STAGGER * band;
	float t = (float)(frame - lauch) / (float)SLICE_DUR;
	if (t <= 0.0f) return 0.0f;
	if (t > 1.0f) t = 1.0f;
	// ease-out cubic
	float e = 1.0f - math::pow(1.0f - t, 3.0f);
	return e * (float)(self.w + 8);
}

fn void slice_step(void* raw) {
	Model* self = (Model*)raw;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		int band = p.row - self.text_y;
		int lauch = self.phase_frame + SLICE_STAGGER * band;
		if (self.frame - lauch >= SLICE_DUR) p.alive = false;
	}
	if (!self.any_alive()) self.restart_cycle();
}

fn void slice_render(void* raw) {
	Model* self = (Model*)raw;
	FxSlice* s = slice_data(self);
	xray::ScreenBuffer* sb = self.canvas;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		int band = p.row - self.text_y;
		// Even rows read as right-going, odd as left-going, alternating.
		float dir = (float)(((band & 1) == 0 ? 1 : -1) * s.flip);
		float off = slice_offset(self, band, self.frame);
		float x = (float)p.col + dir * off;
		int col = (int)x;
		int row = (int)p.y;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		xray::Style ss = xray::default_style().set_fg(gradient_color(self, p.col));
		String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
		sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, ss));
	}
}

fn void slice_teardown(void* raw) {
	Model* self = (Model*)raw;
	mem::free(slice_data(self));
	self.fx_state = null;
}

fn Effect slice_effect() {
	return { .name = "SLICE", .setup = &slice_setup, .step = &slice_step,
		.render = &slice_render, .teardown = &slice_teardown };
}