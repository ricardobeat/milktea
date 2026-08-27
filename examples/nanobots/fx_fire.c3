// FIRE exit, as a self-contained effect.
//
// The word burns. A flame front crawls up from the bottom; each glyph cell
// is the fuel. While a cell burns it sits in place, glows through the
// blackbody colours and spits rising embers; once its fuel is spent it chars
// black and crumbles (falls and fades). The fire spreads row by row until
// the whole text is black and gone.
//
// Everything this effect simulates lives in its own state, so the model only
// sees an opaque `fx_state` pointer it hands back on each hook. setup()
// snapshots the settled word into FireState; from then on the fire never
// touches Model.particles again — it animates its own FireCells and embers
// and draws them straight onto the canvas. The only shared things it reads
// are the canvas, the screen size, and the parsed text (via Model.rows) it
// needs to draw the glyphs still ahead of the flame.
module nanobots;

import xray;
import std::math;

const float FIRE_LIFT = -0.62f;        // upward drift of a rising ember spark
const int FIRE_LIFE = @dur(44);        // how long a glyph cell burns before charring
const int FIRE_ROWDELAY = @dur(9);     // extra ticks of fire delay per row up the
	                                   // word, so the flame creeps from the bottom
const int FIRE_CHAR_FADE = @dur(46);   // ticks a charred piece crumbles and fades
const int FIRE_EMBER_LIFE = @dur(34);  // longest life of an emitted ember
const int EMBER_POOL = 240;            // live-ember slots (ring buffer)
const int EMBER_EMIT = 20;             // 1/EMBER_EMIT chance a burning cell spits
	                                   // an ember each tick (~1-2/s per cell)

// A short-lived spark billowing off a burning fuel cell. Floats up, cools
// through the fire colours, and dies — the visible "flame" above the word.
struct FireEmber {
	float x;
	float y;
	float vx;
	float vy;
	int born;          // frame it was emitted
	int life;          // total frames it lives
	bool active;
}

// One glyph cell of the word, plus the fire state riding along with it. The
// model's shared Particle[] is the *assembling* world; once the fire starts
// it owns its own copy so nothing about the burn leaks back into the model.
struct FireCell {
	float x;           // current x (cells; holds col while burning, falls when charred)
	float y;
	float vx;
	float vy;
	int col;           // the cell it was born at (also the flame column)
	int row;
	int row_src;       // glyph source (for drawing cells ahead of the flame)
	int byte_off;
	int byte_len;
	int ignite_tick;   // frame this cell caught
	int char_tick;     // frame it charred
	float noise_seed;  // flicker / crumble-wobble phase
	bool alive;
	bool charred;
}

// The whole fire simulation: the word's cells and the ember pool it spits.
struct FireState {
	FireCell[] cells;
	FireEmber[EMBER_POOL] embers;
	int ember_head;    // ring cursor into embers[]
	// (alive count is derived as cells iterate, so restart_cycle fires when
	// the last cell crumbles away.)
}

fn FireState* fire_state(Model* self) => (FireState*)self.fx_state;

// Seed a fresh fire: reset the ember pool and snapshot every settled glyph
// cell, staggering each one's ignition so the burn crawls bottom-to-top.
fn void fire_setup(void* raw) {
	Model* self = (Model*)raw;
	FireState* fs = mem::new(FireState);
	fs.cells = mem::new_array(FireCell, self.total);
	for (int i = 0; i < EMBER_POOL; i++) fs.embers[i].active = false;
	fs.ember_head = 0;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		FireCell* c = &fs.cells[i];
		c.alive = true;
		c.charred = false;
		c.col = p.col;
		c.row = p.row;
		c.row_src = p.row_src;
		c.byte_off = p.byte_off;
		c.byte_len = p.byte_len;
		c.x = (float)p.col;
		c.y = (float)p.row;
		c.vx = 0;
		c.vy = 0;
		// The fire creeps up from the bottom: the lower the row, the sooner
		// it catches. Delay grows by FIRE_ROWDELAY per row, plus a little
		// jitter so a row doesn't light as one flat line — this is what
		// makes the burn crawl over the word instead of flashing at once.
		int from_bottom = self.text_y + self.text_h - p.row;
		c.ignite_tick = self.frame + FIRE_ROWDELAY * from_bottom + @dur(rand() % 7);
		// Per-block phase for the flame flicker and the char wobble.
		c.noise_seed = rand_range(0.0f, 1000.0f);
	}
	self.fx_state = fs;
	self.phase = Phase.FIRE;
	self.phase_frame = self.frame;
}

