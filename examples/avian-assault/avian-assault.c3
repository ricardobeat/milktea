module avian_assault;

import milktea;
import xray;
import glaze;
import std::io;
import std::math;
import std::core::string;
import std::core::dstring;
import std::core::mem;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

// ── Game Constants ─────────────────────────────────────────────────────────────

const sz FRAME_MS = 25; // 40 FPS
const sz MAX_BLOCKS = 32;
const sz MAX_PIGS = 8;
const sz MAX_PARTICLES = 160;
const sz MAX_TRAIL = 40;
const sz MAX_LEVELS = 3;

enum GameState : char {
	INTRO,      // Animated splash screen
	MENU,       // Main menu
	AIMING,     // Slingshot ready / dragging
	FLYING,     // Bird in flight
	SETTLING,   // Post-launch physics settling
	LEVEL_WON,  // Level clear dialog & stars
	LEVEL_LOST, // Out of birds dialog
	HELP,       // Help & Controls overlay
}

enum BirdType : char {
	RED,    // Classic direct impact
	CHUCK,  // Yellow triangle - speed boost on click/space
	BOMB,   // Black round - explosive on click or impact
}

enum BlockMaterial : char {
	WOOD,
	ICE,
	STONE,
	TNT,
}

// ── Entities & Physics ─────────────────────────────────────────────────────────

struct TrailPoint {
	float x;
	float y;
	sz life;
	bool active;
}

struct Particle {
	float x;
	float y;
	float vx;
	float vy;
	sz life;
	sz max_life;
	xray::Color color;
	bool active;
}

struct Block {
	float x;
	float y;
	float vx;
	float vy;
	float w;
	float h;
	float hp;
	float max_hp;
	BlockMaterial mat;
	bool alive;
}

struct Pig {
	float x;
	float y;
	float vx;
	float vy;
	float radius;
	float hp;
	float max_hp;
	sz blink_timer;
	bool alive;
}

struct ActiveBird {
	float x;
	float y;
	float vx;
	float vy;
	float radius;
	BirdType type;
	bool launched;
	bool used_ability;
	sz flight_ticks;
	bool alive;
}



// ── Model ─────────────────────────────────────────────────────────────────────

struct AvianAssaultModel {
	sz term_w;
	sz term_h;
	sz ticks;

	GameState state;
	sz current_level;
	sz menu_selected; // 0: Play, 1: Level Select, 2: Help, 3: Quit

	// Slingshot Base Position (in pixel coords)
	float sling_x;
	float sling_y;

	// Mouse dragging for sling
	bool is_dragging;
	float drag_x;
	float drag_y;

	// Keyboard aiming angle & power
	float key_angle; // in degrees
	float key_power; // 0.0 - 1.0

	// Birds inventory
	ActiveBird bird;
	BirdType[3] birds_queue;
	sz birds_left;

	// Entities
	Block[MAX_BLOCKS] blocks;
	Pig[MAX_PIGS] pigs;
	Particle[MAX_PARTICLES] particles;
	TrailPoint[MAX_TRAIL] trail;

	sz score;
	sz high_score;
	sz settle_timer;
	sz flash_timer;

	xray::PixelBuffer* vbuf;
	ScreenBuffer* screen;
}

// ── Random Helpers ────────────────────────────────────────────────────────────

fn float rnd_float(float min, float max) {
	float r = (float)(rand() % 10000) / 10000.0f;
	return min + r * (max - min);
}

fn sz rnd_int(sz min, sz max) {
	if (max <= min) return min;
	return min + (rand() % (max - min + 1));
}

// ── Particle & Trail Helpers ──────────────────────────────────────────────────

fn void AvianAssaultModel.spawn_particle(&self, float x, float y, float vx, float vy, sz life, xray::Color c) {
	for (sz i = 0; i < MAX_PARTICLES; i++) {
		if (!self.particles[i].active) {
			self.particles[i] = (Particle){
				.x = x,
				.y = y,
				.vx = vx,
				.vy = vy,
				.life = life,
				.max_life = life,
				.color = c,
				.active = true,
			};
			return;
		}
	}
}

fn void AvianAssaultModel.spawn_explosion(&self, float cx, float cy, sz count, xray::Color c1, xray::Color c2) {
	for (sz i = 0; i < count; i++) {
		float ang = rnd_float(0.0f, 6.28318f);
		float spd = rnd_float(1.5f, 6.5f);
		float vx = math::cos(ang) * spd;
		float vy = math::sin(ang) * spd - 1.2f;
		xray::Color col = (i % 2 == 0) ? c1 : c2;
		self.spawn_particle(cx, cy, vx, vy, rnd_int(15, 30), col);
	}
}

fn void AvianAssaultModel.add_trail(&self, float x, float y) {
	for (sz i = 0; i < MAX_TRAIL; i++) {
		if (!self.trail[i].active) {
			self.trail[i] = (TrailPoint){ .x = x, .y = y, .life = 60, .active = true };
			return;
		}
	}
	// Recycle oldest
	self.trail[0] = (TrailPoint){ .x = x, .y = y, .life = 60, .active = true };
}

fn void AvianAssaultModel.update_particles(&self) {
	for (sz i = 0; i < MAX_PARTICLES; i++) {
		if (!self.particles[i].active) continue;
		self.particles[i].x += self.particles[i].vx;
		self.particles[i].y += self.particles[i].vy;
		self.particles[i].vy += 0.22f; // gravity
		self.particles[i].life--;
		if (self.particles[i].life <= 0) {
			self.particles[i].active = false;
		}
	}
	for (sz i = 0; i < MAX_TRAIL; i++) {
		if (!self.trail[i].active) continue;
		self.trail[i].life--;
		if (self.trail[i].life <= 0) {
			self.trail[i].active = false;
		}
	}
}

// ── Level Construction ────────────────────────────────────────────────────────

