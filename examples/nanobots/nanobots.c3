module nanobots;

import milktea;
import xray;
import glaze;
import std::io;
import std::math;
import std::collections;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

// Rendered `milktea` from `figlet -f phm-slanted.flf` (Philippe Majerus,
// https://github.com/PhMajerus/FIGfonts). The font uses Unicode 13 sextant
// characters from the Symbols for Legacy Computing block, so each character
// in the file is one terminal cell that draws a slanted block — no half-
// height packing needed. 6 rows tall.
//
// A "filled" sextant (🭅, 🭋, █, 🭛, 🭡, 🭞, 🭚, ▐) is part of the
// text glyph; a space is empty.
const char[] EMBED_TEXT = $embed("milktea.txt");

// 48fps. Everything here was tuned at 20fps, so DT is the ratio between the
// two: forces and velocities are scaled by it so motion covers the same
// ground per second, and tick-count durations are scaled by 1/DT so they
// last the same wall-clock time. Damping is per-tick and exponential, so it
// gets pow(damp, DT) via the `decay` helper rather than a plain multiply —
// multiplying a damping factor by DT would make things stop faster, not
// slower.
const int FRAME_MS = 21;        // ~48fps
const float DT = 20.0f * (float)FRAME_MS / 1000.0f; // sim-ticks per frame

