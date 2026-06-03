module glb;

import stb_json;
import std::io;
import std::math;
import std::os;

// ── Vec3 ─────────────────────────────────────────────────────────────────────

struct Vec3 {
	float x;
	float y;
	float z;
}

fn Vec3 vec3(float x, float y, float z) => (Vec3) { x, y, z };

// ── Geometry ─────────────────────────────────────────────────────────────────

struct Pixel {
	char r;
	char g;
	char b;
}

struct Triangle {
	Vec3 v0;
	Vec3 v1;
	Vec3 v2;
	Vec3 normal;
	char r;
	char g;
	char b;
}

const int MAX_TRIANGLES = 65536;
const int MAX_MATERIALS = 128;

struct GlbModel {
	Triangle[MAX_TRIANGLES] triangles;
	int triangle_count;
	int width;
	int height;
	int frame;
	Pixel[] pixels;
	float[] depth;
	float model_yaw;
	float model_pitch;
	float cam_px;
	float cam_py;
	float cam_pz;
	float cam_yaw;
	float cam_pitch;
}

// ── GLB loading ──────────────────────────────────────────────────────────────

faultdef GLB_OPEN_FAILED, GLB_BAD_MAGIC, GLB_JSON_ERROR;

struct AccessorInfo {
	int bv_index;
	int byte_offset;
	int count;
	int component_type;
}

struct BufferViewInfo {
	int byte_offset;
	int byte_length;
	int byte_stride;
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

	uint json_len  = read_u32(raw, 12);
	char* json_buf = raw + 20;
	sz bin_chunk_start = 20 + (sz)json_len;
	char* bin          = raw + bin_chunk_start + 8;

	stb_json::Cursor root = stb_json::stbj_load_buffer(json_buf, json_len);
	if (stb_json::stbj_any_error(&root) != 0) return GLB_JSON_ERROR~;

	stb_json::Cursor meshes = stb_json::stbj_move_cursor_name(&root, "meshes");
	int mesh_count = stb_json::stbj_count_values(&meshes);

	stb_json::Cursor accessors = stb_json::stbj_move_cursor_name(&root, "accessors");
	stb_json::Cursor bvs       = stb_json::stbj_move_cursor_name(&root, "bufferViews");

	// Parse materials
	char[MAX_MATERIALS * 3] mat_color;
	char[MAX_MATERIALS] mat_present;
	for (int mi = 0; mi < MAX_MATERIALS; mi++) mat_present[mi] = (char)0;
	stb_json::Cursor materials = stb_json::stbj_move_cursor_name(&root, "materials");
	int mat_count = stb_json::stbj_count_values(&materials);
	if (mat_count > MAX_MATERIALS) mat_count = MAX_MATERIALS;
	for (int mi = 0; mi < mat_count; mi++) {
		stb_json::Cursor mat = stb_json::stbj_move_cursor_index(&materials, mi);
		stb_json::Cursor pbr = stb_json::stbj_move_cursor_name(&mat, "pbrMetallicRoughness");
		if (stb_json::stbj_any_error(&pbr) != 0) {
			mat_color[mi * 3] = (char)255;
			mat_color[mi * 3 + 1] = (char)255;
			mat_color[mi * 3 + 2] = (char)255;
			mat_present[mi] = (char)1;
			continue;
		}
		stb_json::Cursor bcf = stb_json::stbj_move_cursor_name(&pbr, "baseColorFactor");
		if (stb_json::stbj_any_error(&bcf) != 0) {
			mat_color[mi * 3] = (char)255;
			mat_color[mi * 3 + 1] = (char)255;
			mat_color[mi * 3 + 2] = (char)255;
			mat_present[mi] = (char)1;
			continue;
		}
		mat_color[mi * 3]     = (char)(stb_json::stbj_read_double_index(&bcf, 0, 1.0) * 255.0);
		mat_color[mi * 3 + 1] = (char)(stb_json::stbj_read_double_index(&bcf, 1, 1.0) * 255.0);
		mat_color[mi * 3 + 2] = (char)(stb_json::stbj_read_double_index(&bcf, 2, 1.0) * 255.0);
		mat_present[mi] = (char)1;
	}

	// First pass: bounding box
	float min_x = 1e9f; float max_x = -1e9f;
	float min_y = 1e9f; float max_y = -1e9f;
	float min_z = 1e9f; float max_z = -1e9f;

