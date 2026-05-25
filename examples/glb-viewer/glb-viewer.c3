module glb_viewer;

import milktea;
import xray;
import glaze;
import stb_json;
import std::io;
import std::math;
import std::os;
import std::core::dstring;
import std::core::string;

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

// ── Triangle (per-face polygon) ───────────────────────────────────────────────

struct Triangle {
	Vec3 v0;
	Vec3 v1;
	Vec3 v2;
	Vec3 normal; // world-space face normal
	char r;
	char g;
	char b;
}

struct Pixel {
	char r;
	char g;
	char b;
}

// ── GLB geometry ─────────────────────────────────────────────────────────────

const int MAX_TRIANGLES = 65536;


struct GlbModel {
	Triangle[MAX_TRIANGLES] triangles;
	int triangle_count;
	int width;
	int height;
	int frame;
	xray::Cell[] cells;
	Pixel[] pixels;
	float[] depth;
	// camera — set by App before each view() call
	float cam_px;
	float cam_py;
	float cam_pz;
	float cam_yaw;
	float cam_pitch;
	float model_yaw;
	float model_pitch;
}

// ── GLB loading ───────────────────────────────────────────────────────────────

faultdef GLB_OPEN_FAILED, GLB_BAD_MAGIC, GLB_JSON_ERROR, GLB_MESH_NOT_FOUND;

struct AccessorInfo {
	int bv_index;
	int byte_offset;
	int count;
	int component_type; // 5126=float32, 5125=uint32, 5123=uint16
}

struct BufferViewInfo {
	int byte_offset;
	int byte_length;
	int byte_stride;
}

