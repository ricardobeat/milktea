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

const int MAX_BLOCKS = 1024;
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
	// Angular velocity for arrow-key yaw (optional smooth turning).
	float vel_yaw;

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
	bool mouse_init;

	// Dirty flag: rebuild faces only when world changes
	bool world_dirty;
}

// ── World Generation ─────────────────────────────────────────────────────────

fn void Minecraft.generate_island(Minecraft* self) {
	self.block_count = 0;
	// Ground (Grass top layer, Dirt below)
	for (int x = -5; x <= 5; x++) {
		for (int z = -5; z <= 5; z++) {
			float d = (float)math::sqrt((float)(x * x + z * z));
			if (d > 5.5f) continue;

			// Grass top
			self.add_block_typed(x, 0, z, BlockType.GRASS);
			// Dirt below
			self.add_block_typed(x, -1, z, BlockType.DIRT);
		}
	}
	// A tree: wood trunk, leaf canopy
	for (int y = 1; y <= 3; y++) self.add_block_typed(0, y, 0, BlockType.WOOD);
	for (int ox = -2; ox <= 2; ox++) {
		for (int oz = -2; oz <= 2; oz++) {
			for (int oy = 4; oy <= 5; oy++) {
				float d = (float)math::sqrt((float)(ox * ox + oz * oz));
				if (d > 2.2f) continue;
				self.add_block_typed(ox, oy, oz, BlockType.LEAF);
			}
		}
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
	self.cam_y = 2.5f;
	self.cam_z = -12;
	self.yaw = 0;
	self.pitch = 0;
	self.vel_x = 0;
	self.vel_z = 0;
	self.vel_yaw = 0;
	self.mouse_init = false;
	self.world_dirty = true;
	self.generate_island();
	self.allocate_buffers();
	return milktea::tick();
}

fn void Minecraft.allocate_buffers(Minecraft* self) {
	sz ptotal = (sz)(self.width * self.height * 2);
	self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.pixels = mem::new_array(Pixel, ptotal);
	self.depth = mem::new_array(float, ptotal);
}

fn milktea::Cmd Minecraft.update(Minecraft* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		if (self.width == msg.window_size.width && self.height == msg.window_size.height) return null;
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		mem::free(self.cells.ptr);
		mem::free(self.pixels.ptr);
		mem::free(self.depth.ptr);
		self.allocate_buffers();
		return null;
	}

	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg k = msg.key;
		if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && k.rune == 'q')) return milktea::quit();

		// Movement: add impulse to velocity each keypress/repeat.
		// Convention: forward F = (sin yaw, 0, cos yaw), right R = (cos yaw, 0, -sin yaw).
		// Impulse tuned so steady-state speed (impulse / (1 - damp)) ≈ 0.25/tick.
		// impulse=0.05, damp=0.80 → 0.05/0.20 = 0.25/tick. ✓
		float impulse = 0.05f;
		if (k.code == milktea::KeyCode.RUNE) {
			switch (k.rune) {
				case 'w':
					self.vel_x += (float)math::sin(self.yaw) * impulse;
					self.vel_z += (float)math::cos(self.yaw) * impulse;
				case 's':
					self.vel_x -= (float)math::sin(self.yaw) * impulse;
					self.vel_z -= (float)math::cos(self.yaw) * impulse;
				case 'a':
					// Strafe left: -R = (-cos yaw, 0, +sin yaw)
					self.vel_x -= (float)math::cos(self.yaw) * impulse;
					self.vel_z += (float)math::sin(self.yaw) * impulse;
				case 'd':
					// Strafe right: +R = (+cos yaw, 0, -sin yaw)
					self.vel_x += (float)math::cos(self.yaw) * impulse;
					self.vel_z -= (float)math::sin(self.yaw) * impulse;
				case ' ':
					self.swing_frame = 10;
					self.mine_block();
				case 'e':
					// Place a stone block at the face adjacent to the targeted block
					self.place_block();
			}
		}
		// Arrow keys: angular velocity for smooth rotation.
		// damp=0.75 → steady state = 0.015/0.25 = 0.06 rad/tick.
		if (k.code == milktea::KeyCode.LEFT)  self.vel_yaw -= 0.015f;
		if (k.code == milktea::KeyCode.RIGHT) self.vel_yaw += 0.015f;
	}

	if (msg.kind == milktea::MsgKind.MOUSE) {
		if (!self.mouse_init) {
			self.mouse_x = msg.mouse.col;
			self.mouse_y = msg.mouse.row;
			self.mouse_init = true;
		} else {
			if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION) {
				int dx = msg.mouse.col - self.mouse_x;
				int dy = msg.mouse.row - self.mouse_y;
				// yaw += dx*sens: mouse-right (dx>0) increases yaw, turning right
				// because with F=(sin,cos), dF/dyaw = (cos,-sin) = R — consistent. ✓
				self.yaw += (float)dx * 0.05f;
				self.pitch -= (float)dy * 0.05f;
				if (self.pitch > 1.4f) self.pitch = 1.4f;
				if (self.pitch < -1.4f) self.pitch = -1.4f;
				self.mouse_x = msg.mouse.col;
				self.mouse_y = msg.mouse.row;
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

		// Integrate velocity and apply damping each tick so motion smoothly
		// accelerates on key-hold (via OS key-repeat) and decelerates on release.
		float damp = 0.80f;
		self.cam_x += self.vel_x;
		self.cam_z += self.vel_z;
		self.vel_x *= damp;
		self.vel_z *= damp;

		// Angular velocity for arrow-key turning, damped a bit tighter.
		self.yaw += self.vel_yaw;
		self.vel_yaw *= 0.75f;

		return milktea::tick();
	}
	return null;
}

