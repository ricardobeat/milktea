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

const int FRAME_MS = 25; // 40 FPS
const int MAX_PIPES = 8;
const int MAX_PARTICLES = 120;
const int PIPE_WIDTH = 9; // width in pixel columns
const int PIPE_SPACING = 38; // pixel distance between pipe columns

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
	int gap_y;      // center of gap in pixel coordinates
	int gap_size;   // height of gap in pixel rows
	bool scored;
	bool active;
	float speed_y;  // for dynamic moving pipes in hard mode
	int min_gap_y;
	int max_gap_y;
}

struct Particle {
	float x;
	float y;
	float vx;
	float vy;
	int life;
	int max_life;
	xray::Color color;
	bool active;
}

struct Bird {
	float x;
	float y;
	float vy;
	float angle; // tilt in radians
	int flap_frame;
}



// ── Model ─────────────────────────────────────────────────────────────────────

struct FlappyModel {
	int term_w;
	int term_h;
	int ticks;

	GameState state;
	Difficulty difficulty;
	int menu_selected; // 0: Play, 1: Difficulty, 2: Help, 3: Quit

	// Game entities
	Bird bird;
	Pipe[MAX_PIPES] pipes;
	Particle[MAX_PARTICLES] particles;

	int score;
	int high_score;
	int death_timer;
	float world_scroll;

	// Flash effect on hit
	int flash_timer;

	// Graphics buffer
	xray::PixelBuffer* vbuf;
	xray::Cell[] view_cells;
}

// ── Random Helpers ────────────────────────────────────────────────────────────

fn float rnd_float(float min, float max) {
	float r = (float)(rand() % 10000) / 10000.0f;
	return min + r * (max - min);
}

fn int rnd_int(int min, int max) {
	if (max <= min) return min;
	return min + (rand() % (max - min + 1));
}

// ── Particle System ───────────────────────────────────────────────────────────

