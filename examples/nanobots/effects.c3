// Exit effects for the nanobots example.
//
// Each cycle the assembled word leaves the screen one of nine ways. This
// file holds the setup for each — where blocks start, what velocity they
// get, what per-exit state the Model needs seeded — plus the shared helpers
// they lean on. The per-tick integration for each phase lives in
// Model.update_physics, and the drawing in Model.view, both in nanobots.c3.
//
// Adding an exit means: a Phase, an Exit, a setup fn here, a physics branch,
// a termination check in update, and (if it doesn't draw as plain half
// blocks) a render branch.
module nanobots;

import xray;
import std::math;

fn void Model.explode(Model* self) {
	// Blast radially out from the middle of the word, with enough jitter that
	// the shape shreds rather than expanding as a rigid copy of itself.
	float cx = (float)self.text_x + (float)self.text_w * 0.5f;
	float cy = (float)self.text_y + (float)self.text_h * 0.5f;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
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
}

// The alternate exit: cut the word loose and let every block drop under
// gravity, piling up column by column at the bottom of the screen. Each
// column keeps its own fill height in half-cells, so blocks stack on top of
// whatever landed before them rather than all bottoming out on the floor.
fn void Model.collapse(Model* self) {
	for (int c = 0; c < self.w; c++) self.stack_top[c] = self.h * 2;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.fall_col = p.col;
		// A touch of sideways drift and a small initial kick, so the pile
		// comes out uneven instead of a mirror of the word above it.
		p.vx = rand_range(-1.2f, 1.2f);
		p.vy = rand_range(-2.0f, 1.0f);
	}
	self.phase = Phase.FALL;
	self.phase_frame = self.frame;
	self.fade_start = 0;
}

// Third exit: cut the word into horizontal strips, one per text row, and
// send alternating strips off opposite sides of the screen. Each strip
// leaves as a rigid slab — same speed for every block in it — so it reads
// as a slice sliding apart rather than another particle scatter.
fn void Model.slice(Model* self) {
	// Which way the topmost row goes; the rest alternate from there.
	int flip = rand() % 2 == 0 ? 1 : -1;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		int band = p.row - self.text_y;
		float dir = (float)(((band & 1) == 0 ? 1 : -1) * flip);
		// Stagger the launch by row so the strips peel off in sequence, and
		// vary speed a little per strip so they don't stay in lockstep.
		p.spawn_tick = self.frame + @dur(band * 3);
		p.vx = dir * (14.0f + (float)(band % 3) * 2.5f);
		p.vy = rand_range(-0.6f, 0.6f);
	}
	self.phase = Phase.SLICE;
	self.phase_frame = self.frame;
}

// Fourth exit: a hole opens somewhere on screen and drags every block into
// it. Blocks are pulled inward and given a tangential shove, so they wind
// into a spiral rather than falling straight in, and are eaten once they
// reach the middle.
fn void Model.vortex(Model* self) {
	// Keep the hole clear of the very edge so the ring always draws whole.
	self.hole_x = rand_range(8.0f, (float)self.w - 8.0f);
	self.hole_y = rand_range(4.0f, (float)self.h - 4.0f);
	self.hole_r = 0.0f;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = rand_range(-1.0f, 1.0f);
		p.vy = rand_range(-0.5f, 0.5f);
		// Stagger slightly so the word doesn't peel off all at once.
		p.spawn_tick = self.frame + @dur(rand() % 12);
	}
	self.phase = Phase.VORTEX;
	self.phase_frame = self.frame;
}

// DISSOLVE: nothing moves. Each block flickers through a few noise glyphs
// then blanks out, staggered so the word decays raggedly instead of in a
// wave. spawn_tick doubles as "the frame this block starts to break up".
fn void Model.dissolve(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = 0;
		p.vy = 0;
		p.spawn_tick = self.frame + @dur(rand() % 55);
		p.noise_seed = rand_range(0.0f, 1000.0f);
	}
	self.phase = Phase.DISSOLVE;
	self.phase_frame = self.frame;
}

// SHEAR: a gust builds from one side and tears blocks loose column by
// column. Heavy drag plus a little lift makes them streak and flutter
// rather than fly clean, so it doesn't read as another SLICE.
fn void Model.shear(Model* self) {
	self.bar_dir = rand() % 2 == 0 ? 1.0f : -1.0f; // which way the gust blows
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = 0;
		p.vy = 0;
		// Windward columns go first; the delay runs across the text span.
		int band = self.bar_dir > 0
			? p.col - self.text_x
			: self.text_x + self.text_w - p.col;
		p.spawn_tick = self.frame + @dur(band * 2 + rand() % 8);
		p.wander = rand_range(0.0f, 6.2831853f);
		p.wander_rate = rand_range(-0.30f, 0.30f);
	}
	self.phase = Phase.SHEAR;
	self.phase_frame = self.frame;
}