// Release one short-lived ember from a burning fuel cell, reusing a slot in
// the ring buffer if one is free. Embers are the airborne flame above the
// word; the fuel cell itself keeps burning below.
fn void fire_emit_ember(Model* self, FireState* fs, int col, int row) {
	for (int k = 0; k < EMBER_POOL; k++) {
		int idx = (fs.ember_head + k) % EMBER_POOL;
		FireEmber* e = &fs.embers[idx];
		if (e.active) continue;
		e.active = true;
		e.x = (float)col + rand_range(-0.3f, 0.3f);
		e.y = (float)row + rand_range(-0.1f, 0.2f);
		e.vx = rand_range(-0.6f, 0.6f);
		e.vy = -rand_range(1.4f, 3.2f);
		e.born = self.frame;
		e.life = @dur(12) + rand() % (FIRE_EMBER_LIFE - 12);
		fs.ember_head = (idx + 1) % EMBER_POOL;
		return;
	}
}

// Advance the fire one frame: rise/cool the embers, burn fuel cells (spitting
// embers while alight), then char spent cells into falling crumble. Once the
// last cell is gone, hand control back to the model for the next cycle.
fn void fire_step(void* raw) {
	Model* self = (Model*)raw;
	FireState* fs = fire_state(self);

	// Embers rise, drift on a little turbulence, cool (buoyancy eases), expire.
	for (int i = 0; i < EMBER_POOL; i++) {
		FireEmber* e = &fs.embers[i];
		if (!e.active) continue;
		int age = self.frame - e.born;
		if (age >= e.life) { e.active = false; continue; }
		float t = (float)age / (float)e.life;
		float m = 1.0f - t;
		// Uprise eases as the spark cools; a slow wander drifts it sideways
		// so the plume billows instead of rising as a rigid column.
		e.vy *= 0.995f;
		e.vx += math::sin((float)self.frame * 0.14f + (float)i) * 0.24f * m * DT;
		e.vy += FIRE_LIFT * m * DT;
		e.x += e.vx * 0.25f * DT;
		e.y += e.vy * 0.25f * DT;
		if (e.y < -1.0f) e.active = false;
	}

	// Cells: still-ahead glyphs wait, burning ones sit and spit embers, and
	// charred ones crumble (fall, wobble, fade).
	int alive = 0;
	for (int i = 0; i < fs.cells.len; i++) {
		FireCell* c = &fs.cells[i];
		if (!c.alive) continue;
		alive++;
		if (c.charred) {
			int c_age = self.frame - c.char_tick;
			if (c_age >= FIRE_CHAR_FADE || c.y > (float)self.h + 1.0f) {
				c.alive = false;
				alive--;
				continue;
			}
			c.vy += 0.10f * DT;
			c.vx += math::sin((float)c_age * 0.5f + c.noise_seed) * 0.03f * DT;
			c.vx *= 0.96f;
			c.x += c.vx * 0.25f * DT;
			c.y += c.vy * 0.25f * DT;
			continue;
		}
		int age = self.frame - c.ignite_tick;
		if (age < 0) continue; // still ahead of the flame — no work yet
		if (age >= FIRE_LIFE) {
			// Fuel spent: char into a crumbling piece and let it fall.
			c.charred = true;
			c.char_tick = self.frame;
			c.vy = rand_range(0.3f, 0.8f);
			c.vx = rand_range(-0.4f, 0.4f);
			continue;
		}
		c.noise_seed += 0.01f; // shimmer phase advances while it burns
		if ((rand() % EMBER_EMIT) == 0) fire_emit_ember(self, fs, c.col, c.row);
	}

	if (alive == 0) self.restart_cycle();
}

