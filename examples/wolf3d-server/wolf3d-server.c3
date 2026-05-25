module sqlite3;
extern fn int sqlite3_open(char* filename, void** ppDb);
extern fn int sqlite3_close(void* db);
extern fn int sqlite3_exec(void* db, char* sql, void* callback, void* arg, char** errmsg);
extern fn void sqlite3_free(void* ptr);
extern fn int sqlite3_prepare_v2(void* db, char* sql, int nbyte, void** ppStmt, void** pzTail);
extern fn int sqlite3_step(void* stmt);
extern fn int sqlite3_finalize(void* stmt);
extern fn int sqlite3_bind_text(void* stmt, int idx, char* text, int len, void* destructor);
extern fn int sqlite3_bind_int(void* stmt, int idx, int val);
extern fn int sqlite3_column_int(void* stmt, int col);
extern fn char* sqlite3_column_text(void* stmt, int col);

const int SQLITE_OK          = 0;
const int SQLITE_ROW         = 100;
const int SQLITE_DONE        = 101;
const void* SQLITE_TRANSIENT = (void*)(uptr)0xFFFFFFFFFFFFFFFF;

module wolf3d_server;

import tea;
import xray;
import lipgloss;
import std::io;
import std::math;
import std::os;
import std::net;
import std::net::tcp;
import std::thread;
import std::core::dstring;
import sqlite3;

// ── Types ──────────────────────────────────────────────────────────────────

struct Pixel {
	char r, g, b;
}

const ZString VERSION = "0.2.6";

const int MAP_WIDTH  = 16;
const int MAP_HEIGHT = 16;

const char[MAP_WIDTH * MAP_HEIGHT] MAP = {
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 2, 2, 2, 2, 0, 0, 0, 3, 3, 3, 0, 0, 1,
	1, 0, 0, 2, 0, 0, 2, 0, 0, 0, 3, 0, 3, 0, 0, 1,
	1, 0, 0, 2, 0, 0, 2, 0, 0, 0, 3, 0, 3, 0, 0, 1,
	1, 0, 0, 2, 2, 0, 2, 0, 0, 0, 3, 3, 3, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 4, 0, 0, 4, 0, 0, 0, 5, 5, 5, 0, 0, 1,
	1, 0, 0, 4, 0, 0, 4, 0, 0, 0, 5, 0, 5, 0, 0, 1,
	1, 0, 0, 4, 4, 4, 4, 0, 0, 0, 5, 5, 5, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
	};

struct TagSprite {
	Tag tag;
	float transform_y;
	int screen_x;
	int screen_y;
}

struct Player {
	int id;
	char[32] name;
	sz name_len;
	float pos_x, pos_y;
	float dir_x, dir_y;
	float plane_x, plane_y;
	bool active;
}

struct Tag {
	int id;
	int wall_x, wall_y;
	int side;
	int tag_offset; // vertical stack offset (0 = first tag at this location)
	char[80] text;
	sz text_len;
	char[32] author;
	sz author_len;
}

struct ServerState {
	thread::Mutex mutex;
	void* db;
	Player[64] players;
	int next_player_id;
}

enum Mode {
	PLAYING,
	ENTERING_NAME,
	TAG_INPUT,
	WELCOME
}

struct Wolf3D {
	ServerState* server_state;
	int player_id;
	Mode mode;
	char[32] name_buf;
	sz name_len;
	char[80] tag_buf;
	sz tag_len;
	Tag[16] nearby_tags;
	int nearby_tags_count;
	int tag_wall_x, tag_wall_y, tag_side;

	float pos_x, pos_y;
	float dir_x, dir_y;
	float plane_x, plane_y;
	int width, height;
	int tick_count;
	xray::Cell[] cells;
	Pixel[] pixels;
	int key_w, key_s, key_a, key_d, key_left, key_right;
	xray::ScreenBuffer* dialog;
}

fn tea::Cmd Wolf3D.init(Wolf3D* self) @dynamic {
	self.dialog = null;
	self.width = 80;
	self.height = 24;

	// Find all open spaces and pick a random one
	int[256] open_spaces;
	int open_count = 0;
	for (int y = 1; y < MAP_HEIGHT - 1; y++) {
		for (int x = 1; x < MAP_WIDTH - 1; x++) {
			if (MAP[y * MAP_WIDTH + x] == 0) {
				open_spaces[open_count] = y * MAP_WIDTH + x;
				open_count++;
			}
		}
	}

	// Pick random open space
	int idx = open_spaces[rand(open_count)];
	int mx  = idx % MAP_WIDTH;
	int my  = idx / MAP_WIDTH;
	self.pos_x = (float)mx + 0.5f;
	self.pos_y = (float)my + 0.5f;

	// Find which side has a wall and face away from it
	bool wall_n = (my > 0 && MAP[(my - 1) * MAP_WIDTH + mx] > 0);
	bool wall_s = (my < MAP_HEIGHT - 1 && MAP[(my + 1) * MAP_WIDTH + mx] > 0);
	bool wall_e = (mx < MAP_WIDTH - 1 && MAP[my * MAP_WIDTH + mx + 1] > 0);
	bool wall_w = (mx > 0 && MAP[my * MAP_WIDTH + mx - 1] > 0);

	if (wall_n && !wall_s) {
		self.dir_x = 0.0f;
		self.dir_y = 1.0f;
	} else if (wall_s && !wall_n) {
		self.dir_x = 0.0f;
		self.dir_y = -1.0f;
	} else if (wall_e && !wall_w) {
		self.dir_x = -1.0f;
		self.dir_y = 0.0f;
	} else if (wall_w && !wall_e) {
		self.dir_x = 1.0f;
		self.dir_y = 0.0f;
	} else if (wall_n) {
		self.dir_x = 0.0f;
		self.dir_y = 1.0f;
	} else if (wall_s) {
		self.dir_x = 0.0f;
		self.dir_y = -1.0f;
	} else if (wall_e) {
		self.dir_x = -1.0f;
		self.dir_y = 0.0f;
	} else {
		self.dir_x = 1.0f;
		self.dir_y = 0.0f;
	}

	// Plane perpendicular to direction
	self.plane_x = -self.dir_y * 0.66f;
	self.plane_y = self.dir_x * 0.66f;

	self.allocate_buffers();
	return tea::tick();
}

