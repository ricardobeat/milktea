module flappybird;

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
const sz MAX_PIPES = 8;
const sz MAX_PARTICLES = 120;
const sz PIPE_WIDTH = 9; // width in pixel columns
const sz PIPE_SPACING = 38; // pixel distance between pipe columns

enum GameState : char {
	INTRO,      // Animated splash screen with floating bird & glowing title
	MENU,       // Main menu (Start, Difficulty, High Scores, How to Play)
	PLAYING,    // Active gameplay
	DYING,      // Flash & bird tumble animation
	GAME_OVER,  // Score board, medals, restart prompt
	HELP,       // Instructions overlay
}

enum Difficulty : char {
	EASY,
	NORMAL,
	HARD,
}

// ── Structs ───────────────────────────────────────────────────────────────────

struct Pipe {
	float x;        // pixel x (sub-cell)
	sz gap_y;      // center of gap in pixel coordinates
	sz gap_size;   // height of gap in pixel rows
	bool scored;
	bool active;
	float speed_y;  // for dynamic moving pipes in hard mode
	sz min_gap_y;
	sz max_gap_y;
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

struct Bird {
	float x;
	float y;
	float vy;
	float angle; // tilt in radians
	sz flap_frame;
}



// ── Model ─────────────────────────────────────────────────────────────────────

struct FlappyModel {
	sz term_w;
	sz term_h;
	sz ticks;

	GameState state;
	Difficulty difficulty;
	sz menu_selected; // 0: Play, 1: Difficulty, 2: Help, 3: Quit

	// Game entities
	Bird bird;
	Pipe[MAX_PIPES] pipes;
	Particle[MAX_PARTICLES] particles;

	sz score;
	sz high_score;
	sz death_timer;
	float world_scroll;

	// Flash effect on hit
	sz flash_timer;