fn void AvianAssaultModel.load_level(&self, sz lvl) {
	self.current_level = lvl;
	self.state = GameState.AIMING;
	self.birds_left = 3;
	self.settle_timer = 0;
	self.flash_timer = 0;
	self.is_dragging = false;

	// Reset particles & trail
	for (sz i = 0; i < MAX_PARTICLES; i++) self.particles[i].active = false;
	for (sz i = 0; i < MAX_TRAIL; i++) self.trail[i].active = false;
	for (sz i = 0; i < MAX_BLOCKS; i++) self.blocks[i].alive = false;
	for (sz i = 0; i < MAX_PIGS; i++) self.pigs[i].alive = false;

	sz ground_y = (sz)self.vbuf.height - 10;
	self.sling_x = 24.0f;
	self.sling_y = (float)(ground_y - 18);
	self.drag_x = self.sling_x;
	self.drag_y = self.sling_y;
	self.key_angle = 45.0f;
	self.key_power = 0.65f;

	// Bird lineup
	if (lvl == 0) {
		self.birds_queue[0] = BirdType.RED;
		self.birds_queue[1] = BirdType.RED;
		self.birds_queue[2] = BirdType.CHUCK;
	} else if (lvl == 1) {
		self.birds_queue[0] = BirdType.CHUCK;
		self.birds_queue[1] = BirdType.RED;
		self.birds_queue[2] = BirdType.BOMB;
	} else {
		self.birds_queue[0] = BirdType.BOMB;
		self.birds_queue[1] = BirdType.CHUCK;
		self.birds_queue[2] = BirdType.RED;
	}
	self.prepare_next_bird();

	sz target_x = (sz)self.vbuf.width - 45;
	if (target_x < 65) target_x = 65;

	// Construct structures
	if (lvl == 0) {
		// Castle 1: Classic wood two-pillar + crossbeam + roof
		self.spawn_block((float)target_x, (float)(ground_y - 18), 4.0f, 18.0f, BlockMaterial.WOOD, 25.0f);
		self.spawn_block((float)(target_x + 18), (float)(ground_y - 18), 4.0f, 18.0f, BlockMaterial.WOOD, 25.0f);
		self.spawn_block((float)(target_x - 2), (float)(ground_y - 22), 26.0f, 4.0f, BlockMaterial.WOOD, 20.0f);

		// Second tier
		self.spawn_block((float)(target_x + 3), (float)(ground_y - 36), 4.0f, 14.0f, BlockMaterial.ICE, 15.0f);
		self.spawn_block((float)(target_x + 15), (float)(ground_y - 36), 4.0f, 14.0f, BlockMaterial.ICE, 15.0f);
		self.spawn_block((float)(target_x + 1), (float)(ground_y - 40), 20.0f, 4.0f, BlockMaterial.WOOD, 20.0f);

		// Pigs
		self.spawn_pig((float)(target_x + 9), (float)(ground_y - 6), 4.0f, 15.0f);
		self.spawn_pig((float)(target_x + 9), (float)(ground_y - 28), 3.5f, 12.0f);
	} else if (lvl == 1) {
		// Castle 2: Stone towers & TNT in the center!
		self.spawn_block((float)target_x, (float)(ground_y - 24), 5.0f, 24.0f, BlockMaterial.STONE, 45.0f);
		self.spawn_block((float)(target_x + 22), (float)(ground_y - 24), 5.0f, 24.0f, BlockMaterial.STONE, 45.0f);
		self.spawn_block((float)(target_x + 8), (float)(ground_y - 10), 10.0f, 10.0f, BlockMaterial.TNT, 5.0f);
		self.spawn_block((float)(target_x - 2), (float)(ground_y - 28), 31.0f, 4.0f, BlockMaterial.WOOD, 20.0f);

		// Top tower
		self.spawn_block((float)(target_x + 11), (float)(ground_y - 44), 5.0f, 16.0f, BlockMaterial.WOOD, 20.0f);
		self.spawn_block((float)(target_x + 6), (float)(ground_y - 48), 15.0f, 4.0f, BlockMaterial.ICE, 15.0f);

		// Pigs
		self.spawn_pig((float)(target_x + 13), (float)(ground_y - 22), 4.0f, 15.0f);
		self.spawn_pig((float)(target_x + 13), (float)(ground_y - 54), 4.0f, 15.0f);
		self.spawn_pig((float)(target_x + 32), (float)(ground_y - 6), 3.5f, 10.0f);
	} else {
		// Castle 3: Fortress with Triple Tier & Dual TNT
		self.spawn_block((float)target_x, (float)(ground_y - 28), 5.0f, 28.0f, BlockMaterial.STONE, 50.0f);
		self.spawn_block((float)(target_x + 14), (float)(ground_y - 28), 5.0f, 28.0f, BlockMaterial.STONE, 50.0f);
		self.spawn_block((float)(target_x + 28), (float)(ground_y - 28), 5.0f, 28.0f, BlockMaterial.STONE, 50.0f);

		self.spawn_block((float)(target_x + 5), (float)(ground_y - 10), 9.0f, 10.0f, BlockMaterial.TNT, 5.0f);
		self.spawn_block((float)(target_x + 19), (float)(ground_y - 10), 9.0f, 10.0f, BlockMaterial.TNT, 5.0f);

		self.spawn_block((float)(target_x - 3), (float)(ground_y - 32), 39.0f, 4.0f, BlockMaterial.STONE, 40.0f);

		self.spawn_block((float)(target_x + 6), (float)(ground_y - 50), 4.0f, 18.0f, BlockMaterial.ICE, 15.0f);
		self.spawn_block((float)(target_x + 22), (float)(ground_y - 50), 4.0f, 18.0f, BlockMaterial.ICE, 15.0f);
		self.spawn_block((float)(target_x + 4), (float)(ground_y - 54), 24.0f, 4.0f, BlockMaterial.WOOD, 20.0f);

		// King Pig + Guards
		self.spawn_pig((float)(target_x + 14), (float)(ground_y - 40), 5.5f, 30.0f);
		self.spawn_pig((float)(target_x + 7), (float)(ground_y - 22), 3.5f, 12.0f);
		self.spawn_pig((float)(target_x + 21), (float)(ground_y - 22), 3.5f, 12.0f);
	}
}

fn void AvianAssaultModel.spawn_block(&self, float x, float y, float w, float h, BlockMaterial mat, float hp) {
	for (sz i = 0; i < MAX_BLOCKS; i++) {
		if (!self.blocks[i].alive) {
			self.blocks[i] = (Block){
				.x = x,
				.y = y,
				.vx = 0.0f,
				.vy = 0.0f,
				.w = w,
				.h = h,
				.hp = hp,
				.max_hp = hp,
				.mat = mat,
				.alive = true,
			};
			return;
		}
	}
}

fn void AvianAssaultModel.spawn_pig(&self, float x, float y, float radius, float hp) {
	for (sz i = 0; i < MAX_PIGS; i++) {
		if (!self.pigs[i].alive) {
			self.pigs[i] = (Pig){
				.x = x,
				.y = y,
				.vx = 0.0f,
				.vy = 0.0f,
				.radius = radius,
				.hp = hp,
				.max_hp = hp,
				.blink_timer = rnd_int(20, 60),
				.alive = true,
			};
			return;
		}
	}
}

fn void AvianAssaultModel.prepare_next_bird(&self) {
	if (self.birds_left <= 0) return;
	sz idx = 3 - self.birds_left;
	BirdType type = self.birds_queue[idx];

	float rad = 3.5f;
	if (type == BirdType.BOMB) rad = 4.5f;
	if (type == BirdType.CHUCK) rad = 3.2f;

	self.bird = (ActiveBird){
		.x = self.sling_x,
		.y = self.sling_y,
		.vx = 0.0f,
		.vy = 0.0f,
		.radius = rad,
		.type = type,
		.launched = false,
		.used_ability = false,
		.flight_ticks = 0,
		.alive = true,
	};
}

fn void AvianAssaultModel.launch_bird(&self, float vx, float vy) {
	if (self.state != GameState.AIMING) return;
	self.bird.vx = vx;
	self.bird.vy = vy;
	self.bird.launched = true;
	self.state = GameState.FLYING;
	self.birds_left--;
}

fn void AvianAssaultModel.activate_ability(&self) {
	if (self.state != GameState.FLYING || !self.bird.alive || self.bird.used_ability) return;
	self.bird.used_ability = true;

	if (self.bird.type == BirdType.CHUCK) {
		// Speed turbo boost!
		self.bird.vx *= 2.4f;
		self.bird.vy *= 0.6f;
		self.spawn_explosion(self.bird.x, self.bird.y, 16, xray::color_rgb(255, 255, 100), xray::color_rgb(255, 180, 40));
	} else if (self.bird.type == BirdType.BOMB) {
		// Instant explosion!
		self.trigger_bomb_explosion(self.bird.x, self.bird.y);
		self.bird.alive = false;
	}
}