// Read a little-endian uint32 from a byte buffer at offset
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
	// Read entire file
	char[]? data_opt = file::load(mem, path);
	if (catch data_opt) return GLB_OPEN_FAILED~;
	char[] data = (char[])data_opt;
	char* raw   = data.ptr;
	defer mem::free(raw);

	// Validate magic "glTF"
	if (raw[0] != 'g' || raw[1] != 'l' || raw[2] != 'T' || raw[3] != 'F') {
		return GLB_BAD_MAGIC~;
	}

	// JSON chunk: bytes 12-15 = chunkLength, data starts at byte 20
	uint json_len  = read_u32(raw, 12);
	char* json_buf = raw + 20;

	// Binary chunk follows JSON chunk: skip chunkLength(4) + chunkType(4)
	sz bin_chunk_start = 20 + (sz)json_len;
	char* bin          = raw + bin_chunk_start + 8;

	// Parse JSON
	stb_json::Cursor root = stb_json::stbj_load_buffer(json_buf, json_len);
	if (stb_json::stbj_any_error(&root) != 0) {
		return GLB_JSON_ERROR~;
	}

	// Navigate to meshes array
	stb_json::Cursor meshes = stb_json::stbj_move_cursor_name(&root, "meshes");
	int mesh_count          = stb_json::stbj_count_values(&meshes);

	stb_json::Cursor accessors = stb_json::stbj_move_cursor_name(&root, "accessors");
	stb_json::Cursor bvs       = stb_json::stbj_move_cursor_name(&root, "bufferViews");

	// ── First pass: compute global bounding box from all primitives ─────────

	float min_x =  1e9f;
	float max_x = -1e9f;
	float min_y =  1e9f;
	float max_y = -1e9f;
	float min_z =  1e9f;
	float max_z = -1e9f;

	for (int mi = 0; mi < mesh_count; mi++) {
		stb_json::Cursor mesh  = stb_json::stbj_move_cursor_index(&meshes, mi);
		stb_json::Cursor prims = stb_json::stbj_move_cursor_name(&mesh, "primitives");
		int prim_count         = stb_json::stbj_count_values(&prims);

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
				if (x < min_x) min_x = x;
				if (x > max_x) max_x = x;
				if (y < min_y) min_y = y;
				if (y > max_y) max_y = y;
				if (z < min_z) min_z = z;
				if (z > max_z) max_z = z;
			}
		}
	}

	float center_x = (min_x + max_x) / 2.0f;
	float center_y = (min_y + max_y) / 2.0f;
	float center_z = (min_z + max_z) / 2.0f;

	// Normalize model so its longest axis spans ~10 units
	float span_x   = max_x - min_x;
	float span_y   = max_y - min_y;
	float span_z   = max_z - min_z;
	float max_span = span_x;
	if (span_y > max_span) max_span = span_y;
	if (span_z > max_span) max_span = span_z;
	float scale = (max_span > 0.0f) ? (10.0f / max_span) : 1.0f;

	// ── Second pass: load triangles from all primitives ─────────────────────

	GlbModel* model = mem::new(GlbModel);
	model.triangle_count = 0;

	for (int mi = 0; mi < mesh_count; mi++) {
		stb_json::Cursor mesh  = stb_json::stbj_move_cursor_index(&meshes, mi);
		stb_json::Cursor prims = stb_json::stbj_move_cursor_name(&mesh, "primitives");
		int prim_count         = stb_json::stbj_count_values(&prims);

		for (int pi = 0; pi < prim_count; pi++) {
			if (model.triangle_count >= MAX_TRIANGLES) break;

			stb_json::Cursor prim  = stb_json::stbj_move_cursor_index(&prims, pi);
			stb_json::Cursor attrs = stb_json::stbj_move_cursor_name(&prim, "attributes");
			int pos_acc_idx = stb_json::stbj_read_int_name(&attrs, "POSITION", -1);
			int idx_acc_idx = stb_json::stbj_read_int_name(&prim, "indices", -1);
			int uv_acc_idx  = stb_json::stbj_read_int_name(&attrs, "TEXCOORD_0", -1);
			if (pos_acc_idx < 0 || idx_acc_idx < 0) continue;

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

				float e1x = v1x - v0x;
				float e1y = v1y - v0y;
				float e1z = v1z - v0z;
				float e2x = v2x - v0x;
				float e2y = v2y - v0y;
				float e2z = v2z - v0z;
				float nx  = e1y * e2z - e1z * e2y;
				float ny  = e1z * e2x - e1x * e2z;
				float nz  = e1x * e2y - e1y * e2x;
				float nl  = (float)math::sqrt(nx * nx + ny * ny + nz * nz);
				if (nl > 0.0f) { nx /= nl; ny /= nl; nz /= nl; }
				// Y/Z swap inverts handedness — negate to restore correct orientation
				nx = -nx; ny = -ny; nz = -nz;

				char cr = (char)180;
				char cg = (char)180;
				char cb = (char)200;
				if (has_uv) {
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
					.r = cr,
					.g = cg,
					.b = cb,
				};
			}
		}
	}

	// Allocate render buffers
	model.width = 80;
	model.height = 24;
	model.cells = mem::new_array(xray::Cell, (sz)(model.width * model.height));
	model.pixels = mem::new_array(Pixel, (sz)(model.width * model.height * 2));
	model.depth = mem::new_array(float, (sz)(model.width * model.height * 2));

	return model;
}

// ── Tea model callbacks ───────────────────────────────────────────────────────

GlbModel* g_model = null;

fn milktea::Cmd GlbModel.init(GlbModel* self) @dynamic {
	milktea::Cmd[] cmds = { milktea::tick() };
	return milktea::batch(cmds);
}

fn milktea::Cmd GlbModel.update(GlbModel* self, milktea::Msg msg) @dynamic {
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

	return null;
}