// Convert a duration tuned in 20fps ticks into frames at the current rate.
macro int @dur(#ticks) => (int)((float)(#ticks) / DT);

// Per-frame survival of a per-tick damping factor.
fn float decay(float per_tick) {
	return (float)math::pow((double)per_tick, (double)DT);
}

const int PARTICLES_PER_WAVE = 20; // 7 rounds of 20 = 140 blocks; user-tunable
const int EMIT_COOLDOWN = @dur(42);   // ~2.1s between waves at 50ms/tick
const int HOLD_DURATION = @dur(60);   // ticks the finished word stays up (~3s)
const int BUILD_TIMEOUT = @dur(600);  // safety net: if a straggler somehow never
                                // settles, snap it home rather than stall
const float PULL_MAX = 0.9f;    // ceiling on the spring force, so a thrown
                                // bot coasts before the pull takes over
const int SPAWN_STAGGER = @dur(2);    // ticks between bots within one wave, so a wave
                                // sprays out over ~2s instead of popping at once
const float GRAVITY = 1.4f;     // cells/tick^2 in the FALL exit
const float BOUNCE = 0.32f;     // energy kept when a block hits the pile
const int FADE_DURATION = @dur(45);   // ticks the settled pile takes to fade out
const int DISSOLVE_FLICKERS = 5; // noise flashes a block shows before blanking
const int DISSOLVE_STEP = @dur(3);    // ticks per flicker frame
const float WIND_ACCEL = 2.2f;  // sideways force in the SHEAR exit
const float TOPPLE_ACCEL = 0.0016f; // angular accel of the falling slab
const int LINE_HOLD = @dur(10);       // ticks the hot line holds before it collapses
const int DOT_HOLD = @dur(16);        // ticks the dot lingers after the flare
const int SWELL_DURATION = @dur(22);  // ticks the picture stretches and brightens
const float SWELL_MAX = 1.5f;   // how far the picture widens before collapsing
const float SPLAT_SPEED = 15.0f; // top speed of the thrown slab
const int SPLAT_WINDUP = @dur(14);     // ticks of pull-back before the release
const float SPLAT_SPLASH = 7.0f; // how hard blocks spray along the wall
const float FIRE_LIFT = -0.62f;  // upward drift of a rising ember spark
const int FIRE_LIFE = @dur(44);  // how long a glyph cell burns (its fuel) before charring
const int FIRE_ROWDELAY = @dur(9);  // extra ticks of fire delay per row up the word,
	                            // so the flame creeps from the bottom rather than
	                            // lighting everything at once
const int FIRE_CHAR_FADE = @dur(46); // ticks a charred piece crumbles and fades
const int FIRE_EMBER_LIFE = @dur(34); // longest life of an emitted ember
const int EMBER_POOL = 240;      // live-ember slots (ring buffer)
const int EMBER_EMIT = 20;       // 1/EMBER_EMIT chance a burning cell spits an
	                             // ember each tick (~1-2/s per cell)
const float BALL_BOUNCE = 0.82f; // energy a sphere keeps per floor bounce
const float BALL_REST = 0.7f;    // below this impact speed a sphere stops
const float BALL_RADIUS = 0.75f; // contact distance between two spheres, in
                                 // screen-square units (x is halved to match
                                 // the 2:1 cell aspect)
const int GLOW_RADIUS = 3;      // cells the bloom reaches past the glyphs
const int BADGE_DURATION = @dur(30);  // ticks the exit name stays on screen
	                              // after TAB before fading from view
const int DUST_COUNT = 26;      // motes left hanging after the word goes


// Each cell is one UTF-8 character. We scan the embedded text row by row
// to extract target positions for the particle cloud.
struct Particle {
	int col;       // target cell column
	int row;       // target cell row
	int row_src;   // index into the rows[] List — the source row
	int byte_off;  // byte offset of the glyph's first byte in that row
	int byte_len;  // byte length of the glyph (1-4)
	float x;       // current x (cell col as float)
	float y;       // current y (cell row as float)
	float vx;
	float vy;
	int spawn_tick;
	float attract;     // per-bot spring constant pulling it toward its cell
	float damp;        // per-bot damping — the spread in this and in attract
	                   // is what staggers arrival and varies the springiness
	float wander;      // current wander heading, radians
	float wander_rate; // how fast that heading turns
	bool alive;
	bool settled;
	bool resting;      // FALL exit: landed on the pile, no longer moving
	int fall_col;      // FALL exit: column it is stacking in
	float noise_seed;  // DISSOLVE exit: per-block offset into the noise glyphs
	int ignite_tick;   // FIRE exit: frame this block caught. Its age drives
	                   // the colour ramp, and once it passes FIRE_LIFE the
	                   // block chars and crumbles.
	bool charred;      // FIRE exit: this fuel cell has burnt out and is now
	                   // crumbling (falling) away
	int char_tick;     // FIRE exit: frame it charred, so it can fade out
	int fire_col;      // FIRE exit: column of the fuel cell (used when it
	                   // shimmers in place and when it crumbles)
}

// A short-lived spark billowing off a burning fuel cell. Floats up, cools
// through the fire colours, and dies — the visible "flame" above the word.
struct Ember {
	float x;
	float y;
	float vx;
	float vy;
	int born;          // frame it was emitted
	int life;          // total frames it lives
	bool active;
}

// The word builds up, holds, then blows apart and rebuilds — forever.
enum Phase {
	BUILD,
	HOLD,
	BLOW,
	FALL,
	SLICE,
	VORTEX,
	DISSOLVE,
	SHEAR,
	TOPPLE,
	IMPLODE,
	SPLAT,
	FIRE,
	SPHERES,
}

// How the word leaves the screen at the end of a cycle. Picked at random
// each time so successive cycles don't repeat the same exit.
enum Exit {
	EXPLODE,
	COLLAPSE,
	SLICE,
	VORTEX,
	DISSOLVE,
	SHEAR,
	TOPPLE,
	IMPLODE,
	SPLAT,
	FIRE,
	SPHERES,
}
const int EXIT_COUNT = 13;

struct Corner {
	int col;
	int row;
}

struct Model {
	xray::ScreenBuffer* canvas;
	int w;
	int h;
	int frame;
	int last_emit_frame;
	Phase phase;
	int phase_frame;           // frame the current phase started
	int cycle;                 // completed build/blow cycles
	int next_emit_index;       // cursor into self.particles[]
	Corner corner;
	Particle[] particles;
	int total;
	int text_x;                // top-left col of rendered text
	int text_y;
	int text_w;
	int text_h;
	char[] half_mask;          // per-cell half-block occupancy for flying bots:
	                           // bit 0 = upper half, bit 1 = lower half
	xray::Color[] half_col;    // colour for those cells
	List{String} rows;         // parsed source lines, indexed by row_src
	bool rows_ready;
	int[] stack_top;           // FALL exit: next free half-row per column,
	                           // measured in half-cells from the top
	int fade_start;            // frame the pile started fading
	Exit last_exit;            // previous cycle's exit, never picked twice
	bool has_last_exit;        // false until the first exit has run
	bool exit_forced;          // TAB queued a specific exit for the next run.
	                           // One-shot: consumed on use, so the cycle
	                           // after a TAB preview is random again.
	Exit forced_exit;          // the queued one
	bool exit_previewed;       // the badge shows a TAB pick rather than a
	                           // random draw — only affects its colour
	int preview_at;            // frame a queued TAB preview fires (0 = none).
	                           // The pause lets you read the badge and see
	                           // the assembled word before it goes.
	int badge_until;           // frame the exit-name badge disappears again.
	                           // TAB flashes the name briefly rather than
	                           // pinning it up for the whole cycle.
	float[] glow;              // per-cell bloom intensity, built by seeding
	                           // the glyph cells and spreading outward
	float[DUST_COUNT] dust_x;  // motes left behind after the flash
	float[DUST_COUNT] dust_y;
	float[DUST_COUNT] dust_v;  // brightness, so they twinkle out
	Ember[EMBER_POOL] fire_embers;   // FIRE exit: sparks billowing off the
	                                 // burning fuel cells
	int fire_ember_head;       // ring cursor into fire_embers[]
	float hole_x;              // VORTEX exit: centre of the hole, in cells
	float hole_y;
	float hole_r;              // current visual radius, grows as it opens
	float bar_dir;             // SHEAR/TOPPLE: which way the gust blows or
	                           // the slab tips. +1 right, -1 left.
	float topple_angle;        // TOPPLE exit: current rotation, radians
	float topple_vel;          // angular velocity
	float pivot_x;             // corner the slab rotates about
	float pivot_y;
	bool topple_shattered;     // true once the slab has hit the floor
	float line_y;              // IMPLODE exit: the centreline blocks collapse to
	int line_frame;            // frame the line finished compressing (0 = not yet)
	int crt_stage;             // IMPLODE: 0=swell, 1=squash, 2=hold line,
	                           // 3=collapse to dot, 4=dot lingers
	float crt_swell;           // horizontal stretch during stage 0, 1 = normal
	int crt_stage_frame;       // frame the current stage began
	float crt_dot;             // brightness of the final dot, 1 at the flare
	float splat_wall;          // SPLAT exit: x of the wall blocks are thrown
	                           // at — 0 for the left edge, w-1 for the right
	bool splat_falling;        // true once the slab has hit and broken up
	int splat_launch;          // frame the throw was released; before it the
	                           // slab is winding up in the opposite direction
	int turbo_until;           // frame the 4x speed-up lapses. Terminals only
	                           // report key *release* under the kitty
	                           // protocol, so "held" is inferred from auto-
	                           // repeat: each space press extends this a few
	                           // ticks, and letting go lets it run out.
	xray::Color[3] palette;    // 0=lime, 1=light blue, 2=pale yellow
}

// Read one Unicode codepoint from the embedded file, using the standard
// library's UTF-8 decoder. Returns 0 on end-of-iteration, but always
// advances *k past the consumed bytes (or by 1 on empty input) so the
// caller's loop makes progress.
fn long read_codepoint(String s, int* k) {
	if (*k >= s.len) return 0;
	StringIterator it;
	it.utf8 = s;
	it.current = (sz)*k;
	int start = *k;
	Char32? cp_opt = it.next();
	*k = (int)it.current;
	Char32 cp = cp_opt ?? (Char32)0;
	if (*k == start) *k += 1; // safety: always advance
	return (long)cp;
}

fn bool is_sextant_filled(long cp) {
	// phm-slanted draws with the Symbols for Legacy Computing block
	// (U+1FB00..U+1FB8B: sextants, diagonals and triangular shades) plus
	// the classic block elements █ ▐ ▌ ▄ ▀ from U+2580..U+259F.
	if (cp >= 0x1FB00 && cp <= 0x1FB8B) return true;
	if (cp >= 0x2580 && cp <= 0x259F) return true;
	return false;
}

fn void Model.parse_text(Model* self) {
	// Split the embedded file into rows by '\n'. Each row is a slice into
	// the embedded blob, so no copying (and no leaking) is needed.
	String text = (String)EMBED_TEXT;
	if (self.rows_ready) {
		self.rows.clear();
	} else {
		self.rows.init(mem);
		self.rows_ready = true;
	}
	int line_start = 0;
	for (int i = 0; i <= text.len; i++) {
		if (i == text.len || text[i] == (char)0x0A) {
			self.rows.push(text[line_start:(sz)(i - line_start)]);
			line_start = i + 1;
		}
	}
	List{String} rows = self.rows;
	int row_count = (int)rows.len();

	// First pass: bounding box and count.
	int min_col = 0x7fffffff;
	int max_col = -1;
	int min_row = 0x7fffffff;
	int max_row = -1;
	int count = 0;
	for (int r = 0; r < row_count; r++) {
		String line = rows[r];
		int k = 0;
		int col = 0;
		while (k < line.len) {
			long cp = read_codepoint(line, &k);
			if (cp == 0x20) { col++; continue; }
			if (!is_sextant_filled(cp)) continue;
			if (col < min_col) min_col = col;
			if (col > max_col) max_col = col;
			if (r < min_row) min_row = r;
			if (r > max_row) max_row = r;
			count++;
			col++;
		}
	}
	if (self.particles.len) {
		mem::free(self.particles);
		self.particles = {};
	}
	if (max_col < 0 || count == 0) { self.total = 0; return; }
	self.text_w = max_col - min_col + 1;
	self.text_h = max_row - min_row + 1;
	self.text_x = (self.w - self.text_w) / 2;
	self.text_y = (self.h - self.text_h) / 2 - 1;
	self.total = count;
	self.particles = mem::new_array(Particle, (sz)self.total);

	// Second pass: collect targets. byte_off/byte_len point into the source
	// row String so we can render the actual seXtant glyph at the cell.
	int idx = 0;
	for (int r = min_row; r <= max_row && idx < self.total; r++) {
		String line = rows[r];
		int k = 0;
		int col = 0;
		while (k < line.len && idx < self.total) {
			int glyph_start = k;
			long cp = read_codepoint(line, &k);
			if (cp == 0x20) { col++; continue; }
			if (!is_sextant_filled(cp)) continue;
			if (col < min_col) { col++; continue; }
			Particle* p = &self.particles[idx];
			p.col = self.text_x + (col - min_col);
			p.row = self.text_y + (r - min_row);
			p.row_src = r;
			p.byte_off = glyph_start;
			p.byte_len = k - glyph_start;
			p.x = (float)p.col;
			p.y = (float)p.row;
			p.vx = 0;
			p.vy = 0;
			p.spawn_tick = 0;
			p.attract = 0;
			p.damp = 0;
			p.wander = 0;
			p.wander_rate = 0;
			p.alive = false;
			p.settled = false;
			idx++;
			col++;
		}
	}

	// Sort bottom-up, then left-to-right, so successive waves rebuild the
	// word row by row starting from the baseline.
	for (int i = 1; i < self.total; i++) {
		Particle cur_p = self.particles[i];
		int j = i - 1;
		while (j >= 0
				&& (self.particles[j].row < cur_p.row
					|| (self.particles[j].row == cur_p.row
						&& self.particles[j].col > cur_p.col))) {
			self.particles[j + 1] = self.particles[j];
			j--;
		}
		self.particles[j + 1] = cur_p;
	}
}

fn void Model.rotate_corner(Model* self) {
	switch (self.corner.col * 100 + self.corner.row) {
		case 0: self.corner = { .col = self.w - 1, .row = 0 };
		case (self.w - 1) * 100: self.corner = { .col = self.w - 1, .row = self.h - 1 };
		case (self.w - 1) * 100 + self.h - 1: self.corner = { .col = 0, .row = self.h - 1 };
		case (self.h - 1): self.corner = { .col = 0, .row = 0 };
		default: self.corner = { .col = 0, .row = 0 };
	}
}

fn void Model.alloc_half_buffers(Model* self) {
	if (self.half_mask.len) mem::free(self.half_mask);
	if (self.half_col.len) mem::free(self.half_col);
	sz n = (sz)(self.w * self.h);
	self.half_mask = mem::new_array(char, n);
	self.half_col = mem::new_array(xray::Color, n);
	if (self.stack_top.len) mem::free(self.stack_top);
	self.stack_top = mem::new_array(int, (sz)self.w);
	if (self.glow.len) mem::free(self.glow);
	self.glow = mem::new_array(float, n);
}

fn float rand_range(float lo, float hi) {
	return lo + (float)(rand() % 100000) / 100000.0f * (hi - lo);
}

fn void Model.emit_cloud(Model* self) {
	int n = self.total;
	int start = self.next_emit_index;
	int end = start + PARTICLES_PER_WAVE;
	if (end > n) end = n;
	for (int i = start; i < end; i++) {
		Particle* p = &self.particles[i];
		// Spray: scatter the launch point widely around the corner, fire in a
		// fully random direction at a slightly random speed, and stagger the
		// bots across ticks so the wave streams out rather than popping.
		p.x = (float)self.corner.col + rand_range(-4.0f, 4.0f);
		p.y = (float)self.corner.row + rand_range(-3.0f, 3.0f);

		float angle = rand_range(0.0f, 6.2831853f);
		float speed = rand_range(10.0f, 22.0f);
		p.vx = math::cos(angle) * speed;
		p.vy = math::sin(angle) * speed * 0.7f; // cells are taller than wide

		p.spawn_tick = self.frame + (i - start) * SPAWN_STAGGER;
		// No scripted timing: a weak, floppy spring takes far longer to bring
		// its bot home than a stiff one, so the word fills a cell at a time on
		// its own — and each bot springs in with its own character.
		p.attract = rand_range(0.040f, 0.085f);
		p.damp = rand_range(0.905f, 0.935f);
		p.wander = rand_range(0.0f, 6.2831853f);
		p.wander_rate = rand_range(-0.15f, 0.15f);
		p.alive = true;
		p.settled = false;
		self.next_emit_index = i + 1;
	}
	self.last_emit_frame = self.frame;
}

fn xray::Color from_glaze(glaze::Color c) {
	return xray::color_rgb(c.r, c.g, c.b);
}

// Pick a fresh 3-stop gradient for the next cycle. Built in HCL at fixed
// chroma/luminance so every palette lands at a similar brightness — random
// RGB would throw up muddy or near-black stops.
fn void Model.randomize_palette(Model* self) {
	double base = (double)rand_range(0.0f, 360.0f);
	double spread = (double)rand_range(40.0f, 110.0f);
	double dir = rand() % 2 == 0 ? 1.0 : -1.0;
	for (int i = 0; i < 3; i++) {
		double hue = base + dir * spread * (double)i;
		while (hue < 0.0) hue += 360.0;
		while (hue >= 360.0) hue -= 360.0;
		double chroma = (double)rand_range(55.0f, 85.0f);
		double lum = (double)rand_range(60.0f, 76.0f);
		self.palette[i] = from_glaze(glaze::hcl(hue, chroma, lum));
	}
}

fn bool Model.all_settled(Model* self) {
	if (self.total == 0) return false;
	if (self.next_emit_index < self.total) return false;
	for (int i = 0; i < self.total; i++) {
		if (!self.particles[i].settled) return false;
	}
	return true;
}

fn void Model.snap_stragglers(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = true;
	}
	self.next_emit_index = self.total;
}

