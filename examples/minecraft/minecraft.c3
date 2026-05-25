module minecraft;

import tea;
import xray;
import lipgloss;
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

struct Block {
	int x, y, z;
	char r, g, b;
	bool active;
}

struct Pixel {
	char r, g, b;
}

const int MAX_BLOCKS = 1024;
const int MAX_VOXELS = 32768; // Increased from 16384

struct BlockFace {
	Vec3 pos;
	Vec3 normal;
	Vec3 tan_u;
	Vec3 tan_v;
	char r, g, b;
}

struct Minecraft {
	Block[MAX_BLOCKS] blocks;
	int block_count;

	BlockFace[MAX_BLOCKS * 6] faces;
	int face_count;

	// Camera
	float cam_x, cam_y, cam_z;
	float yaw, pitch;

	// Viewport
	int width, height;
	int frame;

	// Rendering buffers
	xray::Cell[] cells;
	Pixel[] pixels;
	float[] depth;
	Pixel[] prev_pixels;

	// Game state
	int tick_count;
	int swing_frame;

	// Mouse state
	int mouse_x, mouse_y;
	bool mouse_init;

	// Input state
	int key_w, key_s, key_a, key_d, key_left, key_right;
}

// ── World Generation ─────────────────────────────────────────────────────────

fn void Minecraft.generate_island(Minecraft* self) {
	self.block_count = 0;
	// Ground (Sand/Grass)
	for (int x = -5; x <= 5; x++) {
		for (int z = -5; z <= 5; z++) {
			float d = (float)math::sqrt((float)(x * x + z * z));
			if (d > 5.5f) continue;

			// Grass top
			self.add_block(x, 0, z, 100, 180, 50);
			// Dirt below
			self.add_block(x, -1, z, 100, 70, 30);
		}
	}
	// A tree
	for (int y = 1; y <= 3; y++) self.add_block(0, y, 0, 120, 90, 60); // Trunk
	for (int ox = -2; ox <= 2; ox++) {
		for (int oz = -2; oz <= 2; oz++) {
			for (int oy = 4; oy <= 5; oy++) {
				float d = (float)math::sqrt((float)(ox * ox + oz * oz));
				if (d > 2.2f) continue;
				self.add_block(ox, oy, oz, 40, 150, 40); // Leaves
			}
		}
	}
}

fn void Minecraft.add_block(Minecraft* self, int x, int y, int z, char r, char g, char b) {
	if (self.block_count >= MAX_BLOCKS) return;
	self.blocks[self.block_count++] = { x, y, z, r, g, b, true };
}

// ── Tea Methods ──────────────────────────────────────────────────────────────

fn tea::Cmd Minecraft.init(Minecraft* self) @dynamic {
	self.width = 80;
	self.height = 24;
	self.cam_x = 0;
	self.cam_y = 2.5f;
	self.cam_z = -12;
	self.yaw = 0;
	self.pitch = 0;
	self.mouse_init = false;
	self.generate_island();
	self.allocate_buffers();
	return tea::tick();
}

fn void Minecraft.allocate_buffers(Minecraft* self) {
	sz ptotal = (sz)(self.width * self.height * 2);
	self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.pixels = mem::new_array(Pixel, ptotal);
	self.prev_pixels = mem::new_array(Pixel, ptotal);
	self.depth = mem::new_array(float, ptotal);
}