// Edge function: positive on one side of the line A→B, negative on the other.
fn float edge_fn(float ax, float ay, float bx, float by, float px, float py) {
	return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

// Rasterize a triangle using top-left fill convention so coplanar adjacent
// triangles tile exactly without double-shading shared edges.
fn void rasterize_tri(
	GlbModel* self,
	int w,
	int ph,
	float ax,
	float ay,
	float bx,
	float by,
	float cx,
	float cy,
	float depth_z,
	Pixel col
) {
	// Determine winding via the triangle's signed area.
	float area = edge_fn(ax, ay, bx, by, cx, cy);
	if (area == 0.0f) return;

	// Make winding positive so the inside is where all edge functions are >= 0.
	if (area < 0.0f) {
		float tx = bx;
		float ty = by;
		bx = cx;
		by = cy;
		cx = tx;
		cy = ty;
		area = -area;
	}

	// Bounding box in pixel space, clipped to viewport.
	float min_x = ax;
	if (bx < min_x) min_x = bx;
	if (cx < min_x) min_x = cx;
	float max_x = ax;
	if (bx > max_x) max_x = bx;
	if (cx > max_x) max_x = cx;
	float min_y = ay;
	if (by < min_y) min_y = by;
	if (cy < min_y) min_y = cy;
	float max_y = ay;
	if (by > max_y) max_y = by;
	if (cy > max_y) max_y = cy;

	int x0 = (int)math::floor(min_x);
	if (x0 < 0) x0 = 0;
	int x1 = (int)math::ceil(max_x);
	if (x1 >= w) x1 = w - 1;
	int y0 = (int)math::floor(min_y);
	if (y0 < 0) y0 = 0;
	int y1 = (int)math::ceil(max_y);
	if (y1 >= ph) y1 = ph - 1;
	if (x0 > x1 || y0 > y1) return;

	// Top-left fill rule: for each edge, decide whether points exactly on it count.
	// An edge counts if it's a "top" edge (horizontal, going right) or a "left"
	// edge (going down). This guarantees each pixel-center is owned by exactly
	// one triangle when triangles share an edge.
	bool tl_ab    = (ay == by && bx > ax) || (by < ay);
	bool tl_bc    = (by == cy && cx > bx) || (cy < by);
	bool tl_ca    = (cy == ay && ax > cx) || (ay < cy);
	float bias_ab = tl_ab ? 0.0f : -0.0001f;
	float bias_bc = tl_bc ? 0.0f : -0.0001f;
	float bias_ca = tl_ca ? 0.0f : -0.0001f;

	for (int py = y0; py <= y1; py++) {
		float pcy = (float)py + 0.5f;
		for (int px = x0; px <= x1; px++) {
			float pcx = (float)px + 0.5f;
			float e0  = edge_fn(ax, ay, bx, by, pcx, pcy) + bias_ab;
			float e1  = edge_fn(bx, by, cx, cy, pcx, pcy) + bias_bc;
			float e2  = edge_fn(cx, cy, ax, ay, pcx, pcy) + bias_ca;
			if (e0 < 0.0f || e1 < 0.0f || e2 < 0.0f) continue;
			sz idx = (sz)(py * w + px);
			if (depth_z < self.depth[idx]) {
				self.depth[idx] = depth_z;
				self.pixels[idx] = col;
			}
		}
	}
}

fn milktea::View GlbModel.view(GlbModel* self) @dynamic {
	int w     = self.width;
	int h     = self.height;
	int ph    = h * 2;
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

	float light_x   =  0.4f;
	float light_y   =  0.8f;
	float light_z   = -0.5f;
	float light_len =  (float)math::sqrt(light_x * light_x + light_y * light_y + light_z * light_z);
	light_x /= light_len;
	light_y /= light_len;
	light_z /= light_len;

	for (int t = 0; t < self.triangle_count; t++) {
		Triangle* tri = &self.triangles[t];

		// Step 1: Rotate model by model_yaw (Y) then model_pitch (X)
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

		// Step 2: Translate to camera space
		float rx0 = mx0p - self.cam_px;
		float ry0 = my0p - self.cam_py;
		float rz0 = mz0p - self.cam_pz;
		float rx1 = mx1p - self.cam_px;
		float ry1 = my1p - self.cam_py;
		float rz1 = mz1p - self.cam_pz;
		float rx2 = mx2p - self.cam_px;
		float ry2 = my2p - self.cam_py;
		float rz2 = mz2p - self.cam_pz;

		// Step 3: Camera yaw rotation (inverse of camera orientation)
		float ax0 = cos_yaw * rx0 - sin_yaw * rz0;
		float ay0 = ry0;
		float az0 = sin_yaw * rx0 + cos_yaw * rz0;
		float ax1 = cos_yaw * rx1 - sin_yaw * rz1;
		float ay1 = ry1;
		float az1 = sin_yaw * rx1 + cos_yaw * rz1;
		float ax2 = cos_yaw * rx2 - sin_yaw * rz2;
		float ay2 = ry2;
		float az2 = sin_yaw * rx2 + cos_yaw * rz2;

		// Step 4: Camera pitch rotation
		float cx0 = ax0;
		float cy0 =  cos_pitch * ay0 + sin_pitch * az0;
		float cz0 = -sin_pitch * ay0 + cos_pitch * az0;
		float cx1 = ax1;
		float cy1 =  cos_pitch * ay1 + sin_pitch * az1;
		float cz1 = -sin_pitch * ay1 + cos_pitch * az1;
		float cx2 = ax2;
		float cy2 =  cos_pitch * ay2 + sin_pitch * az2;
		float cz2 = -sin_pitch * ay2 + cos_pitch * az2;

		// Near-clip check before projection
		if (cz0 < 0.1f || cz1 < 0.1f || cz2 < 0.1f) continue;

		// Rotate world-space normal through model then camera for back-face cull
		float nwx = tri.normal.x;
		float nwy = tri.normal.y;
		float nwz = tri.normal.z;
		// Model rotation
		float nmx = cos_myaw * nwx - sin_myaw * nwz;
		float nmy = nwy;
		float nmz = sin_myaw * nwx + cos_myaw * nwz;
		float npx = nmx;
		float npy = cos_mpitch * nmy - sin_mpitch * nmz;
		float npz = sin_mpitch * nmy + cos_mpitch * nmz;
		// Camera rotation
		float nax =  cos_yaw * npx - sin_yaw * npz;
		float nay =  npy;
		float naz =  sin_yaw * npx + cos_yaw * npz;
		float ncz = -sin_pitch * nay + cos_pitch * naz;
		if (ncz > 0.0f) continue;

		// Fixed world-space light — use model-rotated normal
		float diff = npx * light_x + npy * light_y + npz * light_z;
		if (diff < 0.0f) diff = 0.0f;
		float brightness = 0.30f + 0.70f * diff;

		Pixel col = {
			(char)((float)tri.r * brightness),
			(char)((float)tri.g * brightness),
			(char)((float)tri.b * brightness),
		};

		// Project to screen
		float scx0 = (fov / cz0) * cx0 * 2.0f;
		float scy0 = (fov / cz0) * -cy0 * 2.0f;
		float scx1 = (fov / cz1) * cx1 * 2.0f;
		float scy1 = (fov / cz1) * -cy1 * 2.0f;
		float scx2 = (fov / cz2) * cx2 * 2.0f;
		float scy2 = (fov / cz2) * -cy2 * 2.0f;

		float sx0 = scx0 + cx;
		float sy0 = scy0 + cy;
		float sx1 = scx1 + cx;
		float sy1 = scy1 + cy;
		float sx2 = scx2 + cx;
		float sy2 = scy2 + cy;

		// Use average depth for z-buffer
		float avg_z = (cz0 + cz1 + cz2) / 3.0f;
		rasterize_tri(self, w, ph, sx0, sy0, sx1, sy1, sx2, sy2, avg_z, col);
	}

	// Combine into half-block cells
	for (sz i = 0; i < (sz)(w * h); i++) self.cells[i] = xray::empty_cell();
	for (int ty = 0; ty < h; ty++) {
		for (int tx = 0; tx < w; tx++) {
			sz top_idx      = (sz)((ty * 2) * w + tx);
			sz bot_idx      = (sz)((ty * 2 + 1) * w + tx);
			bool top_filled = self.depth[top_idx] < 999.0f;
			bool bot_filled = self.depth[bot_idx] < 999.0f;
			if (!top_filled && !bot_filled) continue;
			Pixel top          = self.pixels[top_idx];
			Pixel bot          = self.pixels[bot_idx];
			sz cidx            = (sz)(ty * w + tx);
			xray::Color fg_col = top_filled ? xray::color_rgb(top.r, top.g, top.b) : xray::color_rgb(0, 0, 0);
			xray::Color bg_col = bot_filled ? xray::color_rgb(bot.r, bot.g, bot.b) : xray::color_rgb(0, 0, 0);
			xray::Style style  = xray::default_style().set_fg(fg_col).set_bg(bg_col);
			self.cells[cidx] = xray::new_cell("\xe2\x96\x80", 1, style); // ▀
		}
	}

	return milktea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

// ── File picker ───────────────────────────────────────────────────────────────

const int MAX_FILES = 256;

enum AppMode {
	PICKING,
	VIEWING
}

struct App {
	AppMode mode;
	// picker state
	String[MAX_FILES] files;
	int file_count;
	int cursor;
	int scroll;
	int width;
	int height;
	String error_msg;
	// viewer
	GlbModel* model;
	// free-fly camera
	float cam_px;
	float cam_py;
	float cam_pz;
	float cam_yaw;
	float cam_pitch;
	float model_yaw;
	float model_pitch;
	float vel_fwd;
	float vel_up;
	float vel_yaw;
	float vel_pitch;
	float vel_pan;
	bool auto_rotate;
	// mouse state
	bool dragging;
	int drag_start_x;
	int drag_start_y;
	float drag_start_yaw;
	float drag_start_pitch;
	// last frame each key was seen (key repeat simulates held state)
	int key_w;
	int key_s;
	int key_a;
	int key_d;
	int key_q;
	int key_e;
	int key_left;
	int key_right;
	int key_up;
	int key_down;
	int tick_count;
}

fn void App.free_model(App* self) {
	if (self.model == null) return;
	mem::free(self.model.cells.ptr);
	mem::free(self.model.pixels.ptr);
	mem::free(self.model.depth.ptr);
	mem::free(self.model);
	self.model = null;
}

fn void App.load_file(App* self, String path) {
	self.free_model();
	self.error_msg = "";
	GlbModel*? result = load_glb(path);
	if (catch err = result) {
		self.error_msg = string::tformat("Error loading '%s': %s", path, err);
		return;
	}
	self.model = result;
	self.model.width = self.width;
	self.model.height = self.height;
	mem::free(self.model.cells.ptr);
	mem::free(self.model.pixels.ptr);
	mem::free(self.model.depth.ptr);
	self.model.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.model.pixels = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
	self.model.depth = mem::new_array(float, (sz)(self.width * self.height * 2));
	self.model.frame = 0;
	self.cam_px = 0.0f;
	self.cam_py = 0.0f;
	self.cam_pz = -20.0f;
	self.cam_yaw = 0.0f;
	self.cam_pitch = 0.0f;
	self.model_yaw = 0.0f;
	self.model_pitch = 0.0f;
	self.vel_fwd = 0.0f;
	self.vel_up = 0.0f;
	self.vel_yaw = 0.0f;
	self.vel_pan = 0.0f;
	self.auto_rotate = true;
	self.mode = VIEWING;
}

fn void scan_glb_files(App* self, String dir) {
	self.file_count = 0;
	Path? dp = path::new(tmem, dir);
	if (catch dp) return;
	Path d          = (Path)dp;
	PathList? files = path::ls(tmem, d, no_dirs: true, mask: "*.glb");
	if (catch files) return;
	foreach (p : (PathList)files) {
		if (self.file_count >= MAX_FILES) break;
		String name = (String)p;
		if (!name.ends_with(".glb")) continue;
		self.files[self.file_count++] = name.copy(mem);
	}
}

fn milktea::Cmd App.init(App* self) @dynamic {
	self.width = 80;
	self.height = 24;
	self.mode = PICKING;
	self.cursor = 0;
	self.scroll = 0;
	self.model = null;
	self.error_msg = "";
	self.cam_px = 0.0f;
	self.cam_py = 0.0f;
	self.cam_pz = -20.0f;
	self.cam_yaw = 0.0f;
	self.cam_pitch = 0.0f;
	self.model_yaw = 0.0f;
	self.model_pitch = 0.0f;
	self.vel_fwd = 0.0f;
	self.vel_up = 0.0f;
	self.vel_yaw = 0.0f;
	self.vel_pan = 0.0f;
	self.auto_rotate = true;
	self.dragging = false;
	scan_glb_files(self, ".");
	return null;
}

fn milktea::Cmd App.update(App* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		if (self.model != null) {
			// forward resize to model
			milktea::Msg resize = msg;
			self.model.update(resize);
		}
		return null;
	}

	if (self.mode == VIEWING) {
		if (msg.kind == milktea::MsgKind.MOUSE) {
			if (msg.mouse.action == milktea::MouseAction.MOUSE_PRESS) {
				if (msg.mouse.button == milktea::MouseButton.MOUSE_LEFT) {
					self.dragging = true;
					self.drag_start_x = msg.mouse.col;
					self.drag_start_y = msg.mouse.row;
					self.drag_start_yaw = self.model_yaw;
					self.drag_start_pitch = self.model_pitch;
					self.auto_rotate = false;
				} else if (msg.mouse.button == milktea::MouseButton.MOUSE_WHEEL_UP) {
					float fwd_x =  (float)math::sin(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					float fwd_y = -(float)math::sin(self.cam_pitch);
					float fwd_z =  (float)math::cos(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					self.cam_px += fwd_x * 0.2f;
					self.cam_py += fwd_y * 0.2f;
					self.cam_pz += fwd_z * 0.2f;
				} else if (msg.mouse.button == milktea::MouseButton.MOUSE_WHEEL_DOWN) {
					float fwd_x =  (float)math::sin(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					float fwd_y = -(float)math::sin(self.cam_pitch);
					float fwd_z =  (float)math::cos(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					self.cam_px -= fwd_x * 0.2f;
					self.cam_py -= fwd_y * 0.2f;
					self.cam_pz -= fwd_z * 0.2f;
				}
			} else if (msg.mouse.action == milktea::MouseAction.MOUSE_RELEASE) {
				if (msg.mouse.button == milktea::MouseButton.MOUSE_LEFT) {
					self.dragging = false;
				}
			} else if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION && self.dragging) {
				int total_dx = msg.mouse.col - self.drag_start_x;
				int total_dy = msg.mouse.row - self.drag_start_y;
				self.model_yaw   = self.drag_start_yaw   + (float)total_dx / (float)self.width * 2.0f;
				self.model_pitch = self.drag_start_pitch - (float)total_dy / (float)self.height * 2.0f;
				if (self.model_pitch > 1.4f) self.model_pitch = 1.4f;
				if (self.model_pitch < -1.4f) self.model_pitch = -1.4f;
			}
		}
		if (msg.kind == milktea::MsgKind.KEY) {
			milktea::KeyMsg k = msg.key;
			if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && k.rune == 'b')) {
				self.mode = PICKING;
				return null;
			}
			if (k.code == milktea::KeyCode.CTRL_C || (k.code == milktea::KeyCode.RUNE && k.rune == 'q')) {
				return milktea::quit();
			}
			if (k.code == milktea::KeyCode.RUNE) {
				switch (k.rune) {
					case 'w': self.key_w = self.tick_count; self.auto_rotate = false;
					case 's': self.key_s = self.tick_count; self.auto_rotate = false;
					case 'a': self.key_a = self.tick_count; self.auto_rotate = false;
					case 'd': self.key_d = self.tick_count; self.auto_rotate = false;
					default:
				}
			}
			if (k.code == milktea::KeyCode.UP) {
				self.key_up = self.tick_count;
				self.auto_rotate = false;
			}
			if (k.code == milktea::KeyCode.DOWN) {
				self.key_down = self.tick_count;
				self.auto_rotate = false;
			}
			if (k.code == milktea::KeyCode.LEFT) {
				self.key_left = self.tick_count;
				self.auto_rotate = false;
			}
			if (k.code == milktea::KeyCode.RIGHT) {
				self.key_right = self.tick_count;
				self.auto_rotate = false;
			}
		}
		if (msg.kind == milktea::MsgKind.TICK) {
			self.tick_count++;
			int held_thresh = self.tick_count - 2;
			bool held_w     = self.key_w >= held_thresh;
			bool held_s     = self.key_s >= held_thresh;
			bool held_a     = self.key_a >= held_thresh;
			bool held_d     = self.key_d >= held_thresh;
			bool held_q     = self.key_q >= held_thresh;
			bool held_e     = self.key_e >= held_thresh;
			bool held_left  = self.key_left >= held_thresh;
			bool held_right = self.key_right >= held_thresh;
			bool held_up    = self.key_up >= held_thresh;
			bool held_down  = self.key_down >= held_thresh;

			if (self.model != null) {
				self.model.frame++;
				if (self.auto_rotate) {
					self.model_yaw   = (float)self.model.frame * 0.01f;
					self.model_pitch = (float)math::sin((float)self.model.frame * 0.003) * 0.15f;
				}

				float accel_fwd   = 0.04f;
				float accel_yaw   = 0.008f;
				float accel_pitch = 0.008f;
				float accel_up    = 0.04f;
				float accel_pan   = 0.04f;
				float max_fwd     = 0.4f;
				float max_yaw     = 0.08f;
				float max_pitch   = 0.06f;
				float max_up      = 0.4f;
				float max_pan     = 0.4f;
				float friction    = 0.80f;

				if (held_w) {
					self.vel_fwd += accel_fwd;
					if (self.vel_fwd > max_fwd) self.vel_fwd = max_fwd;
				}
				if (held_s) {
					self.vel_fwd -= accel_fwd;
					if (self.vel_fwd < -max_fwd) self.vel_fwd = -max_fwd;
				}
				if (held_a) {
					self.vel_yaw -= accel_yaw;
					if (self.vel_yaw < -max_yaw) self.vel_yaw = -max_yaw;
				}
				if (held_d) {
					self.vel_yaw += accel_yaw;
					if (self.vel_yaw > max_yaw) self.vel_yaw = max_yaw;
				}
				if (held_q) {
					self.vel_pitch -= accel_pitch;
					if (self.vel_pitch < -max_pitch) self.vel_pitch = -max_pitch;
				}
				if (held_e) {
					self.vel_pitch += accel_pitch;
					if (self.vel_pitch > max_pitch) self.vel_pitch = max_pitch;
				}
				if (held_left) {
					self.vel_pan -= accel_pan;
					if (self.vel_pan < -max_pan) self.vel_pan = -max_pan;
				}
				if (held_right) {
					self.vel_pan += accel_pan;
					if (self.vel_pan > max_pan) self.vel_pan = max_pan;
				}
				if (held_up) {
					self.vel_up += accel_up;
					if (self.vel_up > max_up) self.vel_up = max_up;
				}
				if (held_down) {
					self.vel_up -= accel_up;
					if (self.vel_up < -max_up) self.vel_up = -max_up;
				}

				if (!held_w && !held_s) self.vel_fwd *= friction;
				if (!held_a && !held_d) self.vel_yaw *= friction;
				if (!held_q && !held_e) self.vel_pitch *= friction;
				if (!held_left && !held_right) self.vel_pan *= friction;
				if (!held_up && !held_down) self.vel_up *= friction;

				float cos_yaw   = (float)math::cos(self.cam_yaw);
				float sin_yaw   = (float)math::sin(self.cam_yaw);
				float cos_pitch = (float)math::cos(self.cam_pitch);
				// forward in world: (sin_yaw*cos_pitch, -sin_pitch, cos_yaw*cos_pitch)



				// right in world:   (cos_yaw, 0, -sin_yaw)

				self.cam_px += sin_yaw * cos_pitch * self.vel_fwd + cos_yaw * self.vel_pan;
				self.cam_py += -self.vel_fwd * (float)math::sin(self.cam_pitch) + self.vel_up;
				self.cam_pz += cos_yaw * cos_pitch * self.vel_fwd - sin_yaw * self.vel_pan;
				self.cam_yaw += self.vel_yaw;
				self.cam_pitch += self.vel_pitch;
				// clamp pitch to avoid flipping
				if (self.cam_pitch > 1.4f) self.cam_pitch = 1.4f;
				if (self.cam_pitch < -1.4f) self.cam_pitch = -1.4f;
			}
			return milktea::tick();
		}
		return null;
	}

	// PICKING mode
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	int visible   = self.height - 3;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'j') {
				if (self.cursor < self.file_count - 1) {
					self.cursor++;
					if (self.cursor >= self.scroll + visible) self.scroll++;
				}
			}
			if (k.rune == 'k') {
				if (self.cursor > 0) {
					self.cursor--;
					if (self.cursor < self.scroll) self.scroll--;
				}
			}
		case milktea::KeyCode.DOWN:
			if (self.cursor < self.file_count - 1) {
				self.cursor++;
				if (self.cursor >= self.scroll + visible) self.scroll++;
			}
		case milktea::KeyCode.UP:
			if (self.cursor > 0) {
				self.cursor--;
				if (self.cursor < self.scroll) self.scroll--;
			}
		case milktea::KeyCode.ENTER:
			if (self.file_count > 0) {
				self.load_file(self.files[self.cursor]);
				if (self.mode == VIEWING) return milktea::tick();
			}
		default:
	}
	return null;
}