fn void AvianAssaultModel.trigger_bomb_explosion(&self, float cx, float cy) {
	self.flash_timer = 5;
	self.spawn_explosion(cx, cy, 45, xray::color_rgb(255, 80, 20), xray::color_rgb(255, 240, 50));

	float blast_rad = 32.0f;
	// Damage & blow blocks away
	for (sz i = 0; i < MAX_BLOCKS; i++) {
		if (!self.blocks[i].alive) continue;
		float bx = self.blocks[i].x + self.blocks[i].w / 2.0f;
		float by = self.blocks[i].y + self.blocks[i].h / 2.0f;
		float dx = bx - cx;
		float dy = by - cy;
		float dist = math::sqrt(dx * dx + dy * dy);
		if (dist < blast_rad) {
			float force = (1.0f - dist / blast_rad) * 8.0f;
			self.blocks[i].vx += (dx / (dist + 0.1f)) * force;
			self.blocks[i].vy += (dy / (dist + 0.1f)) * force - 2.0f;
			self.blocks[i].hp -= (1.0f - dist / blast_rad) * 60.0f;
		}
	}
	// Damage & blow pigs away
	for (sz i = 0; i < MAX_PIGS; i++) {
		if (!self.pigs[i].alive) continue;
		float dx = self.pigs[i].x - cx;
		float dy = self.pigs[i].y - cy;
		float dist = math::sqrt(dx * dx + dy * dy);
		if (dist < blast_rad) {
			float force = (1.0f - dist / blast_rad) * 9.0f;
			self.pigs[i].vx += (dx / (dist + 0.1f)) * force;
			self.pigs[i].vy += (dy / (dist + 0.1f)) * force - 3.0f;
			self.pigs[i].hp -= 50.0f;
		}
	}
}

// ── Physics Simulation ────────────────────────────────────────────────────────

fn void AvianAssaultModel.update_physics(&self) {
	sz ground_y = (sz)self.vbuf.height - 10;
	float gravity = 0.32f;

	// 1. Update Bird
	if (self.state == GameState.FLYING && self.bird.alive) {
		self.bird.flight_ticks++;
		self.bird.vy += gravity;
		self.bird.x += self.bird.vx;
		self.bird.y += self.bird.vy;

		if (self.bird.flight_ticks % 2 == 0) {
			self.add_trail(self.bird.x, self.bird.y);
		}

		// Floor collision
		if (self.bird.y + self.bird.radius >= (float)ground_y) {
			self.bird.y = (float)ground_y - self.bird.radius;
			self.bird.vy = -self.bird.vy * 0.4f;
			self.bird.vx *= 0.75f;
			if (self.bird.type == BirdType.BOMB && !self.bird.used_ability) {
				self.trigger_bomb_explosion(self.bird.x, self.bird.y);
				self.bird.alive = false;
			}
		}

		// Bird collision against blocks
		for (sz i = 0; i < MAX_BLOCKS; i++) {
			if (!self.blocks[i].alive) continue;
			Block* b = &self.blocks[i];
			if (self.bird.x + self.bird.radius >= b.x && self.bird.x - self.bird.radius <= b.x + b.w &&
				self.bird.y + self.bird.radius >= b.y && self.bird.y - self.bird.radius <= b.y + b.h) {

				float impact = math::sqrt(self.bird.vx * self.bird.vx + self.bird.vy * self.bird.vy);
				b.hp -= impact * 6.0f;
				b.vx += self.bird.vx * 0.6f;
				b.vy += self.bird.vy * 0.6f;

				self.bird.vx *= 0.5f;
				self.bird.vy *= 0.5f;

				if (b.mat == BlockMaterial.TNT) {
					self.trigger_bomb_explosion(b.x + b.w / 2.0f, b.y + b.h / 2.0f);
					b.alive = false;
				}

				if (self.bird.type == BirdType.BOMB) {
					self.trigger_bomb_explosion(self.bird.x, self.bird.y);
					self.bird.alive = false;
					break;
				}
			}
		}

		// Bird collision against pigs
		for (sz i = 0; i < MAX_PIGS; i++) {
			if (!self.pigs[i].alive) continue;
			Pig* p = &self.pigs[i];
			float dx = p.x - self.bird.x;
			float dy = p.y - self.bird.y;
			float dist = math::sqrt(dx * dx + dy * dy);
			if (dist < p.radius + self.bird.radius) {
				float impact = math::sqrt(self.bird.vx * self.bird.vx + self.bird.vy * self.bird.vy);
				p.hp -= impact * 10.0f;
				p.vx += self.bird.vx * 0.8f;
				p.vy += self.bird.vy * 0.8f;

				self.bird.vx *= 0.5f;
				self.bird.vy *= 0.5f;
			}
		}

		// Bird stopped or out of bounds
		if (self.bird.x > (float)((sz)self.vbuf.width + 10) || self.bird.x < -20.0f ||
			(math::abs(self.bird.vx) < 0.15f && math::abs(self.bird.vy) < 0.2f && self.bird.y >= (float)(ground_y - 6))) {
			self.state = GameState.SETTLING;
			self.settle_timer = 40;
		}
	}

	// 2. Update Blocks (Movement, Gravity & Stacking Collisions)
	for (sz i = 0; i < MAX_BLOCKS; i++) {
		if (!self.blocks[i].alive) continue;
		Block* b = &self.blocks[i];

		if (b.hp <= 0.0f) {
			b.alive = false;
			self.score += 50;
			xray::Color col = (b.mat == BlockMaterial.ICE) ? xray::color_rgb(180, 230, 255) : (b.mat == BlockMaterial.STONE ? xray::color_rgb(170, 170, 170) : xray::color_rgb(190, 120, 60));
			self.spawn_explosion(b.x + b.w / 2.0f, b.y + b.h / 2.0f, 12, col, xray::color_rgb(255, 255, 255));
			continue;
		}

		b.vy += gravity * 0.85f;
		b.x += b.vx;
		b.y += b.vy;
		b.vx *= 0.92f;
		b.vy *= 0.95f;

		// Floor collision
		if (b.y + b.h >= (float)ground_y) {
			b.y = (float)ground_y - b.h;
			if (b.vy > 0.0f) b.vy = -b.vy * 0.15f;
			b.vx *= 0.75f;
		}

		// Block-on-Block collision & stacking
		for (sz j = 0; j < MAX_BLOCKS; j++) {
			if (i == j || !self.blocks[j].alive) continue;
			Block* other = &self.blocks[j];

			// Check overlap
			float overlap_x = math::min(b.x + b.w, other.x + other.w) - math::max(b.x, other.x);
			float overlap_y = math::min(b.y + b.h, other.y + other.h) - math::max(b.y, other.y);

			if (overlap_x > 0.5f && overlap_y > 0.5f) {
				// Resolve along shallowest penetration axis
				if (overlap_y < overlap_x) {
					if (b.y + b.h / 2.0f < other.y + other.h / 2.0f) {
						// b is on top of other (resting/stacking)
						b.y -= overlap_y;
						if (b.vy > 0.0f) b.vy = 0.0f;
						b.vx *= 0.82f;
					} else {
						// b is below other
						b.y += overlap_y;
						if (b.vy < 0.0f) b.vy = 0.0f;
					}
				} else {
					if (b.x + b.w / 2.0f < other.x + other.w / 2.0f) {
						b.x -= overlap_x;
						b.vx *= -0.2f;
					} else {
						b.x += overlap_x;
						b.vx *= -0.2f;
					}
				}
			}
		}
	}

	// 3. Update Pigs (Movement, Gravity & Stacking on Blocks/Floor)
	sz alive_pigs = 0;
	for (sz i = 0; i < MAX_PIGS; i++) {
		if (!self.pigs[i].alive) continue;
		Pig* p = &self.pigs[i];
		alive_pigs++;

		if (p.hp <= 0.0f) {
			p.alive = false;
			self.score += 200;
			self.spawn_explosion(p.x, p.y, 20, xray::color_rgb(120, 230, 60), xray::color_rgb(255, 240, 100));
			continue;
		}

		p.vy += gravity;
		p.x += p.vx;
		p.y += p.vy;
		p.vx *= 0.92f;
		p.vy *= 0.95f;

		// Floor collision
		if (p.y + p.radius >= (float)ground_y) {
			p.y = (float)ground_y - p.radius;
			if (p.vy > 0.0f) p.vy = -p.vy * 0.2f;
			p.vx *= 0.8f;
		}

		// Pig resting/stacking on blocks
		for (sz j = 0; j < MAX_BLOCKS; j++) {
			if (!self.blocks[j].alive) continue;
			Block* b = &self.blocks[j];

			if (p.x + p.radius > b.x && p.x - p.radius < b.x + b.w) {
				// Resting on top of block
				if (p.y + p.radius >= b.y && p.y - p.radius < b.y) {
					p.y = b.y - p.radius;
					if (p.vy > 0.0f) p.vy = 0.0f;
					p.vx *= 0.82f;
				}
			}
		}
	}

	// 4. State Transitions (Settling -> Next bird or Won/Lost)
	if (self.state == GameState.SETTLING) {
		self.settle_timer--;
		if (self.settle_timer <= 0) {
			if (alive_pigs == 0) {
				self.state = GameState.LEVEL_WON;
				if (self.score > self.high_score) self.high_score = self.score;
			} else if (self.birds_left <= 0) {
				self.state = GameState.LEVEL_LOST;
			} else {
				self.prepare_next_bird();
				self.state = GameState.AIMING;
			}
		}
	} else if (alive_pigs == 0 && (self.state == GameState.FLYING || self.state == GameState.AIMING)) {
		self.state = GameState.LEVEL_WON;
		if (self.score > self.high_score) self.high_score = self.score;
	}
}

