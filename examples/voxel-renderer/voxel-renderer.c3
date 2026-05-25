module voxel_renderer;

import tea;
import xray;
import std::io;
import std::math;

struct Vec3 {
	float x;
	float y;
	float z;
}

struct Voxel {
	Vec3 pos;
	Vec3 normal;
	Vec3 tan_u; // half-extent along first tangent axis
	Vec3 tan_v; // half-extent along second tangent axis
}

struct Pixel {
	char r;
	char g;
	char b;
}

struct VoxelModel {
	Voxel[8192] voxels;
	int voxel_count;
	float rotation_x;
	float rotation_y;
	float rotation_z;
	int width;
	int height;
	int frame;
	xray::Cell[] cells; // w * h terminal cells (output)
	Pixel[] pixels; // w * h*2 pixel colors (double-height render buffer)
	float[] depth; // w * h*2 depth buffer
}

fn Vec3 vec3(float x, float y, float z) => (Vec3) { x, y, z };

fn Vec3 Vec3.rotate_x(&self, float angle) {
	float c = (float)math::cos(angle);
	float s = (float)math::sin(angle);
	return vec3(self.x, self.y * c - self.z * s, self.y * s + self.z * c);
}

fn Vec3 Vec3.rotate_y(&self, float angle) {
	float c = (float)math::cos(angle);
	float s = (float)math::sin(angle);
	return vec3(self.x * c + self.z * s, self.y, -self.x * s + self.z * c);
}

fn Vec3 Vec3.rotate_z(&self, float angle) {
	float c = (float)math::cos(angle);
	float s = (float)math::sin(angle);
	return vec3(self.x * c - self.y * s, self.x * s + self.y * c, self.z);
}

fn tea::Cmd VoxelModel.init(VoxelModel* self) @dynamic {
	self.width = 80;
	self.height = 24;
	self.frame = 0;
	self.voxel_count = 0;
	self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
	self.depth = mem::new_array(float, (sz)(self.width * self.height * 2));
	create_voxels(self);
	tea::Cmd[] cmds = { tea::tick() };
	return tea::batch(cmds);
}

const int GRID_W = 25;
const int GRID_H = 5;

// Each row is 25 chars: █ = filled, space = empty
const String[5] ROWS = {
	"████████ ███████  █████  ",
	"   ██    ██      ██   ██ ",
	"   ██    █████   ███████ ",
	"   ██    ██      ██   ██ ",
	"   ██    ███████ ██   ██ ",
};

fn bool grid_set(int x, int y) {
	if (x < 0 || x >= GRID_W || y < 0 || y >= GRID_H) return false;
	// each █ is 3 UTF-8 bytes (0xe2 0x96 0x88), space is 1 byte
	// scan the row counting logical columns
	String row = ROWS[y];
	int col    = 0;
	sz i       = 0;
	while (i < row.len && col <= x) {
		char b = row[i];
		if (b == ' ') {
			if (col == x) return false;
			col++;
			i++;
		} else {
			// █ = 3 bytes
			if (col == x) return true;
			col++;
			i += 3;
		}
	}
	return false;
}

// u, v are the two half-extent vectors spanning the face quad
fn void push_face(VoxelModel* self, float x, float y, float z, Vec3 normal, Vec3 u, Vec3 v) {
	if (self.voxel_count >= 8192) return;
	self.voxels[self.voxel_count++] = { .pos = vec3(x, y, z), .normal = normal, .tan_u = u, .tan_v = v, };
}

const int DEPTH = 3;

fn bool voxel_set(int x, int y, int z) {
	if (z < 0 || z >= DEPTH) return false;
	return grid_set(x, y);
}

