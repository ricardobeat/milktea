module doom_fire_3d;

import milktea;
import xray;
import std::io;
import std::math;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();

struct Vec3 {
	float x;
	float y;
	float z;
}

struct FireColor {
	char r;
	char g;
	char b;
}

FireColor[37] fire_palette = {
	{ 7, 7, 7 },
	{ 31, 7, 7 },
	{ 47, 15, 7 },
	{ 71, 15, 7 },
	{ 87, 23, 7 },
	{ 103, 31, 7 },
	{ 119, 31, 7 },
	{ 143, 39, 7 },
	{ 159, 47, 7 },
	{ 175, 63, 7 },
	{ 191, 71, 7 },
	{ 199, 71, 7 },
	{ 223, 79, 7 },
	{ 223, 87, 7 },
	{ 223, 87, 7 },
	{ 215, 95, 7 },
	{ 215, 95, 7 },
	{ 215, 103, 15 },
	{ 207, 111, 15 },
	{ 207, 119, 15 },
	{ 207, 127, 15 },
	{ 207, 135, 23 },
	{ 199, 135, 23 },
	{ 199, 143, 23 },
	{ 199, 151, 31 },
	{ 191, 159, 31 },
	{ 191, 159, 31 },
	{ 191, 167, 39 },
	{ 191, 167, 39 },
	{ 191, 175, 47 },
	{ 183, 175, 47 },
	{ 183, 183, 47 },
	{ 183, 183, 55 },
	{ 207, 207, 111 },
	{ 223, 223, 159 },
	{ 239, 239, 199 },
	{ 255, 255, 255 },
	};

struct Particle {
	Vec3 pos;
	Vec3 vel;
	int fire_idx;
	bool alive;
}

struct RenderVoxel {
	Vec3 pos;
	int fire_idx;
}

struct Pixel {
	char r;
	char g;
	char b;
}

const int MAX_PARTICLES   =  2048;
const int SPAWN_PER_FRAME =  12;
const float SPREAD_Z      =  4.0f;
const float BASE_Y        = -6.0f;