fn bool Model.any_alive(Model* self) {
	for (int i = 0; i < self.total; i++) {
		if (self.particles[i].alive) return true;
	}
	return false;
}

fn void Model.restart_cycle(Model* self) {
	self.cycle++;
	self.randomize_palette();
	for (int i = 0; i < self.total; i++) {
		self.particles[i].alive = false;
		self.particles[i].settled = false;
		self.particles[i].resting = false;
		self.particles[i].charred = false;
	}
	// Any leftover embers from a fire exit die with the cycle.
	for (int i = 0; i < EMBER_POOL; i++) self.fire_embers[i].active = false;
	self.fire_ember_head = 0;
	self.fade_start = 0;
	self.line_frame = 0;
	self.splat_falling = false;
	self.preview_at = 0;
	self.crt_stage = 0;
	self.crt_dot = 0;
	self.crt_swell = 1.0f;
	self.topple_angle = 0;
	self.topple_vel = 0;
	self.topple_shattered = false;
	self.next_emit_index = 0;
	self.last_emit_frame = self.frame - EMIT_COOLDOWN;
	self.phase = Phase.BUILD;
	self.phase_frame = self.frame;
	self.rotate_corner();
	self.emit_cloud();
}

fn void Model.update_physics(Model* self) {
	if (self.phase == Phase.SPHERES) self.collide_spheres();
	if (self.phase == Phase.FIRE) self.update_embers();
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue; // not sprayed out yet
		if (p.settled) {
			p.x = (float)p.col;
			p.y = (float)p.row;
			p.vx = 0;
			p.vy = 0;
			continue;
		}
		if (self.phase == Phase.FALL) {
			if (p.resting) continue;
			p.vy += GRAVITY * DT;
			p.vx *= decay(0.98f);
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;

			float max_x = (float)(self.w - 1);
			if (p.x < 0)     { p.x = 0;     p.vx = -p.vx * 0.4f; }
			if (p.x > max_x) { p.x = max_x; p.vx = -p.vx * 0.4f; }

			// Stack in whichever column the block is currently over, so a
			// block that drifts sideways lands on that column's pile.
			int c = (int)p.x;
			if (c < 0) c = 0;
			if (c >= self.w) c = self.w - 1;
			p.fall_col = c;
			// The resting spot is one half-cell above the column's fill line;
			// p.y is in cells, the stack in half-cells.
			float floor_y = (float)(self.stack_top[c] - 1) * 0.5f;
			if (p.y >= floor_y) {
				p.y = floor_y;
				if (p.vy > 3.0f) {
					// Enough speed left to bounce once more.
					p.vy = -p.vy * BOUNCE;
					p.vx *= 0.7f;
				} else {
					p.vy = 0;
					p.vx = 0;
					p.x = (float)c;
					p.resting = true;
					if (self.stack_top[c] > 0) self.stack_top[c]--;
				}
			}
			continue;
		}
		if (self.phase == Phase.DISSOLVE) {
			// Purely visual — the block stays put and the view decides what
			// glyph to draw. It retires once its flicker sequence is done.
			int age = self.frame - p.spawn_tick;
			if (age >= DISSOLVE_FLICKERS * DISSOLVE_STEP) p.alive = false;
			continue;
		}
		if (self.phase == Phase.SHEAR) {
			if (self.frame < p.spawn_tick) continue; // not torn loose yet
			p.vx += WIND_ACCEL * self.bar_dir * DT;
			// Flutter: a slowly turning heading gives lift that alternates,
			// so blocks tumble down the gust instead of tracking straight.
			p.wander += p.wander_rate * DT;
			p.vy += math::sin(p.wander) * 0.55f * DT;
			p.vx *= decay(0.88f); // heavy drag, so they streak rather than launch
			p.vy *= decay(0.86f);
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;
			if (p.x < -4.0f || p.x > (float)self.w + 4.0f) p.alive = false;
			continue;
		}
		if (self.phase == Phase.TOPPLE) {
			// Before the crash the slab is rigid: the shared angle drives
			// every block, so there's nothing per-particle to integrate.
			if (!self.topple_shattered) continue;
			// After it, blocks behave exactly like the FALL pile.
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
			float floor_y = (float)(self.stack_top[c] - 1) * 0.5f;
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
					if (self.stack_top[c] > 0) self.stack_top[c]--;
				}
			}
			continue;
		}
		if (self.phase == Phase.SPHERES) {
			if (self.frame < p.spawn_tick) continue; // still part of the word
			if (p.resting) continue;
			p.vy += GRAVITY * DT;
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;
			// Side walls: bounce, losing a little each time.
			float mx = (float)(self.w - 1);
			if (p.x < 0)  { p.x = 0;  p.vx = -p.vx * 0.7f; }
			if (p.x > mx) { p.x = mx; p.vx = -p.vx * 0.7f; }
			// The floor is the bottom row — these bounce on the ground
			// rather than stacking on each other, so the scatter stays
			// visible instead of building a wall. The top of the settled
			// pile counts as ground too, or a ball that lands on another
			// ball would never stop bouncing.
			float floor_y = (float)(self.h - 1);
			bool landed = false;
			if (p.y >= floor_y) {
				p.y = floor_y;
				landed = true;
			} else if (p.vy >= 0 && self.on_resting_ball(p)) {
				landed = true;
			}
			if (landed) {
				if (p.vy > BALL_REST) {
					p.vy = -p.vy * BALL_BOUNCE;
					p.vx *= 0.94f; // slight friction on contact
				} else {
					p.vy = 0;
					p.vx *= 0.7f;
					// Once it has stopped hopping it rolls to a halt.
					if (p.vx > -0.25f && p.vx < 0.25f) {
						p.vx = 0;
						p.resting = true;
					}
				}
			}
			continue;
		}
		if (self.phase == Phase.FIRE) {
			if (p.charred) {
				// The burnt-out piece crumbles: it falls, wobbles a little,
				// and fades to nothing over FIRE_CHAR_FADE.
				int c_age = self.frame - p.char_tick;
				if (c_age >= FIRE_CHAR_FADE || p.y > (float)self.h + 1.0f) {
					p.alive = false;
					continue;
				}
				p.vy += 0.10f * DT;
				p.vx += math::sin((float)c_age * 0.5f + p.noise_seed) * 0.03f * DT;
				p.vx *= 0.96f;
				p.x += p.vx * 0.25f * DT;
				p.y += p.vy * 0.25f * DT;
				continue;
			}
			// Not charred yet, and the loop gate at the top skipped frames
			// before p.spawn_tick (== the ignition frame), so this block is
			// burning: it stays in place as the fuel while it spits embers,
			// then chars into crumble once its fuel is spent.
			int age = self.frame - p.ignite_tick;
			if (age >= FIRE_LIFE) {
				p.charred = true;
				p.char_tick = self.frame;
				p.vy = rand_range(0.3f, 0.8f);
				p.vx = rand_range(-0.4f, 0.4f);
				continue;
			}
			p.noise_seed += 0.01f;   // shimmer phase advances while it burns
			if ((rand() % EMBER_EMIT) == 0) self.emit_fire_ember(p.fire_col, p.row);
			continue;
		}
		if (self.phase == Phase.SPLAT) {
			if (!self.splat_falling) {
				// The throw, eased. Windup: the slab eases backward away
				// from the wall, decelerating into the turn. Release: it
				// accelerates hard, so the impact is the fastest moment
				// rather than just where the travel happens to stop.
				int rel = self.frame - self.splat_launch;
				float ease;
				if (rel < 0) {
					// Pull-back, tapering to a standstill at the turn.
					float u = (float)(-rel) / (float)SPLAT_WINDUP;
					ease = -0.16f * u * u;
				} else {
					// Accelerate into the wall: quadratic ramp, clamped once
					// it reaches full speed so it doesn't run away.
					float u = (float)rel / 9.0f;
					if (u > 1.0f) u = 1.0f;
					ease = u * u;
				}
				p.x += p.vx * ease * 0.25f * DT;
				p.y += p.vy * ease * 0.25f * DT;
				continue;
			}
			if (p.resting) continue;
			p.vy += GRAVITY * DT;
			p.vx *= decay(0.94f); // scrubbing along the wall bleeds sideways speed
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;
			float mx = (float)(self.w - 1);
			if (p.x < 0)  { p.x = 0;  p.vx = -p.vx * 0.3f; }
			if (p.x > mx) { p.x = mx; p.vx = -p.vx * 0.3f; }
			int c = (int)p.x;
			if (c < 0) c = 0;
			if (c >= self.w) c = self.w - 1;
			float floor_y = (float)(self.stack_top[c] - 1) * 0.5f;
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
					if (self.stack_top[c] > 0) self.stack_top[c]--;
				}
			}
			continue;
		}
		if (self.phase == Phase.IMPLODE) {
			if (self.crt_stage == 0) {
				// Swelling: blocks hold their rows; the render does the
				// stretching, so the shape stays coherent as it widens.
			} else if (self.crt_stage == 1) {
				// Vertical squash. A stiff, underdamped spring, so the
				// picture slams past the centreline and rings back instead
				// of easing into it.
				float dy = self.line_y - p.y;
				p.vy += dy * 0.55f * DT;
				p.vy *= decay(0.72f);
				p.y += p.vy * 0.25f * DT;
			} else if (self.crt_stage == 2) {
				// The line burns. Blocks jitter a fraction of a cell on the
				// scanline so it looks live rather than frozen.
				p.y = self.line_y + p.wander * 0.15f;
			} else if (self.crt_stage == 3) {
				// Horizontal collapse, accelerating hard toward the centre
				// so the line snaps shut rather than sliding closed.
				float cx = (float)self.text_x + (float)self.text_w * 0.5f;
				float dx = cx - p.x;
				p.vx += dx * 0.42f * DT;
				p.vx *= decay(0.74f);
				p.x += p.vx * 0.25f * DT;
				p.y = self.line_y;
				if (dx > -0.8f && dx < 0.8f) p.alive = false;
			} else {
				p.y = self.line_y;
			}
			continue;
		}
		if (self.phase == Phase.VORTEX) {
			float dx = self.hole_x - p.x;
			float dy = (self.hole_y - p.y) * 2.0f; // cells are ~2x tall
			float d = math::sqrt(dx * dx + dy * dy);
			if (d < 0.9f) { p.alive = false; continue; }
			float nx = dx / d;
			float ny = dy / d;
			// Pull scales with 1/d, capped near the middle so a block that
			// gets close doesn't take an infinite kick on the last tick.
			float pull = 26.0f / d;
			if (pull > 5.0f) pull = 5.0f;
			p.vx += nx * pull * DT;
			p.vy += ny * pull * 0.5f * DT;
			// Tangential component: perpendicular to the inward normal, and
			// it's what turns a straight fall into a spiral. It has to fade
			// as the block closes in — held at full strength it balances the
			// inward pull exactly and the block just orbits forever.
			float swirl = d / 14.0f;
			if (swirl > 1.0f) swirl = 1.0f;
			p.vx += -ny * pull * 0.55f * swirl * DT;
			p.vy += nx * pull * 0.28f * swirl * DT;
			// Damping alone can't kill a circular orbit, since it sheds
			// tangential and radial speed alike. This extra inward creep is
			// unconditional, so every block loses altitude every tick.
			p.x += nx * 0.10f;
			p.y += ny * 0.05f;
			p.vx *= decay(0.90f);
			p.vy *= decay(0.90f);
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;
			continue;
		}
		if (self.phase == Phase.SLICE) {
			// A slab, not a cloud: no drag on vx, so the strip holds its
			// shape all the way off the edge.
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;
			if (p.x < -4.0f || p.x > (float)self.w + 4.0f) p.alive = false;
			continue;
		}
		if (self.phase == Phase.BLOW) {
			// No pull, no walls — coast outward until off screen, then retire.
			p.vx *= decay(0.995f);
			p.vy *= decay(0.995f);
			p.x += p.vx * 0.25f * DT;
			p.y += p.vy * 0.25f * DT;
			if (p.x < -4.0f || p.x > (float)self.w + 4.0f
					|| p.y < -4.0f || p.y > (float)self.h + 4.0f) {
				p.alive = false;
			}
			continue;
		}

		float tx = (float)p.col;
		float ty = (float)p.row;
		float dx = tx - p.x;
		float dy = ty - p.y;
		float dist2 = dx * dx + dy * dy;
		float dist = math::sqrt(dist2);

		// Spring toward the target cell, stiffness per bot — but clamped in
		// magnitude. Unclamped, Hooke's law at 40 cells out is ~2.4 cells/tick
		// of pull, which swamps the throw within a single tick and makes every
		// bot beeline. Capping it lets momentum win first: a bot thrown away
		// from its cell coasts outward, sheds speed to drag, and only then
		// gets reeled in. Near the target the clamp never binds, so the
		// springy overshoot is untouched.
		float fx = dx * p.attract;
		float fy = dy * p.attract;
		float fm2 = fx * fx + fy * fy;
		if (fm2 > PULL_MAX * PULL_MAX) {
			float fm = math::sqrt(fm2);
			fx = fx / fm * PULL_MAX;
			fy = fy / fm * PULL_MAX;
		}
		p.vx += fx * DT;
		p.vy += fy * DT;

		// Free-floating wander along a slowly turning heading. It fades out
		// as the bot closes in, so it drifts on approach and then locks on.
		// Wander fades quadratically with distance, so it dominates out in
		// open space but dies away well before the pull does — a linear fade
		// left bots random-walking a few cells short of their target.
		float w = dist > 12.0f ? 1.0f : dist / 12.0f;
		w = w * w;
		p.wander += p.wander_rate * DT;
		p.vx += math::cos(p.wander) * 0.22f * w * DT;
		p.vy += math::sin(p.wander) * 0.11f * w * DT;
		float noise = 0.10f * w;
		p.vx += rand_range(-noise, noise) * DT;
		p.vy += rand_range(-noise, noise) * DT;

		// Underdamped on purpose: a bot carries enough momentum to sail past
		// its cell and get pulled back, so it springs into place over a couple
		// of shrinking swings rather than sliding in on a straight line.
		p.vx *= p.damp;
		p.vy *= p.damp;

		float sp2 = p.vx * p.vx + p.vy * p.vy;
		float cap = 18.0f;
		if (sp2 > cap * cap) {
			float sp = math::sqrt(sp2);
			p.vx = p.vx / sp * cap;
			p.vy = p.vy / sp * cap;
		}

		p.x += p.vx * 0.25f * DT;
		p.y += p.vy * 0.25f * DT;

		float max_x = (float)(self.w - 1);
		float max_y = (float)(self.h - 1);
		// Absorb at the edges instead of reflecting — a bounce reads as a
		// rubber ball, which is exactly the wrong feel here.
		if (p.x < 0)     { p.x = 0;     if (p.vx < 0) p.vx = 0; }
		if (p.y < 0)     { p.y = 0;     if (p.vy < 0) p.vy = 0; }
		if (p.x > max_x) { p.x = max_x; if (p.vx > 0) p.vx = 0; }
		if (p.y > max_y) { p.y = max_y; if (p.vy > 0) p.vy = 0; }

		// Recheck against the post-move position, not the stale pre-move one.
		float ndx = tx - p.x;
		float ndy = ty - p.y;
		if (ndx * ndx + ndy * ndy < 0.50f && sp2 < 1.5f) {
			p.x = tx;
			p.y = ty;
			p.vx = 0;
			p.vy = 0;
			p.settled = true;
		}
	}
}