	// Graphics buffer
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

// ── Particle System ───────────────────────────────────────────────────────────

fn void FlappyModel.spawn_particle(&self, float x, float y, float vx, float vy, sz life, xray::Color c) {
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

fn void FlappyModel.spawn_feathers(&self, float x, float y, sz count) {
	for (sz i = 0; i < count; i++) {
		float angle = rnd_float(0.0f, 6.28318f);
		float speed = rnd_float(1.5f, 5.0f);
		float vx = math::cos(angle) * speed;
		float vy = math::sin(angle) * speed - 1.0f;
		xray::Color c = (i % 2 == 0) ? xray::color_rgb(255, 215, 0) : xray::color_rgb(255, 90, 30);
		self.spawn_particle(x, y, vx, vy, rnd_int(15, 30), c);
	}
}

fn void FlappyModel.spawn_score_sparkles(&self, float x, float y) {
	for (sz i = 0; i < 14; i++) {
		float angle = rnd_float(0.0f, 6.28318f);
		float speed = rnd_float(1.0f, 4.0f);
		xray::Color c = (i % 3 == 0) ? xray::color_rgb(255, 255, 100) : (i % 3 == 1 ? xray::color_rgb(100, 255, 255) : xray::color_rgb(255, 255, 255));
		self.spawn_particle(x, y, math::cos(angle) * speed, math::sin(angle) * speed, rnd_int(12, 22), c);
	}
}

fn void FlappyModel.update_particles(&self) {
	for (sz i = 0; i < MAX_PARTICLES; i++) {
		if (!self.particles[i].active) continue;
		self.particles[i].x += self.particles[i].vx;
		self.particles[i].y += self.particles[i].vy;
		self.particles[i].vy += 0.15f; // particle gravity
		self.particles[i].life--;
		if (self.particles[i].life <= 0) {
			self.particles[i].active = false;
		}
	}
}

// ── Game Reset / Init ─────────────────────────────────────────────────────────

fn void FlappyModel.start_game(&self) {
	self.state = GameState.PLAYING;
	self.score = 0;
	self.flash_timer = 0;
	self.world_scroll = 0.0f;

	sz py = self.vbuf.height > 0 ? (sz)self.vbuf.height / 2 : 25;
	self.bird = (Bird){
		.x = 18.0f,
		.y = (float)py,
		.vy = -1.5f,
		.angle = 0.0f,
		.flap_frame = 0,
	};

	// Reset particles
	for (sz i = 0; i < MAX_PARTICLES; i++) {
		self.particles[i].active = false;
	}

	// Gap size according to difficulty
	sz gap = 17;
	if (self.difficulty == Difficulty.EASY) gap = 21;
	if (self.difficulty == Difficulty.HARD) gap = 13;

	// Reset pipes
	float start_x = (float)((sz)self.vbuf.width + 10);
	for (sz i = 0; i < MAX_PIPES; i++) {
		sz min_y = 12;
		sz max_y = (sz)self.vbuf.height - 20;
		if (max_y <= min_y) max_y = min_y + 10;
		sz gy = rnd_int(min_y, max_y);

		self.pipes[i] = (Pipe){
			.x = start_x + (float)(i * PIPE_SPACING),
			.gap_y = gy,
			.gap_size = gap,
			.scored = false,
			.active = true,
			.speed_y = (self.difficulty == Difficulty.HARD && i % 2 == 1) ? 0.4f : 0.0f,
			.min_gap_y = min_y,
			.max_gap_y = max_y,
		};
	}
}

// ── Tea Model Callbacks ───────────────────────────────────────────────────────

fn milktea::Cmd FlappyModel.init(FlappyModel* self) @dynamic {
	ulong seed = (ulong)c3_time_ms_long();
	srand((uint)seed);

	self.state = GameState.INTRO;
	self.difficulty = Difficulty.NORMAL;
	self.menu_selected = 0;
	self.score = 0;
	self.high_score = 0;
	self.ticks = 0;

	return milktea::tick(FRAME_MS);
}

fn milktea::Cmd FlappyModel.update(FlappyModel* self, milktea::Msg msg) @dynamic {
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

		float scroll_spd = 0.8f;
		if (self.state == GameState.PLAYING) {
			scroll_spd = (self.difficulty == Difficulty.HARD) ? 1.4f : 1.0f;
		}
		self.world_scroll += scroll_spd;

		// State-specific updates
		switch (self.state) {
			case INTRO:
				if (self.ticks > 80) {
					self.state = GameState.MENU;
				}
			case MENU:
				// gentle bobbing
				self.bird.y = 26.0f + math::sin((float)self.ticks * 0.1f) * 4.0f;
				self.bird.flap_frame = (self.ticks / 6) % 3;
			case PLAYING:
				// Bird physics
				self.bird.vy += 0.38f; // gravity
				if (self.bird.vy > 2.6f) self.bird.vy = 2.6f;
				self.bird.y += self.bird.vy;

				// Bird angle based on velocity
				float target_angle = self.bird.vy * 0.28f;
				if (target_angle > 1.2f) target_angle = 1.2f;
				if (target_angle < -0.8f) target_angle = -0.8f;
				self.bird.angle = self.bird.angle * 0.7f + target_angle * 0.3f;

				self.bird.flap_frame = (self.bird.vy < 0.0f) ? (self.ticks / 3) % 3 : 1;

				// Bounds collision (floor/ceiling)
				sz ground_y = (sz)self.vbuf.height - 8;
				if (self.bird.y >= (float)(ground_y - 2) || self.bird.y <= 1.0f) {
					self.trigger_death();
				}

				// Update pipes
				float pipe_speed = (self.difficulty == Difficulty.HARD) ? 1.4f : 1.0f;
				for (sz i = 0; i < MAX_PIPES; i++) {
					if (!self.pipes[i].active) continue;
					self.pipes[i].x -= pipe_speed;

					// Vertical oscillation for hard mode
					if (self.pipes[i].speed_y != 0.0f) {
						self.pipes[i].gap_y += (sz)(self.pipes[i].speed_y * 1.5f);
						if (self.pipes[i].gap_y <= self.pipes[i].min_gap_y || self.pipes[i].gap_y >= self.pipes[i].max_gap_y) {
							self.pipes[i].speed_y = -self.pipes[i].speed_y;
						}
					}

					// Scoring
					if (!self.pipes[i].scored && self.pipes[i].x + (float)PIPE_WIDTH < self.bird.x) {
						self.pipes[i].scored = true;
						self.score++;
						if (self.score > self.high_score) {
							self.high_score = self.score;
						}
						self.spawn_score_sparkles(self.bird.x + 4.0f, self.bird.y);
					}

					// Recycle pipe
					if (self.pipes[i].x < -(float)PIPE_WIDTH) {
						// Find furthest pipe x
						float max_x = 0.0f;
						for (sz j = 0; j < MAX_PIPES; j++) {
							if (self.pipes[j].x > max_x) max_x = self.pipes[j].x;
						}
						self.pipes[i].x = max_x + (float)PIPE_SPACING;
						sz min_y = 12;
						sz max_y = (sz)self.vbuf.height - 20;
						if (max_y <= min_y) max_y = min_y + 10;
						self.pipes[i].gap_y = rnd_int(min_y, max_y);
						self.pipes[i].scored = false;
					}

					// Collision detection (Bird is 6x4 pixels)
					float bx = self.bird.x;
					float by = self.bird.y;
					float px = self.pipes[i].x;
					sz gy = self.pipes[i].gap_y;
					sz gs = self.pipes[i].gap_size;

					if (bx + 5.0f >= px && bx <= px + (float)PIPE_WIDTH) {
						sz top_pipe_bottom = gy - gs / 2;
						sz bot_pipe_top = gy + gs / 2;

						if (by - 2.0f < (float)top_pipe_bottom || by + 2.0f > (float)bot_pipe_top) {
							self.trigger_death();
						}
					}
				}

			case DYING:
				self.bird.vy += 0.45f;
				self.bird.y += self.bird.vy;
				self.bird.angle += 0.25f;
				self.death_timer--;
				if (self.death_timer <= 0) {
					self.state = GameState.GAME_OVER;
				}
				break;

			case GAME_OVER:
			case HELP:
				break;
		}

		return milktea::tick(FRAME_MS);
	}

	// ── Input Handling ───────────────────────────────────────────────────────
	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg k = msg.key;

		if (k.code == milktea::KeyCode.CTRL_C) {
			return milktea::quit();
		}

		switch (self.state) {
			case INTRO:
				// Any key skips intro
				self.state = GameState.MENU;

			case MENU:
				switch (k.code) {
					case milktea::KeyCode.UP:
						self.menu_selected = (self.menu_selected + 3) % 4;
					case milktea::KeyCode.DOWN:
						self.menu_selected = (self.menu_selected + 1) % 4;
					case milktea::KeyCode.ENTER:
						switch (self.menu_selected) {
							case 0:
								self.start_game();
							case 1:
								self.difficulty = (Difficulty)(((sz)self.difficulty + 1) % 3);
							case 2:
								self.state = GameState.HELP;
							case 3:
								return milktea::quit();
						}
					case milktea::KeyCode.RUNE:
						if (k.rune == 'q' || k.rune == 'Q') return milktea::quit();
						if (k.rune == ' ') {
							switch (self.menu_selected) {
								case 0:
									self.start_game();
								case 1:
									self.difficulty = (Difficulty)(((sz)self.difficulty + 1) % 3);
								case 2:
									self.state = GameState.HELP;
								case 3:
									return milktea::quit();
							}
						}
						if (k.rune == ' ') self.start_game();
						if (k.rune == 'd' || k.rune == 'D') {
							self.difficulty = (Difficulty)(((sz)self.difficulty + 1) % 3);
						}
						if (k.rune == 'h' || k.rune == 'H' || k.rune == '?') {
							self.state = GameState.HELP;
						}
					default:
				}

			case PLAYING:
				if (k.code == milktea::KeyCode.UP || (k.code == milktea::KeyCode.RUNE && (k.rune == ' ' || k.rune == 'w' || k.rune == 'W' || k.rune == 'k' || k.rune == 'j'))) {
					self.bird_flap();
				} else if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && (k.rune == 'q' || k.rune == 'Q'))) {
					self.state = GameState.MENU;
				}