fn void create_voxels(VoxelModel* self) {
	float ox = -(float)GRID_W / 2.0f;
	float oy =  (float)GRID_H / 2.0f;
	float oz = -(float)DEPTH / 2.0f;

	for (int gy = 0; gy < GRID_H; gy++) {
		for (int gx = 0; gx < GRID_W; gx++) {
			for (int gz = 0; gz < DEPTH; gz++) {
				if (!voxel_set(gx, gy, gz)) continue;

				float x =  (float)gx + ox;
				float y = -(float)gy + oy;
				float z =  (float)gz + oz;

				// normal, tan_u (+X tangent), tan_v (+Y tangent) — each 0.5 unit half-extent
				if (!voxel_set(
					gx,
					gy,
					gz + 1
				)) push_face(self, x, y, z + 0.5f, vec3(0, 0, 1), vec3(0.5f, 0, 0), vec3(0, 0.5f, 0));
				if (!voxel_set(
					gx,
					gy,
					gz - 1
				)) push_face(self, x, y, z - 0.5f, vec3(0, 0, -1), vec3(0.5f, 0, 0), vec3(0, 0.5f, 0));
				if (!voxel_set(
					gx,
					gy - 1,
					gz
				)) push_face(self, x, y + 0.5f, z, vec3(0, 1, 0), vec3(0.5f, 0, 0), vec3(0, 0, 0.5f));
				if (!voxel_set(
					gx,
					gy + 1,
					gz
				)) push_face(self, x, y - 0.5f, z, vec3(0, -1, 0), vec3(0.5f, 0, 0), vec3(0, 0, 0.5f));
				if (!voxel_set(
					gx + 1,
					gy,
					gz
				)) push_face(self, x + 0.5f, y, z, vec3(1, 0, 0), vec3(0, 0.5f, 0), vec3(0, 0, 0.5f));
				if (!voxel_set(
					gx - 1,
					gy,
					gz
				)) push_face(self, x - 0.5f, y, z, vec3(-1, 0, 0), vec3(0, 0.5f, 0), vec3(0, 0, 0.5f));
			}
		}
	}
}

fn tea::Cmd VoxelModel.update(VoxelModel* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		mem::free(self.cells.ptr);
		mem::free(self.pixels.ptr);
		mem::free(self.depth.ptr);
		self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
		self.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
		self.depth = mem::new_array(float, (sz)(self.width * self.height * 2));
		return null;
	}

	if (msg.kind == tea::MsgKind.TICK) {
		self.frame++;
		self.rotation_x = (float)math::sin((float)self.frame * 0.003) * 0.15f;
		self.rotation_y = (float)self.frame * 0.01f;
		self.rotation_z = 0.0f;
		return tea::tick();
	}

	if (msg.kind != tea::MsgKind.KEY) return null;
	tea::KeyMsg k = msg.key;
	switch (k.code) {
		case tea::KeyCode.CTRL_C:
			return tea::quit();
		case tea::KeyCode.RUNE:
			if (k.rune == 'q') return tea::quit();
		default:
	}
	return null;
}