fn glaze::Color to_glaze(xray::Color c) {
	return { .kind = glaze::ColorKind.TRUECOLOR, .r = c.r, .g = c.g, .b = c.b };
}

// Like gradient_color but samples at an arbitrary, wrapping offset — used
// by SWEEP to slide the ramp under the stationary word. Wrapping (rather
// than clamping) is what lets it scroll indefinitely without running out.
fn xray::Color gradient_sat(Model* self, float pos) {
	float span = (float)(self.text_w > 1 ? self.text_w - 1 : 1);
	float t = pos / span;
	t = t - (float)(int)t;      // fractional part
	if (t < 0.0f) t += 1.0f;    // ...which is negative for a leftward scroll
	int lo = t < 0.5f ? 0 : 1;
	double u = t < 0.5f ? (double)t * 2.0 : ((double)t - 0.5) * 2.0;
	glaze::Color from = to_glaze(self.palette[lo]);
	glaze::Color to = to_glaze(self.palette[lo + 1]);
	glaze::Color mixed = glaze::blend_luv(from, to, u);
	return xray::color_rgb(mixed.r, mixed.g, mixed.b);
}

fn xray::Color gradient_color(Model* self, int col) {
	// Map the column across the *text* span (not the screen) to a 3-stop
	// gradient. `col` is an absolute screen column, so subtract text_x first
	// and clamp — otherwise t runs past 1 and the ramp overshoots.
	float t = 0.0f;
	if (self.text_w > 1) {
		t = (float)(col - self.text_x) / (float)(self.text_w - 1);
	}
	if (t < 0.0f) t = 0.0f;
	if (t > 1.0f) t = 1.0f;

	// Blend in CIE LUV via glaze, not sRGB — a straight sRGB lerp dips in
	// lightness mid-ramp and reads as a seam at each stop.
	int lo = t < 0.5f ? 0 : 1;
	double u = t < 0.5f ? (double)t * 2.0 : ((double)t - 0.5) * 2.0;
	glaze::Color from = to_glaze(self.palette[lo]);
	glaze::Color to = to_glaze(self.palette[lo + 1]);
	glaze::Color mixed = glaze::blend_luv(from, to, u);
	return xray::color_rgb(mixed.r, mixed.g, mixed.b);
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	srand((uint)c3_time_ms_long());
	self.w = 80;
	self.h = 24;
	self.frame = 0;
	self.last_emit_frame = -EMIT_COOLDOWN;
	self.phase = Phase.BUILD;
	self.phase_frame = 0;
	self.cycle = 0;
	self.next_emit_index = 0;
	self.corner = { .col = 0, .row = 0 };
	// Same HCL luminance band as randomize_palette, so cycle 0 is no
	// brighter than the cycles that follow.
	self.palette = {
		xray::color_rgb(138, 207, 5),   // lime green
		xray::color_rgb(87, 174, 228),  // light blue
		xray::color_rgb(199, 189, 122), // pale yellow
	};
	self.canvas = xray::new_screen_buffer(80, 24);
	self.alloc_half_buffers();
	self.parse_text();
	self.emit_cloud();
	return milktea::tick(FRAME_MS);
}