			case DYING:
				// Locked input during death tumble
				break;

			case GAME_OVER:
				if (k.code == milktea::KeyCode.ENTER || (k.code == milktea::KeyCode.RUNE && (k.rune == ' ' || k.rune == 'r' || k.rune == 'R'))) {
					self.start_game();
				} else if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && (k.rune == 'm' || k.rune == 'M' || k.rune == 'q' || k.rune == 'Q'))) {
					self.state = GameState.MENU;
				}
				break;

			case HELP:
				if (k.code == milktea::KeyCode.ESC || k.code == milktea::KeyCode.ENTER || (k.code == milktea::KeyCode.RUNE && (k.rune == ' ' || k.rune == 'q' || k.rune == 'h'))) {
					self.state = GameState.MENU;
				}
		}
		return null;
	}

	return null;
}

fn void FlappyModel.bird_flap(&self) {
	self.bird.vy = -2.1f;
}

fn void FlappyModel.trigger_death(&self) {
	if (self.state == GameState.DYING || self.state == GameState.GAME_OVER) return;
	self.state = GameState.DYING;
	self.death_timer = 24;
	self.flash_timer = 4;
	self.bird.vy = -2.5f;
	self.spawn_feathers(self.bird.x + 3.0f, self.bird.y, 25);
}