fn void Wolf3D.allocate_buffers(Wolf3D* self) {
	sz ptotal = (sz)(self.width * self.height * 2);
	self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.pixels = mem::new_array(Pixel, ptotal);
	if (self.dialog) {
		self.dialog.resize((sz)self.width, (sz)self.height);
	} else {
		self.dialog = xray::new_screen_buffer((sz)self.width, (sz)self.height);
	}
}

fn tea::Cmd Wolf3D.update(Wolf3D* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		if (self.width == msg.window_size.width && self.height == msg.window_size.height) return null;
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		mem::free(self.cells.ptr);
		mem::free(self.pixels.ptr);
		self.allocate_buffers();
		return null;
	}
	if (msg.kind == tea::MsgKind.KEY) {
		tea::KeyMsg k = msg.key;
		if (self.mode == WELCOME) {
			if (k.code == tea::KeyCode.ENTER && self.name_len > 0) {
				self.mode = PLAYING;
				self.name_buf[self.name_len] = '\0';
				self.server_state.mutex.lock()!!;
				int id = self.server_state.next_player_id++;
				self.player_id = id;
				for (int i = 0; i < 64; i++) {
					if (!self.server_state.players[i].active) {
						self.server_state.players[i].id = id;
						self.server_state.players[i].active = true;
						self.server_state.players[i].name_len = self.name_len;
						for (sz j = 0; j < self.name_len; j++) {
							self.server_state.players[i].name[j] = self.name_buf[j];
						}
						self.server_state.players[i].name[self.name_len] = '\0';
						self.server_state.players[i].pos_x = self.pos_x;
						self.server_state.players[i].pos_y = self.pos_y;
						break;
					}
				}
				self.server_state.mutex.unlock();
				io::printfn("Player joined: %s", &self.name_buf[0]);
			}
			if (k.code == tea::KeyCode.RUNE) {
				if (self.name_len < 31) {
					self.name_buf[self.name_len++] = k.rune;
				}
			} else if (k.code == tea::KeyCode.BACKSPACE && self.name_len > 0) {
				self.name_len--;
			}
			return null;
		}
		if (self.mode == ENTERING_NAME) {
			if (k.code == tea::KeyCode.RUNE) {
				if (self.name_len < 31) {
					self.name_buf[self.name_len++] = k.rune;
				}
			} else if (k.code == tea::KeyCode.BACKSPACE && self.name_len > 0) {
				self.name_len--;
			} else if (k.code == tea::KeyCode.ENTER && self.name_len > 0) {
				self.mode = PLAYING;
				self.name_buf[self.name_len] = '\0';
				self.server_state.mutex.lock()!!;
				int id = self.server_state.next_player_id++;
				self.player_id = id;
				for (int i = 0; i < 64; i++) {
					if (!self.server_state.players[i].active) {
						self.server_state.players[i].id = id;
						self.server_state.players[i].active = true;
						self.server_state.players[i].name_len = self.name_len;
						for (sz j = 0; j < self.name_len; j++) {
							self.server_state.players[i].name[j] = self.name_buf[j];
						}
						self.server_state.players[i].name[self.name_len] = '\0';
						self.server_state.players[i].pos_x = self.pos_x;
						self.server_state.players[i].pos_y = self.pos_y;
						break;
					}
				}
				self.server_state.mutex.unlock();
				io::printfn("Player joined: %s", &self.name_buf[0]);
			}
			return null;
		} else if (self.mode == TAG_INPUT) {
			if (k.code == tea::KeyCode.RUNE) {
				if (self.tag_len < 79) {
					self.tag_buf[self.tag_len++] = k.rune;
				}
			} else if (k.code == tea::KeyCode.BACKSPACE && self.tag_len > 0) {
				self.tag_len--;
			} else if (k.code == tea::KeyCode.ENTER && self.tag_len > 0) {
				self.tag_buf[self.tag_len] = '\0';
				self.server_state.mutex.lock()!!;
				db_save_tag(
					self.server_state,
					self.tag_wall_x,
					self.tag_wall_y,
					self.tag_side,
					(String)self.tag_buf[:self.tag_len],
					(String)self.name_buf[:self.name_len]
				);
				self.server_state.mutex.unlock();
				self.mode = PLAYING;
			} else if (k.code == tea::KeyCode.ESC) {
				self.mode = PLAYING;
			}
			return null;
		} else {
			if (k.code == tea::KeyCode.RUNE) {
				if (k.rune == 't') {
					float ray_dir_x    = self.dir_x;
					float ray_dir_y    = self.dir_y;
					int map_x          = (int)self.pos_x;
					int map_y          = (int)self.pos_y;
					float delta_dist_x = (float)math::abs(1.0f / ray_dir_x);
					float delta_dist_y = (float)math::abs(1.0f / ray_dir_y);
					float side_dist_x, side_dist_y;
					int step_x, step_y;
					int side           = 0;
					if (ray_dir_x < 0) {
						step_x = -1;
						side_dist_x = (self.pos_x - (float)map_x) * delta_dist_x;
					} else {
						step_x = 1;
						side_dist_x = ((float)map_x + 1.0f - self.pos_x) * delta_dist_x;
					}
					if (ray_dir_y < 0) {
						step_y = -1;
						side_dist_y = (self.pos_y - (float)map_y) * delta_dist_y;
					} else {
						step_y = 1;
						side_dist_y = ((float)map_y + 1.0f - self.pos_y) * delta_dist_y;
					}

					int hit = 0;
					while (hit == 0) {
						if (side_dist_x < side_dist_y) {
							side_dist_x += delta_dist_x;
							map_x += step_x;
							side = 0;
						} else {
							side_dist_y += delta_dist_y;
							map_y += step_y;
							side = 1;
						}
						if (MAP[map_x + map_y * MAP_WIDTH] > 0) hit = 1;
					}
					float perp_wall_dist = (side == 0) ? (side_dist_x - delta_dist_x) : (side_dist_y - delta_dist_y);
					if (perp_wall_dist <= 2.0f) {
						self.mode = TAG_INPUT;
						self.tag_len = 0;
						self.tag_wall_x = map_x;
						self.tag_wall_y = map_y;
						self.tag_side = side;
					}
				} else {
					switch (k.rune) {
						case 'w': self.key_w = self.tick_count;
						case 's': self.key_s = self.tick_count;
						case 'a': self.key_left = self.tick_count;
						case 'd': self.key_right = self.tick_count;
					}
				}
			}
			if (k.code == tea::KeyCode.LEFT) self.key_left = self.tick_count;
			if (k.code == tea::KeyCode.RIGHT) self.key_right = self.tick_count;
		}
	}
	if (msg.kind == tea::MsgKind.TICK) {
		self.tick_count++;
		if (self.mode == PLAYING) {
			float move_speed = 0.25f;
			float rot_speed  = 0.12f;
			int thresh       = self.tick_count - 5;
			if (self.key_w >= thresh) {
				if (MAP[(int)(self.pos_x + self.dir_x * move_speed) + (int)(self.pos_y) * MAP_WIDTH]
					== 0) self.pos_x += self.dir_x * move_speed;
				if (MAP[(int)(self.pos_x) + (int)(self.pos_y + self.dir_y * move_speed) * MAP_WIDTH]
					== 0) self.pos_y += self.dir_y * move_speed;
				self.key_w = 0;
			}
			if (self.key_s >= thresh) {
				if (MAP[(int)(self.pos_x - self.dir_x * move_speed) + (int)(self.pos_y) * MAP_WIDTH]
					== 0) self.pos_x -= self.dir_x * move_speed;
				if (MAP[(int)(self.pos_x) + (int)(self.pos_y - self.dir_y * move_speed) * MAP_WIDTH]
					== 0) self.pos_y -= self.dir_y * move_speed;
				self.key_s = 0;
			}
			if (self.key_right >= thresh) {
				float old_dir_x = self.dir_x;
				self.dir_x = self.dir_x * (float)math::cos(rot_speed) - self.dir_y * (float)math::sin(rot_speed);
				self.dir_y = old_dir_x * (float)math::sin(rot_speed) + self.dir_y * (float)math::cos(rot_speed);
				float old_plane_x = self.plane_x;
				self.plane_x = self.plane_x * (float)math::cos(rot_speed) - self.plane_y * (float)math::sin(rot_speed);
				self.plane_y = old_plane_x * (float)math::sin(rot_speed) + self.plane_y * (float)math::cos(rot_speed);
				self.key_right = 0;
			}
			if (self.key_left >= thresh) {
				float old_dir_x = self.dir_x;
				self.dir_x = self.dir_x * (float)math::cos(-rot_speed) - self.dir_y * (float)math::sin(-rot_speed);
				self.dir_y = old_dir_x * (float)math::sin(-rot_speed) + self.dir_y * (float)math::cos(-rot_speed);
				float old_plane_x = self.plane_x;
				self.plane_x = self.plane_x * (float)math::cos(-rot_speed)
					- self.plane_y * (float)math::sin(-rot_speed);
				self.plane_y = old_plane_x * (float)math::sin(-rot_speed) + self.plane_y * (float)math::cos(-rot_speed);
				self.key_left = 0;
			}

			// update shared state pos
			self.server_state.mutex.lock()!!;
			for (int i = 0; i < 64; i++) {
				if (self.server_state.players[i].active && self.server_state.players[i].id == self.player_id) {
					self.server_state.players[i].pos_x = self.pos_x;
					self.server_state.players[i].pos_y = self.pos_y;
					self.server_state.players[i].dir_x = self.dir_x;
					self.server_state.players[i].dir_y = self.dir_y;
					break;
				}
			}
			db_load_tags_near(
				self.server_state,
				(int)self.pos_x,
				(int)self.pos_y,
				self.nearby_tags[..],
				&self.nearby_tags_count
			);
			self.server_state.mutex.unlock();
		}
		return tea::tick();
	}
	return null;
}