// ── Tea Model Callbacks ───────────────────────────────────────────────────────

fn milktea::Cmd AvianAssaultModel.init(AvianAssaultModel* self) @dynamic {
	ulong seed = (ulong)c3_time_ms_long();
	srand((uint)seed);

	self.state = GameState.INTRO;
	self.current_level = 0;
	self.menu_selected = 0;
	self.score = 0;
	self.high_score = 0;
	self.ticks = 0;

	return milktea::tick(FRAME_MS);
}

fn milktea::Cmd AvianAssaultModel.update(AvianAssaultModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.term_w = msg.window_size.width;
		self.term_h = msg.window_size.height;
		if (self.vbuf != null) { self.vbuf.destroy(); mem::free(self.vbuf); }
		self.vbuf = xray::new_pixel_buffer((sz)self.term_w, (sz)(self.term_h * 2));
		self.vbuf.clear(xray::color_rgb(20, 24, 40));

		if (self.screen == null) {
			self.screen = xray::new_screen_buffer(self.term_w, self.term_h);
		} else {
			self.screen.resize(self.term_w, self.term_h);
		}
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.ticks++;
		if (self.flash_timer > 0) self.flash_timer--;
		self.update_particles();

		if (self.state == GameState.INTRO && self.ticks > 80) {
			self.state = GameState.MENU;
		}

		if (self.state == GameState.AIMING || self.state == GameState.FLYING || self.state == GameState.SETTLING) {
			self.update_physics();
		}

		return milktea::tick(FRAME_MS);
	}

	// ── Mouse Drag & Slingshot Interaction ────────────────────────────────────
	if (msg.kind == milktea::MsgKind.MOUSE) {
		milktea::MouseMsg m = msg.mouse;
		float mx = (float)m.col;
		float my = (float)(m.row * 2); // terminal cell row -> pixel row

		if (self.state == GameState.AIMING) {
			if (m.action == milktea::MouseAction.MOUSE_PRESS) {
				float dx = mx - self.sling_x;
				float dy = my - self.sling_y;
				if (math::sqrt(dx * dx + dy * dy) < 22.0f) {
					self.is_dragging = true;
					self.drag_x = mx;
					self.drag_y = my;
				}
			} else if (m.action == milktea::MouseAction.MOUSE_MOTION && self.is_dragging) {
				float dx = mx - self.sling_x;
				float dy = my - self.sling_y;
				float dist = math::sqrt(dx * dx + dy * dy);
				float max_drag = 24.0f;
				if (dist > max_drag) {
					self.drag_x = self.sling_x + (dx / dist) * max_drag;
					self.drag_y = self.sling_y + (dy / dist) * max_drag;
				} else {
					self.drag_x = mx;
					self.drag_y = my;
				}
			} else if (m.action == milktea::MouseAction.MOUSE_RELEASE && self.is_dragging) {
				self.is_dragging = false;
				float pull_x = self.sling_x - self.drag_x;
				float pull_y = self.sling_y - self.drag_y;
				float pull_len = math::sqrt(pull_x * pull_x + pull_y * pull_y);
				if (pull_len > 3.0f) {
					float launch_spd = 0.28f;
					self.launch_bird(pull_x * launch_spd, pull_y * launch_spd);
				}
			}
		} else if (self.state == GameState.FLYING && m.action == milktea::MouseAction.MOUSE_PRESS) {
			self.activate_ability();
		}
		return null;
	}

	// ── Keyboard Controls ─────────────────────────────────────────────────────
	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg k = msg.key;
		if (k.code == milktea::KeyCode.CTRL_C) return milktea::quit();

		switch (self.state) {
			case INTRO:
				self.state = GameState.MENU;

			case MENU:
				switch (k.code) {
					case milktea::KeyCode.UP:
						self.menu_selected = (self.menu_selected + 3) % 4;
					case milktea::KeyCode.DOWN:
						self.menu_selected = (self.menu_selected + 1) % 4;
					case milktea::KeyCode.ENTER:
						switch (self.menu_selected) {
							case 0: self.load_level(0);
							case 1: self.current_level = (self.current_level + 1) % MAX_LEVELS;
							case 2: self.state = GameState.HELP;
							case 3: return milktea::quit();
						}
					case milktea::KeyCode.RUNE:
						if (k.rune == 'q' || k.rune == 'Q') return milktea::quit();
						if (k.rune == ' ') self.load_level(self.current_level);
						if (k.rune == 'l' || k.rune == 'L') {
							self.current_level = (self.current_level + 1) % MAX_LEVELS;
						}
						if (k.rune == 'h' || k.rune == 'H' || k.rune == '?') {
							self.state = GameState.HELP;
						}
					default:
				}

			case AIMING:
				switch (k.code) {
					case milktea::KeyCode.LEFT:
						self.key_angle += 2.5f;
						if (self.key_angle > 85.0f) self.key_angle = 85.0f;
					case milktea::KeyCode.RIGHT:
						self.key_angle -= 2.5f;
						if (self.key_angle < 5.0f) self.key_angle = 5.0f;
					case milktea::KeyCode.UP:
						self.key_power += 0.05f;
						if (self.key_power > 1.0f) self.key_power = 1.0f;
					case milktea::KeyCode.DOWN:
						self.key_power -= 0.05f;
						if (self.key_power < 0.2f) self.key_power = 0.2f;
					case milktea::KeyCode.ENTER:
						float rad = self.key_angle * (3.14159265f / 180.0f);
						float spd = self.key_power * 6.5f;
						self.launch_bird(math::cos(rad) * spd, -math::sin(rad) * spd);
					case milktea::KeyCode.ESC:
						self.state = GameState.MENU;
					case milktea::KeyCode.RUNE:
						if (k.rune == ' ') {
							float rad2 = self.key_angle * (3.14159265f / 180.0f);
							float spd2 = self.key_power * 6.5f;
							self.launch_bird(math::cos(rad2) * spd2, -math::sin(rad2) * spd2);
						} else if (k.rune == 'r' || k.rune == 'R') {
							self.load_level(self.current_level);
						} else if (k.rune == 'q' || k.rune == 'Q') {
							self.state = GameState.MENU;
						}
					default:
				}

			case FLYING:
				if (k.code == milktea::KeyCode.ENTER || (k.code == milktea::KeyCode.RUNE && k.rune == ' ')) {
					self.activate_ability();
				} else if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && (k.rune == 'q' || k.rune == 'Q'))) {
					self.state = GameState.MENU;
				}

			case SETTLING:
				if (k.code == milktea::KeyCode.ESC) self.state = GameState.MENU;

			case LEVEL_WON:
				if (k.code == milktea::KeyCode.ENTER || (k.code == milktea::KeyCode.RUNE && (k.rune == ' ' || k.rune == 'n' || k.rune == 'N'))) {
					sz next_lvl = (self.current_level + 1) % MAX_LEVELS;
					self.load_level(next_lvl);
				} else if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && (k.rune == 'm' || k.rune == 'q'))) {
					self.state = GameState.MENU;
				}
				break;

			case LEVEL_LOST:
				if (k.code == milktea::KeyCode.ENTER || (k.code == milktea::KeyCode.RUNE && (k.rune == ' ' || k.rune == 'r' || k.rune == 'R'))) {
					self.load_level(self.current_level);
				} else if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && (k.rune == 'm' || k.rune == 'q'))) {
					self.state = GameState.MENU;
				}
				break;

			case HELP:
				if (k.code == milktea::KeyCode.ESC || k.code == milktea::KeyCode.ENTER || (k.code == milktea::KeyCode.RUNE && (k.rune == ' ' || k.rune == 'q' || k.rune == 'h'))) {
					self.state = GameState.MENU;
				}
				break;
		}
		return null;
	}

	return null;
}

