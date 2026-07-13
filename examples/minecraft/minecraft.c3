module minecraft;

import milktea;
import xray;
import glaze;
import std::io;
import std::math;
import std::os;

// ── Math & Types ─────────────────────────────────────────────────────────────

struct Vec3 {
	float x, y, z;
}

fn Vec3 vec3(float x, float y, float z) => (Vec3) { x, y, z };

fn float Vec3.dist_sq(Vec3 a, Vec3 b) {
	float dx = a.x - b.x;
	float dy = a.y - b.y;
	float dz = a.z - b.z;
	return dx * dx + dy * dy + dz * dz;
}

// Block type determines visual appearance via procedural textures.
enum BlockType : char {
	GRASS,
	DIRT,
	WOOD,
	LEAF,
	STONE,
}

struct Block {
	int x, y, z;
	char r, g, b;
	bool active;
	BlockType btype;
}

struct Pixel {
	char r, g, b;
}

const int MAX_BLOCKS = 4096;
const int MAX_VOXELS = 32768;

struct BlockFace {
	Vec3 pos;
	Vec3 normal;
	Vec3 tan_u;
	Vec3 tan_v;
	char r, g, b;
	// Block world position for texel hashing
	int bx, by, bz;
	// Face normal index 0-5 (+x,-x,+y,-y,+z,-z) for hash variation
	int face_idx;
	BlockType btype;
}

struct Minecraft {
	Block[MAX_BLOCKS] blocks;
	int block_count;

	BlockFace[MAX_BLOCKS * 6] faces;
	int face_count;

	// Camera
	float cam_x, cam_y, cam_z;
	float yaw, pitch;

	// Velocity-based movement: impulse on keypress, damped each tick.
	// Top speed tuned so it matches the old 0.25/tick feel at steady state:
	// impulse 0.35, damping 0.80 → steady state ≈ 0.35/(1-0.80) = 1.75/tick
	// which is too fast, so we scale impulse down to reach ~0.25/tick:
	// 0.05/(1-0.80) = 0.25 — use impulse=0.05, damp=0.80.
	float vel_x, vel_z;
	// Vertical velocity: gravity pulls down each tick, jump sets positive.
	float vel_y;
	bool grounded;
	// Angular velocity for arrow-key yaw (optional smooth turning).
	float vel_yaw;

	// Held-key movement state: set on KEY_PRESS/KEY_REPEAT, cleared on
	// KEY_RELEASE. On terminals without kitty key-release reporting, only
	// KEY_PRESS ever arrives, so a held key is also expired in TICK if not
	// refreshed for a few ticks (OS key-repeat keeps refreshing it while held).
	bool held_w, held_a, held_s, held_d, held_space;
	int held_w_tick, held_a_tick, held_s_tick, held_d_tick, held_space_tick;

	// Viewport
	int width, height;
	int frame;

	// Rendering buffers
	xray::Cell[] cells;
	Pixel[] pixels;
	float[] depth;

	// Game state
	int tick_count;
	int swing_frame;

	// Mouse state
	int mouse_x, mouse_y;
	int mouse_px, mouse_py;
	bool mouse_init;
	// Terminal width in pixels (0 if the terminal doesn't report it), used to
	// scale look sensitivity so a full-window swipe turns a fixed angle
	// regardless of font size or window size.
	int win_px_w;

	// Dirty flag: rebuild faces only when world changes
	bool world_dirty;

	// Sliding-window world generation: (world_cx, world_cz) is the integer
	// column the world was last generated around. regen_world() is called
	// from TICK whenever the player strays more than 4 cells from this
	// center (hysteresis keeps it from firing every tick).
	int world_cx, world_cz;

	// Player edits must survive window regeneration. mined_cells records
	// cells the player has dug out (so regen_world skips re-emitting the
	// procedural block there); placed_blocks records player-placed blocks
	// (so regen_world re-adds them when they fall back inside the window).
	int[3][512] mined_cells;
	int mined_count;
	int[4][512] placed_blocks; // x, y, z, btype
	int placed_count;
}

// ── World Generation ─────────────────────────────────────────────────────────

// terrain_height returns a clamped [0,4] height for a given (x,z) column
// using a combination of two sine/cosine waves plus an integer hash jitter.
fn int terrain_height(int x, int z) {
	// Cheap integer hash for a small jitter term
	uint h_hash = (uint)x * 374761393u + (uint)z * 668265263u;
	h_hash ^= (h_hash >> 13);
	h_hash *= 1274126177u;
	h_hash ^= (h_hash >> 16);
	float jitter = (float)(h_hash & 0xFFu) / 255.0f - 0.5f; // [-0.5, 0.5)

	float hf = 1.5f
		+ 1.2f * (float)math::sin((float)x * 0.35f)
		+ 1.2f * (float)math::cos((float)z * 0.3f)
		+ 0.4f * jitter;
	int h = 1 + (int)hf;
	if (h < 0) h = 0;
	if (h > 4) h = 4;
	return h;
}

// tree_hash returns a small integer 0-15 for (x,z) used to decide tree placement.
fn int tree_hash(int x, int z) {
	uint h = (uint)x * 2246822519u + (uint)z * 3266489917u;
	h ^= (h >> 17);
	h *= 2246822519u;
	h ^= (h >> 13);
	return (int)(h & 0xFu); // 0..15
}

fn void Minecraft.place_tree(Minecraft* self, int tx, int tz, int base_y) {
	// Trunk: 3 WOOD blocks above the grass surface
	for (int y = base_y + 1; y <= base_y + 3; y++) {
		self.add_block_typed(tx, y, tz, BlockType.WOOD);
	}
	// Canopy: two leaf layers at y = base_y+4 and base_y+5, radius ~2.2
	for (int ox = -2; ox <= 2; ox++) {
		for (int oz = -2; oz <= 2; oz++) {
			float d = (float)math::sqrt((float)(ox * ox + oz * oz));
			if (d > 2.2f) continue;
			self.add_block_typed(tx + ox, base_y + 4, tz + oz, BlockType.LEAF);
			self.add_block_typed(tx + ox, base_y + 5, tz + oz, BlockType.LEAF);
		}
	}
}

