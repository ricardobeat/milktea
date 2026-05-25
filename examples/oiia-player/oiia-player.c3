module oiia_player;

import tea;
import xray;
import stb_json;
import stb_image;
import std::io;
import std::math;
import std::os;

extern fn int system(char* command);
import std::core::dstring;
import std::core::string;

extern fn int fork();
extern fn int execvp(char* file, char** argv);
extern fn int kill(int pid, int sig);

extern fn double c3_sin(double x);
extern fn double c3_cos(double x);

// ── Vec3 ─────────────────────────────────────────────────────────────────────

struct Vec3 {
	float x;
	float y;
	float z;
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

// ── Pixel ────────────────────────────────────────────────────────────────────

struct Pixel {
	char r;
	char g;
	char b;
}

// ── Voxel face ───────────────────────────────────────────────────────────────

struct Voxel {
	Vec3 pos;
	Vec3 normal;
	Vec3 tan_u;
	Vec3 tan_v;
	char r;
	char g;
	char b;
}

const int MAX_VOXELS = 32768;

// ── GLB geometry ─────────────────────────────────────────────────────────────

struct GlbModel {
	Voxel[MAX_VOXELS] voxels;
	int voxel_count;
	int width;
	int height;
	int frame;
	int[MAX_VOXELS] last_visible;
	xray::Cell[] cells;
	Pixel[] pixels;
	Pixel[] prev_pixels;
	float[] depth;
	float cam_px;
	float cam_py;
	float cam_pz;
	float cam_yaw;
	float cam_pitch;
}

// ── GLB loading ───────────────────────────────────────────────────────────────

faultdef GLB_OPEN_FAILED, GLB_BAD_MAGIC, GLB_JSON_ERROR, GLB_MESH_NOT_FOUND;

struct AccessorInfo {
	int bv_index;
	int byte_offset;
	int count;
	int component_type;
	int num_components;
}

struct BufferViewInfo {
	int byte_offset;
	int byte_length;
	int byte_stride;
}

fn int components_for_type(char* type_str) {
	if (type_str[0] == 'S') return 1;
	if (type_str[0] == 'V' && type_str[3] == '2') return 2;
	if (type_str[0] == 'V' && type_str[3] == '3') return 3;
	if (type_str[0] == 'V' && type_str[3] == '4') return 4;
	return 1;
}

fn uint read_u32(char* buf, sz offset) {
	char* p = buf + offset;
	return (uint)p[0] | ((uint)p[1] << 8) | ((uint)p[2] << 16) | ((uint)p[3] << 24);
}

fn float read_f32(char* buf, sz offset) {
	uint u = read_u32(buf, offset);
	float f;
	mem::copy(&f, &u, 4);
	return f;
}

fn void parse_accessor(stb_json::Cursor* accessors_arr, int idx, AccessorInfo* out) {
	stb_json::Cursor acc = stb_json::stbj_move_cursor_index(accessors_arr, idx);
	out.bv_index = stb_json::stbj_read_int_name(&acc, "bufferView", -1);
	out.byte_offset = stb_json::stbj_read_int_name(&acc, "byteOffset", 0);
	out.count = stb_json::stbj_read_int_name(&acc, "count", 0);
	out.component_type = stb_json::stbj_read_int_name(&acc, "componentType", 5126);
	char[8] type_str;
	stb_json::stbj_read_string_name(&acc, "type", &type_str, 8, "SCALAR");
	if (type_str[0] == 'S') {
		out.num_components = 1;
	} else if (type_str[3] == '2') {
		out.num_components = 2;
	} else if (type_str[3] == '3') {
		out.num_components = 3;
	} else if (type_str[3] == '4') {
		out.num_components = 4;
	} else {
		out.num_components = 1;
	}
}

fn void parse_bufview(stb_json::Cursor* bvs_arr, int idx, BufferViewInfo* out) {
	stb_json::Cursor bv = stb_json::stbj_move_cursor_index(bvs_arr, idx);
	out.byte_offset = stb_json::stbj_read_int_name(&bv, "byteOffset", 0);
	out.byte_length = stb_json::stbj_read_int_name(&bv, "byteLength", 0);
	out.byte_stride = stb_json::stbj_read_int_name(&bv, "byteStride", 0);
}

fn GlbModel*? load_glb(String path) {
	char[]? data_opt = file::load(mem, path);
	if (catch data_opt) return GLB_OPEN_FAILED~;
	char[] data = (char[])data_opt;
	char* raw   = data.ptr;
	defer mem::free(raw);

	if (raw[0] != 'g' || raw[1] != 'l' || raw[2] != 'T' || raw[3] != 'F') {
		return GLB_BAD_MAGIC~;
	}

	uint json_len      = read_u32(raw, 12);
	char* json_buf     = raw + 20;
	sz bin_chunk_start = 20 + (sz)json_len;
	char* bin          = raw + bin_chunk_start + 8;

	stb_json::Cursor root = stb_json::stbj_load_buffer(json_buf, json_len);
	if (stb_json::stbj_any_error(&root) != 0) {
		return GLB_JSON_ERROR~;
	}

	stb_json::Cursor meshes = stb_json::stbj_move_cursor_name(&root, "meshes");
	stb_json::Cursor mesh0  = stb_json::stbj_move_cursor_index(&meshes, 0);
	stb_json::Cursor prims  = stb_json::stbj_move_cursor_name(&mesh0, "primitives");
	stb_json::Cursor prim0  = stb_json::stbj_move_cursor_index(&prims, 0);
	stb_json::Cursor attrs  = stb_json::stbj_move_cursor_name(&prim0, "attributes");

	int pos_acc_idx = stb_json::stbj_read_int_name(&attrs, "POSITION", -1);
	int uv_acc_idx  = stb_json::stbj_read_int_name(&attrs, "TEXCOORD_0", -1);
	int idx_acc_idx = stb_json::stbj_read_int_name(&prim0, "indices", -1);

	if (pos_acc_idx < 0 || idx_acc_idx < 0) return GLB_MESH_NOT_FOUND~;

	stb_json::Cursor accessors = stb_json::stbj_move_cursor_name(&root, "accessors");
	stb_json::Cursor bvs       = stb_json::stbj_move_cursor_name(&root, "bufferViews");

	AccessorInfo pos_acc;
	parse_accessor(&accessors, pos_acc_idx, &pos_acc);
	AccessorInfo idx_acc;
	parse_accessor(&accessors, idx_acc_idx, &idx_acc);
	BufferViewInfo pos_bv;
	parse_bufview(&bvs, pos_acc.bv_index, &pos_bv);
	BufferViewInfo idx_bv;
	parse_bufview(&bvs, idx_acc.bv_index, &idx_bv);

	sz pos_base   = (sz)(pos_bv.byte_offset + pos_acc.byte_offset);
	sz pos_stride = (sz)(pos_bv.byte_stride > 0 ? pos_bv.byte_stride : 12);
	sz idx_base   = (sz)(idx_bv.byte_offset + idx_acc.byte_offset);
	bool idx32    = (idx_acc.component_type == 5125);

	bool has_uv  = (uv_acc_idx >= 0);
	sz uv_base   = 0;
	sz uv_stride = 8;
	if (has_uv) {
		AccessorInfo uv_acc;
		parse_accessor(&accessors, uv_acc_idx, &uv_acc);
		BufferViewInfo uv_bv;
		parse_bufview(&bvs, uv_acc.bv_index, &uv_bv);
		uv_base = (sz)(uv_bv.byte_offset + uv_acc.byte_offset);
		uv_stride = (sz)(uv_bv.byte_stride > 0 ? uv_bv.byte_stride : 8);
	}

	// Compute bounding box from vertices
	float min_x =  1e9f;
	float max_x = -1e9f;
	float min_y =  1e9f;
	float max_y = -1e9f;
	float min_z =  1e9f;
	float max_z = -1e9f;
	for (int i = 0; i < pos_acc.count; i++) {
		sz base = pos_base + (sz)i * pos_stride;
		float x = read_f32(bin, base);
		float y = read_f32(bin, base + 4);
		float z = read_f32(bin, base + 8);
		if (x < min_x) min_x = x;
		if (x > max_x) max_x = x;
		if (y < min_y) min_y = y;
		if (y > max_y) max_y = y;
		if (z < min_z) min_z = z;
		if (z > max_z) max_z = z;
	}
	float center_x = (min_x + max_x) / 2.0f;
	float center_y = (min_y + max_y) / 2.0f;
	float center_z = (min_z + max_z) / 2.0f;

	// Allocate occupancy grid
	int gx0        = (int)(min_x - center_x) - 1;
	int gy0        = (int)(min_y - center_y) - 1;
	int gz0        = (int)(min_z - center_z) - 1;
	int gx1        = (int)(max_x - center_x) + 2;
	int gy1        = (int)(max_y - center_y) + 2;
	int gz1        = (int)(max_z - center_z) + 2;
	int gdx        = gx1 - gx0;
	int gdy        = gy1 - gy0;
	int gdz        = gz1 - gz0;
	sz grid_size   = (sz)(gdx * gdy * gdz);
	bool* occupied = mem::new_array(bool, grid_size);
	char* colors   = mem::new_array(char, grid_size * 3);
	defer mem::free(occupied);
	defer mem::free(colors);

	// Voxelize: snap each triangle centroid to integer grid
	int tri_count = idx_acc.count / 3;
	for (int ti = 0; ti < tri_count; ti++) {
		int i0, i1, i2;
		if (idx32) {
			i0 = (int)read_u32(bin, idx_base + (sz)ti * 12);
			i1 = (int)read_u32(bin, idx_base + (sz)ti * 12 + 4);
			i2 = (int)read_u32(bin, idx_base + (sz)ti * 12 + 8);
		} else {
			char* p = bin + idx_base + (sz)ti * 6;
			i0 = (int)((uint)p[0] | ((uint)p[1] << 8));
			i1 = (int)((uint)p[2] | ((uint)p[3] << 8));
			i2 = (int)((uint)p[4] | ((uint)p[5] << 8));
		}

		sz b0 = pos_base + (sz)i0 * pos_stride;
		sz b1 = pos_base + (sz)i1 * pos_stride;
		sz b2 = pos_base + (sz)i2 * pos_stride;

		float cx3 = (read_f32(bin, b0) + read_f32(bin, b1) + read_f32(bin, b2)) / 3.0f - center_x;
		float cy3 = (read_f32(bin, b0 + 4) + read_f32(bin, b1 + 4) + read_f32(bin, b2 + 4)) / 3.0f - center_y;
		float cz3 = (read_f32(bin, b0 + 8) + read_f32(bin, b1 + 8) + read_f32(bin, b2 + 8)) / 3.0f - center_z;

		int gx = (int)(cx3 + 0.5f) - gx0;
		int gy = (int)(cy3 + 0.5f) - gy0;
		int gz = (int)(cz3 + 0.5f) - gz0;

		if (gx < 0 || gx >= gdx || gy < 0 || gy >= gdy || gz < 0 || gz >= gdz) continue;
		sz gidx = (sz)(gx + gy * gdx + gz * gdx * gdy);

		char cr = (char)180;
		char cg = (char)180;
		char cb = (char)200;
		if (has_uv) {
			float u = read_f32(bin, uv_base + (sz)i0 * uv_stride);
			float t = u < 0.0f ? 0.0f : (u > 1.0f ? 1.0f : u);
			cr = (char)(180.0f + t * 50.0f);
			cg = (char)(180.0f + t * 20.0f);
			cb = (char)(200.0f + t * 30.0f);
		}

		occupied[gidx] = true;
		colors[gidx * 3] = cr;
		colors[gidx * 3 + 1] = cg;
		colors[gidx * 3 + 2] = cb;
	}

	// 6 face directions
	int[6] nox   = { 0, 0, 0, 0, 1, -1 };
	int[6] noy   = { 0, 0, 1, -1, 0, 0 };
	int[6] noz   = { 1, -1, 0, 0, 0, 0 };
	float[6] fnx = { 0, 0, 0, 0, 1, -1 };
	float[6] fny = { 1, -1, 0, 0, 0, 0 };
	float[6] fnz = { 0, 0, 1, -1, 0, 0 };
	float[6] tux = { 0.5f, 0.5f, 0.5f, 0.5f, 0, 0 };
	float[6] tuy = { 0, 0, 0, 0, 0.5f, 0.5f };
	float[6] tuz = { 0, 0, 0, 0, 0, 0 };
	float[6] tvx = { 0, 0, 0, 0, 0, 0 };
	float[6] tvy = { 0.5f, 0.5f, 0, 0, 0, 0 };
	float[6] tvz = { 0, 0, 0.5f, 0.5f, 0.5f, 0.5f };
	float[6] fox = { 0, 0, 0, 0, 0.5f, -0.5f };
	float[6] foy = { 0.5f, -0.5f, 0, 0, 0, 0 };
	float[6] foz = { 0, 0, 0.5f, -0.5f, 0, 0 };

	// Normalize to ~10 units
	float span_x   = max_x - min_x;
	float span_y   = max_y - min_y;
	float span_z   = max_z - min_z;
	float max_span = span_x;
	if (span_y > max_span) max_span = span_y;
	if (span_z > max_span) max_span = span_z;
	float scale = (max_span > 0.0f) ? (10.0f / max_span) : 1.0f;

	GlbModel* model = mem::new(GlbModel);
	model.voxel_count = 0;

	for (int igz = 0; igz < gdz; igz++) {
		for (int igy = 0; igy < gdy; igy++) {
			for (int igx = 0; igx < gdx; igx++) {
				sz gidx = (sz)(igx + igy * gdx + igz * gdx * gdy);
				if (!occupied[gidx]) continue;

				// Swap Y and Z: GLB Z-up → renderer Y-up
				float wx = (float)(igx + gx0) * scale;
				float wy = (float)(igz + gz0) * scale;
				float wz = (float)(igy + gy0) * scale;
				char cr  = colors[gidx * 3];
				char cg2 = colors[gidx * 3 + 1];
				char cb  = colors[gidx * 3 + 2];

				for (int f = 0; f < 6; f++) {
					int nx3        = igx + nox[f];
					int ny3        = igy + noy[f];
					int nz3        = igz + noz[f];
					bool neighbour = false;
					if (nx3 >= 0 && nx3 < gdx && ny3 >= 0 && ny3 < gdy && nz3 >= 0 && nz3 < gdz) {
						neighbour = occupied[(sz)(nx3 + ny3 * gdx + nz3 * gdx * gdy)];
					}
					if (neighbour) continue;
					if (model.voxel_count >= MAX_VOXELS) break;
					model.voxels[model.voxel_count++] = {
						.pos = vec3(wx + fox[f] * scale, wy + foy[f] * scale, wz + foz[f] * scale),
						.normal = vec3(fnx[f], fny[f], fnz[f]),
						.tan_u = vec3(tux[f] * scale, tuy[f] * scale, tuz[f] * scale),
						.tan_v = vec3(tvx[f] * scale, tvy[f] * scale, tvz[f] * scale),
						.r = cr,
						.g = cg2,
						.b = cb,
					};
				}
			}
		}
	}

	model.width = 80;
	model.height = 24;
	model.cells = mem::new_array(xray::Cell, (sz)(model.width * model.height));
	model.pixels = mem::new_array(Pixel, (sz)(model.width * model.height * 2));
	model.prev_pixels = mem::new_array(Pixel, (sz)(model.width * model.height * 2));
	model.depth = mem::new_array(float, (sz)(model.width * model.height * 2));

	return model;
}

// ── App ──────────────────────────────────────────────────────────────────────

enum AppMode {
	SHOWING_IMAGE,
	PLAYING
}

struct App {
	AppMode mode;
	int width;
	int height;
	int frame;
	int key_tick;
	int sound_pid;