fn void Minecraft.mine_block(Minecraft* self) {
	float best_dist = 4.5f;
	int target      = -1;
	Vec3 cam_pos    = { self.cam_x, self.cam_y, self.cam_z };
	// Forward ray: F = (sin yaw, 0, cos yaw) in horizontal plane, pitched up/down.
	// fwd_y = +sin(pitch): positive pitch means looking up, fwd_y > 0. ✓
	float fwd_x     = (float)math::sin(self.yaw) * (float)math::cos(self.pitch);
	float fwd_y     = (float)math::sin(self.pitch);
	float fwd_z     = (float)math::cos(self.yaw) * (float)math::cos(self.pitch);

	for (int i = 0; i < self.block_count; i++) {
		if (!self.blocks[i].active) continue;
		Vec3 bp = { (float)self.blocks[i].x, (float)self.blocks[i].y, (float)self.blocks[i].z };

		float dx  = bp.x - cam_pos.x;
		float dy  = bp.y - cam_pos.y;
		float dz  = bp.z - cam_pos.z;
		float dot = dx * fwd_x + dy * fwd_y + dz * fwd_z;
		if (dot < 0) continue;

		float d = (float)math::sqrt(Vec3.dist_sq(cam_pos, bp));
		if (d < best_dist) {
			best_dist = d;
			target = i;
		}
	}
	if (target != -1) {
		self.blocks[target].active = false;
		self.world_dirty = true;
	}
}

// place_block finds the block nearest to the targeting ray and places a new
// block on the face closest to the approach direction. The approach axis is
// determined by the largest component of (block_center - camera): whichever
// axis dominates tells us which face was hit, and we step one unit outward
// along that axis to get the placement cell.
fn void Minecraft.place_block(Minecraft* self) {
	if (self.block_count >= MAX_BLOCKS) return;

	float best_dist = 4.5f;
	int target      = -1;
	Vec3 cam_pos    = { self.cam_x, self.cam_y, self.cam_z };
	float fwd_x     = (float)math::sin(self.yaw) * (float)math::cos(self.pitch);
	float fwd_y     = (float)math::sin(self.pitch);
	float fwd_z     = (float)math::cos(self.yaw) * (float)math::cos(self.pitch);

	for (int i = 0; i < self.block_count; i++) {
		if (!self.blocks[i].active) continue;
		Vec3 bp = { (float)self.blocks[i].x, (float)self.blocks[i].y, (float)self.blocks[i].z };

		float dx  = bp.x - cam_pos.x;
		float dy  = bp.y - cam_pos.y;
		float dz  = bp.z - cam_pos.z;
		float dot = dx * fwd_x + dy * fwd_y + dz * fwd_z;
		if (dot < 0) continue;

		float d = (float)math::sqrt(Vec3.dist_sq(cam_pos, bp));
		if (d < best_dist) {
			best_dist = d;
			target = i;
		}
	}

	if (target == -1) return;

	// Determine the dominant approach axis by looking at which component of
	// (block_center - camera) is largest in magnitude. The placement cell is
	// one unit outward from that face (opposite approach direction).
	Block* tb = &self.blocks[target];
	float ax = (float)tb.x - cam_pos.x;
	float ay = (float)tb.y - cam_pos.y;
	float az = (float)tb.z - cam_pos.z;

	float abs_ax = ax < 0 ? -ax : ax;
	float abs_ay = ay < 0 ? -ay : ay;
	float abs_az = az < 0 ? -az : az;

	int nx = 0;
	int ny = 0;
	int nz = 0;
	// Step outward: approach came from the dominant axis direction,
	// so we place on the face that the camera is on — step toward the camera.
	if (abs_ax >= abs_ay && abs_ax >= abs_az) {
		nx = (ax > 0) ? -1 : 1;
	} else if (abs_ay >= abs_ax && abs_ay >= abs_az) {
		ny = (ay > 0) ? -1 : 1;
	} else {
		nz = (az > 0) ? -1 : 1;
	}

	int px = tb.x + nx;
	int py = tb.y + ny;
	int pz = tb.z + nz;

	// Only place if the target cell is unoccupied
	for (int i = 0; i < self.block_count; i++) {
		if (!self.blocks[i].active) continue;
		if (self.blocks[i].x == px && self.blocks[i].y == py && self.blocks[i].z == pz) return;
	}

	// Placed blocks are always stone
	self.add_block_typed(px, py, pz, BlockType.STONE);
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
	String hint = "  wasd move  mouse look  space/click mine  e place  q quit";
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
		.set_mouse_mode(milktea::MouseMode.MOUSE_MODE_ALL_MOTION);
}

fn int main(String[] args) {
	Minecraft* app = mem::new(Minecraft);
	if (catch err = milktea::@run_program(app)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