// is_mined returns true if (x, y, z) is a cell the player has previously dug
// out — regen_world skips re-emitting procedural terrain there.
fn bool Minecraft.is_mined(Minecraft* self, int x, int y, int z) {
	for (int i = 0; i < self.mined_count; i++) {
		if (self.mined_cells[i][0] == x && self.mined_cells[i][1] == y && self.mined_cells[i][2] == z) {
			return true;
		}
	}
	return false;
}

// World window radius around the player. 29x29 columns * ~2-3 blocks/column
// stays comfortably within MAX_BLOCKS, and chosen so pop-in at the edge
// happens mostly inside the distance-fog band (fully fogged at ~38 units).
const int WORLD_RADIUS = 14;

// regen_world regenerates the sliding terrain window centered on the
// player's current column (round(cam_x), round(cam_z)). Procedural terrain
// and trees are pure functions of (x, z), so the same columns regenerate
// identically each time the window recenters. Player edits are reapplied:
// mined cells are skipped during generation, and placed blocks inside the
// new window are re-added.
fn void Minecraft.regen_world(Minecraft* self) {
	self.block_count = 0;

	int cx = (int)math::round(self.cam_x);
	int cz = (int)math::round(self.cam_z);
	self.world_cx = cx;
	self.world_cz = cz;

	for (int x = cx - WORLD_RADIUS; x <= cx + WORLD_RADIUS; x++) {
		for (int z = cz - WORLD_RADIUS; z <= cz + WORLD_RADIUS; z++) {
			int h = terrain_height(x, z);

			// Top layer: grass
			if (!self.is_mined(x, h, z)) self.add_block_typed(x, h, z, BlockType.GRASS);
			// Below grass: dirt
			if (!self.is_mined(x, h - 1, z)) self.add_block_typed(x, h - 1, z, BlockType.DIRT);
			// Stone one more down, only if column is tall enough (saves blocks)
			if (h >= 2 && !self.is_mined(x, h - 2, z)) {
				self.add_block_typed(x, h - 2, z, BlockType.STONE);
			}

			// Deterministic sparse tree placement: only on a coarse 5x5 grid
			// of columns, and only when tree_hash lands on 0 (1-in-16 chance)
			// — roughly 1 tree per 125-400 columns, canopy radius 2.2 so a
			// 5-cell grid spacing never overlaps neighboring canopies.
			if (x % 5 == 0 && z % 5 == 0 && tree_hash(x, z) == 0) {
				self.place_tree(x, z, h);
			}
		}
	}

	// Re-add player-placed blocks that fall inside the new window.
	for (int i = 0; i < self.placed_count; i++) {
		int px = self.placed_blocks[i][0];
		int py = self.placed_blocks[i][1];
		int pz = self.placed_blocks[i][2];
		if (px < cx - WORLD_RADIUS || px > cx + WORLD_RADIUS) continue;
		if (pz < cz - WORLD_RADIUS || pz > cz + WORLD_RADIUS) continue;
		self.add_block_typed(px, py, pz, (BlockType)self.placed_blocks[i][3]);
	}
}

// base_color_for_face returns the RGB triple for a block type given its face
// normal index (0=+x,1=-x,2=+y,3=-y,4=+z,5=-z).
macro void base_color_for_face(BlockType btype, int face_idx, char* r, char* g, char* b) {
	switch (btype) {
		case BlockType.GRASS:
			// Top (+y) is grass green; bottom is dirt; sides are dirt with a
			// thin green strip handled per-pixel via v coordinate.
			if (face_idx == 2) {
				// +y: grass top
				*r = 80; *g = 160; *b = 50;
			} else if (face_idx == 3) {
				// -y: dirt bottom
				*r = 110; *g = 75; *b = 30;
			} else {
				// sides: base dirt color; green strip added per-pixel
				*r = 110; *g = 75; *b = 30;
			}
		case BlockType.DIRT:
			*r = 110; *g = 75; *b = 30;
		case BlockType.WOOD:
			if (face_idx == 2 || face_idx == 3) {
				// Top/bottom: wood rings (yellowish)
				*r = 180; *g = 140; *b = 80;
			} else {
				// Sides: bark brown
				*r = 120; *g = 80; *b = 45;
			}
		case BlockType.LEAF:
			*r = 40; *g = 140; *b = 40;
		case BlockType.STONE:
			*r = 128; *g = 128; *b = 128;
	}
}

fn void Minecraft.add_block_typed(Minecraft* self, int x, int y, int z, BlockType btype) {
	if (self.block_count >= MAX_BLOCKS) return;
	char r, g, b;
	base_color_for_face(btype, 0, &r, &g, &b); // placeholder, not used for render
	self.blocks[self.block_count++] = { x, y, z, r, g, b, true, btype };
}

fn void Minecraft.add_block(Minecraft* self, int x, int y, int z, char r, char g, char b) {
	if (self.block_count >= MAX_BLOCKS) return;
	self.blocks[self.block_count++] = { x, y, z, r, g, b, true, BlockType.STONE };
}

// ── Tea Methods ──────────────────────────────────────────────────────────────

fn milktea::Cmd Minecraft.init(Minecraft* self) @dynamic {
	self.width = 80;
	self.height = 24;
	self.cam_x = 0;
	// Eye is 1.6 above feet; feet start at terrain surface top + 0.5,
	// then spawn slightly higher so gravity settles the player naturally.
	// Use (0, -12) to match the actual spawn column (cam_x=0, cam_z=-12).
	self.cam_y = (float)(terrain_height(0, -12)) + 0.5f + 1.6f + 0.5f;
	self.cam_z = -12;
	self.yaw = 0;
	self.pitch = 0;
	self.vel_x = 0;
	self.vel_z = 0;
	self.vel_y = 0;
	self.grounded = false;
	self.vel_yaw = 0;
	self.mouse_init = false;
	self.win_px_w = (int)milktea::get_window_size().ws_xpixel;
	self.world_dirty = true;
	self.mined_count = 0;
	self.placed_count = 0;
	self.regen_world();
	self.allocate_buffers();
	return milktea::tick();
}

fn void Minecraft.allocate_buffers(Minecraft* self) {
	sz ptotal = (sz)(self.width * self.height * 2);
	self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.pixels = mem::new_array(Pixel, ptotal);
	self.depth = mem::new_array(float, ptotal);
}