	for (int mi = 0; mi < mesh_count; mi++) {
		stb_json::Cursor mesh  = stb_json::stbj_move_cursor_index(&meshes, mi);
		stb_json::Cursor prims = stb_json::stbj_move_cursor_name(&mesh, "primitives");
		int prim_count = stb_json::stbj_count_values(&prims);
		for (int pi = 0; pi < prim_count; pi++) {
			stb_json::Cursor prim  = stb_json::stbj_move_cursor_index(&prims, pi);
			stb_json::Cursor attrs = stb_json::stbj_move_cursor_name(&prim, "attributes");
			int pos_acc_idx = stb_json::stbj_read_int_name(&attrs, "POSITION", -1);
			if (pos_acc_idx < 0) continue;
			AccessorInfo pa;
			parse_accessor(&accessors, pos_acc_idx, &pa);
			BufferViewInfo pbv;
			parse_bufview(&bvs, pa.bv_index, &pbv);
			sz pbase   = (sz)(pbv.byte_offset + pa.byte_offset);
			sz pstride = (sz)(pbv.byte_stride > 0 ? pbv.byte_stride : 12);
			for (int i = 0; i < pa.count; i++) {
				sz base = pbase + (sz)i * pstride;
				float x = read_f32(bin, base);
				float y = read_f32(bin, base + 4);
				float z = read_f32(bin, base + 8);
				if (x < min_x) min_x = x; if (x > max_x) max_x = x;
				if (y < min_y) min_y = y; if (y > max_y) max_y = y;
				if (z < min_z) min_z = z; if (z > max_z) max_z = z;
			}
		}
	}

	float center_x = (min_x + max_x) / 2.0f;
	float center_y = (min_y + max_y) / 2.0f;
	float center_z = (min_z + max_z) / 2.0f;
	float span_x = max_x - min_x;
	float span_y = max_y - min_y;
	float span_z = max_z - min_z;
	float max_span = span_x;
	if (span_y > max_span) max_span = span_y;
	if (span_z > max_span) max_span = span_z;
	float scale = (max_span > 0.0f) ? (10.0f / max_span) : 1.0f;

	// Second pass: load triangles
	GlbModel* model = mem::new(GlbModel);
	model.triangle_count = 0;