	// PNG image data
	char* img_data;
	int img_w;
	int img_h;
	int img_channels;

	// GLB model
	GlbModel* model;
	bool glb_loaded;

	// Camera
	float cam_px;
	float cam_py;
	float cam_pz;
	float cam_yaw;
	float cam_pitch;
}

fn void App.play_sound(App* self) {
	int pid = fork();
	if (pid == 0) {
		char[512] sh_cmd;
		char* p   = &sh_cmd;
		char* src = "sh";
		while (*src != 0) {
			*p = *src;
			p++;
			src++;
		}
		*p = 0;

		char[512] arg0;
		char* a0 = &arg0;
		src = "sh";
		while (*src != 0) {
			*a0 = *src;
			a0++;
			src++;
		}
		*a0 = 0;

		char[512] arg1;
		char* a1 = &arg1;
		src = "-c";
		while (*src != 0) {
			*a1 = *src;
			a1++;
			src++;
		}
		*a1 = 0;

		char[1024] arg2;
		char* a2 = &arg2;
		src = "while :; do afplay oiia-oiia-sound.mp3; done";
		while (*src != 0) {
			*a2 = *src;
			a2++;
			src++;
		}
		*a2 = 0;

		char*[4] argv;
		argv[0] = &sh_cmd;
		argv[1] = &arg1;
		argv[2] = &arg2;
		argv[3] = null;
		execvp(&sh_cmd, &argv);
	} else if (pid > 0) {
		self.sound_pid = pid;
	}
}

fn void App.load_png(App* self) {
	char[256] path;
	char* p   = &path;
	char* src = "oiia.png";
	while (*src != 0) {
		*p = *src;
		p++;
		src++;
	}
	*p = 0;
	self.img_data = stb_image::stbi_load((String)&path, &self.img_w, &self.img_h, &self.img_channels, 3);
}

fn void App.load_glb_model(App* self) {
	char[256] path;
	char* p   = &path;
	char* src = "felix_loaf.glb";
	while (*src != 0) {
		*p = *src;
		p++;
		src++;
	}
	*p = 0;

	GlbModel*? result = load_glb((String)&path);
	if (catch err = result) {
		io::printfn("Error loading GLB: %s", err);
		return;
	}
	self.model = result;
	self.model.width = self.width;
	self.model.height = self.height;
	mem::free(self.model.cells.ptr);
	mem::free(self.model.pixels.ptr);
	mem::free(self.model.prev_pixels.ptr);
	mem::free(self.model.depth.ptr);
	self.model.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.model.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
	self.model.prev_pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
	self.model.depth = mem::new_array(float, (sz)(self.width * self.height * 2));
	self.model.frame = 0;
	self.cam_px = 0.0f;
	self.cam_py = 0.0f;
	self.cam_pz = -35.0f;
	self.cam_yaw = 0.0f;
	self.cam_pitch = 0.0f;
	self.glb_loaded = true;
}

fn void App.free_model(App* self) {
	if (self.model == null) return;
	mem::free(self.model.cells.ptr);
	mem::free(self.model.pixels.ptr);
	mem::free(self.model.prev_pixels.ptr);
	mem::free(self.model.depth.ptr);
	mem::free(self.model);
	self.model = null;
}

// ── Tea callbacks ─────────────────────────────────────────────────────────────

fn tea::Cmd App.init(App* self) @dynamic {
	self.width = 80;
	self.height = 24;
	self.frame = 0;
	self.mode = SHOWING_IMAGE;
	self.glb_loaded = false;
	self.model = null;
	self.img_data = null;
	self.sound_pid = 0;
	self.cam_px = 0.0f;
	self.cam_py = 0.0f;
	self.cam_pz = -35.0f;
	self.cam_yaw = 0.0f;
	self.cam_pitch = 0.0f;
	self.load_png();
	return tea::tick();
}

fn tea::Cmd App.update(App* self, tea::Msg msg) @dynamic {
	if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		if (self.model != null) {
			self.model.width = self.width;
			self.model.height = self.height;
			mem::free(self.model.cells.ptr);
			mem::free(self.model.pixels.ptr);
			mem::free(self.model.prev_pixels.ptr);
			mem::free(self.model.depth.ptr);
			self.model.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
			self.model.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
			self.model.prev_pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
			self.model.depth = mem::new_array(float, (sz)(self.width * self.height * 2));
		}
		return null;
	}