// Returns true if an active block occupies the feet or head cell of the
// player's body at horizontal position (x, z) with eye height y_eye.
// The body is treated as a small square (radius 0.3) rather than a point,
// so corners are checked too — this makes side collisions feel solid
// instead of letting the player clip past block edges.
fn bool Minecraft.body_collides(Minecraft* self, float x, float y_eye, float z) {
	// The ±0.1 keeps the feet cell from including the block being stood on
	// and the head cell from grazing a ceiling block just above.
	int feet_cell_y = (int)math::round(y_eye - 1.6f + 0.1f);
	int head_cell_y = (int)math::round(y_eye - 0.1f);
	float radius = 0.3f;
	for (int ci = 0; ci < self.block_count; ci++) {
		if (!self.blocks[ci].active) continue;
		if (self.blocks[ci].y != feet_cell_y && self.blocks[ci].y != head_cell_y) continue;
		foreach (float cx : { x - radius, x + radius }) {
			int col_x = (int)math::round(cx);
			if (self.blocks[ci].x != col_x) continue;
			foreach (float cz : { z - radius, z + radius }) {
				int col_z = (int)math::round(cz);
				if (self.blocks[ci].z != col_z) continue;
				return true;
			}
		}
	}
	return false;
}

fn milktea::Cmd Minecraft.update(Minecraft* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		if (self.width == msg.window_size.width && self.height == msg.window_size.height) return null;
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		self.win_px_w = (int)milktea::get_window_size().ws_xpixel;
		mem::free(self.cells.ptr);
		mem::free(self.pixels.ptr);
		mem::free(self.depth.ptr);
		self.allocate_buffers();
		return null;
	}

	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg k = msg.key;
		if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && k.rune == 'q')) return milktea::quit();

		bool is_release = k.action == milktea::KeyAction.KEY_RELEASE;

		// Held-key state for w/a/s/d/space: PRESS/REPEAT mark the key held
		// and stamp the current tick; RELEASE clears it immediately. On
		// terminals that never send releases, a safety expiry in TICK
		// clears keys that haven't been refreshed in a few ticks.
		if (k.code == milktea::KeyCode.RUNE) {
			switch (k.rune) {
				case 'w':
					self.held_w = !is_release;
					self.held_w_tick = self.tick_count;
				case 'a':
					self.held_a = !is_release;
					self.held_a_tick = self.tick_count;
				case 's':
					self.held_s = !is_release;
					self.held_s_tick = self.tick_count;
				case 'd':
					self.held_d = !is_release;
					self.held_d_tick = self.tick_count;
				case ' ':
					self.held_space = !is_release;
					self.held_space_tick = self.tick_count;
				default: break;
			}
		}

		// Non-movement actions only fire on PRESS/REPEAT, never on RELEASE
		// (a release of 'f' must not mine a second block).
		if (!is_release) {
			if (k.code == milktea::KeyCode.RUNE) {
				switch (k.rune) {
					case 'f':
						self.swing_frame = 10;
						self.mine_block();
					case 'e':
						// Place a stone block at the face adjacent to the targeted block
						self.place_block();
					default: break;
				}
			}
			// Arrow keys: angular velocity for smooth rotation.
			// damp=0.75 -> steady state = 0.015/0.25 = 0.06 rad/tick.
			if (k.code == milktea::KeyCode.LEFT)  self.vel_yaw -= 0.015f;
			if (k.code == milktea::KeyCode.RIGHT) self.vel_yaw += 0.015f;
		}
	}

	if (msg.kind == milktea::MsgKind.MOUSE) {
		if (!self.mouse_init) {
			self.mouse_x = msg.mouse.col;
			self.mouse_y = msg.mouse.row;
			self.mouse_px = msg.mouse.px;
			self.mouse_py = msg.mouse.py;
			self.mouse_init = true;
		} else {
			if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION) {
				// Prefer pixel-resolution deltas when the terminal reports them
				// (SGR-Pixels, DEC mode 1016); pixels are square so no aspect
				// correction is needed and both axes share one sensitivity.
				// Fall back to cell deltas otherwise.
				//
				// Sensitivity is proportional to window size: a swipe across
				// the full window width always turns TURN_PER_WIDTH radians
				// (~275°, matching the old 0.06 rad/cell feel at 80 cols),
				// independent of font size or window dimensions.
				float turn_per_width = 4.8f;
				if (msg.mouse.px != 0 || msg.mouse.py != 0) {
					int dpx = msg.mouse.px - self.mouse_px;
					int dpy = msg.mouse.py - self.mouse_py;
					float sens = self.win_px_w > 0 ? turn_per_width / (float)self.win_px_w : 0.006f;
					self.yaw += (float)dpx * sens;
					self.pitch -= (float)dpy * sens;
				} else {
					int dx = msg.mouse.col - self.mouse_x;
					int dy = msg.mouse.row - self.mouse_y;
					// yaw += dx*sens: mouse-right (dx>0) increases yaw, turning right
					// because with F=(sin,cos), dF/dyaw = (cos,-sin) = R — consistent. ✓
					float sens = self.width > 0 ? turn_per_width / (float)self.width : 0.06f;
					self.yaw += (float)dx * sens;
					self.pitch -= (float)dy * sens;
				}
				if (self.pitch > 1.4f) self.pitch = 1.4f;
				if (self.pitch < -1.4f) self.pitch = -1.4f;
				self.mouse_x = msg.mouse.col;
				self.mouse_y = msg.mouse.row;
				self.mouse_px = msg.mouse.px;
				self.mouse_py = msg.mouse.py;
			}
		}
		if (msg.mouse.action == milktea::MouseAction.MOUSE_PRESS && msg.mouse.button == milktea::MouseButton.MOUSE_LEFT) {
			self.swing_frame = 10;
			self.mine_block();
		}
		if (msg.mouse.action == milktea::MouseAction.MOUSE_PRESS && msg.mouse.button == milktea::MouseButton.MOUSE_RIGHT) {
			self.place_block();
		}
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.tick_count++;
		self.frame++;
		if (self.swing_frame > 0) self.swing_frame--;

		// Safety expiry: on terminals that never send KEY_RELEASE, a held key
		// is cleared if it hasn't been refreshed (by a fresh PRESS/REPEAT) in
		// more than 8 ticks. Kitty terminals send releases immediately, so
		// this only matters as a fallback for legacy key reporting.
		int expiry = 8;
		if (self.held_w && self.tick_count - self.held_w_tick > expiry) self.held_w = false;
		if (self.held_a && self.tick_count - self.held_a_tick > expiry) self.held_a = false;
		if (self.held_s && self.tick_count - self.held_s_tick > expiry) self.held_s = false;
		if (self.held_d && self.tick_count - self.held_d_tick > expiry) self.held_d = false;
		if (self.held_space && self.tick_count - self.held_space_tick > expiry) self.held_space = false;

		// Apply a movement impulse every tick a key is held, instead of only
		// on sparse OS key-repeat events. Convention: forward F = (sin yaw, 0,
		// cos yaw), right R = (cos yaw, 0, -sin yaw). Steady-state speed while
		// grounded ≈ impulse / (1 - damp) = 0.0525 / 0.20 ≈ 0.26/tick.
		float impulse = 0.0525f;
		bool moving = self.held_w || self.held_a || self.held_s || self.held_d;
		if (self.held_w) {
			self.vel_x += (float)math::sin(self.yaw) * impulse;
			self.vel_z += (float)math::cos(self.yaw) * impulse;
		}
		if (self.held_s) {
			self.vel_x -= (float)math::sin(self.yaw) * impulse;
			self.vel_z -= (float)math::cos(self.yaw) * impulse;
		}
		if (self.held_a) {
			// Strafe left: -R = (-cos yaw, 0, +sin yaw)
			self.vel_x -= (float)math::cos(self.yaw) * impulse;
			self.vel_z += (float)math::sin(self.yaw) * impulse;
		}
		if (self.held_d) {
			// Strafe right: +R = (+cos yaw, 0, -sin yaw)
			self.vel_x += (float)math::cos(self.yaw) * impulse;
			self.vel_z -= (float)math::sin(self.yaw) * impulse;
		}
		if (self.held_space && self.grounded) {
			self.vel_y = 0.28f;
			self.grounded = false;
		}

		// Damping: with impulses now arriving every tick (not just on sparse
		// OS key-repeat), applying the airborne damp (0.98) while a movement
		// key is held would let speed run away (0.075/0.02 ≈ 3.75/tick). So
		// use the tight ground damp (0.80) whenever a movement key is held,
		// regardless of grounded state (this also gives Minecraft-style air
		// control). Only fall back to the loose airborne damp (0.98) when no
		// movement key is held, to preserve jump momentum through a jump.
		float damp = moving ? 0.80f : (self.grounded ? 0.80f : 0.98f);

		// ── Horizontal collision ─────────────────────────────────────────
		// Move each axis independently against body_collides so the player
		// slides along walls instead of stopping dead on diagonal contact.
		// On collision keep the velocity (just don't move): pressing into a
		// wall while jumping then carries the player onto the block once the
		// body rises above it — matching the hold-forward-and-jump feel.
		if (!self.body_collides(self.cam_x + self.vel_x, self.cam_y, self.cam_z)) {
			self.cam_x += self.vel_x;
		}
		if (!self.body_collides(self.cam_x, self.cam_y, self.cam_z + self.vel_z)) {
			self.cam_z += self.vel_z;
		}
		self.vel_x *= damp;
		self.vel_z *= damp;

		// ── Gravity & vertical collision ─────────────────────────────────
		// Record feet position BEFORE moving so the candidate filter uses
		// pre-move height; this prevents tunneling when vel_y exceeds 0.02.
		float feet_prev = self.cam_y - 1.6f;

		// Apply gravity each tick, clamp terminal fall velocity, then move.
		self.vel_y -= 0.03f;
		if (self.vel_y < -0.5f) self.vel_y = -0.5f;
		self.cam_y += self.vel_y;

		// Ground collision: scan blocks array for the highest active block
		// whose (x, z) matches the player column (rounded).  A block at
		// integer (bx, by, bz) occupies [bx-0.5, bx+0.5] in x/z and its
		// top surface is at by + 0.5.  Feet are at cam_y - 1.6.
		// Candidate surfaces must be at or below the PRE-MOVE feet position
		// (with a small tolerance) so a surface the player passed through this
		// tick is still detected even when vel_y is large.
		int col_x = (int)math::round(self.cam_x);
		int col_z = (int)math::round(self.cam_z);
		float feet_y = self.cam_y - 1.6f;
		float best_surface = -1000.0f;
		bool found_ground = false;
		for (int gi = 0; gi < self.block_count; gi++) {
			if (!self.blocks[gi].active) continue;
			if (self.blocks[gi].x != col_x) continue;
			if (self.blocks[gi].z != col_z) continue;
			float surface = (float)self.blocks[gi].y + 0.5f;
			// Reject surfaces the player was already below before this tick
			// (avoids snapping up through ceilings).
			if (surface > feet_prev + 0.02f) continue;
			if (surface > best_surface) {
				best_surface = surface;
				found_ground = true;
			}
		}
		// Only snap to ground when falling or standing (not while jumping up).
		if (found_ground && self.vel_y <= 0.0f && feet_y <= best_surface + 0.001f) {
			// Snap feet to surface, zero vertical velocity, mark grounded.
			self.cam_y = best_surface + 1.6f;
			self.vel_y = 0.0f;
			self.grounded = true;
		} else {
			self.grounded = false;
			// Death plane: falling below the world respawns the player at the
			// fixed spawn point (full position reset, not just height).
			if (self.cam_y < -20.0f) {
				self.cam_x = 0;
				self.cam_z = -12;
				self.cam_y = (float)(terrain_height(0, -12)) + 0.5f + 1.6f + 0.5f;
				self.vel_x = 0.0f;
				self.vel_y = 0.0f;
				self.vel_z = 0.0f;
				self.yaw   = 0;
				self.pitch = 0;
			}
		}

		// Angular velocity for arrow-key turning, damped a bit tighter.
		self.yaw += self.vel_yaw;
		self.vel_yaw *= 0.75f;

		// Sliding-window world regen: recenter only once the player has
		// strayed more than 4 cells from the last generation center, so
		// this doesn't fire (and re-run the O(n) generation + O(n²) face
		// collection) every single tick while walking.
		int cur_cx = (int)math::round(self.cam_x);
		int cur_cz = (int)math::round(self.cam_z);
		int dcx = cur_cx - self.world_cx;
		int dcz = cur_cz - self.world_cz;
		if (dcx > 4 || dcx < -4 || dcz > 4 || dcz < -4) {
			self.regen_world();
			self.world_dirty = true;
		}

		return milktea::tick();
	}
	return null;
}