// One simulation step: advance the clock, integrate, then let the current
// phase decide whether it's finished. Split out of update() so the turbo
// key can run it several times per tick.
fn void Model.step(Model* self) {
	self.frame++;
	// A queued TAB preview overrides the normal HOLD timeout.
	if (self.preview_at != 0 && self.frame >= self.preview_at) {
		self.preview_at = 0;
		self.start_exit();
		return;
	}
	self.update_physics();
		switch (self.phase) {
			case Phase.BUILD:
				if (self.next_emit_index < self.total
						&& self.frame - self.last_emit_frame >= EMIT_COOLDOWN) {
					self.rotate_corner();
					self.emit_cloud();
				} else if (self.all_settled()) {
					self.phase = Phase.HOLD;
					self.phase_frame = self.frame;
				} else if (self.frame - self.phase_frame > BUILD_TIMEOUT) {
					self.snap_stragglers();
					self.phase = Phase.HOLD;
					self.phase_frame = self.frame;
				}
			case Phase.HOLD:
				if (self.preview_at == 0
						&& self.frame - self.phase_frame >= HOLD_DURATION) {
					self.start_exit();
				}
			case Phase.BLOW:
				if (!self.any_alive()) self.restart_cycle();
			case Phase.SLICE:
				if (!self.any_alive()) self.restart_cycle();
			case Phase.DISSOLVE:
				if (!self.any_alive()) self.restart_cycle();
			case Phase.SHEAR:
				if (!self.any_alive()) self.restart_cycle();
			case Phase.TOPPLE:
				if (!self.topple_shattered) {
					// Gravity torque: accelerates as the slab goes over.
					self.topple_vel += (TOPPLE_ACCEL + self.topple_angle * 0.004f) * DT;
					self.topple_angle += self.topple_vel;
					// Flat on the floor at a quarter turn — shatter, and hand
					// each block the velocity its rotation had given it.
					if (self.topple_angle >= 1.5707963f) {
						self.topple_angle = 1.5707963f;
						self.topple_shattered = true;
						self.scatter_from_topple();
					}
				} else if (self.all_resting()) {
					if (self.fade_start == 0) self.fade_start = self.frame + @dur(10);
					if (self.frame - self.fade_start >= FADE_DURATION) {
						self.restart_cycle();
					}
				}
			case Phase.IMPLODE: {
				// Stage timings are what make this read as a shutdown rather
				// than a generic collapse: the picture swells and brightens
				// as the supply sags, then a fast squash, a brief burn, a
				// fast pinch, and a dot that outlives the picture.
				int held = self.frame - self.crt_stage_frame;
				if (self.crt_stage == 0) {
					// Bloom outward. Eases off toward the end, so it looks
					// like it's straining against something.
					float t = (float)held / (float)SWELL_DURATION;
					if (t > 1.0f) t = 1.0f;
					self.crt_swell = 1.0f + (SWELL_MAX - 1.0f) * (t * (2.0f - t));
					if (held >= SWELL_DURATION) {
						self.crt_stage = 1;
						self.crt_stage_frame = self.frame;
					}
				} else if (self.crt_stage == 1) {
					if (self.all_on_line() && held > @dur(6)) {
						self.crt_stage = 2;
						self.crt_stage_frame = self.frame;
						self.line_frame = self.frame;
					}
				} else if (self.crt_stage == 2) {
					if (held >= LINE_HOLD) {
						self.crt_stage = 3;
						self.crt_stage_frame = self.frame;
					}
				} else if (self.crt_stage == 3) {
					if (!self.any_alive()) {
						self.crt_stage = 4;
						self.crt_stage_frame = self.frame;
						self.crt_dot = 1.0f; // flare at full white
					}
				} else if (self.crt_stage == 4) {
					// The dot decays after the flare, then the cycle restarts.
					self.crt_dot -= 1.0f / (float)DOT_HOLD;
					if (self.crt_dot <= 0.0f) {
						self.crt_dot = 0.0f;
						self.restart_cycle();
					}
				}
			}
			case Phase.FIRE:
				if (!self.any_alive()) self.restart_cycle();
			case Phase.SPHERES:
				// Everything has to have been released before the pile can
				// be called finished, or it settles while balls still wait.
				// Collisions can keep knocking balls awake, so this has a
				// hard cap as well as the settled test — otherwise a lively
				// pile could jostle forever and never end the phase.
				bool done = self.all_resting()
						|| self.frame - self.phase_frame > @dur(320);
				if (self.frame > self.phase_frame + @dur(90) && done) {
					if (self.fade_start == 0) self.fade_start = self.frame + @dur(10);
					if (self.frame - self.fade_start >= FADE_DURATION) {
						self.restart_cycle();
					}
				}
			case Phase.SPLAT:
				if (!self.splat_falling) {
					// The leading edge reaching the wall triggers the impact
					// for the whole slab at once — that's what makes it read
					// as one object hitting, not a stream of pellets.
					if (self.splat_hit()) {
						self.splat_falling = true;
						self.splash_from_wall();
					}
				} else if (self.all_resting()) {
					if (self.fade_start == 0) self.fade_start = self.frame + @dur(10);
					if (self.frame - self.fade_start >= FADE_DURATION) {
						self.restart_cycle();
					}
				}
			case Phase.VORTEX:
				// The ring irises open, holds while it feeds, then pinches
				// shut once the last block is gone — and only when it has
				// fully closed does the next cycle start.
				if (self.any_alive()) {
					if (self.hole_r < 2.0f) self.hole_r += 0.2f * DT;
				} else {
					self.hole_r -= 0.12f * DT;
					if (self.hole_r <= 0.0f) {
						self.hole_r = 0.0f;
						self.restart_cycle();
					}
				}
			case Phase.FALL:
				// Once the pile has come to rest, hold a beat, then fade the
				// whole heap out before the next cycle starts building.
				if (self.fade_start == 0) {
					if (self.all_resting()) self.fade_start = self.frame + @dur(10);
				} else if (self.frame - self.fade_start >= FADE_DURATION) {
					self.restart_cycle();
				}
		}
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.w = msg.window_size.width;
		self.h = msg.window_size.height;
		if (self.canvas != null) self.canvas.destroy();
		self.canvas = xray::new_screen_buffer((sz)self.w, (sz)self.h);
		self.alloc_half_buffers();
		self.phase = Phase.BUILD;
		self.phase_frame = self.frame;
		self.next_emit_index = 0;
		self.parse_text();
		self.last_emit_frame = self.frame - EMIT_COOLDOWN;
		self.rotate_corner();
		self.emit_cloud();
		return milktea::tick(FRAME_MS);
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		// Holding space runs four steps per frame rather than shortening the
		// frame, so the frame rate stays put and only the sim speeds up.
		int steps = self.frame < self.turbo_until ? 4 : 1;
		for (int step = 0; step < steps; step++) self.step();
		return milktea::tick(FRAME_MS);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C: return milktea::quit();
		case milktea::KeyCode.TAB:
			// Step to the next effect. If a preview is already queued and
			// waiting out its delay, step from *that* rather than from the
			// last effect actually run — otherwise every TAB during the
			// pause re-queues the same one and the key looks dead.
			if (self.preview_at != 0) {
				self.forced_exit = (Exit)(((int)self.forced_exit + 1) % EXIT_COUNT);
			} else if (self.exit_previewed || self.has_last_exit) {
				self.forced_exit = (Exit)(((int)self.last_exit + 1) % EXIT_COUNT);
			} else {
				self.forced_exit = Exit.EXPLODE;
			}
			self.exit_forced = true;
			self.exit_previewed = true;
			// Snap the word together, then hold ~2s before firing: long
			// enough to read the badge and see the word whole, without the
			// full rebuild that would make the key useless for comparing.
			self.snap_stragglers();
			self.fade_start = 0;
			self.phase = Phase.HOLD;
			self.phase_frame = self.frame;
			self.preview_at = self.frame + @dur(40);
			self.badge_until = self.frame + BADGE_DURATION;
			return null;
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q' || k.rune == 'Q') return milktea::quit();
			if (k.rune == 'r' || k.rune == 'R') {
				self.restart_cycle();
				return null;
			}
			if (k.rune == ' ') {
				// Each repeat pushes the deadline out; ~7 ticks is longer
				// than a terminal's auto-repeat interval but short enough
				// that releasing space drops back to normal speed at once.
				self.turbo_until = self.frame + @dur(7);
				return null;
			}
			if (k.rune == 'b' || k.rune == 'B') {
				if (self.phase == Phase.BUILD || self.phase == Phase.HOLD) {
					self.start_exit();
				}
				return null;
			}
		case milktea::KeyCode.ESC: return milktea::quit();
		default:
	}
	return null;
}