// TOPPLE: the word stays rigid and rotates about one bottom corner, then
// shatters into the FALL pile when it lands. Blocks keep their offset from
// the pivot; the render rotates each one by the shared angle.
fn void Model.topple(Model* self) {
	self.bar_dir = rand() % 2 == 0 ? 1.0f : -1.0f; // which way it tips
	self.pivot_x = self.bar_dir > 0
		? (float)(self.text_x + self.text_w - 1)
		: (float)self.text_x;
	self.pivot_y = (float)(self.text_y + self.text_h - 1);
	self.topple_angle = 0.0f;
	self.topple_vel = 0.0f;
	self.topple_shattered = false;
	for (int c = 0; c < self.w; c++) self.stack_top[c] = self.h * 2;
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
	}
	self.phase = Phase.TOPPLE;
	self.phase_frame = self.frame;
}

// IMPLODE: a CRT losing power. The picture snaps down to a hot horizontal
// line — overshooting and springing, because the deflection coils ring
// rather than stop dead — holds while it burns, then the line collapses
// inward to a single dot that flares white and fades. Staged explicitly
// (crt_stage) rather than derived from positions: each beat has its own
// timing and feel, and a shared spring would blur them together.
fn void Model.implode(Model* self) {
	self.line_y = (float)self.text_y + (float)self.text_h * 0.5f;
	self.line_frame = 0;
	self.crt_stage = 0;
	self.crt_stage_frame = self.frame;
	self.crt_dot = 0.0f;
	self.crt_swell = 1.0f;
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
		p.wander = rand_range(-0.35f, 0.35f); // tiny per-block spring offset
	}
	self.phase = Phase.IMPLODE;
	self.phase_frame = self.frame;
}

// SPLAT: the word is hurled at one of the side walls at a random angle,
// hits as a slab, and shatters — blocks spray along the wall, then gravity
// takes them down into the usual pile. Like TOPPLE it stays rigid until
// impact, but the break-up is a splash rather than a collapse.
fn void Model.splat(Model* self) {
	bool to_right = rand() % 2 == 0;
	self.splat_wall = to_right ? (float)(self.w - 1) : 0.0f;
	self.splat_falling = false;
	for (int c = 0; c < self.w; c++) self.stack_top[c] = self.h * 2;
	// One shared throw angle, so the word travels as a single object. Kept
	// shallow: at 0.25 rad the slab drifts about 10 rows crossing an 80-col
	// screen, so it lands on the wall rather than the ceiling.
	float angle = rand_range(-0.25f, 0.25f);
	float dir = to_right ? 1.0f : -1.0f;
	// The throw is eased rather than instant: a short pull-back away from
	// the target, then a hard accelerating release. Constant velocity from
	// frame one reads as the word gliding into the wall.
	self.splat_launch = self.frame + SPLAT_WINDUP;
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
	self.phase = Phase.SPLAT;
	self.phase_frame = self.frame;
}

// FIRE: the word burns. A flame front crawls up from the bottom; each glyph
// cell is the fuel. While a cell burns it sits in place, glows through the
// blackbody colours and spits rising embers; once its fuel is spent it chars
// black and crumbles (falls and fades). The fire spreads row by row until the
// whole text is black and gone.
fn void Model.fire(Model* self) {
	// Reset the ember pool for a fresh fire.
	for (int i = 0; i < EMBER_POOL; i++) self.fire_embers[i].active = false;
	self.fire_ember_head = 0;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.charred = false;
		p.char_tick = 0;
		p.fire_col = p.col;
		p.x = (float)p.col;
		p.y = (float)p.row;
		p.vx = 0;
		p.vy = 0;
		// The fire creeps up from the bottom: the lower the row, the sooner
		// it catches. Delay grows by FIRE_ROWDELAY per row, plus a little
		// jitter so a row doesn't light as one flat line — this is what
		// makes the burn crawl over the word instead of flashing all at once.
		int from_bottom = self.text_y + self.text_h - p.row;
		p.ignite_tick = self.frame + FIRE_ROWDELAY * from_bottom + @dur(rand() % 7);
		p.spawn_tick = p.ignite_tick;
		// Per-block phase for the flame flicker and the char wobble.
		p.noise_seed = rand_range(0.0f, 1000.0f);
	}
	self.phase = Phase.FIRE;
	self.phase_frame = self.frame;
}