fn tea::Cmd Minecraft.update(Minecraft* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		if (self.width == msg.window_size.width && self.height == msg.window_size.height) return null;
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		mem::free(self.cells.ptr);
		mem::free(self.pixels.ptr);
		mem::free(self.prev_pixels.ptr);
		mem::free(self.depth.ptr);
		self.allocate_buffers();
		return null;
	}

	if (msg.kind == tea::MsgKind.KEY) {
		tea::KeyMsg k = msg.key;
		if (k.code == tea::KeyCode.ESC || (k.code == tea::KeyCode.RUNE && k.rune == 'q')) return tea::quit();

		if (k.code == tea::KeyCode.RUNE) {
			switch (k.rune) {
				case 'w': self.key_w = self.tick_count;
				case 's': self.key_s = self.tick_count;
				case 'a': self.key_a = self.tick_count;
				case 'd': self.key_d = self.tick_count;
				case ' ':
					self.swing_frame = 10;
					self.mine_block();
			}
		}
		if (k.code == tea::KeyCode.LEFT) self.key_left = self.tick_count;
		if (k.code == tea::KeyCode.RIGHT) self.key_right = self.tick_count;
	}

	if (msg.kind == tea::MsgKind.MOUSE) {
		if (!self.mouse_init) {
			self.mouse_x = msg.mouse.col;
			self.mouse_y = msg.mouse.row;
			self.mouse_init = true;
		} else {
			if (msg.mouse.action == tea::MouseAction.MOUSE_MOTION) {
				int dx = msg.mouse.col - self.mouse_x;
				int dy = msg.mouse.row - self.mouse_y;
				self.yaw += (float)dx * 0.05f;
				self.pitch -= (float)dy * 0.05f;
				if (self.pitch > 1.4f) self.pitch = 1.4f;
				if (self.pitch < -1.4f) self.pitch = -1.4f;
				self.mouse_x = msg.mouse.col;
				self.mouse_y = msg.mouse.row;
			}
		}
		if (msg.mouse.action == tea::MouseAction.MOUSE_PRESS && msg.mouse.button == tea::MouseButton.MOUSE_LEFT) {
			self.swing_frame = 10;
			self.mine_block();
		}
	}

	if (msg.kind == tea::MsgKind.TICK) {
		self.tick_count++;
		self.frame++;
		if (self.swing_frame > 0) self.swing_frame--;

		float speed     = 0.25f;
		float rot_speed = 0.08f;
		int thresh      = self.tick_count - 2;

		if (self.key_w >= thresh) {
			self.cam_x += (float)math::sin(self.yaw) * speed;
			self.cam_z += (float)math::cos(self.yaw) * speed;
		}
		if (self.key_s >= thresh) {
			self.cam_x -= (float)math::sin(self.yaw) * speed;
			self.cam_z -= (float)math::cos(self.yaw) * speed;
		}
		if (self.key_a >= thresh) {
			self.cam_x -= (float)math::cos(self.yaw) * speed;
			self.cam_z += (float)math::sin(self.yaw) * speed;
		}
		if (self.key_d >= thresh) {
			self.cam_x += (float)math::cos(self.yaw) * speed;
			self.cam_z -= (float)math::sin(self.yaw) * speed;
		}
		if (self.key_left >= thresh) self.yaw -= rot_speed;
		if (self.key_right >= thresh) self.yaw += rot_speed;

		return tea::tick();
	}
	return null;
}

fn void Minecraft.mine_block(Minecraft* self) {
	float best_dist =  4.5f;
	int target      = -1;
	Vec3 cam_pos    =  { self.cam_x, self.cam_y, self.cam_z };
	float fwd_x     =  (float)math::sin(self.yaw) * (float)math::cos(self.pitch);
	float fwd_y     = -(float)math::sin(self.pitch);
	float fwd_z     =  (float)math::cos(self.yaw) * (float)math::cos(self.pitch);

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
	if (target != -1) self.blocks[target].active = false;
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
		// ±X faces



		if (!has_px) self.push_face(b, vec3(0.5, 0, 0), vec3(1, 0, 0), vec3(0, 0, h), vec3(0, h, 0));
		if (!has_nx) self.push_face(b, vec3(-0.5, 0, 0), vec3(-1, 0, 0), vec3(0, 0, h), vec3(0, h, 0));
		// ±Y faces
		if (!has_py) self.push_face(b, vec3(0, 0.5, 0), vec3(0, 1, 0), vec3(h, 0, 0), vec3(0, 0, h));
		if (!has_ny) self.push_face(b, vec3(0, -0.5, 0), vec3(0, -1, 0), vec3(h, 0, 0), vec3(0, 0, h));
		// ±Z faces
		if (!has_pz) self.push_face(b, vec3(0, 0, 0.5), vec3(0, 0, 1), vec3(h, 0, 0), vec3(0, h, 0));
		if (!has_nz) self.push_face(b, vec3(0, 0, -0.5), vec3(0, 0, -1), vec3(h, 0, 0), vec3(0, h, 0));
	}
}

fn void Minecraft.push_face(Minecraft* self, Block* b, Vec3 rel_pos, Vec3 normal, Vec3 tu, Vec3 tv) {
	if (self.face_count >= MAX_BLOCKS * 6) return;
	self.faces[self.face_count++] = {
		.pos = vec3((float)b.x + rel_pos.x, (float)b.y + rel_pos.y, (float)b.z + rel_pos.z),
		.normal = normal,
		.tan_u = tu,
		.tan_v = tv,
		.r = b.r,
		.g = b.g,
		.b = b.b
	};
}