fn String exit_name(Exit e) {
	switch (e) {
		case Exit.EXPLODE: return "EXPLODE";
		case Exit.COLLAPSE: return "COLLAPSE";
		case Exit.SLICE: return "SLICE";
		case Exit.VORTEX: return "VORTEX";
		case Exit.DISSOLVE: return "DISSOLVE";
		case Exit.SHEAR: return "SHEAR";
		case Exit.TOPPLE: return "TOPPLE";
		case Exit.IMPLODE: return "IMPLODE";
		case Exit.SPLAT: return "SPLAT";
		case Exit.FIRE: return "FIRE";
		case Exit.SPHERES: return "SPHERES";
		default: return "?";
	}
}

fn String glyph_at(List{String} rows, int row_src, int byte_off, int byte_len) {
	// Pull the byte range from the source row String. Note the `:len` form —
	// C3's `a..b` range is inclusive and would grab a trailing stray byte.
	String line = rows[row_src];
	return line[byte_off:(sz)byte_len];
}

fn milktea::View Model.view(Model* self) @dynamic {
	xray::ScreenBuffer* sb = self.canvas;
	sb.clear();

	xray::Rect full = xray::new_rect(0, 0, self.w, self.h);
	sb.fill_gradient_v(full, xray::color_rgb(6, 8, 22), xray::color_rgb(18, 22, 38));

	xray::Style dot_s = xray::default_style().set_fg(xray::color_rgb(30, 38, 60)).set_bg(xray::color_transparent());
	for (int row = 0; row < self.h; row++) {
		for (int col = 0; col < self.w; col++) {
			int mod = (col * 7 + row * 13) % 41;
			if (mod == 0) {
				sb.set_cell((sz)col, (sz)row, xray::new_cell(" ", 1, dot_s));
			}
		}
	}

	// In flight a bot is a half block, so it moves at twice the vertical
	// resolution of a cell — the drift reads as smooth instead of stepping a
	// whole row at a time. Two bots sharing a cell composite into a full
	// block, so accumulate into a mask first rather than drawing directly.
	for (sz i = 0; i < self.half_mask.len; i++) self.half_mask[i] = 0;

	// During the FALL exit the pile dims to nothing once everything has
	// landed; elsewhere blocks draw at full brightness.
	// Every exit that ends in a settled pile fades it out the same way.
	float fade = 1.0f;
	bool piling = self.phase == Phase.FALL || self.phase == Phase.SPLAT
			|| self.phase == Phase.TOPPLE || self.phase == Phase.SPHERES;
	if (piling && self.fade_start != 0 && self.frame > self.fade_start) {
		fade = 1.0f - (float)(self.frame - self.fade_start) / (float)FADE_DURATION;
		if (fade < 0.0f) fade = 0.0f;
	}

	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		// In SLICE a row waiting its turn still sits on screen — skipping it
		// here would blink the strip out until its stagger elapsed. SHEAR
		// does the same, but draws its waiting blocks as whole glyphs
		// further down instead: at rest p.y lands exactly on a row, so the
		// half-block path would light only the upper half of each cell and
		// the word would look striped while it waits for the wind.
		if (self.phase == Phase.SHEAR) continue;  // keeps its real glyphs
		if (self.phase == Phase.SPHERES) continue;    // drawn as circles
		if (self.phase == Phase.FIRE) continue;  // drawn with its own colours
		if (self.frame < p.spawn_tick
				&& self.phase != Phase.SLICE && self.phase != Phase.VORTEX) {
			continue;
		}
		// These phases draw their blocks as glyphs further down rather than
		// as half-block particles.
		if (self.phase == Phase.DISSOLVE) continue;
		if (self.phase == Phase.TOPPLE && !self.topple_shattered) continue;
		if (self.phase == Phase.IMPLODE) continue;
		if (p.settled) continue;
		int cell_col = (int)p.x;
		int half_row = (int)(p.y * 2.0f);   // vertical position in half-cells
		int cell_row = half_row / 2;
		if (cell_col < 0 || cell_col >= self.w) continue;
		if (cell_row < 0 || cell_row >= self.h) continue;
		int idx = cell_row * self.w + cell_col;
		self.half_mask[idx] |= (char)(half_row % 2 == 0 ? 1 : 2);
		// A bot carries the colour of the cell it's heading for, so it
		// arrives already matching the word rather than changing hue the
		// instant it lands.
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
			xray::Style s2 = xray::default_style().set_fg(self.half_col[idx]);
			sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, s2));
		}
	}

	// DISSOLVE: each block flashes through noise glyphs in place, then goes
	// dark. Before its turn comes it still shows its real glyph.
	if (self.phase == Phase.DISSOLVE) {
		String[5] noise = { "\u2591", "\u2593", "\u2592", "\u2588", "\u2591" };
		for (int i = 0; i < self.total; i++) {
			Particle* p = &self.particles[i];
			if (!p.alive) continue;
			if (p.col < 0 || p.col >= self.w) continue;
			if (p.row < 0 || p.row >= self.h) continue;
			int age = self.frame - p.spawn_tick;
			xray::Color base = gradient_color(self, p.col);
			String g;
			if (age < 0) {
				g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
			} else {
				int step = age / DISSOLVE_STEP;
				if (step >= DISSOLVE_FLICKERS) continue;
				int ni = (step + (int)p.noise_seed) % 5;
				g = noise[ni];
				// Dim as it breaks up, so the word fades as it shreds.
				float f = 1.0f - (float)step / (float)DISSOLVE_FLICKERS;
				base = xray::color_rgb(
					(char)((float)base.r * f),
					(char)((float)base.g * f),
					(char)((float)base.b * f));
			}
			xray::Style ds = xray::default_style().set_fg(base);
			sb.set_cell((sz)p.col, (sz)p.row, xray::new_cell(g, 1, ds));
		}
	}

	// TOPPLE, before the crash: the word is still one rigid slab, so draw
	// every block at its rotated position with its real glyph.
	if (self.phase == Phase.TOPPLE && !self.topple_shattered) {
		for (int i = 0; i < self.total; i++) {
			Particle* p = &self.particles[i];
			if (!p.alive) continue;
			float rx = 0;
			float ry = 0;
			self.topple_pos(p, &rx, &ry);
			int col = (int)rx;
			int row = (int)ry;
			if (col < 0 || col >= self.w) continue;
			if (row < 0 || row >= self.h) continue;
			xray::Style ts = xray::default_style().set_fg(gradient_color(self, p.col));
			// Rotated glyphs would point the wrong way, so use a plain block.
			sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, ts));
		}
	}

	// IMPLODE, the CRT shutdown. Colour tracks the stage: the picture washes
	// hot as it squashes, the scanline burns near-white, and the dot flares
	// then decays after everything else is gone.
	if (self.phase == Phase.IMPLODE) {
		for (int i = 0; i < self.total; i++) {
			Particle* p = &self.particles[i];
			if (!p.alive) continue;
			// Stage 0 stretches horizontally about the text centre; later
			// stages have already moved the blocks themselves.
			float px = p.x;
			if (self.crt_stage == 0) {
				float scx = (float)self.text_x + (float)self.text_w * 0.5f;
				px = scx + (p.x - scx) * self.crt_swell;
			}
			int col = (int)px;
			int row = (int)p.y;
			if (col < 0 || col >= self.w) continue;
			if (row < 0 || row >= self.h) continue;
			xray::Color c = gradient_color(self, p.col);
			// Blow out toward white — ramping up through the swell, then
			// pinned high for the collapse itself.
			float heat;
			if (self.crt_stage == 0) {
				heat = 0.30f + 0.45f * (self.crt_swell - 1.0f) / (SWELL_MAX - 1.0f);
			} else {
				heat = 0.85f;
			}
			c = xray::color_rgb(
				(char)((float)c.r + (255.0f - (float)c.r) * heat),
				(char)((float)c.g + (255.0f - (float)c.g) * heat),
				(char)((float)c.b + (255.0f - (float)c.b) * heat));
			xray::Style is = xray::default_style().set_fg(c);
			// On the burning scanline the blocks fuse into a solid bar.
			String g = self.crt_stage >= 2 ? "\u2580" : "\u2588";
			sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, is));
		}
		// The dying dot, drawn after the picture is gone.
		if (self.crt_dot > 0.0f) {
			int dc = (int)((float)self.text_x + (float)self.text_w * 0.5f);
			int dr = (int)self.line_y;
			if (dc >= 0 && dc < self.w && dr >= 0 && dr < self.h) {
				float v = self.crt_dot;
				xray::Color dcol = xray::color_rgb(
					(char)(255.0f * v), (char)(255.0f * v), (char)(235.0f * v));
				xray::Style ds2 = xray::default_style().set_fg(dcol);
				sb.set_cell((sz)dc, (sz)dr, xray::new_cell("\u25AA", 1, ds2));
			}
		}
	}

	// SHEAR keeps the word's own glyphs throughout — at rest and in flight.
	// The half-block path would light only half of each stationary cell and
	// stripe the word, and swapping to blocks mid-gust would read as the
	// letters dissolving rather than being carried off intact.
	if (self.phase == Phase.SHEAR) {
		for (int i = 0; i < self.total; i++) {
			Particle* p = &self.particles[i];
			if (!p.alive) continue;
			int col = (int)p.x;
			int row = (int)p.y;
			if (col < 0 || col >= self.w) continue;
			if (row < 0 || row >= self.h) continue;
			xray::Style ss = xray::default_style().set_fg(gradient_color(self, p.col));
			String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
			sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, ss));
		}
	}

	// FIRE: the flame front creeps up the word. Blocks ahead of it are still
	// the real glyph; burning cells glow through the blackbody colours while
	// they hold still as fuel; spent cells char black and crumble, fading as
	// they fall. On top of all that, short ember sparks rise and die.
	if (self.phase == Phase.FIRE) {
		for (int i = 0; i < self.total; i++) {
			Particle* p = &self.particles[i];
			if (!p.alive) continue;
			if (p.charred) {
				// Crumble: a burnt-out piece fades from dark red to black as it
				// falls, so the letters blacken before the char drifts clear.
				int c_age = self.frame - p.char_tick;
				float t = (float)c_age / (float)FIRE_CHAR_FADE;
				if (t > 1.0f) t = 1.0f;
				int col = (int)p.x;
				int row = (int)p.y;
				if (col < 0 || col >= self.w) continue;
				if (row < 0 || row >= self.h) continue;
				float dim = 1.0f - t;
				// A touch of residual red so the char still reads as burnt, not
				// just erased.
				xray::Color c = xray::color_rgb((char)(70.0f * dim), (char)(10.0f * dim), 0);
				xray::Style fs = xray::default_style().set_fg(c);
				sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, fs));
				continue;
			}
			int age = self.frame - p.ignite_tick;
			if (age < 0) {
				// Awahead of the flame: draw the real glyph, untouched.
				if (p.col < 0 || p.col >= self.w) continue;
				if (p.row < 0 || p.row >= self.h) continue;
				xray::Style fs = xray::default_style().set_fg(gradient_color(self, p.col));
				String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
				sb.set_cell((sz)p.col, (sz)p.row, xray::new_cell(g, 1, fs));
				continue;
			}
			if (age > FIRE_LIFE) age = FIRE_LIFE;
			float t = (float)age / (float)FIRE_LIFE;
			if (t >= 1.0f) continue;    // about to char; fuel is spent
			// Flicker: a fast per-block wobble on the temperature, so
			// neighbouring cells aren't locked to the same shade. Real flame is
			// noisy, and a perfectly smooth ramp is what makes a synthetic fire
			// look like a gradient chart.
			float flick = math::sin((float)self.frame * 0.55f + p.noise_seed * 6.3f);
			float tt = t + flick * 0.05f;
			if (tt < 0.0f) tt = 0.0f;
			if (tt > 1.0f) tt = 1.0f;
			xray::Color c;
			if (tt < 0.10f) {
				// Ignition: the fuel's own colour flashes to white-hot.
				float u = tt / 0.10f;
				xray::Color base = gradient_color(self, p.col);
				c = xray::color_rgb(
					(char)((float)base.r + (255.0f - (float)base.r) * u),
					(char)((float)base.g + (250.0f - (float)base.g) * u),
					(char)((float)base.b + (225.0f - (float)base.b) * u));
			} else if (tt < 0.28f) {
				// White-hot core cooling to yellow.
				float u = (tt - 0.10f) / 0.18f;
				c = xray::color_rgb(255, (char)(250.0f - 26.0f * u), (char)(225.0f - 190.0f * u));
			} else if (tt < 0.60f) {
				// Yellow through amber to orange.
				float u = (tt - 0.28f) / 0.32f;
				c = xray::color_rgb(255, (char)(224.0f - 106.0f * u), (char)(35.0f * (1.0f - u)));
			} else if (tt < 0.85f) {
				// Orange to deep red, still bright.
				float u = (tt - 0.60f) / 0.25f;
				c = xray::color_rgb((char)(255.0f - 45.0f * u), (char)(118.0f - 88.0f * u), 0);
			} else {
				// Dying fuel: dims to black, smouldering rather than fading
				// evenly — flicker is strongest at the end.
				float u = (tt - 0.85f) / 0.15f;
				float dim = (1.0f - u) * (0.72f + 0.28f * flick);
				if (dim < 0.0f) dim = 0.0f;
				c = xray::color_rgb((char)(210.0f * dim), (char)(30.0f * dim), 0);
			}
			int cell_col = p.fire_col;
			int cell_row = p.row;
			if (cell_col < 0 || cell_col >= self.w) continue;
			if (cell_row < 0 || cell_row >= self.h) continue;
			xray::Style fs = xray::default_style().set_fg(c);
			sb.set_cell((sz)cell_col, (sz)cell_row, xray::new_cell("█", 1, fs));
		}
		// Embers: the airborne sparks above the fire, drawn after the fuel so
		// they read as flame rising off the burning word.
		xray::Style er = xray::default_style();
		for (int i = 0; i < EMBER_POOL; i++) {
			Ember* e = &self.fire_embers[i];
			if (!e.active) continue;
			int age = self.frame - e.born;
			if (age < 0 || age >= e.life) continue;
			int col = (int)e.x;
			int row = (int)e.y;
			if (col < 0 || col >= self.w) continue;
			if (row < 0 || row >= self.h) continue;
			float t = (float)age / (float)e.life;
			float purs = math::sin((float)self.frame * 0.9f + (float)i);
			xray::Color c;
			if (t < 0.30f) {
				c = xray::color_rgb(255, (char)(235.0f + 20.0f * purs), (char)(150.0f + 50.0f * purs));
			} else if (t < 0.65f) {
				float u = (t - 0.30f) / 0.35f;
				c = xray::color_rgb(255, (char)(235.0f - 125.0f * u), (char)(150.0f - 120.0f * u));
			} else {
				float u = (t - 0.65f) / 0.35f;
				float dim = (1.0f - u) * (0.55f + 0.45f * purs);
				if (dim < 0.0f) dim = 0.0f;
				c = xray::color_rgb((char)(28.0f * dim), (char)(10.0f * dim), 0);
			}
			sb.set_cell((sz)col, (sz)row, xray::new_cell("█", 1, er.set_fg(c)));
		}
	}

	// SPHERES: released glyphs become circles; the rest are still the word.
	// A ball uses a filled round glyph so it reads as a solid object, and
	// keeps its gradient colour so the word's palette survives the drop.
	if (self.phase == Phase.SPHERES) {
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
				// Not dropped yet — still drawn as part of the word.
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

	// The vortex hole: a dark disc ringed in pink. Drawn after the blocks so
	// anything still spiralling in passes behind it. The ellipse is squashed
	// 2:1 vertically because cells are about twice as tall as they are wide.
	if (self.phase == Phase.VORTEX && self.hole_r > 0.05f) {
		xray::Color ring = xray::color_rgb(255, 64, 160);
		xray::Style ring_s = xray::default_style().set_fg(ring);
		xray::Style void_s = xray::default_style().set_fg(xray::color_rgb(10, 4, 14));
		int span = (int)self.hole_r + 2;
		for (int dy = -span; dy <= span; dy++) {
			for (int dx = -span * 2; dx <= span * 2; dx++) {
				int col = (int)self.hole_x + dx;
				int row = (int)self.hole_y + dy;
				if (col < 0 || col >= self.w) continue;
				if (row < 0 || row >= self.h) continue;
				float fx = (float)dx * 0.5f;
				float fy = (float)dy;
				float d = math::sqrt(fx * fx + fy * fy);
				if (d > self.hole_r) continue;
				// The outermost band of the disc is the pink outline.
				if (d > self.hole_r - 0.45f) {
					sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, ring_s));
				} else {
					sb.set_cell((sz)col, (sz)row, xray::new_cell("\u2588", 1, void_s));
				}
			}
		}
	}

	// draw settled particles with gradient
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive || !p.settled) continue;
		if (p.col < 0 || p.col >= self.w) continue;
		if (p.row < 0 || p.row >= self.h) continue;
		xray::Color col = gradient_color(self, p.col);
		xray::Style s2 = xray::default_style().set_fg(col);
		String g = glyph_at(self.rows, p.row_src, p.byte_off, p.byte_len);
		sb.set_cell((sz)p.col, (sz)p.row, xray::new_cell(g, 1, s2));
	}

	// Effect name badge, top right, shown briefly after TAB. Drawn last so
	// no effect paints over it. Muted slate on a dark plate: it has to stay
	// readable against both the dark background and a bright effect passing
	// behind it, without competing with the animation for attention.
	if (self.frame < self.badge_until) {
		// Name the effect that's about to run — the badge is what tells you
		// where TAB has got to.
		Exit shown = self.forced_exit;
		String label = exit_name(shown);
		int pad = 1;
		int bw = (int)label.len + pad * 2;
		int bx = self.w - bw - 1;
		int by = 0;
		if (bx >= 0 && self.h > 0) {
			xray::Color plate = xray::color_rgb(46, 44, 62);
			xray::Color ink = xray::color_rgb(190, 180, 210);
			xray::Style bg = xray::default_style().set_fg(ink).set_bg(plate);
			for (int i = 0; i < bw; i++) {
				sb.set_cell((sz)(bx + i), (sz)by, xray::new_cell(" ", 1, bg));
			}
			for (int i = 0; i < label.len; i++) {
				String ch = label[(sz)i:1];
				sb.set_cell((sz)(bx + pad + i), (sz)by, xray::new_cell(ch, 1, bg));
			}
		}
	}

	return milktea::new_alt_cell_view(sb.cells[0:(sz)(self.w * self.h)], (sz)self.w, (sz)self.h);
}

fn int main() {
	Model m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Goodbye!");
	return 0;
}