// raycast_block marches a ray from the camera eye along the look direction,
// stepping in increments of 0.05 up to 4.5 units. At each step it checks which
// integer cell the ray point occupies and, on encountering an active block,
// returns the block index. The last empty cell visited before the hit is written
// through prev_x/prev_y/prev_z (for block placement). Returns -1 on no hit.
//
// Ray direction: fwd = (sin(yaw)*cos(pitch), sin(pitch), cos(yaw)*cos(pitch)),
// matching the convention used throughout rendering and the old mine_block. ✓
fn int Minecraft.raycast_block(Minecraft* self, int* prev_x, int* prev_y, int* prev_z) {
	float fwd_x = (float)math::sin(self.yaw) * (float)math::cos(self.pitch);
	float fwd_y = (float)math::sin(self.pitch);
	float fwd_z = (float)math::cos(self.yaw) * (float)math::cos(self.pitch);

	// Track the last empty cell visited — placement goes here on a hit.
	int last_cx = (int)math::round(self.cam_x);
	int last_cy = (int)math::round(self.cam_y);
	int last_cz = (int)math::round(self.cam_z);

	// Track the previous step's cell so we skip duplicate lookups when the ray
	// hasn't crossed a cell boundary yet. Initialised to a cell that differs from
	// the start so step 0 always runs.
	int cur_cx = last_cx - 1;
	int cur_cy = last_cy;
	int cur_cz = last_cz;

	for (int step = 0; step <= 90; step++) {
		float t = (float)step * 0.05f;
		float px = self.cam_x + fwd_x * t;
		float py = self.cam_y + fwd_y * t;
		float pz = self.cam_z + fwd_z * t;

		int cx = (int)math::round(px);
		int cy = (int)math::round(py);
		int cz = (int)math::round(pz);

		// Only act when the ray crosses into a new cell.
		if (cx == cur_cx && cy == cur_cy && cz == cur_cz) continue;
		cur_cx = cx;
		cur_cy = cy;
		cur_cz = cz;

		// Scan blocks for an active occupant of this cell.
		for (int i = 0; i < self.block_count; i++) {
			if (!self.blocks[i].active) continue;
			if (self.blocks[i].x == cx && self.blocks[i].y == cy && self.blocks[i].z == cz) {
				// Report the last empty cell and the hit block index.
				*prev_x = last_cx;
				*prev_y = last_cy;
				*prev_z = last_cz;
				return i;
			}
		}

		// Cell is empty — record it as the candidate placement position.
		last_cx = cx;
		last_cy = cy;
		last_cz = cz;
	}
	return -1;
}