fn void FlappyModel.spawn_particle(&self, float x, float y, float vx, float vy, int life, xray::Color c) {
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

fn void FlappyModel.spawn_feathers(&self, float x, float y, int count) {
	for (int i = 0; i < count; i++) {
		float angle = rnd_float(0.0f, 6.28318f);
		float speed = rnd_float(1.5f, 5.0f);
		float vx = math::cos(angle) * speed;
		float vy = math::sin(angle) * speed - 1.0f;
		xray::Color c = (i % 2 == 0) ? xray::color_rgb(255, 215, 0) : xray::color_rgb(255, 90, 30);
		self.spawn_particle(x, y, vx, vy, rnd_int(15, 30), c);
	}
}

fn void FlappyModel.spawn_score_sparkles(&self, float x, float y) {
	for (int i = 0; i < 14; i++) {
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

	int py = self.vbuf.height > 0 ? (int)self.vbuf.height / 2 : 25;
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
	int gap = 17;
	if (self.difficulty == Difficulty.EASY) gap = 21;
	if (self.difficulty == Difficulty.HARD) gap = 13;

	// Reset pipes
	float start_x = (float)((int)self.vbuf.width + 10);
	for (sz i = 0; i < MAX_PIPES; i++) {
		int min_y = 12;
		int max_y = (int)self.vbuf.height - 20;
		if (max_y <= min_y) max_y = min_y + 10;
		int gy = rnd_int(min_y, max_y);

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

		mem::free(self.view_cells.ptr);
		sz total = (sz)self.term_w * (sz)self.term_h;
		self.view_cells = mem::new_array(xray::Cell, total);
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
				int ground_y = (int)self.vbuf.height - 8;
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
						self.pipes[i].gap_y += (int)(self.pipes[i].speed_y * 1.5f);
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
						int min_y = 12;
						int max_y = (int)self.vbuf.height - 20;
						if (max_y <= min_y) max_y = min_y + 10;
						self.pipes[i].gap_y = rnd_int(min_y, max_y);
						self.pipes[i].scored = false;
					}

					// Collision detection (Bird is 6x4 pixels)
					float bx = self.bird.x;
					float by = self.bird.y;
					float px = self.pipes[i].x;
					int gy = self.pipes[i].gap_y;
					int gs = self.pipes[i].gap_size;

					if (bx + 5.0f >= px && bx <= px + (float)PIPE_WIDTH) {
						int top_pipe_bottom = gy - gs / 2;
						int bot_pipe_top = gy + gs / 2;

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
								self.difficulty = (Difficulty)(((int)self.difficulty + 1) % 3);
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
									self.difficulty = (Difficulty)(((int)self.difficulty + 1) % 3);
								case 2:
									self.state = GameState.HELP;
								case 3:
									return milktea::quit();
							}
						}
						if (k.rune == ' ') self.start_game();
						if (k.rune == 'd' || k.rune == 'D') {
							self.difficulty = (Difficulty)(((int)self.difficulty + 1) % 3);
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
	int pw = (int)self.vbuf.width;
	int ph = (int)self.vbuf.height;
	int ground_y = ph - 8;

	// Sky gradient (day to sunset tones based on difficulty/mode)
	xray::Color sky_top = (self.difficulty == Difficulty.HARD) ? xray::color_rgb(30, 20, 60) : xray::color_rgb(35, 75, 150);
	xray::Color sky_bot = (self.difficulty == Difficulty.HARD) ? xray::color_rgb(180, 70, 60) : xray::color_rgb(140, 210, 245);

	for (int y = 0; y < ground_y; y++) {
		float t = (float)y / (float)ground_y;
		int r = (int)((float)sky_top.r * (1.0f - t) + (float)sky_bot.r * t);
		int g = (int)((float)sky_top.g * (1.0f - t) + (float)sky_bot.g * t);
		int b = (int)((float)sky_top.b * (1.0f - t) + (float)sky_bot.b * t);
		xray::Color sky_line = xray::color_rgb((char)r, (char)g, (char)b);

		sz row_off = (sz)y * (sz)pw;
		for (int x = 0; x < pw; x++) {
			self.vbuf.pixels[row_off + (sz)x] = sky_line;
		}
	}

	// Distant Clouds (Parallax 0.15x)
	float cloud_scroll = self.world_scroll * 0.15f;
	xray::Color cloud_c = xray::color_rgba(255, 255, 255, 170);
	for (int i = 0; i < 5; i++) {
		int cx = (int)((float)(i * 45 + 10) - cloud_scroll) % (pw + 50);
		if (cx < -40) cx += pw + 50;
		int cy = 8 + (i % 3) * 6;
		// Cloud shape
		for (int dx = -14; dx <= 14; dx++) {
			for (int dy = -4; dy <= 4; dy++) {
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

	for (int b = 0; b < 15; b++) {
		int bw = 10 + (b * 7) % 11;
		int bh = 14 + (b * 13) % 22;
		int bx = (int)((float)(b * 22) - sky_scroll) % (pw + 30);
		if (bx < -30) bx += pw + 30;
		int by = ground_y - bh;

		self.vbuf.fill_rect(xray::new_rect(bx, by, bw, bh), bldg_c);

		// Windows
		for (int wy = by + 2; wy < ground_y - 2; wy += 4) {
			for (int wx = bx + 2; wx < bx + bw - 2; wx += 3) {
				if ((b + wx + wy) % 5 != 0) {
					self.vbuf.set_pixel(wx, wy, win_c);
				}
			}
		}
	}

	// Green Hills (Parallax 0.6x)
	float hill_scroll = self.world_scroll * 0.6f;
	xray::Color hill_c = (self.difficulty == Difficulty.HARD) ? xray::color_rgb(45, 80, 50) : xray::color_rgb(75, 175, 80);
	for (int x = 0; x < pw; x++) {
		float hx = (float)x + hill_scroll;
		int hy = ground_y - 6 - (int)(math::sin(hx * 0.04f) * 5.0f + math::cos(hx * 0.09f) * 3.0f);
		for (int y = hy; y < ground_y; y++) {
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
	int g_offset = (int)self.world_scroll % 8;
	for (int x = -8; x < pw + 8; x += 8) {
		int px = x - g_offset;
		for (int y = ground_y + 2; y < ph; y++) {
			int dx = (y - ground_y) / 2;
			self.vbuf.set_pixel(px + dx, y, dirt_dark);
		}
	}
}

// Draw a classic Mario-style Pipe with highlights, rims, and shading
fn void FlappyModel.draw_pipe(&self, Pipe* p) {
	int px = (int)p.x;
	int gy = p.gap_y;
	int gs = p.gap_size;
	int top_bottom = gy - gs / 2;
	int bot_top = gy + gs / 2;
	int pw = PIPE_WIDTH;
	int ground_y = (int)self.vbuf.height - 8;

	xray::Color c_dark = xray::color_rgb(25, 100, 30);
	xray::Color c_mid = xray::color_rgb(60, 185, 45);
	xray::Color c_light = xray::color_rgb(140, 240, 85);
	xray::Color c_rim_dark = xray::color_rgb(15, 70, 20);

	// Top Pipe (pointing downwards)
	if (top_bottom > 0) {
		// Body
		for (int y = 0; y < top_bottom - 3; y++) {
			for (int x = 0; x < pw; x++) {
				xray::Color c = (x == 1) ? c_light : ((x >= pw - 2) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw - 1, y, c_rim_dark);
		}
		// Rim Lip
		int lip_y0 = top_bottom - 3;
		int lip_y1 = top_bottom;
		for (int y = lip_y0; y < lip_y1; y++) {
			for (int x = -1; x <= pw; x++) {
				xray::Color c = (x == 0) ? c_light : ((x >= pw - 1) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px - 1, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw, y, c_rim_dark);
		}
		for (int x = -1; x <= pw; x++) {
			self.vbuf.set_pixel(px + x, lip_y1 - 1, c_rim_dark);
		}
	}

	// Bottom Pipe (pointing upwards)
	if (bot_top < ground_y) {
		// Rim Lip
		int lip_y0 = bot_top;
		int lip_y1 = bot_top + 3;
		for (int y = lip_y0; y < lip_y1; y++) {
			for (int x = -1; x <= pw; x++) {
				xray::Color c = (x == 0) ? c_light : ((x >= pw - 1) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px - 1, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw, y, c_rim_dark);
		}
		for (int x = -1; x <= pw; x++) {
			self.vbuf.set_pixel(px + x, lip_y0, c_rim_dark);
		}
		// Body
		for (int y = lip_y1; y < ground_y; y++) {
			for (int x = 0; x < pw; x++) {
				xray::Color c = (x == 1) ? c_light : ((x >= pw - 2) ? c_dark : c_mid);
				self.vbuf.set_pixel(px + x, y, c);
			}
			self.vbuf.set_pixel(px, y, c_rim_dark);
			self.vbuf.set_pixel(px + pw - 1, y, c_rim_dark);
		}
	}
}

// Draw the iconic bird pixel sprite (6x5 pixels)
fn void FlappyModel.draw_bird(&self, float bx, float by, float angle, int frame) {
	int cx = (int)bx;
	int cy = (int)by;

	xray::Color c_body = xray::color_rgb(255, 215, 0);     // Golden Yellow
	xray::Color c_belly = xray::color_rgb(255, 245, 170);   // Pale Yellow
	xray::Color c_outline = xray::color_rgb(40, 20, 10);    // Dark Brown
	xray::Color c_beak = xray::color_rgb(255, 95, 25);      // Orange
	xray::Color c_eye = xray::color_rgb(255, 255, 255);     // White
	xray::Color c_pupil = xray::color_rgb(0, 0, 0);         // Black
	xray::Color c_wing = xray::color_rgb(240, 170, 20);     // Wing Orange

	// Pixel sprite definition: 6 cols x 5 rows
	// Frame 0: Wing up, Frame 1: Wing mid, Frame 2: Wing down
	int[30] sprite = {
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

	for (int dy = -2; dy <= 2; dy++) {
		for (int dx = -3; dx <= 2; dx++) {
			int val = sprite[(dy + 2) * 6 + (dx + 3)];
			if (val == 0) continue;

			// Rotate sprite pixel around center
			float rx = (float)dx * math::cos(angle) - (float)dy * math::sin(angle);
			float ry = (float)dx * math::sin(angle) + (float)dy * math::cos(angle);

			int px = cx + (int)(rx + 0.5f);
			int py = cy + (int)(ry + 0.5f);

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
		int px = (int)self.particles[i].x;
		int py = (int)self.particles[i].y;
		self.vbuf.set_pixel(px, py, self.particles[i].color);
	}
}

// Big blocky digits for HUD score
fn void FlappyModel.draw_score_digit(&self, int digit, int x, int y, xray::Color fg) {
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
	for (int dy = 0; dy < 5; dy++) {
		for (int dx = 0; dx < 3; dx++) {
			if (g[dy * 3 + dx]) {
				self.vbuf.set_pixel(x + dx + 1, y + dy + 1, shadow);
				self.vbuf.set_pixel(x + dx, y + dy, fg);
			}
		}
	}
}

fn void FlappyModel.draw_score_hud(&self) {
	int s = self.score;
	int[5] digits;
	int count = 0;
	if (s == 0) {
		digits[0] = 0;
		count = 1;
	} else {
		while (s > 0 && count < 5) {
			digits[count++] = s % 10;
			s /= 10;
		}
	}

	int total_w = count * 4 - 1;
	int start_x = ((int)self.vbuf.width - total_w) / 2;
	int y = 4;

	xray::Color fg = xray::color_rgb(255, 255, 255);
	for (int i = 0; i < count; i++) {
		int d = digits[count - 1 - i];
		self.draw_score_digit(d, start_x + i * 4, y, fg);
	}
}

// ── Screen Conversion & Overlay Painting ──────────────────────────────────────

fn milktea::View FlappyModel.view(FlappyModel* self) @dynamic {
	if (self.term_w <= 0 || self.term_h <= 0) {
		return milktea::new_alt_screen_view("");
	}

	int w = self.term_w;
	int h = self.term_h;

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

	// 2. Convert PixelBuffer (2 pixel rows -> 1 cell with '▀') into view_cells
	xray::Style base = xray::default_style();
	for (int vy = 0; vy < h; vy++) {
		int py_top = vy * 2;
		int py_bot = py_top + 1;
		sz row_offset = (sz)vy * (sz)w;

		for (int vx = 0; vx < w; vx++) {
			xray::Color c_top = self.vbuf.get_pixel(vx, py_top);
			xray::Color c_bot = self.vbuf.get_pixel(vx, py_bot);

			xray::Cell c;
			// UTF-8 for '▀' (U+2580): 0xE2 0x96 0x80
			c.content[0] = 0xe2;
			c.content[1] = 0x96;
			c.content[2] = 0x80;
			c.content_len = 3;
			c.width = 1;
			c.style = base.set_fg(c_top).set_bg(c_bot);

			self.view_cells[row_offset + (sz)vx] = c;
		}
	}

	// 3. Composite UI Overlays into cell buffer
	ScreenBuffer canvas;
	canvas.width = (sz)w;
	canvas.height = (sz)h;
	canvas.cells = self.view_cells;
	canvas.prev_cells = self.view_cells;
	canvas.dirty_lines = mem::temp_array(bool, (sz)h);

	switch (self.state) {
		case INTRO:
			self.render_intro_overlay(&canvas);
		case MENU:
			self.render_menu_overlay(&canvas);
		case GAME_OVER:
			self.render_game_over_overlay(&canvas);
		case HELP:
			self.render_help_overlay(&canvas);
		default:
	}

	return milktea::new_alt_cell_view(self.view_cells, (sz)w, (sz)h);
}

// ── Overlay UI Renders ────────────────────────────────────────────────────────

fn void FlappyModel.render_intro_overlay(&self, ScreenBuffer* canvas) {
	int w = (int)canvas.width;
	int h = (int)canvas.height;

	// Animated glowing title
	int title_y = h / 2 - 4;
	float pulse = (math::sin((float)self.ticks * 0.15f) + 1.0f) * 0.5f;

	xray::Color c_start = xray::color_rgb(255, (char)(120 + pulse * 100), 20);
	xray::Color c_end = xray::color_rgb((char)(255 - pulse * 50), 230, 50);

	String logo_line1 = "  ███████╗██╗      █████╗ ██████╗ ██████╗ ██╗   ██╗";
	String logo_line2 = "  ██╔════╝██║     ██╔══██╗██╔══██╗██╔══██╗╚██╗ ██╔╝";
	String logo_line3 = "  █████╗  ██║     ███████║██████╔╝██████╔╝ ╚████╔╝ ";
	String logo_line4 = "  ██╔══╝  ██║     ██╔══██║██╔═══╝ ██╔═══╝   ╚██╔╝  ";
	String logo_line5 = "  ██║     ███████╗██║  ██║██║     ██║        ██║   ";
	String logo_line6 = "  ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝        ╚═╝   ";

	int lx = (w - 52) / 2;
	if (lx < 0) lx = 0;

	String[6] lines = { logo_line1, logo_line2, logo_line3, logo_line4, logo_line5, logo_line6 };
	for (int i = 0; i < 6; i++) {
		String styled = glaze::gradient_text(lines[i], c_start, c_end, true);
		canvas.render_ansi_string((sz)lx, (sz)(title_y + i), styled, xray::default_style());
	}

	// Flying intro bird
	int bird_x = (int)((float)self.ticks * 1.8f) % (w + 20) - 10;
	int bird_y = title_y - 2 + (int)(math::sin((float)self.ticks * 0.2f) * 2.0f);
	if (bird_x >= 0 && bird_x < w - 4 && bird_y >= 0 && bird_y < h) {
		canvas.render_ansi_string((sz)bird_x, (sz)bird_y, "🐤💨", xray::default_style());
	}

	// Subtitle
	String sub = "░▒▓ RETRO ARCADE EDITION ▓▒░";
	String sub_styled = glaze::style()
		.foreground(xray::color_rgb(220, 240, 255))
		.with_bold(true)
		.render(sub);
	int sx = (w - glaze::string_width(sub)) / 2;
	canvas.render_ansi_string((sz)sx, (sz)(title_y + 7), sub_styled, xray::default_style());

	// Press any key
	if ((self.ticks / 10) % 2 == 0) {
		String press = "Press any key to enter...";
		String press_styled = glaze::style()
			.foreground(xray::color_rgb(255, 230, 100))
			.render(press);
		int px = (w - glaze::string_width(press)) / 2;
		canvas.render_ansi_string((sz)px, (sz)(title_y + 10), press_styled, xray::default_style());
	}
}

fn void FlappyModel.render_menu_overlay(&self, ScreenBuffer* canvas) {
	int w = (int)canvas.width;
	int h = (int)canvas.height;

	int box_w = 44;
	int box_h = 16;
	int bx = (w - box_w) / 2;
	int by = (h - box_h) / 2 - 1;
	if (bx < 0) bx = 0;
	if (by < 0) by = 0;

	// Semi-transparent / styled dialog box
	xray::Rect dialog_rect = xray::new_rect(bx, by, box_w, box_h);
	xray::Rect inner = canvas.draw_gradient_border(
		dialog_rect,
		xray::ROUNDED,
		xray::color_rgb(255, 200, 50),
		xray::color_rgb(255, 90, 30)
	);

	// Semi-transparent backdrop: tint both fg and bg half-block colors evenly (~70% opacity)
	xray::Color menu_tint = xray::color_rgba(10, 14, 28, 178);
	for (int y = inner.y; y < inner.y + inner.h; y++) {
		for (int x = inner.x; x < inner.x + inner.w; x++) {
			xray::Cell* cl = &canvas.cells[(sz)y * canvas.width + (sz)x];
			cl.style.fg = menu_tint.blend_over(cl.style.fg);
			cl.style.bg = menu_tint.blend_over(cl.style.bg);
		}
	}

	// Title
	String title = " ★ FLAPPY BIRD ★ ";
	String title_s = glaze::gradient_text(title, xray::color_rgb(255, 240, 100), xray::color_rgb(255, 120, 40), true);
	int tx = inner.x + (inner.w - glaze::string_width(title)) / 2;
	canvas.render_ansi_string((sz)tx, (sz)inner.y, title_s, xray::default_style());

	// Menu items
	String diff_str = "NORMAL";
	if (self.difficulty == Difficulty.EASY) diff_str = "EASY";
	if (self.difficulty == Difficulty.HARD) diff_str = "HARD (DYNAMIC!)";

	DString opt1 = dstring::temp();
	opt1.append_string(string::tformat("Difficulty: [%s]", diff_str));

	String[4] options = {
		"Start Game",
		opt1.str_view(),
		"How to Play",
		"Exit",
	};

	for (int i = 0; i < 4; i++) {
		bool sel = (i == self.menu_selected);
		DString line = dstring::temp();
		if (sel) {
			line.append_string("▶ ");
			line.append_string(options[i]);
			line.append_string(" ◀");
		} else {
			line.append_string("  ");
			line.append_string(options[i]);
			line.append_string("  ");
		}

		xray::Color fg = sel ? xray::color_rgb(255, 255, 80) : xray::color_rgb(180, 190, 210);
		xray::Color bg = sel ? xray::color_rgba(60, 40, 90, 200) : xray::color_none();

		glaze::Style s = glaze::style().foreground(fg).with_bold(sel);
		if (sel) s = s.background(bg);

		String rendered = s.render(line.str_view());
		int ox = inner.x + (inner.w - glaze::string_width(line.str_view())) / 2;
		canvas.render_ansi_string((sz)ox, (sz)(inner.y + 3 + i * 2), rendered, xray::default_style());
	}

	// High score badge at bottom of menu
	DString hs_str = dstring::temp();
	hs_str.append_string(string::tformat("🏆 Best Score: %d", self.high_score));
	String hs_s = glaze::style().foreground(xray::color_rgb(255, 215, 0)).render(hs_str.str_view());
	int hx = inner.x + (inner.w - glaze::string_width(hs_str.str_view())) / 2;
	canvas.render_ansi_string((sz)hx, (sz)(inner.y + inner.h - 2), hs_s, xray::default_style());
}

fn void FlappyModel.render_game_over_overlay(&self, ScreenBuffer* canvas) {
	int w = (int)canvas.width;
	int h = (int)canvas.height;

	int box_w = 40;
	int box_h = 15;
	int bx = (w - box_w) / 2;
	int by = (h - box_h) / 2 - 1;
	if (bx < 0) bx = 0;
	if (by < 0) by = 0;

	xray::Rect dialog_rect = xray::new_rect(bx, by, box_w, box_h);
	xray::Rect inner = canvas.draw_gradient_border(
		dialog_rect,
		xray::ROUNDED,
		xray::color_rgb(255, 60, 60),
		xray::color_rgb(255, 140, 40)
	);

	// Semi-transparent backdrop: tint both fg and bg half-block colors evenly (~70% opacity)
	xray::Color go_tint = xray::color_rgba(20, 10, 15, 178);
	for (int y = inner.y; y < inner.y + inner.h; y++) {
		for (int x = inner.x; x < inner.x + inner.w; x++) {
			xray::Cell* cl = &canvas.cells[(sz)y * canvas.width + (sz)x];
			cl.style.fg = go_tint.blend_over(cl.style.fg);
			cl.style.bg = go_tint.blend_over(cl.style.bg);
		}
	}

	// GAME OVER Banner
	String go_text = "💀 GAME OVER 💀";
	String go_s = glaze::style()
		.foreground(xray::color_rgb(255, 70, 70))
		.with_bold(true)
		.render(go_text);
	int gx = inner.x + (inner.w - glaze::string_width(go_text)) / 2;
	canvas.render_ansi_string((sz)gx, (sz)inner.y, go_s, xray::default_style());

	// Medal Award
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

	// Score Stats Panel
	DString score_str = dstring::temp();
	score_str.append_string(string::tformat("Score: %d", self.score));
	String sc_s = glaze::style().foreground(xray::color_rgb(255, 255, 255)).with_bold(true).render(score_str.str_view());
	canvas.render_ansi_string((sz)(inner.x + 4), (sz)(inner.y + 3), sc_s, xray::default_style());

	DString best_str = dstring::temp();
	best_str.append_string(string::tformat("Best:  %d", self.high_score));
	String bst_s = glaze::style().foreground(xray::color_rgb(255, 215, 0)).with_bold(true).render(best_str.str_view());
	canvas.render_ansi_string((sz)(inner.x + 4), (sz)(inner.y + 5), bst_s, xray::default_style());

	DString med_str = dstring::temp();
	med_str.append_string(string::tformat("Medal: %s", medal));
	String med_s = glaze::style().foreground(medal_c).with_bold(true).render(med_str.str_view());
	canvas.render_ansi_string((sz)(inner.x + 4), (sz)(inner.y + 7), med_s, xray::default_style());

	// Retry Prompt
	String prompt = "[SPACE] Play Again  |  [M] Menu";
	String prompt_s = glaze::style().foreground(xray::color_rgb(200, 220, 240)).render(prompt);
	int px = inner.x + (inner.w - glaze::string_width(prompt)) / 2;
	canvas.render_ansi_string((sz)px, (sz)(inner.y + inner.h - 2), prompt_s, xray::default_style());
}

fn void FlappyModel.render_help_overlay(&self, ScreenBuffer* canvas) {
	int w = (int)canvas.width;
	int h = (int)canvas.height;

	int box_w = 46;
	int box_h = 16;
	int bx = (w - box_w) / 2;
	int by = (h - box_h) / 2;
	if (bx < 0) bx = 0;
	if (by < 0) by = 0;

	xray::Rect dialog_rect = xray::new_rect(bx, by, box_w, box_h);
	xray::Rect inner = canvas.draw_gradient_border(
		dialog_rect,
		xray::ROUNDED,
		xray::color_rgb(80, 200, 255),
		xray::color_rgb(140, 100, 255)
	);

	// Semi-transparent backdrop: tint both fg and bg half-block colors evenly (~70% opacity)
	xray::Color help_tint = xray::color_rgba(12, 16, 28, 178);
	for (int y = inner.y; y < inner.y + inner.h; y++) {
		for (int x = inner.x; x < inner.x + inner.w; x++) {
			xray::Cell* cl = &canvas.cells[(sz)y * canvas.width + (sz)x];
			cl.style.fg = help_tint.blend_over(cl.style.fg);
			cl.style.bg = help_tint.blend_over(cl.style.bg);
		}
	}

	String h_title = " HOW TO PLAY ";
	String ht_s = glaze::gradient_text(h_title, xray::color_rgb(100, 220, 255), xray::color_rgb(200, 150, 255), true);
	int tx = inner.x + (inner.w - glaze::string_width(h_title)) / 2;
	canvas.render_ansi_string((sz)tx, (sz)inner.y, ht_s, xray::default_style());

	String[5] instructions = {
		"• Press [SPACE] or [UP] to flap wings",
		"• Fly through pipe gaps to score points",
		"• Avoid colliding with pipes or ground",
		"• Hard mode has moving procedural pipes!",
		"• Press [ESC] or [Q] to pause/quit",
	};

	for (int i = 0; i < 5; i++) {
		String line_s = glaze::style().foreground(xray::color_rgb(220, 230, 245)).render(instructions[i]);
		canvas.render_ansi_string((sz)(inner.x + 2), (sz)(inner.y + 2 + i * 2), line_s, xray::default_style());
	}

	String back = "[Press SPACE or ESC to Return]";
	String back_s = glaze::style().foreground(xray::color_rgb(255, 215, 100)).render(back);
	int back_x = inner.x + (inner.w - glaze::string_width(back)) / 2;
	canvas.render_ansi_string((sz)back_x, (sz)(inner.y + inner.h - 2), back_s, xray::default_style());
}

// ── Main Entry Point ──────────────────────────────────────────────────────────

fn int main() {
	FlappyModel* m = mem::new(FlappyModel);
	if (catch err = milktea::@run_program(m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Thanks for playing Flappy Bird!");
	return 0;
}