// ── Rendering: Procedural Art & Half-block Graphics ────────────────────────────

// Draw dynamic procedural background with city skyline, clouds, hills, and ground
fn void FlappyModel.draw_background(&self) {
	sz pw = (sz)self.vbuf.width;
	sz ph = (sz)self.vbuf.height;
	sz ground_y = ph - 8;

	// Sky gradient (day to sunset tones based on difficulty/mode)
	xray::Color sky_top = (self.difficulty == Difficulty.HARD) ? xray::color_rgb(30, 20, 60) : xray::color_rgb(35, 75, 150);
	xray::Color sky_bot = (self.difficulty == Difficulty.HARD) ? xray::color_rgb(180, 70, 60) : xray::color_rgb(140, 210, 245);

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

	// Distant Clouds (Parallax 0.15x)
	float cloud_scroll = self.world_scroll * 0.15f;
	xray::Color cloud_c = xray::color_rgba(255, 255, 255, 170);
	for (sz i = 0; i < 5; i++) {
		sz cx = (sz)((float)(i * 45 + 10) - cloud_scroll) % (pw + 50);
		if (cx < -40) cx += pw + 50;
		sz cy = 8 + (i % 3) * 6;
		// Cloud shape
		for (sz dx = -14; dx <= 14; dx++) {
			for (sz dy = -4; dy <= 4; dy++) {
				if (dx * dx * 2 + dy * dy * 14 < 160) {
					self.vbuf.blend_pixel(cx + dx, cy + dy, cloud_c);
				}
			}
		}
	}

	// Distant Skyline / Mountain silhouettes (Parallax 0.35x)
	float sky_scroll = self.world_scroll * 0.35f;
	xray::Color bldg_c = (self.difficulty == Difficulty.HARD) ? xray::color_rgb(50, 30, 65) : xray::color_rgb(60, 110, 155);
	xray::Color win_c = xray::color_rgb(255, 230, 120);

	for (sz b = 0; b < 15; b++) {
		sz bw = 10 + (b * 7) % 11;
		sz bh = 14 + (b * 13) % 22;
		sz bx = (sz)((float)(b * 22) - sky_scroll) % (pw + 30);
		if (bx < -30) bx += pw + 30;
		sz by = ground_y - bh;

		self.vbuf.fill_rect(xray::new_rect(bx, by, bw, bh), bldg_c);

		// Windows
		for (sz wy = by + 2; wy < ground_y - 2; wy += 4) {
			for (sz wx = bx + 2; wx < bx + bw - 2; wx += 3) {
				if ((b + wx + wy) % 5 != 0) {
					self.vbuf.set_pixel(wx, wy, win_c);
				}
			}
		}
	}

	// Green Hills (Parallax 0.6x)
	float hill_scroll = self.world_scroll * 0.6f;
	xray::Color hill_c = (self.difficulty == Difficulty.HARD) ? xray::color_rgb(45, 80, 50) : xray::color_rgb(75, 175, 80);
	for (sz x = 0; x < pw; x++) {
		float hx = (float)x + hill_scroll;
		sz hy = ground_y - 6 - (sz)(math::sin(hx * 0.04f) * 5.0f + math::cos(hx * 0.09f) * 3.0f);
		for (sz y = hy; y < ground_y; y++) {
			self.vbuf.set_pixel(x, y, hill_c);
		}
	}

	// Ground / Grass & Dirt (Parallax 1.0x)
	xray::Color grass_c = xray::color_rgb(115, 200, 55);
	xray::Color dirt_c = xray::color_rgb(190, 130, 70);
	xray::Color dirt_dark = xray::color_rgb(140, 90, 45);

	self.vbuf.fill_rect(xray::new_rect(0, ground_y, pw, 2), grass_c);
	self.vbuf.fill_rect(xray::new_rect(0, ground_y + 2, pw, ph - (ground_y + 2)), dirt_c);

	// Ground moving chevron pattern
	sz g_offset = (sz)self.world_scroll % 8;
	for (sz x = -8; x < pw + 8; x += 8) {
		sz px = x - g_offset;
		for (sz y = ground_y + 2; y < ph; y++) {
			sz dx = (y - ground_y) / 2;
			self.vbuf.set_pixel(px + dx, y, dirt_dark);
		}
	}
}