fn milktea::View App.view(App* self) @dynamic {
	if (self.mode == VIEWING && self.model != null) {
		self.model.cam_px = self.cam_px;
		self.model.cam_py = self.cam_py;
		self.model.cam_pz = self.cam_pz;
		self.model.cam_yaw = self.cam_yaw;
		self.model.cam_pitch = self.cam_pitch;
		self.model.model_yaw = self.model_yaw;
		self.model.model_pitch = self.model_pitch;
		return self.model.view();
	}

	// Picker view using glaze
	DString out = dstring::temp();

	glaze::Style title_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true);
	glaze::Style cursor_style = glaze::new_style().foreground(glaze::color_hex("#ffffff")).set_bold(true)
		.background(glaze::color_hex("#444444"));
	glaze::Style normal_style = glaze::new_style().foreground(glaze::color_hex("#aaaaaa"));
	glaze::Style error_style  = glaze::new_style().foreground(glaze::color_hex("#ff5555"));
	glaze::Style hint_style   = glaze::new_style().foreground(glaze::color_hex("#555555"));

	out.append_string(title_style.render("GLB Viewer — select a file"));
	out.append_char('\n');

	if (self.file_count == 0) {
		out.append_string(normal_style.render("  No .glb files found in current directory."));
		out.append_char('\n');
	} else {
		int visible = self.height - 3;
		int end     = self.scroll + visible;
		if (end > self.file_count) end = self.file_count;
		for (int i = self.scroll; i < end; i++) {
			String name    = path::new(tmem, self.files[i])!!.basename();
			bool is_cursor = (i == self.cursor);
			String line = is_cursor ? cursor_style.render(
				string::tformat(" ▶ %s", name)
			) : normal_style.render(string::tformat("   %s", name));
			out.append_string(line);
			out.append_char('\n');
		}
	}

	if (self.error_msg.len > 0) {
		out.append_string(error_style.render(self.error_msg));
		out.append_char('\n');
	}

	out.append_string(hint_style.render("↑/↓ or j/k to navigate · enter to open · q to quit"));

	return milktea::new_alt_screen_view(out.str_view());
}

// ── main ─────────────────────────────────────────────────────────────────────

fn int main(String[] args) {
	App* app = mem::new(App);

	if (args.len > 1) {
		// direct path given — skip picker, go straight to viewer
		app.width = 80;
		app.height = 24;
		app.load_file(args[1]);
		if (app.mode != VIEWING) {
			io::printfn("%s", app.error_msg);
			return 1;
		}
	}

	milktea::enable_mouse();

	if (catch err = milktea::@run_program(app)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}