fn tea::View Wolf3D.view(Wolf3D* self) @dynamic {
	int w  = self.width;
	int h  = self.height;
	int ph = h * 2;
	for (int x = 0; x < w; x++) {
		for (int sub = 0; sub < 2; sub++) {
			float camera_x     = 2.0f * ((float)x + (sub == 0 ? 0.25f : 0.75f)) / (float)w - 1.0f;
			float ray_dir_x    = self.dir_x + self.plane_x * camera_x;
			float ray_dir_y    = self.dir_y + self.plane_y * camera_x;
			int map_x          = (int)self.pos_x;
			int map_y          = (int)self.pos_y;
			float delta_dist_x = (float)math::abs(1.0f / ray_dir_x);
			float delta_dist_y = (float)math::abs(1.0f / ray_dir_y);
			float side_dist_x, side_dist_y;
			int step_x, step_y;
			int hit            = 0;
			int side;
			if (ray_dir_x < 0) {
				step_x = -1;
				side_dist_x = (self.pos_x - (float)map_x) * delta_dist_x;
			} else {
				step_x = 1;
				side_dist_x = ((float)map_x + 1.0f - self.pos_x) * delta_dist_x;
			}
			if (ray_dir_y < 0) {
				step_y = -1;
				side_dist_y = (self.pos_y - (float)map_y) * delta_dist_y;
			} else {
				step_y = 1;
				side_dist_y = ((float)map_y + 1.0f - self.pos_y) * delta_dist_y;
			}
			while (hit == 0) {
				if (side_dist_x < side_dist_y) {
					side_dist_x += delta_dist_x;
					map_x += step_x;
					side = 0;
				} else {
					side_dist_y += delta_dist_y;
					map_y += step_y;
					side = 1;
				}
				if (MAP[map_x + map_y * MAP_WIDTH] > 0) hit = 1;
			}
			float perp_wall_dist =  (side == 0) ? (side_dist_x - delta_dist_x) : (side_dist_y - delta_dist_y);
			int line_height      =  (int)((float)ph / perp_wall_dist);
			int draw_start       = -line_height / 2 + ph / 2;
			if (draw_start < 0) draw_start = 0;
			int draw_end = line_height / 2 + ph / 2;
			if (draw_end >= ph) draw_end = ph - 1;
			Pixel color;
			switch (MAP[map_x + map_y * MAP_WIDTH]) {
				case 1: color = (Pixel) { 255, 0, 0 };
				case 2: color = (Pixel) { 0, 255, 0 };
				case 3: color = (Pixel) { 0, 0, 255 };
				case 4: color = (Pixel) { 255, 255, 0 };
				default: color = (Pixel) { 128, 80, 80 };  // Brown-ish so text is visible
			}
			if (side == 1) {
				color.r /= 2;
				color.g /= 2;
				color.b /= 2;
			}
			for (int y = 0; y < ph; y++) {
				sz idx = (sz)(y * w + x);
				Pixel sample_col;
				if (y < draw_start) {
					sample_col = { 40, 40, 40 };
				} else if (y < draw_end) {
					sample_col = color;
				} else {
					sample_col = { 80, 80, 80 };
				}
				if (sub == 0) {
					self.pixels[idx] = sample_col;
				} else {
					self.pixels[idx].r = (char)(((int)self.pixels[idx].r + (int)sample_col.r) / 2);
					self.pixels[idx].g = (char)(((int)self.pixels[idx].g + (int)sample_col.g) / 2);
					self.pixels[idx].b = (char)(((int)self.pixels[idx].b + (int)sample_col.b) / 2);
				}
			}
		}
	}
	for (int ty = 0; ty < h; ty++) {
		for (int tx = 0; tx < w; tx++) {
			sz top_idx = (sz)((ty * 2) * w + tx);
			sz bot_idx = (sz)((ty * 2 + 1) * w + tx);
			Pixel top  = self.pixels[top_idx];
			Pixel bot  = self.pixels[bot_idx];
			xray::Style style = xray::default_style().set_fg(xray::color_rgb(top.r, top.g, top.b))
				.set_bg(xray::color_rgb(bot.r, bot.g, bot.b));
			self.cells[ty * w + tx] = xray::new_cell("\xe2\x96\x80", 1, style);
		}
	}

	self.server_state.mutex.lock()!!;

	// Collect visible tags with their projected positions
	TagSprite[16] visible_tags;
	int visible_count = 0;

	for (int i = 0; i < self.nearby_tags_count; i++) {
		Tag t = self.nearby_tags[i];

		// Position sprite at exact wall center
		float tag_px = (float)t.wall_x + 0.5f;
		float tag_py = (float)t.wall_y + 0.5f;

		float sprite_x = tag_px - self.pos_x;
		float sprite_y = tag_py - self.pos_y;

		float inv_det     = 1.0f / (self.plane_x * self.dir_y - self.dir_x * self.plane_y);
		float transform_x = inv_det * (self.dir_y * sprite_x - self.dir_x * sprite_y);
		float transform_y = inv_det * (-self.plane_y * sprite_x + self.plane_x * sprite_y);

		if (transform_y > 0.1f) {
			int sprite_screen_x = (int)((float)w / 2.0f * (1.0f + transform_x / transform_y));
			int sprite_screen_y = h / 2;

			visible_tags[visible_count].tag = t;
			visible_tags[visible_count].transform_y = transform_y;
			visible_tags[visible_count].screen_x = sprite_screen_x;
			visible_tags[visible_count].screen_y = sprite_screen_y;
			visible_count++;
		}
	}

	// Sort by distance (furthest first - painter's algorithm)
	for (int i = 0; i < visible_count - 1; i++) {
		for (int j = i + 1; j < visible_count; j++) {
			if (visible_tags[j].transform_y > visible_tags[i].transform_y) {
				TagSprite tmp = visible_tags[i];
				visible_tags[i] = visible_tags[j];
				visible_tags[j] = tmp;
			}
		}
	}

	// Render tags (sorted back to front)
	for (int i = 0; i < visible_count; i++) {
		Tag t               = visible_tags[i].tag;
		int sprite_screen_x = visible_tags[i].screen_x;

		if (sprite_screen_x >= 0 && sprite_screen_x < w) {
			// Position tags at row 4 from top (in the wall area), stack going down
			int draw_y = 4 + (int)t.tag_offset * 2;
			if (draw_y >= 0 && draw_y < h) {
				int start_x = sprite_screen_x - (int)t.text_len / 2;
				for (sz j = 0; j < t.text_len; j++) {
					int cx = start_x + (int)j;
					if (cx >= 0 && cx < w) {
						xray::Style st = self.cells[draw_y * w + cx].style;
						st = st.set_fg(xray::color_rgb(0, 255, 255)).set_bg(xray::color_rgb(20, 20, 20));
						char[2] ch = { t.text[j], '\0' };
						self.cells[draw_y * w + cx] = xray::new_cell((String)ch[..], 1, st);
					}
				}

				// Draw author line "- [name]" below message
				if (draw_y + 1 < h) {
					char[25] author_line;
					author_line[0] = '-';
					author_line[1] = ' ';
					sz a = 2;
					for (sz j = 0; j < t.author_len && j < 20; j++) {
						author_line[a++] = t.author[j];
					}
					author_line[a] = '\0';
					sz author_len = a;

					int author_start_x = sprite_screen_x - (int)author_len / 2;
					for (sz j = 0; j < author_len; j++) {
						int cx = author_start_x + (int)j;
						if (cx >= 0 && cx < w) {
							xray::Style st = self.cells[(draw_y + 1) * w + cx].style;
							st = st.set_fg(xray::color_rgb(150, 150, 150)).set_bg(xray::color_rgb(20, 20, 20));
							char[2] ch = { author_line[j], '\0' };
							self.cells[(draw_y + 1) * w + cx] = xray::new_cell((String)ch[..], 1, st);
						}
					}
				}
			}
		}
	}

	for (int i = 0; i < 64; i++) {
		Player p = self.server_state.players[i];
		if (p.active && p.id != self.player_id) {
			float sprite_x = p.pos_x - self.pos_x;
			float sprite_y = p.pos_y - self.pos_y;

			float inv_det     = 1.0f / (self.plane_x * self.dir_y - self.dir_x * self.plane_y);
			float transform_x = inv_det * (self.dir_y * sprite_x - self.dir_x * sprite_y);
			float transform_y = inv_det * (-self.plane_y * sprite_x + self.plane_x * sprite_y);

			if (transform_y > 0.5f) {
				int sprite_screen_x =  (int)((float)w / 2.0f * (1.0f + transform_x / transform_y));
				int sprite_height   =  (int)math::abs((float)h / transform_y);
				int draw_start_y    = -sprite_height / 2 + h / 2;
				if (draw_start_y < 0) draw_start_y = 0;

				if (sprite_screen_x >= 0 && sprite_screen_x < w && draw_start_y < h) {
					xray::Style st = self.cells[draw_start_y * w + sprite_screen_x].style;
					st = st.set_fg(xray::color_rgb(255, 255, 0));
					char[2] initial = { p.name[0], '\0' };
					if (p.name_len == 0) initial[0] = '@';
					self.cells[draw_start_y * w + sprite_screen_x] = xray::new_cell((String)initial[..], 1, st);

					if (draw_start_y > 0) {
						int name_y  = draw_start_y - 1;
						int start_x = sprite_screen_x - (int)p.name_len / 2;
						for (sz j = 0; j < p.name_len; j++) {
							int cx = start_x + (int)j;
							if (cx >= 0 && cx < w) {
								xray::Style nst = self.cells[name_y * w + cx].style;
								nst = nst.set_fg(xray::color_rgb(200, 200, 200));
								char[2] ch = { p.name[j], '\0' };
								self.cells[name_y * w + cx] = xray::new_cell((String)ch[..], 1, nst);
							}
						}
					}
				}
			}
		}
	}
	self.server_state.mutex.unlock();

	// Help box in bottom-left corner
	if (self.mode == PLAYING) {
		char[] help_text = "[T] Tag Wall  [Q] Quit";
		int box_w        = (int)help_text.len;
		int box_y        = h - 1;
		int box_x        = 0;

		xray::Style box_st = xray::default_style().set_bg(xray::color_rgb(20, 20, 20))
			.set_fg(xray::color_rgb(180, 180, 180));
		xray::Style key_st = xray::default_style().set_bg(xray::color_rgb(20, 20, 20))
			.set_fg(xray::color_rgb(100, 200, 255));

		for (int x = box_x; x < box_x + box_w; x++) {
			if (x >= 0 && x < w) {
				int text_idx = x - box_x;
				char[2] ch   = { help_text[text_idx], '\0' };
				// Highlight [T] and [Q] keys



				if (text_idx <= 3 || (text_idx >= 14 && text_idx <= 17)) {
					self.cells[box_y * w + x] = xray::new_cell((String)ch[..], 1, key_st);
				} else {
					self.cells[box_y * w + x] = xray::new_cell((String)ch[..], 1, box_st);
				}
			}
		}
	}

	// Welcome screen with twinkling stars
	if (self.mode == WELCOME) {
		// ── Starfield background ──
		for (int y = 0; y < h; y++) {
			for (int x = 0; x < w; x++) {
				int hash = x * 374761393 + y * 668265263;
				hash = (hash ^ (hash >> 13)) * 1103515245;
				int star_rand  = (hash & 0x7FFFFFFF) % 100;
				xray::Style st = xray::default_style().set_bg(xray::color_rgb(3, 3, 12));
				if (star_rand < 1) {
					// Bright twinkling star — cycle characters for blink effect
					int phase = hash % 40;
					float t   = (float)((self.tick_count + phase) % 40) * 0.15f;
					char b    = (char)(150 + (int)(math::sin(t) * 80));
					st = st.set_fg(xray::color_rgb(b, b, (char)(b + 20)));
					int blink           = (self.tick_count / 8 + phase) % 4;
					String[] star_chars = { "✦", "✧", "∗", "·" };
					self.cells[y * w + x] = xray::new_cell(star_chars[blink], 1, st);
				} else if (star_rand < 4) {
					// Dim steady star — slower character cycle
					char b = (char)(40 + hash % 50);
					st = st.set_fg(xray::color_rgb(b, b, b));
					int blink          = (self.tick_count / 12 + hash) % 3;
					String[] dim_chars = { "·", "∙", "︙" };
					self.cells[y * w + x] = xray::new_cell(dim_chars[blink], 1, st);
				} else {
					self.cells[y * w + x] = xray::new_cell(" "[..], 1, st);
				}
			}
		}

		// ── Dialog via lipgloss ──
		DString content = dstring::temp();
		content.append_string("  WELCOME TO THE VOID  \n\n");
		content.append_string("   Enter name: ");
		for (sz i = 0; i < self.name_len; i++) {
			content.append_char(self.name_buf[i]);
		}
		content.append_char('_');
		content.append_string("\n\n");
		content.append_string("  [ Enter the Void ]  ");

		lipgloss::Style box_st = lipgloss::new_style().set_border(lipgloss::double_border())
			.set_border_fg(lipgloss::color_hex("#6450c8"))
			.background(lipgloss::color_hex("#140a28"))
			.foreground(lipgloss::color_hex("#c8b4ff"))
			.padding(1, 2, 1, 2);

		String rendered = box_st.render(content.str_view());

		// Center the dialog in the screen via lipgloss::place, then render
		// into the dialog buffer.  Padding spaces from place() have no bg
		// style so they are transparent during compositing over the starfield.
		String placed = lipgloss::place(w, h, rendered);
		self.dialog.clear();
		self.dialog.render_ansi_string(0, 0, placed, xray::default_style());

		// Composite dialog over starfield — skip transparent (space + no bg) cells
		for (int dy = 0; dy < (int)self.dialog.height; dy++) {
			for (int dx = 0; dx < (int)self.dialog.width; dx++) {
				xray::Cell c = *self.dialog.cell_at((sz)dx, (sz)dy);
				if (c.content[0] != ' ' || c.style.bg.kind != xray::ColorKind.NONE) {
					self.cells[dy * w + dx] = c;
				}
			}
		}
	}

	if (self.mode == ENTERING_NAME || self.mode == TAG_INPUT) {
		char[128] prompt;
		sz p_len = 0;
		if (self.mode == ENTERING_NAME) {
			p_len = str_copy(prompt[..], "Enter Name: ");
			for (sz i = 0; i < self.name_len; i++) prompt[p_len++] = self.name_buf[i];
		} else {
			p_len = str_copy(prompt[..], "Tag Wall: ");
			for (sz i = 0; i < self.tag_len; i++) prompt[p_len++] = self.tag_buf[i];
		}
		prompt[p_len++] = '_';
		prompt[p_len] = '\0';

		// Render the prompt box with lipgloss, center it with FlexNode
		lipgloss::Style box_st = lipgloss::new_style().set_border(lipgloss::rounded_border())
			.set_border_fg(lipgloss::color_hex("#6450c8"))
			.background(lipgloss::color_hex("#140a28"))
			.foreground(lipgloss::color_hex("#c8b4ff"));
		String rendered = box_st.render((String)prompt[:p_len]);
		int box_w       = (int)lipgloss::string_width(rendered);
		int box_h       = 3;

		xray::FlexNode* root = xray::flex_col().with_justify(xray::JustifyContent.JUSTIFY_CENTER)
			.with_align(xray::AlignItems.ALIGN_CENTER)
			.add(xray::flex_node().with_main_size(xray::constraint_len(box_h))
				.with_cross_size(xray::constraint_len(box_w)));
		root.solve(xray::new_rect(0, 0, w, h));
		xray::Rect box = root.child_rect(0);

		self.dialog.clear();
		self.dialog.render_ansi_string(0, 0, lipgloss::place(w, h, rendered), xray::default_style());
		for (int dy = 0; dy < box_h && box.y + dy < h; dy++) {
			for (int dx = 0; dx < box_w && box.x + dx < w; dx++) {
				xray::Cell c = *self.dialog.cell_at((sz)(box.x + dx), (sz)(box.y + dy));
				if (c.content[0] != ' ' || c.style.bg.kind != xray::ColorKind.NONE) {
					self.cells[(box.y + dy) * w + (box.x + dx)] = c;
				}
			}
		}
	}

	return tea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

// ── Server Implementation ──────────────────────────────────────────────────

struct Client {
	TcpSocket socket;
	ServerState* server_state;
}

fn void db_init(ServerState* state) {
	int rc = sqlite3::sqlite3_open("tags.db", &state.db);
	if (rc != 0) {
		io::printfn("Can't open database");
		return;
	}
	char* errmsg = null;
	rc = sqlite3::sqlite3_exec(state.db, "PRAGMA journal_mode=WAL;", null, null, &errmsg);
	if (rc != 0) {
		io::printfn("SQL error: %s", errmsg);
		sqlite3::sqlite3_free(errmsg);
	}

	char* sql = "CREATE TABLE IF NOT EXISTS tags (" "id INTEGER PRIMARY KEY AUTOINCREMENT, " "wall_x INTEGER NOT NULL, " "wall_y INTEGER NOT NULL, " "side INTEGER NOT NULL, " "tag_offset INTEGER NOT NULL DEFAULT 0, " "text TEXT NOT NULL, " "author TEXT NOT NULL, " "created_at DATETIME DEFAULT CURRENT_TIMESTAMP);";
	rc = sqlite3::sqlite3_exec(state.db, sql, null, null, &errmsg);
	if (rc != 0) {
		io::printfn("SQL error: %s", errmsg);
		sqlite3::sqlite3_free(errmsg);
	}
}

fn int db_get_tag_count_at(ServerState* state, int wall_x, int wall_y, int side) {
	void* stmt = null;
	char* sql  = "SELECT COUNT(*) FROM tags WHERE wall_x = ? AND wall_y = ? AND side = ?;";
	int rc     = sqlite3::sqlite3_prepare_v2(state.db, sql, -1, &stmt, null);
	if (rc != 0) return 0;
	sqlite3::sqlite3_bind_int(stmt, 1, wall_x);
	sqlite3::sqlite3_bind_int(stmt, 2, wall_y);
	sqlite3::sqlite3_bind_int(stmt, 3, side);
	int count = 0;
	if (sqlite3::sqlite3_step(stmt) == sqlite3::SQLITE_ROW) {
		count = sqlite3::sqlite3_column_int(stmt, 0);
	}
	sqlite3::sqlite3_finalize(stmt);
	return count;
}

fn void db_save_tag(ServerState* state, int wall_x, int wall_y, int side, String text, String author) {
	// Assign offset based on existing tags at this location
	int offset = db_get_tag_count_at(state, wall_x, wall_y, side);
	void* stmt = null;
	char* sql  = "INSERT INTO tags (wall_x, wall_y, side, tag_offset, text, author) VALUES (?, ?, ?, ?, ?, ?);";
	int rc     = sqlite3::sqlite3_prepare_v2(state.db, sql, -1, &stmt, null);
	if (rc != 0) return;

	sqlite3::sqlite3_bind_int(stmt, 1, wall_x);
	sqlite3::sqlite3_bind_int(stmt, 2, wall_y);
	sqlite3::sqlite3_bind_int(stmt, 3, side);
	sqlite3::sqlite3_bind_int(stmt, 4, offset);
	sqlite3::sqlite3_bind_text(stmt, 5, text.ptr, (int)text.len, sqlite3::SQLITE_TRANSIENT);
	sqlite3::sqlite3_bind_text(stmt, 6, author.ptr, (int)author.len, sqlite3::SQLITE_TRANSIENT);

	sqlite3::sqlite3_step(stmt);
	sqlite3::sqlite3_finalize(stmt);
}

fn sz str_copy(char[] dest, char* src) {
	if (src == null) return 0;
	sz i = 0;
	while (src[i] != '\0' && i < dest.len) {
		dest[i] = src[i];
		i++;
	}
	return i;
}

fn void db_load_tags_near(ServerState* state, int player_x, int player_y, Tag[] out_tags, int* out_count) {
	void* stmt = null;
	char* sql  = "SELECT id, wall_x, wall_y, side, tag_offset, text, author FROM tags WHERE abs(wall_x - ?) <= 2 AND abs(wall_y - ?) <= 2 ORDER BY tag_offset LIMIT 16;";
	int rc     = sqlite3::sqlite3_prepare_v2(state.db, sql, -1, &stmt, null);
	if (rc != 0) return;

	sqlite3::sqlite3_bind_int(stmt, 1, player_x);
	sqlite3::sqlite3_bind_int(stmt, 2, player_y);

	int count = 0;
	while (sqlite3::sqlite3_step(stmt) == sqlite3::SQLITE_ROW && count < 16) {
		Tag t;
		t.id = sqlite3::sqlite3_column_int(stmt, 0);
		t.wall_x = sqlite3::sqlite3_column_int(stmt, 1);
		t.wall_y = sqlite3::sqlite3_column_int(stmt, 2);
		t.side = sqlite3::sqlite3_column_int(stmt, 3);
		t.tag_offset = sqlite3::sqlite3_column_int(stmt, 4);

		char* text_ptr = sqlite3::sqlite3_column_text(stmt, 5);
		t.text_len = str_copy(t.text[..], text_ptr);

		char* author_ptr = sqlite3::sqlite3_column_text(stmt, 6);
		t.author_len = str_copy(t.author[..], author_ptr);

		out_tags[count] = t;
		count++;
	}
	*out_count = count;
	sqlite3::sqlite3_finalize(stmt);
}

fn void write_socket(TcpSocket* s, char[] data) {
	(void)s.write(data);
}

fn sz byte_to_str(char b, char* buf) {
	if (b >= 100) {
		buf[0] = (char)('0' + b / 100);
		buf[1] = (char)('0' + (b / 10) % 10);
		buf[2] = (char)('0' + b % 10);
		return 3;
	} else if (b >= 10) {
		buf[0] = (char)('0' + b / 10);
		buf[1] = (char)('0' + b % 10);
		return 2;
	}
	buf[0] = (char)('0' + b);
	return 1;
}

fn void write_sgr(TcpSocket* s, xray::Color fg, xray::Color bg) {
	char[48] buf;
	sz pos = 0;
	buf[pos++] = '\x1b';
	buf[pos++] = '[';
	buf[pos++] = '0';
	buf[pos++] = 'm';
	if (fg.kind == xray::ColorKind.TRUECOLOR) {
		buf[pos++] = '\x1b';
		buf[pos++] = '[';
		buf[pos++] = '3';
		buf[pos++] = '8';
		buf[pos++] = ';';
		buf[pos++] = '2';
		buf[pos++] = ';';
		pos += byte_to_str(fg.r, &buf[pos]);
		buf[pos++] = ';';
		pos += byte_to_str(fg.g, &buf[pos]);
		buf[pos++] = ';';
		pos += byte_to_str(fg.b, &buf[pos]);
		buf[pos++] = 'm';
	}
	if (bg.kind == xray::ColorKind.TRUECOLOR) {
		buf[pos++] = '\x1b';
		buf[pos++] = '[';
		buf[pos++] = '4';
		buf[pos++] = '8';
		buf[pos++] = ';';
		buf[pos++] = '2';
		buf[pos++] = ';';
		pos += byte_to_str(bg.r, &buf[pos]);
		buf[pos++] = ';';
		pos += byte_to_str(bg.g, &buf[pos]);
		buf[pos++] = ';';
		pos += byte_to_str(bg.b, &buf[pos]);
		buf[pos++] = 'm';
	}
	write_socket(s, buf[:pos]);
}

fn void render_cells_to(xray::Cell[] cells, sz width, sz height, TcpSocket* s) {
	write_socket(s, (char[])"\x1b[H");
	xray::Style pen = xray::default_style();
	for (sz y = 0; y < height; y++) {
		for (sz x = 0; x < width; x++) {
			xray::Cell cell = cells[y * width + x];
			if (!cell.style.eq(pen)) {
				write_sgr(s, cell.style.fg, cell.style.bg);
				pen = cell.style;
			}
			write_socket(s, (char[])cell.content_str());
		}
		if (y < height - 1) {
			write_socket(s, (char[])"\x1b[K\r\n");
		} else {
			write_socket(s, (char[])"\x1b[K");
		}
	}
	write_socket(s, (char[])"\x1b[0m");
}

extern fn void* signal(int signum, void* handler);
extern fn long c3_time_ms_long();
const int SIGPIPE   = 13;
const void* SIG_IGN = (void*)(uptr)1;

// Telnet option codes
const char TELNET_IAC  = 255;
const char TELNET_SB   = 250;
const char TELNET_SE   = 240;
const char TELNET_NAWS = 31; // Negotiate About Window Size

fn bool wait_for_naws(TcpSocket* s, int* out_w, int* out_h) {
	char[32] buf;
	int pos      = 0;
	int deadline = 500; // 500ms timeout
	int start    = (int)c3_time_ms_long();
	while ((int)c3_time_ms_long() - start < deadline) {
		sz? r = s.read(buf[pos..]);
		if (catch err = r) return false;
		if (r > 0) {
			pos += (int)r;
			// Look for IAC SB NAWS <w_hi> <w_lo> <h_hi> <h_lo> IAC SE
			for (int i = 0; i <= pos - 9; i++) {
				if (buf[i] == TELNET_IAC && i + 8 < pos) {
					if (buf[i + 1] == TELNET_SB && buf[i + 2] == TELNET_NAWS) {
						if (buf[i + 7] == TELNET_IAC && buf[i + 8] == TELNET_SE) {
							*out_w = ((int)(char)buf[i + 3] << 8) | (int)(char)buf[i + 4];
							*out_h = ((int)(char)buf[i + 5] << 8) | (int)(char)buf[i + 6];
							return true;
						}
					}
				}
			}
		}
		thread::sleep_ms(10);
	}
	return false;
}

fn int handle_client(void* arg) {
	@pool_init(&allocators::LIBC_ALLOCATOR, 256 * 1024) {
		Client* c   = (Client*)arg;
		TcpSocket s = c.socket;
		Wolf3D* app = mem::new(Wolf3D);
		app.init();
		app.server_state = c.server_state;
		app.mode = WELCOME;

		// 1. Send Telnet negotiation bytes to force character mode and suppress local echo
		// IAC (255), WILL (251), ECHO (1)
		// IAC (255), WILL (251), SUPPRESS GO AHEAD (3)
		// IAC (255), DO (253), SUPPRESS GO AHEAD (3)
		char[] telnet_init = {
			(char)255,
			(char)251,
			(char)1,
			(char)255,
			(char)251,
			(char)3,
			(char)255,
			(char)253,
			(char)3
		};
		write_socket(&s, telnet_init);

		write_socket(&s, (char[])"\x1b[?1049h\x1b[?25l");

		// Query terminal size via NAWS
		char[] naws_req = { (char)255, (char)253, (char)31 }; // IAC DO NAWS
		write_socket(&s, naws_req);

		int term_w = 80;
		int term_h = 24;
		wait_for_naws(&s, &term_w, &term_h);
		if (term_w > 0 && term_h > 0) {
			app.width = term_w;
			app.height = term_h;
			mem::free(app.cells.ptr);
			mem::free(app.pixels.ptr);
			app.allocate_buffers();
		}

		// Clear screen once at start (only needed if terminal is wider than our buffer)
		write_socket(&s, (char[])"\x1b[2J");

		// @pool per frame: frees temp allocations (lipgloss/dstring) each frame.
		// @pool_init above sets up tmem for this thread.
		bool running = true;
		char[1024] buf;
		while (running) {
			@pool() {
				tea::View v = app.view();
				render_cells_to(v.cells, v.cells_width, v.cells_height, &s);
			};

			// Poll socket with 0ms timeout — only read if data is available,
			// so the loop keeps ticking and animating without input.
			tea::PollFd pfd;
			pfd.fd = s.sock;
			pfd.events = tea::POLLIN;
			pfd.revents = 0;

			if (tea::poll(&pfd, 1, 0) > 0 && (pfd.revents & tea::POLLIN) != 0) {
				sz? read_result = s.read(buf[..]);
				if (catch err = read_result) {
					running = false;
				} else {
					sz n = read_result;
					if (n == 0) {
						running = false;
					} else if (n > 0) {
						// Filter out incoming Telnet command sequences starting with IAC (255)
						sz out_n = 0;
						sz i     = 0;
						while (i < n) {
							if (buf[i] == (char)255) {
								if (i + 2 < n) {
									i += 3;
								} else {
									i = n;
								}
							} else {
								buf[out_n++] = buf[i++];
							}
						}
						n = out_n;

						if (n > 0) {
							tea::ParseResult pr = tea::parse_key(buf[:n]);
							if (pr.consumed > 0) {
								// Only quit on ESC/'q' when in PLAYING mode
								// (input modes handle their own keys via update)
								bool is_quit = (pr.key.code == tea::KeyCode.ESC
									|| (pr.key.code == tea::KeyCode.RUNE && pr.key.rune == 'q'));
								if (is_quit && app.mode == PLAYING) {
									running = false;
								} else {
									app.update({ .kind = tea::MsgKind.KEY, .key = pr.key });
								}
							}
						}
					}
				}
			}

			if (running) app.update(tea::tick_msg());
			thread::sleep_ms(16);
		}
		write_socket(&s, (char[])"\x1b[?1049l\x1b[?25h");
		(void)s.close();

		app.server_state.mutex.lock()!!;
		for (int i = 0; i < 64; i++) {
			if (app.server_state.players[i].id == app.player_id) {
				app.server_state.players[i].active = false;
			}
		}
		app.server_state.mutex.unlock();

		mem::free(app);
		mem::free(c);
	}; // @pool_init
	return 0;
}

fn int main(String[] args) {
	signal(SIGPIPE, SIG_IGN);
	ServerState* state = mem::new(ServerState);
	state.mutex.init()!!;
	db_init(state);

	TcpServerSocket server = tcp::listen("0.0.0.0", 8080, 10)!!;
	io::printfn("Wolf3D Server v%s listening on :8080", VERSION);
	while (true) {
		if (try client = tcp::accept(&server)) {
			Client* c = mem::new(Client);
			c.socket = client;
			c.server_state = state;
			thread::Thread t;
			thread::Thread.create(&t, &handle_client, c)!!;
			t.detach();
		}
	}
}