fn tea::View Minecraft.view(Minecraft* self) @dynamic {
	self.collect_faces();

	int w     = self.width;
	int h     = self.height;
	int ph    = h * 2;
	sz ptotal = (sz)(w * ph);

	float fov = 45.0f;
	float cx  = (float)w / 2.0f;
	float cy  = (float)ph / 2.0f;

	for (int ty = 0; ty < ph; ty++) {
		float sky_factor = (float)ty / (float)ph;
		// Simple horizon line: above mid is sky, below is water/ground



		// Adjust based on pitch to keep horizon stable

		float horizon = cy + (float)math::sin(self.pitch) * fov * 2.0f;

		for (int tx = 0; tx < w; tx++) {
			sz idx = (sz)(ty * w + tx);
			self.depth[idx] = 1000.0f;
			if ((float)ty < horizon) {
				// Sky gradient: Light blue to slightly darker blue
				self.pixels[idx] = (Pixel) { (char)(100 + 50 * sky_factor), (char)(150 + 50 * sky_factor), (char)255 };
			} else {
				// Water/Dark ground
				self.pixels[idx] = (Pixel) { 20, 40, 80 };
			}
		}
	}

	float cos_yaw   = (float)math::cos(-self.yaw);
	float sin_yaw   = (float)math::sin(-self.yaw);
	float cos_pitch = (float)math::cos(-self.pitch);
	float sin_pitch = (float)math::sin(-self.pitch);

	float light_x =  0.577f;
	float light_y =  0.577f;
	float light_z = -0.577f;

	for (int i = 0; i < self.face_count; i++) {
		BlockFace* f = &self.faces[i];

		// Transform center
		float vx = f.pos.x - self.cam_x;
		float vy = f.pos.y - self.cam_y;
		float vz = f.pos.z - self.cam_z;

		float rx1 =  cos_yaw * vx - sin_yaw * vz;
		float rz1 =  sin_yaw * vx + cos_yaw * vz;
		float ry  =  cos_pitch * vy + sin_pitch * rz1;
		float rz  = -sin_pitch * vy + cos_pitch * rz1;

		// Normal rotation (Corrected: Yaw around Y, then Pitch around X)
		float nx1 = cos_yaw * f.normal.x - sin_yaw * f.normal.z;
		float ny1 = f.normal.y;
		float nz1 = sin_yaw * f.normal.x + cos_yaw * f.normal.z;

		float n_ry =  cos_pitch * ny1 + sin_pitch * nz1;
		float n_rz = -sin_pitch * ny1 + cos_pitch * nz1;

		// Cull back-faces (faces pointing away from camera in camera-space)
		if (n_rz > 0.0f) continue;

		// Tangent rotations
		Vec3 tu     =  f.tan_u;
		float tux1  =  cos_yaw * tu.x - sin_yaw * tu.z;
		float tuz1  =  sin_yaw * tu.x + cos_yaw * tu.z;
		float tu_rx =  tux1;
		float tu_ry =  cos_pitch * tu.y + sin_pitch * tuz1;
		float tu_rz = -sin_pitch * tu.y + cos_pitch * tuz1;
		tu = { tu_rx, tu_ry, tu_rz };

		Vec3 tv     =  f.tan_v;
		float tvx1  =  cos_yaw * tv.x - sin_yaw * tv.z;
		float tvz1  =  sin_yaw * tv.x + cos_yaw * tv.z;
		float tv_rx =  tvx1;
		float tv_ry =  cos_pitch * tv.y + sin_pitch * tvz1;
		float tv_rz = -sin_pitch * tv.y + cos_pitch * tvz1;
		tv = { tv_rx, tv_ry, tv_rz };

		// Project corners to find bounds
		float min_sx =  1e9f;
		float max_sx = -1e9f;
		float min_sy =  1e9f;
		float max_sy = -1e9f;
		float[4] cu  =  { -1, -1, 1, 1 };
		float[4] cv  =  { -1, 1, -1, 1 };
		for (int j = 0; j < 4; j++) {
			float px3 = rx1 + cu[j] * tu.x + cv[j] * tv.x;
			float py3 = ry + cu[j] * tu.y + cv[j] * tv.y;
			float pz3 = rz + cu[j] * tu.z + cv[j] * tv.z;
			if (pz3 < 0.1f) continue;
			float sc  =  fov / pz3;
			float csx =  px3 * sc * 2.0f + cx;
			float csy = -py3 * sc * 2.0f + cy;
			if (csx < min_sx) min_sx = csx;
			if (csx > max_sx) max_sx = csx;
			if (csy < min_sy) min_sy = csy;
			if (csy > max_sy) max_sy = csy;
		}

		int x0 = (int)min_sx;
		int x1 = (int)max_sx;
		int y0 = (int)min_sy;
		int y1 = (int)max_sy;

		// Correct Shading: Lighting in world space before camera rotation
		float diff = f.normal.x * light_x + f.normal.y * light_y + f.normal.z * light_z;
		if (diff < 0.0f) diff = 0.0f;
		float brightness = 0.25f + 0.75f * diff;
		Pixel col = {
			(char)((float)f.r * brightness),
			(char)((float)f.g * brightness),
			(char)((float)f.b * brightness)
		};

		for (int py = y0; py <= y1; py++) {
			if (py < 0 || py >= ph) continue;
			for (int px = x0; px <= x1; px++) {
				if (px < 0 || px >= w) continue;
				sz idx = (sz)(py * w + px);
				if (rz < self.depth[idx]) {
					self.depth[idx] = rz;
					self.pixels[idx] = col;
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

	// Crosshair
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

	return tea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

fn int main(String[] args) {
	Minecraft* app = mem::new(Minecraft);
	tea::enable_mouse();
	if (catch err = tea::@run_program(app)) {
		tea::disable_mouse();
		io::printfn("Error: %s", err);
		return 1;
	}
	tea::disable_mouse();
	return 0;
}