	if (msg.kind == tea::MsgKind.TICK) {
		self.frame++;

		if (self.mode == PLAYING && self.glb_loaded && self.model != null) {
			self.model.frame++;
			float orbit_dist  = 20.0f;
			float orbit_yaw   = (float)self.model.frame * 0.3f;
			float orbit_pitch = (float)math::sin((float)self.model.frame * 0.003) * 0.15f;
			self.cam_yaw = orbit_yaw;
			self.cam_pitch = orbit_pitch;
			float fwd_x =  (float)math::sin(orbit_yaw) * (float)math::cos(orbit_pitch);
			float fwd_y = -(float)math::sin(orbit_pitch);
			float fwd_z =  (float)math::cos(orbit_yaw) * (float)math::cos(orbit_pitch);
			self.cam_px = -fwd_x * orbit_dist;
			self.cam_py = -fwd_y * orbit_dist;
			self.cam_pz = -fwd_z * orbit_dist;
		}

		return tea::tick();
	}

	if (msg.kind == tea::MsgKind.KEY) {
		tea::KeyMsg k = msg.key;
		if (k.code == tea::KeyCode.CTRL_C || (k.code == tea::KeyCode.RUNE && k.rune == 'q')) {
			if (self.sound_pid > 0) kill(self.sound_pid, 15);
			if (self.img_data != null) stb_image::stbi_image_free(self.img_data);
			self.free_model();
			return tea::quit();
		}

		// Any key or click transitions from SHOWING_IMAGE → PLAYING
		if (self.mode == SHOWING_IMAGE) {
			self.play_sound();
			self.load_glb_model();
			self.mode = PLAYING;
		}
	}