// mine_block fires a precise ray from the camera eye along the look direction
// and deactivates the first block it hits within 4.5 units.
fn void Minecraft.mine_block(Minecraft* self) {
	int prev_x, prev_y, prev_z;
	int target = self.raycast_block(&prev_x, &prev_y, &prev_z);
	if (target != -1) {
		int bx = self.blocks[target].x;
		int by = self.blocks[target].y;
		int bz = self.blocks[target].z;
		self.blocks[target].active = false;
		self.world_dirty = true;

		// If the mined block was itself player-placed, just drop it from the
		// placed list — it never needs to be recorded as "mined" since
		// regen_world only re-adds it if it's still in placed_blocks.
		bool was_placed = false;
		for (int i = 0; i < self.placed_count; i++) {
			if (self.placed_blocks[i][0] == bx && self.placed_blocks[i][1] == by && self.placed_blocks[i][2] == bz) {
				// Swap-remove
				self.placed_blocks[i] = self.placed_blocks[self.placed_count - 1];
				self.placed_count--;
				was_placed = true;
				break;
			}
		}

		if (!was_placed && self.mined_count < 512) {
			self.mined_cells[self.mined_count][0] = bx;
			self.mined_cells[self.mined_count][1] = by;
			self.mined_cells[self.mined_count][2] = bz;
			self.mined_count++;
		}
	}
}

// place_block fires a precise ray from the camera eye and places a STONE block
// in the last empty cell the ray passed through before hitting a block, i.e. on
// the face of the targeted block that faces the camera. Refuses to place if the
// cell is already occupied or if it overlaps the player's body.
fn void Minecraft.place_block(Minecraft* self) {
	if (self.block_count >= MAX_BLOCKS) return;

	int prev_x, prev_y, prev_z;
	int target = self.raycast_block(&prev_x, &prev_y, &prev_z);
	if (target == -1) return;

	int px = prev_x;
	int py = prev_y;
	int pz = prev_z;

	// Don't place into an already-occupied cell.
	for (int i = 0; i < self.block_count; i++) {
		if (!self.blocks[i].active) continue;
		if (self.blocks[i].x == px && self.blocks[i].y == py && self.blocks[i].z == pz) return;
	}

	// Don't place a block inside the player's body.
	// Feet are at cam_y - 1.6; the body occupies the two cells round(feet) and
	// round(head ≈ cam_y), at the player's (x,z) column.
	int col_x  = (int)math::round(self.cam_x);
	int col_z  = (int)math::round(self.cam_z);
	int feet_y = (int)math::round(self.cam_y - 1.6f);
	int head_y = (int)math::round(self.cam_y);
	if (px == col_x && pz == col_z && (py == feet_y || py == head_y)) return;

	// Refuse placement if the persistence list is full.
	if (self.placed_count >= 512) return;

	// Placed blocks are always stone.
	self.add_block_typed(px, py, pz, BlockType.STONE);
	self.placed_blocks[self.placed_count][0] = px;
	self.placed_blocks[self.placed_count][1] = py;
	self.placed_blocks[self.placed_count][2] = pz;
	self.placed_blocks[self.placed_count][3] = (int)BlockType.STONE;
	self.placed_count++;
	self.world_dirty = true;
}