struct Fire3DModel {
	Particle[] particles;
	int active_count;
	RenderVoxel[] render_voxels;
	int render_count;
	float rotation_x;
	float rotation_y;
	float rotation_z;
	int width;
	int height;
	int frame;
	xray::Cell[] cells;
	Pixel[] pixels;
	float[] depth;
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

fn float rand_float() => (float)(rand() % 10000) / 10000.0f;

fn void spawn_particle(Fire3DModel* self) {
	float spread_x = (float)self.width * 0.15f;
	for (int i = 0; i < MAX_PARTICLES; i++) {
		if (!self.particles[i].alive) {
			float rx    = (rand_float() * 2.0f - 1.0f) * spread_x;
			float rz    = (rand_float() * 2.0f - 1.0f) * SPREAD_Z;
			float speed = 0.08f + rand_float() * 0.12f;
			self.particles[i] = {
				.pos = vec3(rx, BASE_Y, rz),
				.vel = vec3((rand_float() - 0.5f) * 0.04f, speed, (rand_float() - 0.5f) * 0.04f),
				.fire_idx = 36,
				.alive = true,
			};
			return;
		}
	}
}

fn void update_particles(Fire3DModel* self) {
	self.active_count = 0;
	for (int i = 0; i < MAX_PARTICLES; i++) {
		Particle* p = &self.particles[i];
		if (!p.alive) continue;

		p.pos.x += p.vel.x;
		p.pos.y += p.vel.y;
		p.pos.z += p.vel.z;

		// turbulence: random lateral drift
		p.vel.x += (rand_float() - 0.5f) * 0.006f;
		p.vel.z += (rand_float() - 0.5f) * 0.006f;

		// friction
		p.vel.x *= 0.98f;
		p.vel.z *= 0.98f;

		// decay fire
		int decay = rand() % 3;
		p.fire_idx -= decay;
		if (p.fire_idx < 0) {
			p.alive = false;
			continue;
		}

		// kill if too high
		if (p.pos.y > 8.0f) {
			p.alive = false;
			continue;
		}

		self.active_count++;
	}
}

fn void build_render_voxels(Fire3DModel* self) {
	self.render_count = 0;
	float half = 0.4f;

	for (int i = 0; i < MAX_PARTICLES; i++) {
		if (!self.particles[i].alive) continue;
		if (self.render_count >= 8192) break;

		Particle* p = &self.particles[i];

		// size shrinks as fire decays
		float t   = (float)p.fire_idx / 36.0f;
		float sz2 = half * (0.3f + 0.7f * t);

		// front face
		self.render_voxels[self.render_count] = {
			.pos = vec3(p.pos.x, p.pos.y, p.pos.z + sz2),
			.fire_idx = p.fire_idx,
		};
		self.render_count++;

		// back face
		self.render_voxels[self.render_count] = {
			.pos = vec3(p.pos.x, p.pos.y, p.pos.z - sz2),
			.fire_idx = p.fire_idx,
		};
		self.render_count++;

		// left
		self.render_voxels[self.render_count] = {
			.pos = vec3(p.pos.x - sz2, p.pos.y, p.pos.z),
			.fire_idx = p.fire_idx,
		};
		self.render_count++;

		// right
		self.render_voxels[self.render_count] = {
			.pos = vec3(p.pos.x + sz2, p.pos.y, p.pos.z),
			.fire_idx = p.fire_idx,
		};
		self.render_count++;

		// top
		self.render_voxels[self.render_count] = {
			.pos = vec3(p.pos.x, p.pos.y + sz2, p.pos.z),
			.fire_idx = p.fire_idx,
		};
		self.render_count++;

		// bottom
		self.render_voxels[self.render_count] = {
			.pos = vec3(p.pos.x, p.pos.y - sz2, p.pos.z),
			.fire_idx = p.fire_idx,
		};
		self.render_count++;
	}
}

fn milktea::Cmd Fire3DModel.init(Fire3DModel* self) @dynamic {
	ulong seed = (ulong)c3_time_ms_long();
	srand((uint)seed);
	self.width = 80;
	self.height = 24;
	self.frame = 0;
	self.active_count = 0;
	self.render_count = 0;

	self.particles = mem::new_array(Particle, (sz)MAX_PARTICLES);
	self.render_voxels = mem::new_array(RenderVoxel, (sz)(MAX_PARTICLES * 6));
	self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
	self.depth = mem::new_array(float, (sz)(self.width * self.height * 2));

	return milktea::tick();
}

fn milktea::Cmd Fire3DModel.update(Fire3DModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
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

	if (msg.kind == milktea::MsgKind.TICK) {
		self.frame++;

		// spawn new particles
		for (int i = 0; i < SPAWN_PER_FRAME; i++) {
			spawn_particle(self);
		}

		update_particles(self);
		build_render_voxels(self);

		self.rotation_x = (float)math::sin((float)self.frame * 0.004) * 0.15f;
		self.rotation_y = (float)self.frame * 0.008f;
		self.rotation_z = 0.0f;

		return milktea::tick();
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View Fire3DModel.view(Fire3DModel* self) @dynamic {
	int w    = self.width;
	int h    = self.height;
	sz total = (sz)(w * h);

	for (sz i = 0; i < total; i++) {
		self.cells[i] = xray::empty_cell();
		self.depth[i] = 1000.0f;
	}

	float fov  = (float)w * 0.35f;
	float dist = 20.0f;
	float cx   = (float)w / 2.0f;
	float cy   = (float)h / 2.0f;

	for (int v = 0; v < self.render_count; v++) {
		Vec3 p = self.render_voxels[v].pos;
		int fi = self.render_voxels[v].fire_idx;

		p = p.rotate_x(self.rotation_x);
		p = p.rotate_y(self.rotation_y);
		p = p.rotate_z(self.rotation_z);

		float dz = dist + p.z;
		if (dz < 0.5f) continue;

		float sc =  fov / dz;
		float sx =  p.x * sc * 2.0f + cx;
		float sy = -p.y * sc + cy;

		int ix = (int)sx;
		int iy = (int)sy;
		if (ix < 0 || ix >= w || iy < 0 || iy >= h) continue;

		sz idx = (sz)(iy * w + ix);
		if (dz < self.depth[idx]) {
			self.depth[idx] = dz;
			FireColor fc      = fire_palette[fi];
			xray::Style style = xray::default_style().set_fg(xray::color_rgb(fc.r, fc.g, fc.b));
			self.cells[idx] = xray::new_cell("\xe2\x96\x88", 1, style);
		}
	}

	// AA pass
	int[4] ddx = { 1, -1, 0, 0 };
	int[4] ddy = { 0, 0, 1, -1 };
	for (int py = 0; py < h; py++) {
		for (int px = 0; px < w; px++) {
			sz idx = (sz)(py * w + px);
			if (self.depth[idx] < 999.0f) continue;

			float sum_r = 0.0f;
			float sum_g = 0.0f;
			float sum_b = 0.0f;
			int count   = 0;

			for (int d = 0; d < 4; d++) {
				int nx2 = px + ddx[d];
				int ny2 = py + ddy[d];
				if (nx2 < 0 || nx2 >= w || ny2 < 0 || ny2 >= h) continue;
				sz nidx = (sz)(ny2 * w + nx2);
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

			String glyph;
			switch (count) {
				case 1: glyph = "\xe2\x96\x91";
				case 2: glyph = "\xe2\x96\x92";
				case 3: glyph = "\xe2\x96\x93";
				default: glyph = "\xe2\x96\x88";
			}
			self.cells[idx] = xray::new_cell(glyph, 1, aa_style);
		}
	}

	return milktea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

fn int main() {
	Fire3DModel* model = mem::new(Fire3DModel);
	if (catch err = milktea::@run_program(model)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	mem::free(model);
	return 0;
}