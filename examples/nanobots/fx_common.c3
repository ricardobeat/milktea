module nanobots;

import xray;
import std::math;

// Pile fade for effects that end by accumulating a settled heap (FALL, SPLAT,
// TOPPLE, SPHERES). Returns 1.0 before the pile starts fading, then ramps
// down to 0 over FADE_DURATION frames once fade_start has passed.
fn float fx_pile_fade(Model* self, int fade_start) {
	if (fade_start != 0 && self.frame > fade_start) {
		float f = 1.0f - (float)(self.frame - fade_start) / (float)FADE_DURATION;
		if (f < 0.0f) f = 0.0f;
		return f;
	}
	return 1.0f;
}

// Blit the flying blocks as half-block particles. Used by any effect whose
// cells travel as free particles (EXPLODE, FALL, SLICE, VORTEX, TOPPLE after
// the crash, SPLAT). A bot carries the colour of the cell it's heading for,
// so it arrives already matching the word. `fade` dims it (during a pile
// fade-out); pass 1.0 for effects that don't fade.
fn void fx_draw_moving(Model* self, float fade) {
	xray::ScreenBuffer* sb = self.canvas;
	for (sz i = 0; i < self.half_mask.len; i++) self.half_mask[i] = 0;

	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue; // not sprayed out yet
		if (p.settled) continue;
		if (p.resting) continue;
		int cell_col = (int)p.x;
		int half_row = (int)(p.y * 2.0f);   // vertical position in half-cells
		int cell_row = half_row / 2;
		if (cell_col < 0 || cell_col >= self.w) continue;
		if (cell_row < 0 || cell_row >= self.h) continue;
		int idx = cell_row * self.w + cell_col;
		self.half_mask[idx] |= (char)(half_row % 2 == 0 ? 1 : 2);
		xray::Color pc = gradient_color(self, p.col);
		if (fade < 1.0f) {
			pc = xray::color_rgb(
				(char)((float)pc.r * fade),
				(char)((float)pc.g * fade),
				(char)((float)pc.b * fade));
		}
		self.half_col[idx] = pc;
	}

	for (int row = 0; row < self.h; row++) {
		for (int col = 0; col < self.w; col++) {
			int idx = row * self.w + col;
			char mask = self.half_mask[idx];
			if (mask == 0) continue;
			String g = "\u2588";              // both halves
			if (mask == 1) g = "\u2580";      // upper half
			if (mask == 2) g = "\u2584";      // lower half
			xray::Style s2 = xray::default_style().set_fg(self.half_col[idx]).set_bg(xray::color_transparent());
			sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, s2));
		}
	}
}

// Convenience accessor for model -> effect state.
macro void* fx_blob(Model* self) => self.fx_state;