// Draw a classic Mario-style Pipe with highlights, rims, and shading
fn void FlappyModel.draw_pipe(&self, Pipe* p) {
	sz px = (sz)p.x;
	sz gy = p.gap_y;
	sz gs = p.gap_size;
	sz top_bottom = gy - gs / 2;
	sz bot_top = gy + gs / 2;
	sz pw = PIPE_WIDTH;
	sz ground_y = (sz)self.vbuf.height - 8;

	xray::Color c_dark = xray::color_rgb(25, 100, 30);
	xray::Color c_mid = xray::color_rgb(60, 185, 45);
	xray::Color c_light = xray::color_rgb(140, 240, 85);
	xray::Color c_rim_dark = xray::color_rgb(15, 70, 20);

	// Top Pipe (pointing downwards)
	if (top_bottom > 0) {
		// Body
		for (sz y = 0; y < top_bottom - 3; y++) {
			for (sz x = 0; x < pw; x++) {
				xray::Color c = (x == 1) ? c_light : ((x >= pw - 2) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw - 1, y, c_rim_dark);
		}
		// Rim Lip
		sz lip_y0 = top_bottom - 3;
		sz lip_y1 = top_bottom;
		for (sz y = lip_y0; y < lip_y1; y++) {
			for (sz x = -1; x <= pw; x++) {
				xray::Color c = (x == 0) ? c_light : ((x >= pw - 1) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px - 1, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw, y, c_rim_dark);
		}
		for (sz x = -1; x <= pw; x++) {
			self.vbuf.set_pixel(px + x, lip_y1 - 1, c_rim_dark);
		}
	}

	// Bottom Pipe (pointing upwards)
	if (bot_top < ground_y) {
		// Rim Lip
		sz lip_y0 = bot_top;
		sz lip_y1 = bot_top + 3;
		for (sz y = lip_y0; y < lip_y1; y++) {
			for (sz x = -1; x <= pw; x++) {
				xray::Color c = (x == 0) ? c_light : ((x >= pw - 1) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px - 1, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw, y, c_rim_dark);
		}
		for (sz x = -1; x <= pw; x++) {
			self.vbuf.set_pixel(px + x, lip_y0, c_rim_dark);
		}
		// Body
		for (sz y = lip_y1; y < ground_y; y++) {
			for (sz x = 0; x < pw; x++) {
				xray::Color c = (x == 1) ? c_light : ((x >= pw - 2) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw - 1, y, c_rim_dark);
		}
	}
}

// Draw the iconic bird pixel sprite (6x5 pixels)
fn void FlappyModel.draw_bird(&self, float bx, float by, float angle, sz frame) {
	sz cx = (sz)bx;
	sz cy = (sz)by;

	xray::Color c_body = xray::color_rgb(255, 215, 0);     // Golden Yellow
	xray::Color c_belly = xray::color_rgb(255, 245, 170);   // Pale Yellow
	xray::Color c_outline = xray::color_rgb(40, 20, 10);    // Dark Brown
	xray::Color c_beak = xray::color_rgb(255, 95, 25);      // Orange
	xray::Color c_eye = xray::color_rgb(255, 255, 255);     // White
	xray::Color c_pupil = xray::color_rgb(0, 0, 0);         // Black
	xray::Color c_wing = xray::color_rgb(240, 170, 20);     // Wing Orange

	// Pixel sprite definition: 6 cols x 5 rows
	// Frame 0: Wing up, Frame 1: Wing mid, Frame 2: Wing down
	sz[30] sprite = {
		0, 1, 1, 1, 1, 0,
		1, 2, 5, 2, 1, 0,
		1, 3, 2, 2, 4, 4,
		1, 3, 3, 2, 4, 0,
		0, 1, 1, 1, 0, 0,
	};

	// Animate wing pixel (idx 3)
	if (frame == 0) {
		sprite[1 * 6 + 1] = 3;
		sprite[2 * 6 + 1] = 2;
	} else if (frame == 2) {
		sprite[3 * 6 + 1] = 3;
		sprite[2 * 6 + 1] = 2;
	}

	for (sz dy = -2; dy <= 2; dy++) {
		for (sz dx = -3; dx <= 2; dx++) {
			sz val = sprite[(dy + 2) * 6 + (dx + 3)];
			if (val == 0) continue;

			// Rotate sprite pixel around center
			float rx = (float)dx * math::cos(angle) - (float)dy * math::sin(angle);
			float ry = (float)dx * math::sin(angle) + (float)dy * math::cos(angle);

			sz px = cx + (sz)(rx + 0.5f);
			sz py = cy + (sz)(ry + 0.5f);

			xray::Color col = c_outline;
			switch (val) {
				case 1: col = c_outline;
				case 2: col = c_body;
				case 3: col = c_wing;
				case 4: col = c_beak;
				case 5: col = c_eye;
			}
			self.vbuf.set_pixel(px, py, col);
			if (val == 5) {
				self.vbuf.set_pixel(px + 1, py, c_pupil);
			}
		}
	}
}

// Draw active particles into the pixel buffer
fn void FlappyModel.draw_particles(&self) {
	for (sz i = 0; i < MAX_PARTICLES; i++) {
		if (!self.particles[i].active) continue;
		sz px = (sz)self.particles[i].x;
		sz py = (sz)self.particles[i].y;
		self.vbuf.set_pixel(px, py, self.particles[i].color);
	}
}

// Big blocky digits for HUD score
fn void FlappyModel.draw_score_digit(&self, sz digit, sz x, sz y, xray::Color fg) {
	// 3x5 font table flattened
	bool[15] g;
	switch (digit) {
		case 0: g = { true, true, true, true, false, true, true, false, true, true, false, true, true, true, true };
		case 1: g = { false, true, false, true, true, false, false, true, false, false, true, false, true, true, true };
		case 2: g = { true, true, true, false, false, true, true, true, true, true, false, false, true, true, true };
		case 3: g = { true, true, true, false, false, true, true, true, true, false, false, true, true, true, true };
		case 4: g = { true, false, true, true, false, true, true, true, true, false, false, true, false, false, true };
		case 5: g = { true, true, true, true, false, false, true, true, true, false, false, true, true, true, true };
		case 6: g = { true, true, true, true, false, false, true, true, true, true, false, true, true, true, true };
		case 7: g = { true, true, true, false, false, true, false, true, false, false, true, false, false, true, false };
		case 8: g = { true, true, true, true, false, true, true, true, true, true, false, true, true, true, true };
		case 9: g = { true, true, true, true, false, true, true, true, true, false, false, true, true, true, true };
		default: g = { false, false, false, false, false, false, false, false, false, false, false, false, false, false, false };
	}

	xray::Color shadow = xray::color_rgb(20, 20, 20);
	for (sz dy = 0; dy < 5; dy++) {
		for (sz dx = 0; dx < 3; dx++) {
			if (g[dy * 3 + dx]) {
				self.vbuf.set_pixel(x + dx + 1, y + dy + 1, shadow);
				self.vbuf.set_pixel(x + dx, y + dy, fg);
			}
		}
	}
}

fn void FlappyModel.draw_score_hud(&self) {
	sz s = self.score;
	sz[5] digits;
	sz count = 0;
	if (s == 0) {
		digits[0] = 0;
		count = 1;
	} else {
		while (s > 0 && count < 5) {
			digits[count++] = s % 10;
			s /= 10;
		}
	}

	sz total_w = count * 4 - 1;
	sz start_x = ((sz)self.vbuf.width - total_w) / 2;
	sz y = 4;

	xray::Color fg = xray::color_rgb(255, 255, 255);
	for (sz i = 0; i < count; i++) {
		sz d = digits[count - 1 - i];
		self.draw_score_digit(d, start_x + i * 4, y, fg);
	}
}

// ── Screen Conversion & Dialogs ───────────────────────────────────────────────

fn milktea::Node* FlappyModel.view(FlappyModel* self) @dynamic {
	if (self.screen == null) return milktea::text("");

	// 1. Render all procedural art into virtual pixel buffer
	self.draw_background();

	// Draw pipes
	if (self.state == GameState.PLAYING || self.state == GameState.DYING || self.state == GameState.GAME_OVER) {
		for (sz i = 0; i < MAX_PIPES; i++) {
			if (self.pipes[i].active) {
				self.draw_pipe(&self.pipes[i]);
			}
		}
	}

	// Draw bird
	if (self.state != INTRO) {
		self.draw_bird(self.bird.x, self.bird.y, self.bird.angle, self.bird.flap_frame);
	}

	// Draw particles
	self.draw_particles();

	// Draw Score HUD during game
	if (self.state == GameState.PLAYING) {
		self.draw_score_hud();
	}

	// Hit flash effect
	if (self.flash_timer > 0) {
		xray::Color flash_c = xray::color_rgba(255, 255, 255, 200);
		for (sz i = 0; i < (sz)self.vbuf.width * (sz)self.vbuf.height; i++) {
			self.vbuf.pixels[i] = flash_c.blend_over(self.vbuf.pixels[i]);
		}
	}

	// 2. Convert the pixels to cells, two pixel rows to each.
	self.vbuf.to_half_blocks(self.screen);

	// 3. Paint the dialog for this state over the game. It goes into the
	// game's own cells rather than a layer above them, so its backdrop can
	// dim the pixels it covers.
	milktea::Node* dialog;
	switch (self.state) {
		case INTRO:     dialog = self.intro_dialog();
		case MENU:      dialog = self.menu_dialog();
		case GAME_OVER: dialog = self.game_over_dialog();
		case HELP:      dialog = self.help_dialog();
		default:
	}
	if (dialog) {
		milktea::Node* ui = milktea::root().add(dialog);
		ui.solve(xray::new_rect(0, 0, self.screen.width, self.screen.height));
		self.screen.paint(ui);
	}

	return milktea::canvas(self.screen);
}

// ── Dialogs ───────────────────────────────────────────────────────────────────

// Panel is a dialog's backdrop. It dims the game behind the dialog without
// hiding it — the half blocks keep their glyphs and both their colors are
// tinted — and frames it with a gradient border.
struct Panel (xray::Content) {
	xray::Color tint;
	xray::Color edge_from;
	xray::Color edge_to;
}

fn void Panel.paint(&self, ScreenBuffer* dst, xray::Rect r) @dynamic {
	xray::Rect inner = dst.draw_gradient_border(r, xray::ROUNDED, self.edge_from, self.edge_to);
	for (sz y = inner.y; y < inner.y + inner.h; y++) {
		for (sz x = inner.x; x < inner.x + inner.w; x++) {
			if (x < 0 || y < 0 || x >= dst.width || y >= dst.height) continue;
			xray::Cell* c = &dst.cells[y * dst.width + x];
			c.style.fg = self.tint.blend_over(c.style.fg);
			c.style.bg = self.tint.blend_over(c.style.bg);
		}
	}
}

// panel is a dialog box centred on screen, as wide as width or, at 0, as its
// widest line. Its first line sits under the top border, and the rest stack
// below it with a blank row between each.
fn milktea::Node* panel(sz width, xray::Color tint, xray::Color edge_from, xray::Color edge_to) {
	Panel* p = mem::tnew(Panel);
	*p = { tint, edge_from, edge_to };
	milktea::Node* n = milktea::component(p);
	if (width > 0) n.width(milktea::cells(width));
	return n
		// The border takes the outer row and column on each side.
		.with_padding(1, 3, 1, 3)
		.with_gap(1)
		.with_align(milktea::ALIGN_CENTER)
		.center();
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

const String[6] LOGO = {
	"███████╗██╗      █████╗ ██████╗ ██████╗ ██╗   ██╗",
	"██╔════╝██║     ██╔══██╗██╔══██╗██╔══██╗╚██╗ ██╔╝",
	"█████╗  ██║     ███████║██████╔╝██████╔╝ ╚████╔╝ ",
	"██╔══╝  ██║     ██╔══██║██╔═══╝ ██╔═══╝   ╚██╔╝  ",
	"██║     ███████╗██║  ██║██║     ██║        ██║   ",
	"╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝        ╚═╝   ",
};

fn milktea::Node* FlappyModel.intro_dialog(&self) {
	// Animated glowing title
	float pulse = (math::sin((float)self.ticks * 0.15f) + 1.0f) * 0.5f;
	xray::Color c_start = xray::color_rgb(255, (char)(120 + pulse * 100), 20);
	xray::Color c_end = xray::color_rgb((char)(255 - pulse * 50), 230, 50);

	milktea::Node* logo = milktea::vstack();
	foreach (l : LOGO) logo.add(milktea::text(glaze::gradient_text(l, c_start, c_end, true)));

	// The bird flies across the whole screen, bobbing in a lane above the logo.
	sz w = self.screen.width;
	sz bird_x = (sz)((float)self.ticks * 1.8f) % (w + 20) - 10;
	sz bird_y = (sz)(math::sin((float)self.ticks * 0.2f) * 2.0f);
	milktea::Node* lane = milktea::zstack().width(milktea::fill(1)).height(milktea::cells(1));
	if (bird_x >= 0 && bird_x < w - 4) lane.add(milktea::text("🐤💨").at(bird_x, bird_y));

	// The prompt blinks without moving what is below it: at alpha 0 it keeps
	// its place in the layout and paints nothing.
	bool blink_on = (self.ticks / 10) % 2 == 0;

	return milktea::vstack()
		.with_justify(milktea::CENTER)
		.with_align(milktea::ALIGN_CENTER)
		.with_gap(1)
		.add(lane)
		.add(logo)
		.add(line("░▒▓ RETRO ARCADE EDITION ▓▒░", xray::color_rgb(220, 240, 255), bold: true))
		.add(line("Press any key to enter...", xray::color_rgb(255, 230, 100))
			.alpha(blink_on ? 255 : 0));
}

fn milktea::Node* FlappyModel.menu_dialog(&self) {
	String diff_str = "NORMAL";
	if (self.difficulty == Difficulty.EASY) diff_str = "EASY";
	if (self.difficulty == Difficulty.HARD) diff_str = "HARD (DYNAMIC!)";

	String[4] options = {
		"Start Game",
		string::tformat("Difficulty: [%s]", diff_str),
		"How to Play",
		"Exit",
	};

	milktea::Node* items = milktea::vstack().with_gap(1).with_align(milktea::ALIGN_CENTER);
	foreach (i, opt : options) {
		bool sel = i == self.menu_selected;
		glaze::Style s = sel
			? glaze::style().foreground(xray::color_rgb(255, 255, 80)).with_bold(true)
				.background(xray::color_rgba(60, 40, 90, 200))
			: glaze::style().foreground(xray::color_rgb(180, 190, 210));
		items.add(milktea::text(string::tformat(sel ? "▶ %s ◀" : "  %s  ", opt), s));
	}

	return panel(44, xray::color_rgba(10, 14, 28, 178),
			xray::color_rgb(255, 200, 50), xray::color_rgb(255, 90, 30))
		.offset(0, -1)
		.add(milktea::text(glaze::gradient_text(" ★ FLAPPY BIRD ★ ",
			xray::color_rgb(255, 240, 100), xray::color_rgb(255, 120, 40), true)))
		.add(items)
		.add(line(string::tformat("🏆 Best Score: %d", self.high_score), xray::color_rgb(255, 215, 0)));
}

fn milktea::Node* FlappyModel.game_over_dialog(&self) {
	String medal = "🥉 Bronze";
	xray::Color medal_c = xray::color_rgb(205, 127, 50);
	if (self.score >= 20) {
		medal = "🥇 Platinum";
		medal_c = xray::color_rgb(220, 245, 255);
	} else if (self.score >= 10) {
		medal = "🥇 Gold";
		medal_c = xray::color_rgb(255, 215, 0);
	} else if (self.score >= 5) {
		medal = "🥈 Silver";
		medal_c = xray::color_rgb(192, 192, 192);
	}

	// The stats are one left-aligned block, centred as a whole.
	milktea::Node* stats = milktea::vstack().with_gap(1)
		.add(line(string::tformat("Score: %d", self.score), xray::color_rgb(255, 255, 255), bold: true))
		.add(line(string::tformat("Best:  %d", self.high_score), xray::color_rgb(255, 215, 0), bold: true))
		.add(line(string::tformat("Medal: %s", medal), medal_c, bold: true));

	return panel(40, xray::color_rgba(20, 10, 15, 178),
			xray::color_rgb(255, 60, 60), xray::color_rgb(255, 140, 40))
		.offset(0, -1)
		.add(line("💀 GAME OVER 💀", xray::color_rgb(255, 70, 70), bold: true))
		.add(stats)
		.add(line("[SPACE] Play Again  |  [M] Menu", xray::color_rgb(200, 220, 240)));
}

const String[5] HOW_TO_PLAY = {
	"• Press [SPACE] or [UP] to flap wings",
	"• Fly through pipe gaps to score points",
	"• Avoid colliding with pipes or ground",
	"• Hard mode has moving procedural pipes!",
	"• Press [ESC] or [Q] to pause/quit",
};

fn milktea::Node* FlappyModel.help_dialog(&self) {
	return panel(0, xray::color_rgba(12, 16, 28, 178),
			xray::color_rgb(80, 200, 255), xray::color_rgb(140, 100, 255))
		.add(milktea::text(glaze::gradient_text(" HOW TO PLAY ",
			xray::color_rgb(100, 220, 255), xray::color_rgb(200, 150, 255), true)))
		.add(lines(HOW_TO_PLAY[..], xray::color_rgb(220, 230, 245)))
		.add(line("[Press SPACE or ESC to Return]", xray::color_rgb(255, 215, 100)));
}

// ── Main Entry Point ──────────────────────────────────────────────────────────

fn int main() {
	FlappyModel* m = mem::new(FlappyModel);
	if (catch err = milktea::@run_program(m, { .alt_screen = true })) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Thanks for playing Flappy Bird!");
	return 0;
}