// ── Rendering: Background, Entities, Slingshot & UI ───────────────────────────

fn void AvianAssaultModel.draw_background(&self) {
	sz pw = (sz)self.vbuf.width;
	sz ph = (sz)self.vbuf.height;
	sz ground_y = ph - 10;

	// Sky gradient
	xray::Color sky_top = xray::color_rgb(45, 95, 185);
	xray::Color sky_bot = xray::color_rgb(160, 220, 250);

	for (sz y = 0; y < ground_y; y++) {
		float t = (float)y / (float)ground_y;
		sz r = (sz)((float)sky_top.r * (1.0f - t) + (float)sky_bot.r * t);
		sz g = (sz)((float)sky_top.g * (1.0f - t) + (float)sky_bot.g * t);
		sz b = (sz)((float)sky_top.b * (1.0f - t) + (float)sky_bot.b * t);
		xray::Color sky_line = xray::color_rgb((char)r, (char)g, (char)b);

		sz row_off = (sz)y * (sz)pw;
		for (sz x = 0; x < pw; x++) {
			self.vbuf.pixels[row_off + (sz)x] = sky_line;
		}
	}

	// Distant Mountains
	xray::Color mtn_c = xray::color_rgb(110, 150, 180);
	for (sz x = 0; x < pw; x++) {
		sz my = ground_y - 12 - (sz)(math::sin((float)x * 0.03f) * 8.0f + math::cos((float)x * 0.07f) * 4.0f);
		for (sz y = my; y < ground_y; y++) {
			self.vbuf.set_pixel(x, y, mtn_c);
		}
	}

	// Rolling Hills
	xray::Color hill_c = xray::color_rgb(85, 175, 75);
	for (sz x = 0; x < pw; x++) {
		sz hy = ground_y - 6 - (sz)(math::sin((float)x * 0.05f) * 4.0f);
		for (sz y = hy; y < ground_y; y++) {
			self.vbuf.set_pixel(x, y, hill_c);
		}
	}

	// Ground / Dirt & Grass
	xray::Color grass_c = xray::color_rgb(120, 205, 55);
	xray::Color dirt_c = xray::color_rgb(160, 100, 50);
	self.vbuf.fill_rect(xray::new_rect(0, ground_y, pw, 3), grass_c);
	self.vbuf.fill_rect(xray::new_rect(0, ground_y + 3, pw, ph - (ground_y + 3)), dirt_c);
}

fn void AvianAssaultModel.draw_slingshot(&self) {
	sz ground_y = (sz)self.vbuf.height - 10;
	sz sx = (sz)self.sling_x;
	sz sy = (sz)self.sling_y;

	xray::Color wood_c = xray::color_rgb(120, 70, 30);
	xray::Color wood_dark = xray::color_rgb(75, 40, 15);
	xray::Color rubber_c = xray::color_rgb(50, 30, 20);

	// Main post
	self.vbuf.fill_rect(xray::new_rect(sx - 2, sy, 4, ground_y - sy), wood_c);
	self.vbuf.set_pixel(sx - 2, sy, wood_dark);

	// Y-fork branches
	self.vbuf.fill_rect(xray::new_rect(sx - 7, sy - 8, 3, 9), wood_c);
	self.vbuf.fill_rect(xray::new_rect(sx + 4, sy - 8, 3, 9), wood_c);

	// Rubber bands
	float bird_x = self.is_dragging ? self.drag_x : (self.state == GameState.AIMING ? self.sling_x : self.sling_x);
	float bird_y = self.is_dragging ? self.drag_y : (self.state == GameState.AIMING ? self.sling_y : self.sling_y);

	if (self.state == GameState.AIMING) {
		self.vbuf.draw_line(sx - 6, sy - 7, (sz)bird_x, (sz)bird_y, rubber_c);
		self.vbuf.draw_line(sx + 5, sy - 7, (sz)bird_x, (sz)bird_y, rubber_c);

		// Trajectory trajectory guide dots
		float p_vx, p_vy;
		if (self.is_dragging) {
			p_vx = (self.sling_x - self.drag_x) * 0.28f;
			p_vy = (self.sling_y - self.drag_y) * 0.28f;
		} else {
			float r = self.key_angle * (3.14159265f / 180.0f);
			float s = self.key_power * 6.5f;
			p_vx = math::cos(r) * s;
			p_vy = -math::sin(r) * s;
		}

		float sim_x = bird_x;
		float sim_y = bird_y;
		xray::Color dot_c = xray::color_rgba(255, 255, 255, 180);
		for (sz t = 0; t < 16; t++) {
			sim_x += p_vx * 2.0f;
			sim_y += p_vy * 2.0f;
			p_vy += 0.32f * 2.0f;
			if (sim_y >= (float)ground_y) break;
			self.vbuf.blend_pixel((sz)sim_x, (sz)sim_y, dot_c);
		}
	}
}