// Release one short-lived ember from a burning fuel cell, reusing a slot in
// the ring buffer if one is free. Embers are the airborne flame above the
// word; the fuel cell itself keeps burning below.
fn void Model.emit_fire_ember(Model* self, int col, int row) {
	for (int k = 0; k < EMBER_POOL; k++) {
		int idx = (self.fire_ember_head + k) % EMBER_POOL;
		Ember* e = &self.fire_embers[idx];
		if (e.active) continue;
		e.active = true;
		e.x = (float)col + rand_range(-0.3f, 0.3f);
		e.y = (float)row + rand_range(-0.1f, 0.2f);
		e.vx = rand_range(-0.6f, 0.6f);
		e.vy = -rand_range(1.4f, 3.2f);
		e.born = self.frame;
		e.life = @dur(12) + rand() % (FIRE_EMBER_LIFE - 12);
		self.fire_ember_head = (idx + 1) % EMBER_POOL;
		return;
	}
}

// Integrate the ember pool: sparks rise, drift on a little turbulence, cool
// (buoyancy eases), and expire.
fn void Model.update_embers(Model* self) {
	for (int i = 0; i < EMBER_POOL; i++) {
		Ember* e = &self.fire_embers[i];
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
}

// SPHERES: every glyph turns into a ball and drops. They release one by
// one rather than all at once, and unlike the FALL pile these actually
// bounce — high restitution, so they keep hopping and scatter sideways
// across the floor before settling.
fn void Model.spheres(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		p.alive = true;
		p.settled = false;
		p.resting = false;
		p.x = (float)p.col;
		p.y = (float)p.row;
		// A gentle sideways push so they don't all bounce in one column.
		p.vx = rand_range(-2.2f, 2.2f);
		p.vy = 0;
		// Released in the particle list's bottom-up order so the word comes
		// apart as a trickle. Spread over a fixed ~4s regardless of how many
		// blocks the word has — a flat per-block delay would run to 14s on a
		// 140-block word and leave the exit dragging.
		int span = @dur(80);
		int slot = self.total > 1 ? i * span / (self.total - 1) : 0;
		p.spawn_tick = self.frame + slot + @dur(rand() % 4);
	}
	self.phase = Phase.SPHERES;
	self.phase_frame = self.frame;
}

fn void Model.start_exit(Model* self) {
	// Draw from the exits *other* than the last one used, so the same
	// effect never runs twice in a row. Picking uniformly and rerolling on a
	// match would work too, but this needs no loop and can't stall.
	Exit e;
	if (self.exit_forced) {
		// A TAB pick runs once and then clears, so the next cycle goes back
		// to the random rotation on its own.
		e = self.forced_exit;
		self.exit_forced = false;
		self.last_exit = e;
		self.has_last_exit = true;
		self.run_exit(e);
		return;
	}
	self.exit_previewed = false; // a random draw, so the badge dims again
	if (self.has_last_exit) {
		int pick = rand() % (EXIT_COUNT - 1);
		// Shift past the excluded value: indices at or above it move up one,
		// which maps the 3 remaining slots onto the 4 exits with no repeat.
		if (pick >= (int)self.last_exit) pick++;
		e = (Exit)pick;
	} else {
		e = (Exit)(rand() % EXIT_COUNT);
	}
	self.last_exit = e;
	self.has_last_exit = true;
	self.run_exit(e);
}

fn void Model.run_exit(Model* self, Exit e) {
	switch (e) {
		case Exit.EXPLODE: self.explode();
		case Exit.COLLAPSE: self.collapse();
		case Exit.SLICE: self.slice();
		case Exit.VORTEX: self.vortex();
		case Exit.DISSOLVE: self.dissolve();
		case Exit.SHEAR: self.shear();
		case Exit.TOPPLE: self.topple();
		case Exit.IMPLODE: self.implode();
		case Exit.SPLAT: self.splat();
		case Exit.FIRE: self.fire();
		case Exit.SPHERES: self.spheres();
	}
}