// Draw the fire. Cells ahead of the flame keep their real glyph; burning
// cells glow through the blackbody ramp while holding still; charred pieces
// fall as fading black blocks; ember sparks rise above it all.
fn void fire_render(void* raw) {
	Model* self = (Model*)raw;
	FireState* fs = fire_state(self);
	xray::ScreenBuffer* sb = self.canvas;

	for (int i = 0; i < fs.cells.len; i++) {
		FireCell* c = &fs.cells[i];
		if (!c.alive) continue;
		if (c.charred) {
			// Crumble: a burnt-out piece fades from dark red to black as it
			// falls, so the letters blacken before the char drifts clear.
			int c_age = self.frame - c.char_tick;
			float t = (float)c_age / (float)FIRE_CHAR_FADE;
			if (t > 1.0f) t = 1.0f;
			int col = (int)c.x;
			int row = (int)c.y;
			if (col < 0 || col >= self.w) continue;
			if (row < 0 || row >= self.h) continue;
			float dim = 1.0f - t;
			// A touch of residual red so the char still reads as burnt, not
			// just erased.
			xray::Color cc = xray::color_rgb((char)(70.0f * dim), (char)(10.0f * dim), 0);
			xray::Style fsy = xray::default_style().set_fg(cc);
			sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, fsy));
			continue;
		}
		int age = self.frame - c.ignite_tick;
		if (age < 0) {
			// Ahead of the flame: draw the real glyph, untouched.
			if (c.col < 0 || c.col >= self.w) continue;
			if (c.row < 0 || c.row >= self.h) continue;
			xray::Style fsy = xray::default_style().set_fg(gradient_color(self, c.col));
			String g = glyph_at(self.rows, c.row_src, c.byte_off, c.byte_len);
			sb.set_cell((sz)c.col, (sz)c.row, xray::new_cell(g, 1, fsy));
			continue;
		}
		if (age > FIRE_LIFE) age = FIRE_LIFE;
		float t = (float)age / (float)FIRE_LIFE;
		if (t >= 1.0f) continue; // about to char; fuel is spent
		// Flicker: a fast per-block wobble on the temperature, so
		// neighbouring cells aren't locked to the same shade. Real flame is
		// noisy, and a perfectly smooth ramp is what makes a synthetic fire
		// look like a gradient chart.
		float flick = math::sin((float)self.frame * 0.55f + c.noise_seed * 6.3f);
		float tt = t + flick * 0.05f;
		if (tt < 0.0f) tt = 0.0f;
		if (tt > 1.0f) tt = 1.0f;
		xray::Color cc;
		if (tt < 0.10f) {
			// Ignition: the fuel's own colour flashes to white-hot.
			float u = tt / 0.10f;
			xray::Color base = gradient_color(self, c.col);
			cc = xray::color_rgb(
				(char)((float)base.r + (255.0f - (float)base.r) * u),
				(char)((float)base.g + (250.0f - (float)base.g) * u),
				(char)((float)base.b + (225.0f - (float)base.b) * u));
		} else if (tt < 0.28f) {
			// White-hot core cooling to yellow.
			float u = (tt - 0.10f) / 0.18f;
			cc = xray::color_rgb(255, (char)(250.0f - 26.0f * u), (char)(225.0f - 190.0f * u));
		} else if (tt < 0.60f) {
			// Yellow through amber to orange.
			float u = (tt - 0.28f) / 0.32f;
			cc = xray::color_rgb(255, (char)(224.0f - 106.0f * u), (char)(35.0f * (1.0f - u)));
		} else if (tt < 0.85f) {
			// Orange to deep red, still bright.
			float u = (tt - 0.60f) / 0.25f;
			cc = xray::color_rgb((char)(255.0f - 45.0f * u), (char)(118.0f - 88.0f * u), 0);
		} else {
			// Dying fuel: dims to black, smouldering rather than fading
			// evenly — flicker is strongest at the end.
			float u = (tt - 0.85f) / 0.15f;
			float dim = (1.0f - u) * (0.72f + 0.28f * flick);
			if (dim < 0.0f) dim = 0.0f;
			cc = xray::color_rgb((char)(210.0f * dim), (char)(30.0f * dim), 0);
		}
		int cell_col = c.col;
		int cell_row = c.row;
		if (cell_col < 0 || cell_col >= self.w) continue;
		if (cell_row < 0 || cell_row >= self.h) continue;
		xray::Style fsy = xray::default_style().set_fg(cc);
		sb.set_cell((sz)cell_col, (sz)cell_row, xray::new_cell("█", 1, fsy));
	}

	// Embers: the airborne sparks above the fire, drawn after the fuel so
	// they read as flame rising off the burning word.
	xray::Style er = xray::default_style();
	for (int i = 0; i < EMBER_POOL; i++) {
		FireEmber* e = &fs.embers[i];
		if (!e.active) continue;
		int age = self.frame - e.born;
		if (age < 0 || age >= e.life) continue;
		int col = (int)e.x;
		int row = (int)e.y;
		if (col < 0 || col >= self.w) continue;
		if (row < 0 || row >= self.h) continue;
		float t = (float)age / (float)e.life;
		float purs = math::sin((float)self.frame * 0.9f + (float)i);
		xray::Color cc;
		if (t < 0.30f) {
			cc = xray::color_rgb(255, (char)(235.0f + 20.0f * purs), (char)(150.0f + 50.0f * purs));
		} else if (t < 0.65f) {
			float u = (t - 0.30f) / 0.35f;
			cc = xray::color_rgb(255, (char)(235.0f - 125.0f * u), (char)(150.0f - 120.0f * u));
		} else {
			float u = (t - 0.65f) / 0.35f;
			float dim = (1.0f - u) * (0.55f + 0.45f * purs);
			if (dim < 0.0f) dim = 0.0f;
			cc = xray::color_rgb((char)(28.0f * dim), (char)(10.0f * dim), 0);
		}
		sb.set_cell((sz)col, (sz)row, xray::new_cell("█", 1, er.set_fg(cc)));
	}
}

// Release the state this effect allocated and tell the model it's inactive.
fn void fire_teardown(void* raw) {
	Model* self = (Model*)raw;
	FireState* fs = fire_state(self);
	mem::free(fs.cells);
	mem::free(fs);
	self.fx_state = null;
}

// The effect as the model sees it: a name and four lifecycle hooks.
fn Effect fire_effect() {
	return {
		.name = "FIRE",
		.setup = &fire_setup,
		.step = &fire_step,
		.render = &fire_render,
		.teardown = &fire_teardown,
	};
}