fn void AvianAssaultModel.draw_bird_sprite(&self, float bx, float by, BirdType type) {
	sz cx = (sz)bx;
	sz cy = (sz)by;

	xray::Color body_c = xray::color_rgb(230, 40, 30);
	if (type == BirdType.CHUCK) body_c = xray::color_rgb(255, 215, 0);
	if (type == BirdType.BOMB) body_c = xray::color_rgb(35, 35, 40);

	xray::Color beak_c = xray::color_rgb(255, 140, 0);
	xray::Color eye_c = xray::color_rgb(255, 255, 255);
	xray::Color pupil_c = xray::color_rgb(0, 0, 0);
	xray::Color brow_c = xray::color_rgb(20, 20, 20);

	if (type == BirdType.RED) {
		// 7x7 round body
		for (sz dy = -3; dy <= 3; dy++) {
			for (sz dx = -3; dx <= 3; dx++) {
				if (dx * dx + dy * dy <= 10) {
					self.vbuf.set_pixel(cx + dx, cy + dy, body_c);
				}
			}
		}
		// Eyebrows & Eyes
		self.vbuf.set_pixel(cx, cy - 2, brow_c);
		self.vbuf.set_pixel(cx + 1, cy - 1, brow_c);
		self.vbuf.set_pixel(cx + 2, cy - 1, brow_c);
		self.vbuf.set_pixel(cx + 1, cy, eye_c);
		self.vbuf.set_pixel(cx + 2, cy, pupil_c);
		// Beak
		self.vbuf.set_pixel(cx + 3, cy + 1, beak_c);
		self.vbuf.set_pixel(cx + 4, cy + 1, beak_c);
	} else if (type == BirdType.CHUCK) {
		// Triangle body pointing right
		for (sz dx = -3; dx <= 4; dx++) {
			sz h = (4 - dx) / 2 + 1;
			for (sz dy = -h; dy <= h; dy++) {
				self.vbuf.set_pixel(cx + dx, cy + dy, body_c);
			}
		}
		self.vbuf.set_pixel(cx + 1, cy - 1, brow_c);
		self.vbuf.set_pixel(cx + 1, cy, eye_c);
		self.vbuf.set_pixel(cx + 2, cy, pupil_c);
		self.vbuf.set_pixel(cx + 4, cy + 1, beak_c);
		self.vbuf.set_pixel(cx + 5, cy + 1, beak_c);
	} else {
		// Bomb (Larger round body with fuse)
		for (sz dy = -4; dy <= 4; dy++) {
			for (sz dx = -4; dx <= 4; dx++) {
				if (dx * dx + dy * dy <= 17) {
					self.vbuf.set_pixel(cx + dx, cy + dy, body_c);
				}
			}
		}
		// Fuse top
		self.vbuf.set_pixel(cx, cy - 5, xray::color_rgb(255, 200, 50));
		self.vbuf.set_pixel(cx, cy - 6, xray::color_rgb(255, 60, 20));
		// Angry Eyes
		self.vbuf.set_pixel(cx + 1, cy - 1, brow_c);
		self.vbuf.set_pixel(cx + 2, cy - 1, brow_c);
		self.vbuf.set_pixel(cx + 2, cy, eye_c);
		self.vbuf.set_pixel(cx + 3, cy, pupil_c);
		self.vbuf.set_pixel(cx + 4, cy + 1, beak_c);
	}
}

fn void AvianAssaultModel.draw_pig_sprite(&self, Pig* p) {
	sz cx = (sz)p.x;
	sz cy = (sz)p.y;
	sz r = (sz)p.radius;

	xray::Color skin_c = xray::color_rgb(115, 215, 55);
	xray::Color snout_c = xray::color_rgb(85, 175, 35);
	xray::Color eye_c = xray::color_rgb(255, 255, 255);
	xray::Color pupil_c = xray::color_rgb(0, 0, 0);

	for (sz dy = -r; dy <= r; dy++) {
		for (sz dx = -r; dx <= r; dx++) {
			if (dx * dx + dy * dy <= r * r) {
				self.vbuf.set_pixel(cx + dx, cy + dy, skin_c);
			}
		}
	}

	// Snout
	self.vbuf.fill_rect(xray::new_rect(cx - 2, cy, 4, 3), snout_c);
	self.vbuf.set_pixel(cx - 1, cy + 1, pupil_c);
	self.vbuf.set_pixel(cx + 1, cy + 1, pupil_c);

	// Eyes
	self.vbuf.set_pixel(cx - 2, cy - 2, eye_c);
	self.vbuf.set_pixel(cx - 2, cy - 1, eye_c);
	self.vbuf.set_pixel(cx - 2, cy - 1, pupil_c);

	self.vbuf.set_pixel(cx + 2, cy - 2, eye_c);
	self.vbuf.set_pixel(cx + 2, cy - 1, eye_c);
	self.vbuf.set_pixel(cx + 2, cy - 1, pupil_c);
}

fn void AvianAssaultModel.draw_blocks(&self) {
	for (sz i = 0; i < MAX_BLOCKS; i++) {
		if (!self.blocks[i].alive) continue;
		Block* b = &self.blocks[i];
		sz bx = (sz)b.x;
		sz by = (sz)b.y;
		sz bw = (sz)b.w;
		sz bh = (sz)b.h;

		xray::Color col = xray::color_rgb(180, 110, 50);
		xray::Color border_c = xray::color_rgb(120, 70, 30);

		if (b.mat == BlockMaterial.ICE) {
			col = xray::color_rgb(160, 225, 255);
			border_c = xray::color_rgb(100, 180, 230);
		} else if (b.mat == BlockMaterial.STONE) {
			col = xray::color_rgb(150, 150, 155);
			border_c = xray::color_rgb(90, 90, 95);
		} else if (b.mat == BlockMaterial.TNT) {
			col = xray::color_rgb(220, 45, 35);
			border_c = xray::color_rgb(130, 20, 15);
		}

		self.vbuf.fill_rect(xray::new_rect(bx, by, bw, bh), col);

		// Dark border
		for (sz x = 0; x < bw; x++) {
			self.vbuf.set_pixel(bx + x, by, border_c);
			self.vbuf.set_pixel(bx + x, by + bh - 1, border_c);
		}
		for (sz y = 0; y < bh; y++) {
			self.vbuf.set_pixel(bx, by + y, border_c);
			self.vbuf.set_pixel(bx + bw - 1, by + y, border_c);
		}

		// TNT label
		if (b.mat == BlockMaterial.TNT && bw >= 8 && bh >= 8) {
			self.vbuf.fill_rect(xray::new_rect(bx + 1, by + bh / 2 - 1, bw - 2, 3), xray::color_rgb(255, 255, 255));
			self.vbuf.set_pixel(bx + bw / 2 - 2, by + bh / 2, xray::color_rgb(0, 0, 0));
			self.vbuf.set_pixel(bx + bw / 2, by + bh / 2, xray::color_rgb(0, 0, 0));
			self.vbuf.set_pixel(bx + bw / 2 + 2, by + bh / 2, xray::color_rgb(0, 0, 0));
		}
	}
}