	for (int mi = 0; mi < mesh_count; mi++) {
		stb_json::Cursor mesh  = stb_json::stbj_move_cursor_index(&meshes, mi);
		stb_json::Cursor prims = stb_json::stbj_move_cursor_name(&mesh, "primitives");
		int prim_count = stb_json::stbj_count_values(&prims);
		for (int pi = 0; pi < prim_count; pi++) {
			if (model.triangle_count >= MAX_TRIANGLES) break;
			stb_json::Cursor prim  = stb_json::stbj_move_cursor_index(&prims, pi);
			stb_json::Cursor attrs = stb_json::stbj_move_cursor_name(&prim, "attributes");
			int pos_acc_idx = stb_json::stbj_read_int_name(&attrs, "POSITION", -1);
			int idx_acc_idx = stb_json::stbj_read_int_name(&prim, "indices", -1);
			int mat_idx     = stb_json::stbj_read_int_name(&prim, "material", -1);
			int uv_acc_idx  = stb_json::stbj_read_int_name(&attrs, "TEXCOORD_0", -1);
			if (pos_acc_idx < 0 || idx_acc_idx < 0) continue;

			AccessorInfo pos_acc; parse_accessor(&accessors, pos_acc_idx, &pos_acc);
			AccessorInfo idx_acc; parse_accessor(&accessors, idx_acc_idx, &idx_acc);
			BufferViewInfo pos_bv; parse_bufview(&bvs, pos_acc.bv_index, &pos_bv);
			BufferViewInfo idx_bv; parse_bufview(&bvs, idx_acc.bv_index, &idx_bv);

			sz pos_base   = (sz)(pos_bv.byte_offset + pos_acc.byte_offset);
			sz pos_stride = (sz)(pos_bv.byte_stride > 0 ? pos_bv.byte_stride : 12);
			sz idx_base   = (sz)(idx_bv.byte_offset + idx_acc.byte_offset);
			bool idx32    = (idx_acc.component_type == 5125);

			bool has_uv  = (uv_acc_idx >= 0);
			sz uv_base   = 0;
			sz uv_stride = 8;
			if (has_uv) {
				AccessorInfo uv_acc; parse_accessor(&accessors, uv_acc_idx, &uv_acc);
				BufferViewInfo uv_bv; parse_bufview(&bvs, uv_acc.bv_index, &uv_bv);
				uv_base   = (sz)(uv_bv.byte_offset + uv_acc.byte_offset);
				uv_stride = (sz)(uv_bv.byte_stride > 0 ? uv_bv.byte_stride : 8);
			}

			int tri_count = idx_acc.count / 3;
			for (int ti = 0; ti < tri_count; ti++) {
				if (model.triangle_count >= MAX_TRIANGLES) break;
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

				float v0x = (read_f32(bin, b0) - center_x) * scale;
				float v0y = (read_f32(bin, b0 + 8) - center_z) * scale;
				float v0z = (read_f32(bin, b0 + 4) - center_y) * scale;
				float v1x = (read_f32(bin, b1) - center_x) * scale;
				float v1y = (read_f32(bin, b1 + 8) - center_z) * scale;
				float v1z = (read_f32(bin, b1 + 4) - center_y) * scale;
				float v2x = (read_f32(bin, b2) - center_x) * scale;
				float v2y = (read_f32(bin, b2 + 8) - center_z) * scale;
				float v2z = (read_f32(bin, b2 + 4) - center_y) * scale;

				float e1x = v1x - v0x; float e1y = v1y - v0y; float e1z = v1z - v0z;
				float e2x = v2x - v0x; float e2y = v2y - v0y; float e2z = v2z - v0z;
				float nx = e1y * e2z - e1z * e2y;
				float ny = e1z * e2x - e1x * e2z;
				float nz = e1x * e2y - e1y * e2x;
				float nl = (float)math::sqrt(nx * nx + ny * ny + nz * nz);
				if (nl > 0.0f) { nx /= nl; ny /= nl; nz /= nl; }
				nx = -nx; ny = -ny; nz = -nz;

				char cr = (char)180; char cg = (char)180; char cb = (char)200;
				if (mat_idx >= 0 && mat_idx < MAX_MATERIALS && mat_present[mat_idx] != 0) {
					cr = mat_color[mat_idx * 3];
					cg = mat_color[mat_idx * 3 + 1];
					cb = mat_color[mat_idx * 3 + 2];
				} else if (has_uv) {
					float u     = read_f32(bin, uv_base + (sz)i0 * uv_stride);
					int pal_idx = (int)(u * 255.0f + 0.5f);
					if (pal_idx < 0) pal_idx = 0;
					if (pal_idx > 255) pal_idx = 255;
					float t = (float)pal_idx / 255.0f;
					cr = (char)(180.0f + t * 50.0f);
					cg = (char)(180.0f + t * 20.0f);
					cb = (char)(200.0f + t * 30.0f);
				}

				model.triangles[model.triangle_count++] = {
					.v0 = vec3(v0x, v0y, v0z),
					.v1 = vec3(v1x, v1y, v1z),
					.v2 = vec3(v2x, v2y, v2z),
					.normal = vec3(nx, ny, nz),
					.r = cr, .g = cg, .b = cb,
				};
			}
		}
	}

	model.width = 80;
	model.height = 24;
	model.pixels = mem::new_array(Pixel, (sz)(model.width * model.height * 2));
	model.depth  = mem::new_array(float, (sz)(model.width * model.height * 2));
	return model;
}

fn void GlbModel.free(GlbModel* self) {
	mem::free(self.pixels.ptr);
	mem::free(self.depth.ptr);
}

fn void GlbModel.resize(GlbModel* self, int w, int h) {
	self.width = w;
	self.height = h;
	mem::free(self.pixels.ptr);
	mem::free(self.depth.ptr);
	self.pixels = mem::new_array(Pixel, (sz)(w * h * 2));
	self.depth  = mem::new_array(float, (sz)(w * h * 2));
}

// ── Rasterizer ───────────────────────────────────────────────────────────────