fn void Minecraft.collect_faces(Minecraft* self) {
	self.face_count = 0;

	for (int i = 0; i < self.block_count; i++) {
		if (!self.blocks[i].active) continue;
		Block* b = &self.blocks[i];

		bool has_px = false;
		bool has_nx = false;
		bool has_py = false;
		bool has_ny = false;
		bool has_pz = false;
		bool has_nz = false;

		for (int j = 0; j < self.block_count; j++) {
			if (i == j || !self.blocks[j].active) continue;
			Block* n = &self.blocks[j];
			if (n.x == b.x + 1 && n.y == b.y && n.z == b.z) has_px = true;
			if (n.x == b.x - 1 && n.y == b.y && n.z == b.z) has_nx = true;
			if (n.x == b.x && n.y == b.y + 1 && n.z == b.z) has_py = true;
			if (n.x == b.x && n.y == b.y - 1 && n.z == b.z) has_ny = true;
			if (n.x == b.x && n.y == b.y && n.z == b.z + 1) has_pz = true;
			if (n.x == b.x && n.y == b.y && n.z == b.z - 1) has_nz = true;
		}

		float h = 0.5f;
		if (!has_px) self.push_face(b, vec3(0.5, 0, 0),  vec3(1, 0, 0),  vec3(0, 0, h), vec3(0, h, 0), 0);
		if (!has_nx) self.push_face(b, vec3(-0.5, 0, 0), vec3(-1, 0, 0), vec3(0, 0, h), vec3(0, h, 0), 1);
		if (!has_py) self.push_face(b, vec3(0, 0.5, 0),  vec3(0, 1, 0),  vec3(h, 0, 0), vec3(0, 0, h), 2);
		if (!has_ny) self.push_face(b, vec3(0, -0.5, 0), vec3(0, -1, 0), vec3(h, 0, 0), vec3(0, 0, h), 3);
		if (!has_pz) self.push_face(b, vec3(0, 0, 0.5),  vec3(0, 0, 1),  vec3(h, 0, 0), vec3(0, h, 0), 4);
		if (!has_nz) self.push_face(b, vec3(0, 0, -0.5), vec3(0, 0, -1), vec3(h, 0, 0), vec3(0, h, 0), 5);
	}
}

fn void Minecraft.push_face(Minecraft* self, Block* b, Vec3 rel_pos, Vec3 normal, Vec3 tu, Vec3 tv, int face_idx) {
	if (self.face_count >= MAX_BLOCKS * 6) return;
	char r, g, b_col;
	base_color_for_face(b.btype, face_idx, &r, &g, &b_col);
	self.faces[self.face_count++] = {
		.pos = vec3((float)b.x + rel_pos.x, (float)b.y + rel_pos.y, (float)b.z + rel_pos.z),
		.normal = normal,
		.tan_u = tu,
		.tan_v = tv,
		.r = r,
		.g = g,
		.b = b_col,
		.bx = b.x,
		.by = b.y,
		.bz = b.z,
		.face_idx = face_idx,
		.btype = b.btype,
	};
}

// tex_hash returns a cheap 0-255 integer hash of the given inputs for texel
// brightness variation. Uses a Knuth-style multiplicative mix.
macro int tex_hash(int a, int b, int c, int d, int e, int f) {
	int h = a * 1664525 + b * 22695477 + c * 1013904223
	      + d * 214013  + e * 6364136  + f * 1664525;
	h ^= (h >> 16);
	h &= 0xFF;
	return h;
}