// ── Screen Conversion & Overlay Painting ──────────────────────────────────────

fn milktea::Node* AvianAssaultModel.view(AvianAssaultModel* self) @dynamic {
	if (self.screen == null) return milktea::text("");

	// 1. Draw procedural world into pixel buffer
	self.draw_background();

	if (self.state != GameState.INTRO) {
		// Draw Trail
		xray::Color trail_c = xray::color_rgba(255, 255, 255, 140);
		for (sz i = 0; i < MAX_TRAIL; i++) {
			if (self.trail[i].active) {
				self.vbuf.blend_pixel((sz)self.trail[i].x, (sz)self.trail[i].y, trail_c);
			}
		}

		// Draw Blocks & Pigs
		self.draw_blocks();
		for (sz i = 0; i < MAX_PIGS; i++) {
			if (self.pigs[i].alive) self.draw_pig_sprite(&self.pigs[i]);
		}

		// Draw Slingshot
		self.draw_slingshot();

		// Draw active bird
		if (self.bird.alive) {
			float bx = self.is_dragging ? self.drag_x : (self.state == GameState.AIMING ? self.sling_x : self.bird.x);
			float by = self.is_dragging ? self.drag_y : (self.state == GameState.AIMING ? self.sling_y : self.bird.y);
			self.draw_bird_sprite(bx, by, self.bird.type);
		}

		// Draw Birds queue on ground
		sz ground_y = (sz)self.vbuf.height - 10;
		for (sz b = 0; b < self.birds_left - 1; b++) {
			sz idx = 3 - (self.birds_left - 1 - b);
			if (idx >= 0 && idx < 3) {
				self.draw_bird_sprite(self.sling_x - 12.0f - (float)(b * 9), (float)(ground_y - 4), self.birds_queue[idx]);
			}
		}

		// Draw particles
		for (sz i = 0; i < MAX_PARTICLES; i++) {
			if (self.particles[i].active) {
				self.vbuf.set_pixel((sz)self.particles[i].x, (sz)self.particles[i].y, self.particles[i].color);
			}
		}
	}

	// Flash effect
	if (self.flash_timer > 0) {
		xray::Color fl = xray::color_rgba(255, 255, 255, 180);
		for (sz i = 0; i < (sz)self.vbuf.width * (sz)self.vbuf.height; i++) {
			self.vbuf.pixels[i] = fl.blend_over(self.vbuf.pixels[i]);
		}
	}

	// 2. Convert the pixels to cells, two pixel rows to each, then paint the
	// HUD and this state's dialog over them. They go into the game's own cells
	// rather than a layer above them, so a dialog's backdrop can dim the
	// pixels it covers.
	self.vbuf.to_half_blocks(self.screen);

	milktea::Node* ui = milktea::root();
	switch (self.state) {
		case AIMING:
		case FLYING:
		case SETTLING:   ui.add(self.hud());
		case INTRO:      ui.add(self.intro_dialog());
		case MENU:       ui.add(self.menu_dialog());
		case LEVEL_WON:  ui.add(self.won_dialog());
		case LEVEL_LOST: ui.add(self.lost_dialog());
		case HELP:       ui.add(self.help_dialog());
		default:
	}
	ui.solve(xray::new_rect(0, 0, self.screen.width, self.screen.height));
	self.screen.paint(ui);

	return milktea::canvas(self.screen);
}

// ── HUD & Dialogs ─────────────────────────────────────────────────────────────

// hud is what shows during play: the score in the top left, and the keys
// along the bottom, where they have the screen's whole width.
fn milktea::Node* AvianAssaultModel.hud(&self) {
	return milktea::zstack()
		.add(line(string::tformat("LEVEL %d  |  SCORE: %d  |  HIGH: %d  |  BIRDS: %d",
			self.current_level + 1, self.score, self.high_score, self.birds_left),
			xray::color_rgb(255, 255, 255), bold: true)
			.at(2, 1))
		.add(line("[DRAG/ARROWS] Aim  |  [SPACE/CLICK] Boost  |  [R] Reset  |  [ESC] Menu",
			xray::color_rgb(230, 240, 255))
			.place(milktea::CENTER, milktea::ALIGN_END));
}

// Panel is a dialog's backdrop. It dims the game behind the dialog without
// hiding it — the half blocks keep their glyphs and both their colors are
// tinted — and frames it with a gradient border unless it is bare.
struct Panel (xray::Content) {
	xray::Color tint;
	xray::Color edge_from;
	xray::Color edge_to;
	bool bare;
}

fn void Panel.paint(&self, ScreenBuffer* dst, xray::Rect r) @dynamic {
	for (sz y = r.y; y < r.y + r.h; y++) {
		for (sz x = r.x; x < r.x + r.w; x++) {
			if (x < 0 || y < 0 || x >= dst.width || y >= dst.height) continue;
			xray::Cell* c = &dst.cells[y * dst.width + x];
			c.style.fg = self.tint.blend_over(c.style.fg);
			c.style.bg = self.tint.blend_over(c.style.bg);
		}
	}
	// The border sets no background of its own, so it sits on the tint too.
	if (!self.bare) dst.draw_gradient_border(r, xray::ROUNDED, self.edge_from, self.edge_to);
}

// panel is a dialog box centred on screen, as wide as width or, at 0, as its
// widest line. Its first line sits under the top border, and the rest stack
// below it with a blank row between each.
fn milktea::Node* panel(sz width, xray::Color tint, xray::Color edge_from, xray::Color edge_to) {
	Panel* p = mem::tnew(Panel);
	*p = { tint, edge_from, edge_to, false };
	milktea::Node* n = milktea::component(p);
	if (width > 0) n.width(milktea::cells(width));
	return n
		// The border takes the outer row and column on each side.
		.with_padding(1, 3, 1, 3)
		.with_gap(1)
		.with_align(milktea::ALIGN_CENTER)
		.center();
}

// backdrop dims the game behind its lines with no border: a blurred shadow
// of the same shade fades its edges out into the scene.
fn milktea::Node* backdrop(xray::Color tint) {
	Panel* p = mem::tnew(Panel);
	*p = { .tint = tint, .bare = true };
	return milktea::component(p)
		.with_padding(1, 4, 1, 4)
		.with_gap(1)
		.with_align(milktea::ALIGN_CENTER)
		.shadow(xray::shadow(0, 0, tint.a, blur: 3).with_color(xray::color_rgb(tint.r, tint.g, tint.b)));
}

fn milktea::Node* line(String s, xray::Color fg, bool bold = false) {
	return milktea::text(s, glaze::style().foreground(fg).with_bold(bold));
}