fn float edge_fn(float ax, float ay, float bx, float by, float px, float py) {
	return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

fn void GlbModel.rasterize_tri(GlbModel* self, int w, int ph,
		float ax, float ay, float bbx, float bby, float ccx, float ccy,
		float depth_z, Pixel col) {
	float area = edge_fn(ax, ay, bbx, bby, ccx, ccy);
	if (area == 0.0f) return;
	if (area < 0.0f) {
		float tx = bbx; bbx = ccx; ccx = tx;
		float ty = bby; bby = ccy; ccy = ty;
		area = -area;
	}

	float min_xx = ax; if (bbx < min_xx) min_xx = bbx; if (ccx < min_xx) min_xx = ccx;
	float max_xx = ax; if (bbx > max_xx) max_xx = bbx; if (ccx > max_xx) max_xx = ccx;
	float min_yy = ay; if (bby < min_yy) min_yy = bby; if (ccy < min_yy) min_yy = ccy;
	float max_yy = ay; if (bby > max_yy) max_yy = bby; if (ccy > max_yy) max_yy = ccy;

	int x0 = (int)math::floor(min_xx); if (x0 < 0) x0 = 0;
	int x1 = (int)math::ceil(max_xx);  if (x1 >= w) x1 = w - 1;
	int y0 = (int)math::floor(min_yy); if (y0 < 0) y0 = 0;
	int y1 = (int)math::ceil(max_yy);  if (y1 >= ph) y1 = ph - 1;
	if (x0 > x1 || y0 > y1) return;

	bool tl_ab = (ay == bby && bbx > ax) || (bby < ay);
	bool tl_bc = (bby == ccy && ccx > bbx) || (ccy < bby);
	bool tl_ca = (ccy == ay && ax > ccx) || (ay < ccy);
	float bias_ab = tl_ab ? 0.0f : -0.0001f;
	float bias_bc = tl_bc ? 0.0f : -0.0001f;
	float bias_ca = tl_ca ? 0.0f : -0.0001f;

	for (int py = y0; py <= y1; py++) {
		float pcy = (float)py + 0.5f;
		for (int px = x0; px <= x1; px++) {
			float pcx = (float)px + 0.5f;
			if (edge_fn(ax, ay, bbx, bby, pcx, pcy) + bias_ab < 0.0f) continue;
			if (edge_fn(bbx, bby, ccx, ccy, pcx, pcy) + bias_bc < 0.0f) continue;
			if (edge_fn(ccx, ccy, ax, ay, pcx, pcy) + bias_ca < 0.0f) continue;
			sz idx = (sz)(py * w + px);
			if (depth_z < self.depth[idx]) {
				self.depth[idx] = depth_z;
				self.pixels[idx] = col;
			}
		}
	}
}

// ── 3D rendering ─────────────────────────────────────────────────────────────

fn void GlbModel.render(GlbModel* self) {
	int w  = self.width;
	int h  = self.height;
	int ph = h * 2;
	sz ptotal = (sz)(w * ph);

	for (sz i = 0; i < ptotal; i++) {
		self.pixels[i] = (Pixel) { 0, 0, 0 };
		self.depth[i] = 1000.0f;
	}

	float fov = 30.0f;
	float cx  = (float)w / 2.0f;
	float cy  = (float)ph / 2.0f;

	float cos_yaw   = (float)math::cos(self.cam_yaw);
	float sin_yaw   = (float)math::sin(self.cam_yaw);
	float cos_pitch = (float)math::cos(self.cam_pitch);
	float sin_pitch = (float)math::sin(self.cam_pitch);
	float cos_myaw   = (float)math::cos(self.model_yaw);
	float sin_myaw   = (float)math::sin(self.model_yaw);
	float cos_mpitch = (float)math::cos(self.model_pitch);
	float sin_mpitch = (float)math::sin(self.model_pitch);

	float light_x = 0.4f; float light_y = 0.8f; float light_z = -0.5f;
	float light_len = (float)math::sqrt(light_x * light_x + light_y * light_y + light_z * light_z);
	light_x /= light_len; light_y /= light_len; light_z /= light_len;

	for (int t = 0; t < self.triangle_count; t++) {
		Triangle* tri = &self.triangles[t];

		// Model rotation
		float mx0 = cos_myaw * tri.v0.x - sin_myaw * tri.v0.z;
		float my0 = tri.v0.y;
		float mz0 = sin_myaw * tri.v0.x + cos_myaw * tri.v0.z;
		float mx1 = cos_myaw * tri.v1.x - sin_myaw * tri.v1.z;
		float my1 = tri.v1.y;
		float mz1 = sin_myaw * tri.v1.x + cos_myaw * tri.v1.z;
		float mx2 = cos_myaw * tri.v2.x - sin_myaw * tri.v2.z;
		float my2 = tri.v2.y;
		float mz2 = sin_myaw * tri.v2.x + cos_myaw * tri.v2.z;

		float mx0p = mx0;
		float my0p = cos_mpitch * my0 - sin_mpitch * mz0;
		float mz0p = sin_mpitch * my0 + cos_mpitch * mz0;
		float mx1p = mx1;
		float my1p = cos_mpitch * my1 - sin_mpitch * mz1;
		float mz1p = sin_mpitch * my1 + cos_mpitch * mz1;
		float mx2p = mx2;
		float my2p = cos_mpitch * my2 - sin_mpitch * mz2;
		float mz2p = sin_mpitch * my2 + cos_mpitch * mz2;

		// Camera transform
		float rx0 = mx0p - self.cam_px;
		float ry0 = my0p - self.cam_py;
		float rz0 = mz0p - self.cam_pz;
		float rx1 = mx1p - self.cam_px;
		float ry1 = my1p - self.cam_py;
		float rz1 = mz1p - self.cam_pz;
		float rx2 = mx2p - self.cam_px;
		float ry2 = my2p - self.cam_py;
		float rz2 = mz2p - self.cam_pz;

		float ax0 = cos_yaw * rx0 - sin_yaw * rz0;
		float ay0 = ry0;
		float az0 = sin_yaw * rx0 + cos_yaw * rz0;
		float ax1 = cos_yaw * rx1 - sin_yaw * rz1;
		float ay1 = ry1;
		float az1 = sin_yaw * rx1 + cos_yaw * rz1;
		float ax2 = cos_yaw * rx2 - sin_yaw * rz2;
		float ay2 = ry2;
		float az2 = sin_yaw * rx2 + cos_yaw * rz2;

		float cx0 = ax0;
		float cy0 = cos_pitch * ay0 + sin_pitch * az0;
		float cz0 = -sin_pitch * ay0 + cos_pitch * az0;
		float cx1 = ax1;
		float cy1 = cos_pitch * ay1 + sin_pitch * az1;
		float cz1 = -sin_pitch * ay1 + cos_pitch * az1;
		float cx2 = ax2;
		float cy2 = cos_pitch * ay2 + sin_pitch * az2;
		float cz2 = -sin_pitch * ay2 + cos_pitch * az2;

		if (cz0 < 0.1f || cz1 < 0.1f || cz2 < 0.1f) continue;

		// Normal for cull + lighting
		float nwx = tri.normal.x;
		float nwy = tri.normal.y;
		float nwz = tri.normal.z;
		float nmx = cos_myaw * nwx - sin_myaw * nwz;
		float nmy = nwy;
		float nmz = sin_myaw * nwx + cos_myaw * nwz;
		float npx = nmx;
		float npy = cos_mpitch * nmy - sin_mpitch * nmz;
		float npz = sin_mpitch * nmy + cos_mpitch * nmz;
		float nax = cos_yaw * npx - sin_yaw * npz;
		float nay = npy;
		float naz = sin_yaw * npx + cos_yaw * npz;
		float ncz = -sin_pitch * nay + cos_pitch * naz;
		if (ncz > 0.0f) continue;

		float diff = npx * light_x + npy * light_y + npz * light_z;
		if (diff < 0.0f) diff = 0.0f;
		float brightness = 0.30f + 0.70f * diff;

		Pixel col = {
			(char)((float)tri.r * brightness),
			(char)((float)tri.g * brightness),
			(char)((float)tri.b * brightness),
		};

		float scx0 = (fov / cz0) * cx0 * 2.0f;
		float scy0 = (fov / cz0) * -cy0 * 2.0f;
		float scx1 = (fov / cz1) * cx1 * 2.0f;
		float scy1 = (fov / cz1) * -cy1 * 2.0f;
		float scx2 = (fov / cz2) * cx2 * 2.0f;
		float scy2 = (fov / cz2) * -cy2 * 2.0f;

		float avg_z = (cz0 + cz1 + cz2) / 3.0f;
		self.rasterize_tri(w, ph, scx0 + cx, scy0 + cy, scx1 + cx, scy1 + cy, scx2 + cx, scy2 + cy, avg_z, col);
	}
}