fn milktea::View Minecraft.view(Minecraft* self) @dynamic {
	// Only rebuild the face list when the world has changed — the O(n²)
	// neighbor scan is cheap enough for ~260 blocks, but there is no point
	// doing it 30× per second when nothing moved.
	if (self.world_dirty) {
		self.collect_faces();
		self.world_dirty = false;
	}

	int w     = self.width;
	int h     = self.height;
	int ph    = h * 2;
	sz ptotal = (sz)(w * ph);

	float fov = 45.0f;
	float cx  = (float)w / 2.0f;
	float cy  = (float)ph / 2.0f;

	for (int ty = 0; ty < ph; ty++) {
		float sky_factor = (float)ty / (float)ph;
		float horizon = cy + (float)math::sin(self.pitch) * fov * 2.0f;

		for (int tx = 0; tx < w; tx++) {
			sz idx = (sz)(ty * w + tx);
			self.depth[idx] = 1000.0f;
			if ((float)ty < horizon) {
				// Sky gradient: light blue fading slightly toward the horizon
				self.pixels[idx] = (Pixel) { (char)(100 + 50 * sky_factor), (char)(150 + 50 * sky_factor), (char)255 };
			} else {
				// Water/dark ground below the horizon
				self.pixels[idx] = (Pixel) { 20, 40, 80 };
			}
		}
	}

	// Camera rotation matrices.
	// Convention: forward F = (sin yaw, 0, cos yaw), right R = (cos yaw, 0, -sin yaw).
	// With cos_yaw=cos(yaw), sin_yaw=sin(yaw):
	//   rx = cos_yaw*vx - sin_yaw*vz  = dot(v, R.xz component)
	//   rz = sin_yaw*vx + cos_yaw*vz  = dot(v, F.xz component)
	// Verified: block straight ahead (along F) maps to rx≈0, rz≈dist. ✓
	// Verified: block to the right (along R) maps to rx>0. ✓
	float cos_yaw   = (float)math::cos(self.yaw);
	float sin_yaw   = (float)math::sin(self.yaw);

	// Pitch rotation: standard right-hand rotation around X axis.
	// ry = cos_pitch*vy - sin_pitch*rz1;  rz = sin_pitch*vy + cos_pitch*rz1
	// (equivalent to the old double-negated form, made explicit to avoid confusion)
	float cos_pitch = (float)math::cos(self.pitch);
	float sin_pitch = (float)math::sin(self.pitch);

	float light_x =  0.577f;
	float light_y =  0.577f;
	float light_z = -0.577f;

	// Sky/horizon color for distance fog blending
	float sky_r = 175.0f;
	float sky_g = 210.0f;
	float sky_b = 255.0f;

	for (int i = 0; i < self.face_count; i++) {
		BlockFace* f = &self.faces[i];

		// Transform face center into camera space
		float vx = f.pos.x - self.cam_x;
		float vy = f.pos.y - self.cam_y;
		float vz = f.pos.z - self.cam_z;

		float rx1 =  cos_yaw * vx - sin_yaw * vz;
		float rz1 =  sin_yaw * vx + cos_yaw * vz;
		float ry  =  cos_pitch * vy - sin_pitch * rz1;
		float rz  =  sin_pitch * vy + cos_pitch * rz1;

		// Rotate normal into camera space for back-face culling
		float nx1 = cos_yaw * f.normal.x - sin_yaw * f.normal.z;
		float ny1 = f.normal.y;
		float nz1 = sin_yaw * f.normal.x + cos_yaw * f.normal.z;

		float n_ry =  cos_pitch * ny1 - sin_pitch * nz1;
		float n_rz =  sin_pitch * ny1 + cos_pitch * nz1;

		// Cull faces pointing away from the camera in camera space
		if (n_rz > 0.0f) continue;

		// Rotate half-tangent vectors into camera space (same rotation as above)
		Vec3 tu     =  f.tan_u;
		float tux1  =  cos_yaw * tu.x - sin_yaw * tu.z;
		float tuz1  =  sin_yaw * tu.x + cos_yaw * tu.z;
		float tu_rx =  tux1;
		float tu_ry =  cos_pitch * tu.y - sin_pitch * tuz1;
		float tu_rz =  sin_pitch * tu.y + cos_pitch * tuz1;
		tu = { tu_rx, tu_ry, tu_rz };

		Vec3 tv     =  f.tan_v;
		float tvx1  =  cos_yaw * tv.x - sin_yaw * tv.z;
		float tvz1  =  sin_yaw * tv.x + cos_yaw * tv.z;
		float tv_rx =  tvx1;
		float tv_ry =  cos_pitch * tv.y - sin_pitch * tvz1;
		float tv_rz =  sin_pitch * tv.y + cos_pitch * tvz1;
		tv = { tv_rx, tv_ry, tv_rz };

		// Project all four corners to screen space to find bbox.
		// cu/cv are ±1 in tangent coordinates — each corner is center ± tan_u ± tan_v.
		float[4] cu  = { -1, -1, 1, 1 };
		float[4] cv  = { -1,  1,-1, 1 };
		float min_sx =  1e9f;
		float max_sx = -1e9f;
		float min_sy =  1e9f;
		float max_sy = -1e9f;
		int valid_corners = 0;

		for (int j = 0; j < 4; j++) {
			float px3 = rx1 + cu[j] * tu.x + cv[j] * tv.x;
			float py3 = ry  + cu[j] * tu.y + cv[j] * tv.y;
			float pz3 = rz  + cu[j] * tu.z + cv[j] * tv.z;
			if (pz3 < 0.1f) continue;
			valid_corners++;
			float sc  = fov / pz3;
			float csx =  px3 * sc * 2.0f + cx;
			float csy = -py3 * sc * 2.0f + cy;
			if (csx < min_sx) min_sx = csx;
			if (csx > max_sx) max_sx = csx;
			if (csy < min_sy) min_sy = csy;
			if (csy > max_sy) max_sy = csy;
		}

		// If no corners are in front of the near plane, skip the face entirely.
		// If some were behind, use the full screen as bbox so the visible part
		// still rasterizes (the intersection test will handle the rest).
		if (valid_corners == 0) continue;
		int x0;
		int x1;
		int y0;
		int y1;
		if (valid_corners < 4) {
			// Partially behind the near plane — clamp to full screen.
			x0 = 0;
			x1 = w - 1;
			y0 = 0;
			y1 = ph - 1;
		} else {
			x0 = (int)min_sx;
			x1 = (int)max_sx;
			y0 = (int)min_sy;
			y1 = (int)max_sy;
		}

		// Lighting in world space (before camera rotation): diffuse + ambient.
		float diff = f.normal.x * light_x + f.normal.y * light_y + f.normal.z * light_z;
		if (diff < 0.0f) diff = 0.0f;
		float brightness = 0.25f + 0.75f * diff;

		// Precompute dot(TU,TU) and dot(TV,TV) for the tangent normalisation
		// done inside the per-pixel loop — they are constant across the face.
		float dot_tu_tu = tu.x*tu.x + tu.y*tu.y + tu.z*tu.z;
		float dot_tv_tv = tv.x*tv.x + tv.y*tv.y + tv.z*tv.z;

		// Rotated normal (camera-space) components used for the plane equation
		// dot(P0, N) where P0 = (rx1, ry, rz) is the face center in cam space.
		float nx_r = nx1; // already computed above (yaw-rotated only)
		// Full camera-space normal: (nx1, n_ry, n_rz)
		float dot_p0n = rx1 * nx_r + ry * n_ry + rz * n_rz;

		// Per-pixel ray-plane intersection inside the bbox.
		// Ray direction in camera space for pixel (px,py):
		//   D = ((px-cx)/(2*fov),  -(py-cy)/(2*fov),  1)
		// This inverts the projection formula: csx = px3*fov/pz3*2 + cx
		for (int py = y0; py <= y1; py++) {
			if (py < 0 || py >= ph) continue;
			float dy = -(float)(py - (int)cy) / (2.0f * fov);
			for (int px = x0; px <= x1; px++) {
				if (px < 0 || px >= w) continue;
				float dx = (float)(px - (int)cx) / (2.0f * fov);
				// dz = 1.0 (implicit)

				// dot(D, N) with dz=1
				float dot_dn = dx * nx_r + dy * n_ry + n_rz;
				// Skip rays nearly parallel to the plane (|dot| < epsilon)
				if (dot_dn > -0.0001f && dot_dn < 0.0001f) continue;

				// t = dot(P0,N) / dot(D,N)
				float t = dot_p0n / dot_dn;
				if (t < 0.1f) continue; // behind near plane

				// Hit point H = t * D
				float hx = t * dx;
				float hy = t * dy;
				float hz = t; // hz = t * 1.0

				// Local coordinates relative to face center
				float lx = hx - rx1;
				float ly = hy - ry;
				float lz = hz - rz;

				// Tangent-space coordinates: u,v in [-1,1] for inside the face
				float u = (lx*tu.x + ly*tu.y + lz*tu.z) / dot_tu_tu;
				float v = (lx*tv.x + ly*tv.y + lz*tv.z) / dot_tv_tv;

				// Face spans [-1,1] in both tangent directions
				if (u < -1.0f || u > 1.0f || v < -1.0f || v > 1.0f) continue;

				// Per-pixel depth test with H.z (actual intersection depth)
				sz idx = (sz)(py * w + px);
				if (hz >= self.depth[idx]) continue;
				self.depth[idx] = hz;

				// ── Procedural texture ────────────────────────────────────────
				// Quantize u,v into a 4x4 texel grid per face (texels 0-3 each axis).
				int tu_cell = (int)((u + 1.0f) * 2.0f); // 0..3
				int tv_cell = (int)((v + 1.0f) * 2.0f);
				if (tu_cell > 3) tu_cell = 3;
				if (tv_cell > 3) tv_cell = 3;

				int hash = tex_hash(f.bx, f.by, f.bz, f.face_idx, tu_cell, tv_cell);
				// jitter in range [-12%, +12%] relative to base: hash 0-255 → -0.12..+0.12
				float jitter = ((float)hash / 255.0f - 0.5f) * 0.24f;

				// Base color for this face type; may be overridden per-pixel below.
				char base_r = f.r;
				char base_g = f.g;
				char base_b = f.b;

				// Per-block-type texture details at pixel level:
				switch (f.btype) {
					case BlockType.GRASS:
						// Side faces: green strip on the top edge (v near 1.0 = top of face)
						if (f.face_idx != 2 && f.face_idx != 3) {
							// v ranges -1 (bottom) to +1 (top); green strip above 0.6
							if (v > 0.6f) {
								base_r = 80; base_g = 160; base_b = 50;
							}
						}
					case BlockType.WOOD:
						// Side faces: vertical stripe variation — hash on u cell only
						if (f.face_idx != 2 && f.face_idx != 3) {
							int stripe_hash = tex_hash(f.bx, f.by, f.bz, f.face_idx, tu_cell, 0);
							float stripe_jitter = ((float)stripe_hash / 255.0f - 0.5f) * 0.18f;
							// Override jitter for stripe effect; r/g/b unchanged
							jitter = stripe_jitter;
						}
					case BlockType.LEAF:
						// Punch occasional darker holes (transparency effect via darkening)
						if (hash < 30) {
							// Dark hole — strongly reduce brightness
							jitter = -0.5f;
						}
					default: break;
				}

				// Apply brightness (diffuse) and texel jitter
				float lit_r = (float)base_r * brightness * (1.0f + jitter);
				float lit_g = (float)base_g * brightness * (1.0f + jitter);
				float lit_b = (float)base_b * brightness * (1.0f + jitter);

				// ── Distance fog ─────────────────────────────────────────────
				// Blend toward sky color starting at t=8, fully fogged at t=38.
				float fog_t = hz;
				float fog = (fog_t - 8.0f) / 30.0f;
				if (fog < 0.0f) fog = 0.0f;
				if (fog > 0.85f) fog = 0.85f;

				float final_r = lit_r * (1.0f - fog) + sky_r * fog;
				float final_g = lit_g * (1.0f - fog) + sky_g * fog;
				float final_b = lit_b * (1.0f - fog) + sky_b * fog;

				// Clamp to [0,255]
				if (final_r < 0.0f) final_r = 0.0f; if (final_r > 255.0f) final_r = 255.0f;
				if (final_g < 0.0f) final_g = 0.0f; if (final_g > 255.0f) final_g = 255.0f;
				if (final_b < 0.0f) final_b = 0.0f; if (final_b > 255.0f) final_b = 255.0f;

				self.pixels[idx] = (Pixel) {
					(char)(int)final_r,
					(char)(int)final_g,
					(char)(int)final_b
				};
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

	// Crosshair at center
	self.cells[(h / 2) * w + (w / 2)] = xray::new_cell("+", 1, xray::default_style()
		.set_fg(xray::color_rgb(255, 255, 255)));

	// Pickaxe HUD
	if (self.swing_frame > 0) {
		int px = w - 15 - (10 - self.swing_frame);
		int py = h - 5 - (10 - self.swing_frame);
		if (px >= 0 && px < w && py >= 0 && py < h) {
			self.cells[py * w + px] = xray::new_cell("/", 1, xray::default_style()
				.set_fg(xray::color_rgb(200, 200, 200)));
		}
	} else {
		self.cells[(h - 2) * w + (w - 10)] = xray::new_cell("\\", 1, xray::default_style()
			.set_fg(xray::color_rgb(150, 150, 150)));
	}

	// HUD status line — rendered directly into the cell grid, bottom-left
	// Kept subtle (gray) so it doesn't compete with the 3D view
	xray::Style hud_style = xray::default_style().set_fg(xray::color_rgb(160, 160, 160));
	String hud_label = "blocks:";
	for (usz ci = 0; ci < hud_label.len && (int)ci < w; ci++) {
		char ch = hud_label[ci];
		char[2] buf;
		buf[0] = ch;
		buf[1] = 0;
		self.cells[(h - 1) * w + (int)ci] = xray::new_cell((String)buf[:1], 1, hud_style);
	}
	// Block count as digits
	int bcount = 0;
	for (int bi = 0; bi < self.block_count; bi++) {
		if (self.blocks[bi].active) bcount++;
	}
	int digit_x = 8;
	int tmp = bcount;
	if (tmp == 0) {
		if (digit_x < w) {
			self.cells[(h - 1) * w + digit_x] = xray::new_cell("0", 1, hud_style);
		}
		digit_x++;
	} else {
		// print digits left-to-right: find number of digits first
		int digits = 0;
		int ttmp = tmp;
		while (ttmp > 0) { ttmp /= 10; digits++; }
		int start_x = digit_x;
		digit_x += digits - 1;
		while (tmp > 0 && digit_x < w) {
			int d = tmp % 10;
			tmp /= 10;
			char[2] dbuf;
			dbuf[0] = (char)('0' + d);
			dbuf[1] = 0;
			self.cells[(h - 1) * w + digit_x] = xray::new_cell((String)dbuf[:1], 1, hud_style);
			digit_x--;
		}
		digit_x = start_x + digits;
	}
	// Rest of hint text
	String hint = "  wasd move  space jump  f/click mine  e place  q quit";
	int hint_x = digit_x + 1;
	for (usz ci = 0; ci < hint.len && hint_x + (int)ci < w; ci++) {
		char ch = hint[ci];
		char[2] buf;
		buf[0] = ch;
		buf[1] = 0;
		self.cells[(h - 1) * w + hint_x + (int)ci] = xray::new_cell((String)buf[:1], 1, hud_style);
	}

	// set_mouse_mode(ALL_MOTION) lets the runtime manage mouse tracking, so
	// free-look works by moving the mouse without holding any button.
	return milktea::new_alt_cell_view(self.cells, (sz)w, (sz)h)
		.set_mouse_mode(milktea::MouseMode.MOUSE_MODE_ALL_MOTION)
		.set_report_key_events(true)
		.set_mouse_pixels(true);
}

fn int main(String[] args) {
	Minecraft* app = mem::new(Minecraft);
	if (catch err = milktea::@run_program(app)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