// lines stacks strings one under the other, a blank row between each.
fn milktea::Node* lines(String[] items, xray::Color fg) {
	milktea::Node* col = milktea::vstack().with_gap(1);
	foreach (s : items) col.add(line(s, fg));
	return col;
}

// logo stacks the rows of a block-letter word, each shaded from one color to
// the other.
fn milktea::Node* logo(String[] rows, xray::Color from, xray::Color to) {
	milktea::Node* col = milktea::vstack();
	foreach (r : rows) col.add(milktea::text(glaze::gradient_text(r, from, to, true)));
	return col;
}

const String[6] AVIAN = {
	"  █████╗ ██╗   ██╗██╗ █████╗ ███╗   ██╗",
	" ██╔══██╗██║   ██║██║██╔══██╗████╗  ██║",
	" ███████║██║   ██║██║███████║██╔██╗ ██║",
	" ██╔══██║╚██╗ ██╔╝██║██╔══██║██║╚██╗██║",
	" ██║  ██║ ╚████╔╝ ██║██║  ██║██║ ╚████║",
	" ╚═╝  ╚═╝  ╚═══╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝",
};

const String[6] ASSAULT = {
	" █████╗ ███████╗███████╗█████╗ ██╗   ██╗██╗  ████████╗",
	"██╔══██╗██╔════╝██╔════╝██╔══██╗██║   ██║██║  ╚══██╔══╝",
	"███████║███████╗███████╗███████║██║   ██║██║     ██║   ",
	"██╔══██║╚════██║╚════██║██╔══██║██║   ██║██║     ██║   ",
	"██║  ██║███████║███████║██║  ██║╚██████╔╝███████╗██║   ",
	"╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝   ",
};

fn milktea::Node* AvianAssaultModel.intro_dialog(&self) {
	float pulse = (math::sin((float)self.ticks * 0.15f) + 1.0f) * 0.5f;
	xray::Color c1 = xray::color_rgb(255, (char)(60 + pulse * 60), 30);
	xray::Color c2 = xray::color_rgb(255, 220, 50);

	// The prompt blinks without moving what is below it: at alpha 0 it keeps
	// its place in the layout and paints nothing.
	bool blink_on = (self.ticks / 10) % 2 == 0;

	return backdrop(xray::color_rgba(28, 14, 16, 150))
		.center()
		.add(milktea::vstack()
			.with_align(milktea::ALIGN_CENTER)
			.add(logo(AVIAN[..], c1, c2))
			.add(logo(ASSAULT[..], c2, c1)))
		.add(line("░▒▓ RETRO PHYSICS ARCADE ▓▒░", xray::color_rgb(255, 240, 200), bold: true))
		.add(line("Press any key to enter...", xray::color_rgb(255, 230, 100))
			.alpha(blink_on ? 255 : 0));
}

fn milktea::Node* AvianAssaultModel.menu_dialog(&self) {
	String[4] options = {
		"Play Game",
		string::tformat("Select Level: [Level %d]", self.current_level + 1),
		"How to Play",
		"Exit",
	};

	milktea::Node* items = milktea::vstack().with_gap(1).with_align(milktea::ALIGN_CENTER);
	foreach (i, opt : options) {
		bool sel = i == self.menu_selected;
		glaze::Style s = sel
			? glaze::style().foreground(xray::color_rgb(255, 245, 120)).with_bold(true)
				.background(xray::color_rgba(110, 30, 25, 210))
			: glaze::style().foreground(xray::color_rgb(240, 210, 205));
		items.add(milktea::text(string::tformat(sel ? "▶ %s ◀" : "  %s  ", opt), s));
	}

	// A fiery red-to-orange border over a dark crimson backdrop.
	return panel(46, xray::color_rgba(28, 14, 16, 178),
			xray::color_rgb(255, 60, 40), xray::color_rgb(255, 140, 20))
		.add(milktea::text(glaze::gradient_text(" ★ AVIAN ASSAULT ★ ",
			xray::color_rgb(255, 220, 80), xray::color_rgb(255, 75, 45), true)))
		.add(items)
		.add(line(string::tformat("🏆 High Score: %d", self.high_score), xray::color_rgb(255, 185, 40), bold: true));
}

fn milktea::Node* AvianAssaultModel.won_dialog(&self) {
	// Three stars, one lost for each bird used past the first.
	String stars = "⭐⭐⭐";
	if (self.birds_left == 1) stars = "⭐⭐";
	if (self.birds_left == 0) stars = "⭐";

	// The stats are one left-aligned block, centred as a whole.
	milktea::Node* stats = milktea::vstack().with_gap(1)
		.add(line(string::tformat("Score: %d", self.score), xray::color_rgb(255, 255, 255), bold: true))
		.add(line(string::tformat("Best:  %d", self.high_score), xray::color_rgb(255, 215, 0), bold: true));

	return panel(42, xray::color_rgba(10, 25, 15, 178),
			xray::color_rgb(100, 255, 100), xray::color_rgb(255, 215, 0))
		.add(milktea::text(glaze::gradient_text(" ★ LEVEL CLEARED! ★ ",
			xray::color_rgb(120, 255, 120), xray::color_rgb(255, 230, 80), true)))
		.add(milktea::text(stars))
		.add(stats)
		.add(line("[SPACE] Next Level  |  [M] Menu", xray::color_rgb(220, 240, 255)));
}

fn milktea::Node* AvianAssaultModel.lost_dialog(&self) {
	return panel(40, xray::color_rgba(25, 10, 15, 178),
			xray::color_rgb(255, 60, 60), xray::color_rgb(255, 140, 40))
		.add(line(" 💀 LEVEL FAILED 💀 ", xray::color_rgb(255, 70, 70), bold: true))
		.add(line("You ran out of birds!", xray::color_rgb(240, 200, 200)))
		.add(line("[SPACE] Retry  |  [M] Menu", xray::color_rgb(220, 240, 255)));
}

const String[5] HOW_TO_PLAY = {
	"• Drag slingshot with Mouse or use Arrows",
	"• Press [SPACE] / [ENTER] to launch bird",
	"• Mid-flight [SPACE] / [CLICK] triggers abilities:",
	"  - ⚡ Yellow Chuck: Speed turbo dive",
	"  - 💣 Black Bomb: Explosive blast wave",
};

fn milktea::Node* AvianAssaultModel.help_dialog(&self) {
	return panel(0, xray::color_rgba(12, 16, 28, 178),
			xray::color_rgb(80, 200, 255), xray::color_rgb(140, 100, 255))
		.add(milktea::text(glaze::gradient_text(" HOW TO PLAY ",
			xray::color_rgb(100, 220, 255), xray::color_rgb(200, 150, 255), true)))
		.add(lines(HOW_TO_PLAY[..], xray::color_rgb(220, 230, 245)))
		.add(line("[Press SPACE or ESC to Return]", xray::color_rgb(255, 215, 100)));
}

// ── Main Entry Point ──────────────────────────────────────────────────────────

fn int main() {
	AvianAssaultModel* m = mem::new(AvianAssaultModel);
	if (catch err = milktea::@run_program(m, { .alt_screen = true, .mouse_mode = milktea::MouseMode.MOUSE_MODE_CELL_MOTION, .mouse_cursor = "crosshair" })) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Thanks for playing Avian Assault!");
	return 0;
}