fn tea::View VoxelModel.view(VoxelModel* self) @dynamic {
	int w    = self.width;
	int h    = self.height;
	sz total = (sz)(w * h);

	for (sz i = 0; i < total; i++) {
		self.cells[i] = xray::empty_cell();
		self.depth[i] = 1000.0f;
	}

	float fov  = 30.0f;
	float dist = 20.0f;
	float cx   = (float)w / 2.0f;
	float cy   = (float)h / 2.0f;

	// light direction (world space, normalized)
	float light_x   =  0.4f;
	float light_y   =  0.8f;
	float light_z   = -0.5f;
	float light_len =  (float)math::sqrt(light_x * light_x + light_y * light_y + light_z * light_z);
	light_x /= light_len;
	light_y /= light_len;
	light_z /= light_len;

	for (int v = 0; v < self.voxel_count; v++) {
		Vec3 p = self.voxels[v].pos;
		Vec3 n = self.voxels[v].normal;

		p = p.rotate_x(self.rotation_x);
		p = p.rotate_y(self.rotation_y);
		p = p.rotate_z(self.rotation_z);

		n = n.rotate_x(self.rotation_x);
		n = n.rotate_y(self.rotation_y);
		n = n.rotate_z(self.rotation_z);

		// cull back-faces: skip faces pointing away from camera
		if (n.z > 0.0f) continue;

		float dz = dist + p.z;
		if (dz < 0.1f) continue;

		// rotate tangent vectors with the model
		Vec3 tu = self.voxels[v].tan_u;
		Vec3 tv = self.voxels[v].tan_v;
		tu = tu.rotate_x(self.rotation_x);
		tu = tu.rotate_y(self.rotation_y);
		tu = tu.rotate_z(self.rotation_z);
		tv = tv.rotate_x(self.rotation_x);
		tv = tv.rotate_y(self.rotation_y);
		tv = tv.rotate_z(self.rotation_z);

		// project all 4 corners of the face quad: p ± tu ± tv
		float min_sx =  1e9f;
		float max_sx = -1e9f;
		float min_sy =  1e9f;
		float max_sy = -1e9f;

		float[4] cu = { -1, -1, 1, 1 };
		float[4] cv = { -1, 1, -1, 1 };
		for (int ci = 0; ci < 4; ci++) {
			float cx3 = p.x + cu[ci] * tu.x + cv[ci] * tv.x;
			float cy3 = p.y + cu[ci] * tu.y + cv[ci] * tv.y;
			float cz3 = p.z + cu[ci] * tu.z + cv[ci] * tv.z;
			float cdz = dist + cz3;
			if (cdz < 0.1f) continue;
			float sc  =  fov / cdz;
			float csx =  cx3 * sc * 2.0f + cx;
			float csy = -cy3 * sc + cy;
			if (csx < min_sx) min_sx = csx;
			if (csx > max_sx) max_sx = csx;
			if (csy < min_sy) min_sy = csy;
			if (csy > max_sy) max_sy = csy;
		}

		int x0 = (int)min_sx;
		int x1 = (int)max_sx;
		int y0 = (int)min_sy;
		int y1 = (int)max_sy;

		float sx   = (min_sx + max_sx) / 2.0f;
		float sy   = (min_sy + max_sy) / 2.0f;
		float hs_x = (max_sx - min_sx) / 2.0f;
		float hs_y = (max_sy - min_sy) / 2.0f;

		// diffuse + ambient lighting via rotated normal dot light
		float diff = n.x * light_x + n.y * light_y + n.z * light_z;
		if (diff < 0.0f) diff = 0.0f;
		float brightness = 0.15f + 0.85f * diff;

		char r            = (char)(brightness * 220.0f);
		char g            = (char)(brightness * 180.0f);
		char b            = (char)(brightness * 255.0f);
		xray::Style style = xray::default_style().set_fg(xray::color_rgb(r, g, b));

		for (int py = y0; py <= y1; py++) {
			if (py < 0 || py >= h) continue;
			for (int px = x0; px <= x1; px++) {
				if (px < 0 || px >= w) continue;
				sz idx = (sz)(py * w + px);
				if (p.z < self.depth[idx]) {
					self.depth[idx] = p.z;
					self.cells[idx] = xray::new_cell("\xe2\x96\x88", 1, style);
				}
			}
		}
	}

	// post-process AA: for each empty pixel, sum contributions from filled neighbours.
	// gaps between letters get contributions from both sides = brighter fringe.
	// outer silhouette gets contribution from only one side = dimmer fringe.
	int[4] dx = { 1, -1, 0, 0 };
	int[4] dy = { 0, 0, 1, -1 };
	for (int py = 0; py < h; py++) {
		for (int px = 0; px < w; px++) {
			sz idx = (sz)(py * w + px);
			if (self.depth[idx] < 999.0f) continue; // filled, skip

			float sum_r = 0.0f;
			float sum_g = 0.0f;
			float sum_b = 0.0f;
			int count   = 0;

			for (int d = 0; d < 4; d++) {
				int nx = px + dx[d];
				int ny = py + dy[d];
				if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
				sz nidx = (sz)(ny * w + nx);
				if (self.depth[nidx] >= 999.0f) continue;
				xray::Cell src = self.cells[nidx];
				sum_r += (float)src.style.fg.r;
				sum_g += (float)src.style.fg.g;
				sum_b += (float)src.style.fg.b;
				count++;
			}

			if (count == 0) continue;

			char r               = (char)(sum_r / (float)count);
			char g               = (char)(sum_g / (float)count);
			char b               = (char)(sum_b / (float)count);
			xray::Style aa_style = xray::default_style().set_fg(xray::color_rgb(r, g, b));

			// 1 neighbour = ░ (25%), 2 = ▒ (50%), 3 = ▓ (75%), 4 = █ (full)
			String glyph;
			switch (count) {
				case 1: glyph = "\xe2\x96\x91";  // ░
				case 2: glyph = "\xe2\x96\x92";  // ▒
				case 3: glyph = "\xe2\x96\x93";  // ▓
				default: glyph = "\xe2\x96\x88";  // █
			}
			self.cells[idx] = xray::new_cell(glyph, 1, aa_style);
		}
	}

	return tea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

fn int main() {
	VoxelModel* model = mem::new(VoxelModel);
	if (catch err = tea::@run_program(model)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	mem::free(model);
	return 0;
}