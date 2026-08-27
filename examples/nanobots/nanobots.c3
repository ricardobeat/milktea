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
const float SPLAT_SPEED = 20.0f; // top speed of the thrown slab
const int SPLAT_WINDUP = @dur(14);     // ticks of pull-back before the release
const float SPLAT_SPLASH = 7.0f; // how hard blocks spray along the wall
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
	RAINBOW,
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
	RAINBOW,
}
const int EXIT_COUNT = 12;

struct Corner {
	int col;
	int row;
}

// An exit effect: a self-contained animation owning all its own state,
// reached through four lifecycle hooks. The model is a thin dispatcher —
// while an effect is active it stops stepping the build/physics and just
// calls fx.step / fx.render each frame. "Taking over" the exit phase this
// way keeps each effect's logic and data in one file instead of scattered
// through the model. fx_state is owned by whichever effect is running and
// released by its teardown.
//
// Hooks take void* (the Model) so Effect can be declared before Model, which
// in turn lets Model hold an Effect field without a forward-declared struct.
// An effect casts its argument back to Model* on entry.
alias FnFxSetup    = fn void (void*);
alias FnFxStep     = fn void (void*);
alias FnFxRender   = fn void (void*);
alias FnFxTeardown = fn void (void*);

struct Effect {
	String  name;
	FnFxSetup    setup;
	FnFxStep     step;
	FnFxRender   render;
	FnFxTeardown teardown;
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
	Effect fx;                 // the active exit effect, when fx_active
	bool fx_active;            // an exit effect is running and owns the phase
	void* fx_state;            // the active effect's private state; owned by
	                           // the effect and released by its teardown
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

// True when every living bot is at rest — used by effects that end with a
// settled pile (COLLAPSE, SPLAT, TOPPLE, SPHERES) to know when to fade out.
fn bool Model.all_resting(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (p.alive && !p.resting) return false;
	}
	return true;
}

fn void Model.restart_cycle(Model* self) {
	self.cycle++;
	self.randomize_palette();
	for (int i = 0; i < self.total; i++) {
		self.particles[i].alive = false;
		self.particles[i].settled = false;
		self.particles[i].resting = false;
	}
	// Tear down any exit effect that is still running so its state isn't
	// carried into the next cycle.
	if (self.fx_active) {
		if (self.fx.teardown) self.fx.teardown(self);
		self.fx_active = false;
		self.fx_state = null;
	}
	self.preview_at = 0;
	self.next_emit_index = 0;
	self.last_emit_frame = self.frame - EMIT_COOLDOWN;
	self.phase = Phase.BUILD;
	self.phase_frame = self.frame;
	self.rotate_corner();
	self.emit_cloud();
}

fn void Model.update_physics(Model* self) {
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
	// While an exit effect is running it owns this phase: the model stops
	// touching the build/physics switch and just advances the effect.
	if (self.fx_active) {
		self.fx.step(self);
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
			default:
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
			// If an animation is already playing, hold a short preview (~1s) so you
			// can read the badge before the selected effect fires — the
			// running animation keeps playing in the meantime, and step()
			// activates the switch once preview_at passes.
			if (self.fx_active) {
				self.preview_at = self.frame + @dur(20);
				self.badge_until = self.frame + BADGE_DURATION;
				return null;
			}
			// Snap the word together, then hold ~2s before firing: long
			// enough to read the badge and see the word whole, without the
			// full rebuild that would make the key useless for comparing.
			self.snap_stragglers();
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
		case Exit.RAINBOW: return "RAINBOW";
		default: return "?";
	}
}

fn String glyph_at(List{String} rows, int row_src, int byte_off, int byte_len) {
	// Pull the byte range from the source row String. Note the `:len` form —
	// C3's `a..b` range is inclusive and would grab a trailing stray byte.
	String line = rows[row_src];
	return line[byte_off:(sz)byte_len];
}

// Effect name badge, top right, shown briefly after TAB. Drawn last so it
// stays readable and nothing paints over it. Also drawn during an active
// effect, so stepping effects with TAB still shows where you are.
fn void draw_badge(Model* self) {
	if (self.frame >= self.badge_until) return;
	xray::ScreenBuffer* sb = self.canvas;
	Exit shown = self.forced_exit;
	String label = exit_name(shown);
	int pad = 1;
	int bw = (int)label.len + pad * 2;
	int bx = self.w - bw - 1;
	int by = 0;
	if (bx < 0 || self.h <= 0) return;
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

	// An exit effect owns the whole scene while it runs; defer to it. The
	// effect has already had the clear + background gradient painted behind
	// it, and draws everything else itself.
	if (self.fx_active) {
		self.fx.render(self);
		draw_badge(self);
		return milktea::new_alt_cell_view(sb.cells[0:(sz)(self.w * self.h)], (sz)self.w, (sz)self.h);
	}

	// In flight a bot is a half block, so it moves at twice the vertical
	// resolution of a cell. Two bots sharing a cell composite into a full
	// block, so accumulate into a mask first rather than drawing directly.
	for (sz i = 0; i < self.half_mask.len; i++) self.half_mask[i] = 0;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (self.frame < p.spawn_tick) continue;
		if (p.settled) continue;
		if (p.resting) continue;
		int cell_col = (int)p.x;
		int half_row = (int)(p.y * 2.0f);
		int cell_row = half_row / 2;
		if (cell_col < 0 || cell_col >= self.w) continue;
		if (cell_row < 0 || cell_row >= self.h) continue;
		int idx = cell_row * self.w + cell_col;
		self.half_mask[idx] |= (char)(half_row % 2 == 0 ? 1 : 2);
		xray::Color pc = gradient_color(self, p.col);
		self.half_col[idx] = pc;
	}
	for (int row = 0; row < self.h; row++) {
		for (int col = 0; col < self.w; col++) {
			int idx = row * self.w + col;
			char mask = self.half_mask[idx];
			if (mask == 0) continue;
			String g = "█";
			if (mask == 1) g = "▀";
			if (mask == 2) g = "▄";
			xray::Style s2 = xray::default_style().set_fg(self.half_col[idx]);
			sb.set_cell((sz)col, (sz)row, xray::new_cell(g, 1, s2));
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

	// Effect name badge, top right, shown briefly after TAB.
	draw_badge(self);

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