	if (msg.kind == tea::MsgKind.MOUSE && msg.mouse.action == tea::MouseAction.MOUSE_PRESS
		&& msg.mouse.button == tea::MouseButton.MOUSE_LEFT) {
		if (self.mode == SHOWING_IMAGE) {
			self.play_sound();
			self.load_glb_model();
			self.mode = PLAYING;
		}
	}

	return null;
}

fn int clamp_color(int v) {
	if (v < 0) return 0;
	if (v > 255) return 255;
	return v;
}

fn tea::View App.view(App* self) @dynamic {
	int w = self.width;
	int h = self.height;
	if (w < 2) w = 80;
	if (h < 2) h = 24;

	if (self.mode == SHOWING_IMAGE && self.img_data != null) {
		// Render PNG image as half-block cells
		xray::Cell[] cells = mem::new_array(xray::Cell, (sz)(w * h));
		defer mem::free(cells.ptr);

		xray::Style base_style = xray::default_style();
		int pixel_rows         = h * 2;

		for (int y = 0; y < h; y++) {
			for (int x = 0; x < w; x++) {
				// Map terminal cell to image pixel (nearest-neighbor scaling)
				int img_px     = (int)((double)x / (double)w * (double)self.img_w);
				int img_py_top = (int)((double)(y * 2) / (double)pixel_rows * (double)self.img_h);
				int img_py_bot = (int)((double)(y * 2 + 1) / (double)pixel_rows * (double)self.img_h);

				if (img_px >= self.img_w) img_px = self.img_w - 1;
				if (img_py_top >= self.img_h) img_py_top = self.img_h - 1;
				if (img_py_bot >= self.img_h) img_py_bot = self.img_h - 1;

				int top_idx = (img_py_top * self.img_w + img_px) * 3;
				int bot_idx = (img_py_bot * self.img_w + img_px) * 3;

				char tr  = self.img_data[top_idx];
				char tg  = self.img_data[top_idx + 1];
				char tb  = self.img_data[top_idx + 2];
				char br  = self.img_data[bot_idx];
				char bg2 = self.img_data[bot_idx + 1];
				char bb  = self.img_data[bot_idx + 2];

				xray::Cell c;
				c.content[0] = 0xe2;
				c.content[1] = 0x96;
				c.content[2] = 0x80;
				c.content_len = 3;
				c.width = 1;
				c.style = base_style.set_fg(xray::color_rgb(tr, tg, tb)).set_bg(xray::color_rgb(br, bg2, bb));
				cells[y * w + x] = c;
			}
		}

		return tea::new_alt_cell_view(cells, (sz)w, (sz)h);
	}

	if (self.mode == PLAYING && self.glb_loaded && self.model != null) {
		// Render GLB voxel model
		self.model.cam_px = self.cam_px;
		self.model.cam_py = self.cam_py;
		self.model.cam_pz = self.cam_pz;
		self.model.cam_yaw = self.cam_yaw;
		self.model.cam_pitch = self.cam_pitch;

		int ph    = h * 2;
		sz ptotal = (sz)(w * ph);

		for (sz i = 0; i < ptotal; i++) {
			self.model.pixels[i] = (Pixel) { 0, 0, 0 };
			self.model.depth[i] = 1000.0f;
		}

		float fov = 30.0f;
		float cx  = (float)w / 2.0f;
		float cy  = (float)ph / 2.0f;

		float cos_yaw   = (float)math::cos(self.model.cam_yaw);
		float sin_yaw   = (float)math::sin(self.model.cam_yaw);
		float cos_pitch = (float)math::cos(self.model.cam_pitch);
		float sin_pitch = (float)math::sin(self.model.cam_pitch);

		float light_x   =  0.4f;
		float light_y   =  0.8f;
		float light_z   = -0.5f;
		float light_len =  (float)math::sqrt(light_x * light_x + light_y * light_y + light_z * light_z);
		light_x /= light_len;
		light_y /= light_len;
		light_z /= light_len;

		int cur_frame = self.model.frame;

		for (int v = 0; v < self.model.voxel_count; v++) {
			Vec3 p = self.model.voxels[v].pos;
			Vec3 n = self.model.voxels[v].normal;

			float rx = p.x - self.model.cam_px;
			float ry = p.y - self.model.cam_py;
			float rz = p.z - self.model.cam_pz;

			float ax = cos_yaw * rx - sin_yaw * rz;
			float ay = ry;
			float az = sin_yaw * rx + cos_yaw * rz;

			p.x = ax;
			p.y = cos_pitch * ay + sin_pitch * az;
			p.z = -sin_pitch * ay + cos_pitch * az;

			float nax = cos_yaw * n.x - sin_yaw * n.z;
			float nay = n.y;
			float naz = sin_yaw * n.x + cos_yaw * n.z;
			n.x = nax;
			n.y = cos_pitch * nay + sin_pitch * naz;
			n.z = -sin_pitch * nay + cos_pitch * naz;

			if (n.z > 0.08f) continue;

			float dz = p.z;
			if (dz < 0.5f) continue;

			Vec3 tu = self.model.voxels[v].tan_u;
			Vec3 tv = self.model.voxels[v].tan_v;

			float taux = cos_yaw * tu.x - sin_yaw * tu.z;
			float tauz = sin_yaw * tu.x + cos_yaw * tu.z;
			tu.x = taux;
			tu.z = tauz;
			float tvux = cos_yaw * tv.x - sin_yaw * tv.z;
			float tvuz = sin_yaw * tv.x + cos_yaw * tv.z;
			tv.x = tvux;
			tv.z = tvuz;

			float tauy2 =  cos_pitch * tu.y + sin_pitch * tu.z;
			float tauz2 = -sin_pitch * tu.y + cos_pitch * tu.z;
			tu.y = tauy2;
			tu.z = tauz2;
			float tvuy2 =  cos_pitch * tv.y + sin_pitch * tv.z;
			float tvuz2 = -sin_pitch * tv.y + cos_pitch * tv.z;
			tv.y = tvuy2;
			tv.z = tvuz2;

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
				if (cz3 < 0.1f) continue;
				float sc  =  fov / cz3;
				float csx =  cx3 * sc * 2.0f + cx;
				float csy = -cy3 * sc * 2.0f + cy;
				if (csx < min_sx) min_sx = csx;
				if (csx > max_sx) max_sx = csx;
				if (csy < min_sy) min_sy = csy;
				if (csy > max_sy) max_sy = csy;
			}

			float face_w    = max_sx - min_sx;
			float face_h    = max_sy - min_sy;
			float face_area = face_w * face_h;

			bool recently_visible = (cur_frame - self.model.last_visible[v]) <= 3;
			if (face_area < 0.5f && !recently_visible) continue;

			self.model.last_visible[v] = cur_frame;

			float wrap    = 0.5f;
			float diff    = n.x * light_x + n.y * light_y + n.z * light_z;
			float wrapped = (diff + wrap) / (1.0f + wrap);
			if (wrapped < 0.0f) wrapped = 0.0f;
			if (wrapped > 1.0f) wrapped = 1.0f;
			float brightness = 0.25f + 0.75f * wrapped;

			// RGB flash: cycle through red, green, blue based on frame
			float flash = (float)(self.model.frame % 90) / 30.0f;
			float cr    = 1.0f;
			float cg    = 1.0f;
			float cb    = 1.0f;
			if (flash < 1.0f) {
				cr = 1.0f;
				cg = 0.0f;
				cb = 0.0f;
			} else if (flash < 2.0f) {
				cr = 0.0f;
				cg = 1.0f;
				cb = 0.0f;
			} else {
				cr = 0.0f;
				cg = 0.0f;
				cb = 1.0f;
			}

			char pr = (char)((float)self.model.voxels[v].r * brightness * cr);
			char pg = (char)((float)self.model.voxels[v].g * brightness * cg);
			char pb = (char)((float)self.model.voxels[v].b * brightness * cb);

			int x0 = (int)min_sx;
			int x1 = (int)max_sx;
			int y0 = (int)min_sy;
			int y1 = (int)max_sy;
			if (x0 == x1) {
				x0--;
				x1++;
			}
			if (y0 == y1) {
				y0--;
				y1++;
			}

			for (int py = y0; py <= y1; py++) {
				if (py < 0 || py >= ph) continue;
				for (int px = x0; px <= x1; px++) {
					if (px < 0 || px >= w) continue;
					sz idx = (sz)(py * w + px);
					if (p.z < self.model.depth[idx]) {
						self.model.depth[idx] = p.z;
						self.model.pixels[idx] = (Pixel) { pr, pg, pb };
					}
				}
			}
		}

		// AA pass
		int[4] adx = { 1, -1, 0, 0 };
		int[4] ady = { 0, 0, 1, -1 };
		for (int py = 0; py < ph; py++) {
			for (int px = 0; px < w; px++) {
				sz idx = (sz)(py * w + px);
				if (self.model.depth[idx] < 999.0f) continue;

				float sum_r = 0.0f;
				float sum_g = 0.0f;
				float sum_b = 0.0f;
				int count   = 0;
				for (int d = 0; d < 4; d++) {
					int nx = px + adx[d];
					int ny = py + ady[d];
					if (nx < 0 || nx >= w || ny < 0 || ny >= ph) continue;
					sz nidx = (sz)(ny * w + nx);
					if (self.model.depth[nidx] >= 999.0f) continue;
					sum_r += (float)self.model.pixels[nidx].r;
					sum_g += (float)self.model.pixels[nidx].g;
					sum_b += (float)self.model.pixels[nidx].b;
					count++;
				}
				if (count == 0) continue;
				float fade = (float)count * 0.20f;
				float inv  = 1.0f / (float)count;
				self.model.pixels[idx] = (Pixel) {
					(char)(sum_r * inv * fade),
					(char)(sum_g * inv * fade),
					(char)(sum_b * inv * fade),
				};
				self.model.depth[idx] = 998.0f;
			}
		}

		// Temporal accumulation
		for (sz i = 0; i < ptotal; i++) {
			if (self.model.depth[i] >= 999.0f) continue;
			Pixel cur  = self.model.pixels[i];
			Pixel prev = self.model.prev_pixels[i];
			self.model.pixels[i] = (Pixel) {
				(char)((int)cur.r * 4 / 5 + (int)prev.r / 5),
				(char)((int)cur.g * 4 / 5 + (int)prev.g / 5),
				(char)((int)cur.b * 4 / 5 + (int)prev.b / 5),
			};
		}
		mem::copy(self.model.prev_pixels.ptr, self.model.pixels.ptr, ptotal * Pixel::size);

		// Combine into half-block cells
		for (sz i = 0; i < (sz)(w * h); i++) self.model.cells[i] = xray::empty_cell();
		for (int ty = 0; ty < h; ty++) {
			for (int tx = 0; tx < w; tx++) {
				sz top_idx      = (sz)((ty * 2) * w + tx);
				sz bot_idx      = (sz)((ty * 2 + 1) * w + tx);
				bool top_filled = self.model.depth[top_idx] < 999.0f;
				bool bot_filled = self.model.depth[bot_idx] < 999.0f;
				if (!top_filled && !bot_filled) continue;
				Pixel top          = self.model.pixels[top_idx];
				Pixel bot          = self.model.pixels[bot_idx];
				sz cidx            = (sz)(ty * w + tx);
				xray::Color fg_col = top_filled ? xray::color_rgb(top.r, top.g, top.b) : xray::color_rgb(0, 0, 0);
				xray::Color bg_col = bot_filled ? xray::color_rgb(bot.r, bot.g, bot.b) : xray::color_rgb(0, 0, 0);
				xray::Style style  = xray::default_style().set_fg(fg_col).set_bg(bg_col);
				self.model.cells[cidx] = xray::new_cell("\xe2\x96\x80", 1, style);
			}
		}

		return tea::new_alt_cell_view(self.model.cells, (sz)w, (sz)h);
	}

	// Fallback: loading screen
	xray::Cell[] cells = mem::new_array(xray::Cell, (sz)(w * h));
	defer mem::free(cells.ptr);
	xray::Style base_style = xray::default_style();
	xray::Style txt_style  = base_style.set_fg(xray::color_rgb((char)200, (char)200, (char)200));
	for (sz i = 0; i < (sz)(w * h); i++) cells[i] = xray::empty_cell();
	String msg    = "Loading...";
	xray::Cell lc = xray::new_cell(msg, (char)msg.len, txt_style);
	int start_x   = (w - (int)msg.len) / 2;
	if (start_x >= 0 && start_x + (int)msg.len <= w) {
		for (sz i = 0; i < msg.len; i++) {
			cells[(sz)(h / 2) * w + (sz)(start_x) + i] = xray::new_cell(msg[i:1], 1, txt_style);
		}
	}
	return tea::new_alt_cell_view(cells, (sz)w, (sz)h);
}

// ── main ─────────────────────────────────────────────────────────────────────

fn int main() {
	App* app = mem::new(App);
	tea::enable_mouse();
	if (catch err = tea::@run_program(app)) {
		tea::disable_mouse();
		io::printfn("Error: %s", err);
		return 1;
	}
	tea::disable_mouse();
	mem::free(app);
	return 0;
}