// True once every live block has reached the collapse line.
// True once any block has reached the wall the slab was thrown at — or the
// ceiling/floor, which a steeply angled throw reaches first on a short
// terminal. Without that second test a steep throw would sail off the top
// and the phase would never advance.
// Ball-to-ball collisions for SPHERES. O(n^2) over ~140 balls is ~10k
// distance checks a tick, which is nothing at 20fps, so there's no spatial
// index here. Impulses are resolved along the line of centres and the pair
// is pushed apart, since overlapping balls that only get a velocity swap
// stick together and jitter.
fn void Model.collide_spheres(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* a = &self.particles[i];
		if (!a.alive || self.frame < a.spawn_tick) continue;
		for (int j = i + 1; j < self.total; j++) {
			Particle* b = &self.particles[j];
			if (!b.alive || self.frame < b.spawn_tick) continue;
			// Work in square units: a cell is ~2x taller than wide, so the
			// x separation counts for half what the y separation does.
			float dx = (b.x - a.x) * 0.5f;
			float dy = b.y - a.y;
			float d2 = dx * dx + dy * dy;
			if (d2 >= BALL_RADIUS * BALL_RADIUS || d2 < 0.0001f) continue;
			float d = math::sqrt(d2);
			float nx = dx / d;
			float ny = dy / d;
			// Separate them so they stop overlapping, splitting the
			// correction unless one of them has already come to rest.
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
			// Relative velocity along the line of centres.
			float rvx = (b.vx - a.vx) * 0.5f;
			float rvy = b.vy - a.vy;
			float sep = rvx * nx + rvy * ny;
			if (sep > 0.0f) continue; // already moving apart
			float imp = -(1.0f + BALL_BOUNCE) * sep * 0.5f;
			if (!a.resting) {
				a.vx -= nx * imp * 2.0f;
				a.vy -= ny * imp;
			}
			if (!b.resting) {
				b.vx += nx * imp * 2.0f;
				b.vy += ny * imp;
			}
			// A knock is enough to start a settled ball moving again.
			// A settled ball is never woken by an impact: balls in a pile
			// keep tapping their neighbours with impulses well above any
			// sane threshold, so a wake-on-knock rule means the last few
			// balls jitter forever and all_resting() never fires.
			// A settled ball is never woken by an impact: balls in a pile
			// keep tapping their neighbours with impulses well above any
			// sane threshold, so a wake-on-knock rule means the last few
			// balls jitter forever and all_resting() never fires.
		}
	}
}

// True when a ball is in contact with a resting ball below it. That counts
// as ground for the settle rule, otherwise a ball landing on top of the
// pile never touches the floor and bounces in place forever.
fn bool Model.on_resting_ball(Model* self, Particle* p) {
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

fn bool Model.splat_hit(Model* self) {
	// Nothing can land while the slab is still winding up — without this a
	// word already touching an edge would "hit" before it was ever thrown.
	if (self.frame < self.splat_launch) return false;
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		if (p.y <= 0.0f || p.y >= (float)(self.h - 1)) return true;
		if (self.splat_wall > 0.0f) {
			if (p.x >= self.splat_wall) return true;
		} else {
			if (p.x <= 0.0f) return true;
		}
	}
	return false;
}

// Impact: pin every block to the wall and spray it along the surface. The
// spread is centred on where the block already was vertically, so the word
// smears into the wall rather than being redistributed at random.
fn void Model.splash_from_wall(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		// Everything collapses onto the wall plane on impact, clamped into
		// the viewport in case the slab was caught against the ceiling.
		p.x = self.splat_wall;
		if (p.y < 0.0f) p.y = 0.0f;
		if (p.y > (float)(self.h - 1)) p.y = (float)(self.h - 1);
		// Kick away from the wall and along it. Blocks that were deeper into
		// the slab rebound harder, so the splash has some depth to it.
		float away = self.splat_wall > 0.0f ? -1.0f : 1.0f;
		p.vx = away * rand_range(1.0f, SPLAT_SPLASH);
		p.vy = rand_range(-SPLAT_SPLASH, SPLAT_SPLASH * 0.6f);
	}
}

fn bool Model.all_on_line(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		float dy = p.y - self.line_y;
		if (dy > 0.3f || dy < -0.3f) return false;
	}
	return true;
}

// The slab has hit the floor: freeze each block where the rotation left it
// and give it a scatter velocity, so the pile that follows starts from the
// toppled shape rather than the upright one.
fn void Model.scatter_from_topple(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;
		float rx = 0;
		float ry = 0;
		self.topple_pos(p, &rx, &ry);
		p.x = rx;
		p.y = ry;
		// Blocks further from the pivot were travelling fastest on impact.
		float dx = rx - self.pivot_x;
		p.vx = dx * 0.28f + rand_range(-1.5f, 1.5f);
		p.vy = rand_range(-6.0f, -1.0f);
	}
}

fn bool Model.all_resting(Model* self) {
	for (int i = 0; i < self.total; i++) {
		Particle* p = &self.particles[i];
		if (p.alive && !p.resting) return false;
	}
	return true;
}

// Where a block sits after rotating the whole word by topple_angle about
// the pivot corner. Cells are ~2x taller than wide, so the offset is scaled
// into square units before the rotation and back out afterwards.
fn void Model.topple_pos(Model* self, Particle* p, float* out_x, float* out_y) {
	float dx = (float)p.col - self.pivot_x;
	float dy = ((float)p.row - self.pivot_y) * 2.0f;
	float a = self.topple_angle * self.bar_dir;
	float ca = math::cos(a);
	float sa = math::sin(a);
	float rx = dx * ca - dy * sa;
	float ry = dx * sa + dy * ca;
	*out_x = self.pivot_x + rx;
	*out_y = self.pivot_y + ry * 0.5f;
}
