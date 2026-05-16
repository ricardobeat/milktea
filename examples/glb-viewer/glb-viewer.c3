module glb_viewer;

import tea;
import xray;
import lipgloss;
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

fn Vec3 vec3(float x, float y, float z) => (Vec3){ x, y, z };

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

// ── Voxel face (same as voxel-renderer) ──────────────────────────────────────

struct Voxel {
    Vec3 pos;
    Vec3 normal;
    Vec3 tan_u;
    Vec3 tan_v;
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

// One triangle centroid + color after voxelization
struct VoxPoint {
    int x;
    int y;
    int z;
    char r;
    char g;
    char b;
}

const int MAX_VOXELS = 16384;


struct GlbModel {
    Voxel[MAX_VOXELS] voxels;
    int voxel_count;
    int width;
    int height;
    int frame;
    xray::Cell[] cells;
    Pixel[]       pixels;
    float[]       depth;
    // camera — set by App before each view() call
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
    int component_type; // 5126=float32, 5125=uint32, 5123=uint16
    int num_components; // 1=SCALAR, 2=VEC2, 3=VEC3
}

struct BufferViewInfo {
    int byte_offset;
    int byte_length;
    int byte_stride;
}

fn int components_for_type(char* type_str) {
    if (type_str[0] == 'S') return 1;  // SCALAR
    if (type_str[1] == 'E') return 2;  // VEC2
    if (type_str[1] == 'E' + 1) return 3; // VEC3 — fallback below
    // compare manually
    if (type_str[0] == 'V' && type_str[3] == '2') return 2;
    if (type_str[0] == 'V' && type_str[3] == '3') return 3;
    if (type_str[0] == 'V' && type_str[3] == '4') return 4;
    return 1;
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
    out.bv_index      = stb_json::stbj_read_int_name(&acc, "bufferView", -1);
    out.byte_offset   = stb_json::stbj_read_int_name(&acc, "byteOffset", 0);
    out.count         = stb_json::stbj_read_int_name(&acc, "count", 0);
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
    out.byte_offset  = stb_json::stbj_read_int_name(&bv, "byteOffset", 0);
    out.byte_length  = stb_json::stbj_read_int_name(&bv, "byteLength", 0);
    out.byte_stride  = stb_json::stbj_read_int_name(&bv, "byteStride", 0);
}

fn GlbModel*? load_glb(String path) {
    // Read entire file
    char[]? data_opt = file::load(mem, path);
    if (catch data_opt) return GLB_OPEN_FAILED~;
    char[] data = (char[])data_opt;
    char* raw = data.ptr;
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
    char* bin = raw + bin_chunk_start + 8;

    // Parse JSON
    stb_json::Cursor root = stb_json::stbj_load_buffer(json_buf, json_len);
    if (stb_json::stbj_any_error(&root) != 0) {
        return GLB_JSON_ERROR~;
    }

    // Navigate to meshes[0].primitives[0].attributes
    stb_json::Cursor meshes = stb_json::stbj_move_cursor_name(&root, "meshes");
    stb_json::Cursor mesh0  = stb_json::stbj_move_cursor_index(&meshes, 0);
    stb_json::Cursor prims  = stb_json::stbj_move_cursor_name(&mesh0, "primitives");
    stb_json::Cursor prim0  = stb_json::stbj_move_cursor_index(&prims, 0);
    stb_json::Cursor attrs  = stb_json::stbj_move_cursor_name(&prim0, "attributes");

    int pos_acc_idx = stb_json::stbj_read_int_name(&attrs, "POSITION",   -1);
    int uv_acc_idx  = stb_json::stbj_read_int_name(&attrs, "TEXCOORD_0", -1);
    int idx_acc_idx = stb_json::stbj_read_int_name(&prim0, "indices",    -1);

    if (pos_acc_idx < 0 || idx_acc_idx < 0) return GLB_MESH_NOT_FOUND~;

    stb_json::Cursor accessors = stb_json::stbj_move_cursor_name(&root, "accessors");
    stb_json::Cursor bvs       = stb_json::stbj_move_cursor_name(&root, "bufferViews");

    AccessorInfo pos_acc; parse_accessor(&accessors, pos_acc_idx, &pos_acc);
    AccessorInfo idx_acc; parse_accessor(&accessors, idx_acc_idx, &idx_acc);
    BufferViewInfo pos_bv; parse_bufview(&bvs, pos_acc.bv_index, &pos_bv);
    BufferViewInfo idx_bv; parse_bufview(&bvs, idx_acc.bv_index, &idx_bv);

    sz pos_base   = (sz)(pos_bv.byte_offset + pos_acc.byte_offset);
    sz pos_stride = (sz)(pos_bv.byte_stride > 0 ? pos_bv.byte_stride : 12);
    sz idx_base   = (sz)(idx_bv.byte_offset + idx_acc.byte_offset);
    bool idx32    = (idx_acc.component_type == 5125); // 5125=uint32, 5123=uint16

    // UV accessor (for palette color lookup)
    bool has_uv = (uv_acc_idx >= 0);
    sz uv_base   = 0;
    sz uv_stride = 8;
    if (has_uv) {
        AccessorInfo uv_acc; parse_accessor(&accessors, uv_acc_idx, &uv_acc);
        BufferViewInfo uv_bv; parse_bufview(&bvs, uv_acc.bv_index, &uv_bv);
        uv_base   = (sz)(uv_bv.byte_offset + uv_acc.byte_offset);
        uv_stride = (sz)(uv_bv.byte_stride > 0 ? uv_bv.byte_stride : 8);
    }

    // Compute bounding box from accessor min/max (already in JSON)
    // Fall back to scanning vertices
    float min_x =  1e9f; float max_x = -1e9f;
    float min_y =  1e9f; float max_y = -1e9f;
    float min_z =  1e9f; float max_z = -1e9f;
    for (int i = 0; i < pos_acc.count; i++) {
        sz base = pos_base + (sz)i * pos_stride;
        float x = read_f32(bin, base);
        float y = read_f32(bin, base + 4);
        float z = read_f32(bin, base + 8);
        if (x < min_x) min_x = x; if (x > max_x) max_x = x;
        if (y < min_y) min_y = y; if (y > max_y) max_y = y;
        if (z < min_z) min_z = z; if (z > max_z) max_z = z;
    }
    float center_x = (min_x + max_x) / 2.0f;
    float center_y = (min_y + max_y) / 2.0f;
    float center_z = (min_z + max_z) / 2.0f;

    // Allocate occupancy grid
    int gx0 = (int)(min_x - center_x) - 1;
    int gy0 = (int)(min_y - center_y) - 1;
    int gz0 = (int)(min_z - center_z) - 1;
    int gx1 = (int)(max_x - center_x) + 2;
    int gy1 = (int)(max_y - center_y) + 2;
    int gz1 = (int)(max_z - center_z) + 2;
    int gdx = gx1 - gx0;
    int gdy = gy1 - gy0;
    int gdz = gz1 - gz0;
    sz grid_size = (sz)(gdx * gdy * gdz);
    bool* occupied = mem::new_array(bool, grid_size);
    char* colors   = mem::new_array(char, grid_size * 3); // flat r,g,b per cell
    defer mem::free(occupied);
    defer mem::free(colors);

    // Voxelize: snap each triangle centroid to integer grid
    int tri_count = idx_acc.count / 3;
    for (int ti = 0; ti < tri_count; ti++) {
        int i0, i1, i2;
        if (idx32) {
            // uint32: 4 bytes per index
            i0 = (int)read_u32(bin, idx_base + (sz)ti * 12);
            i1 = (int)read_u32(bin, idx_base + (sz)ti * 12 + 4);
            i2 = (int)read_u32(bin, idx_base + (sz)ti * 12 + 8);
        } else {
            // uint16: 2 bytes per index
            char* p = bin + idx_base + (sz)ti * 6;
            i0 = (int)((uint)p[0] | ((uint)p[1] << 8));
            i1 = (int)((uint)p[2] | ((uint)p[3] << 8));
            i2 = (int)((uint)p[4] | ((uint)p[5] << 8));
        }

        sz b0 = pos_base + (sz)i0 * pos_stride;
        sz b1 = pos_base + (sz)i1 * pos_stride;
        sz b2 = pos_base + (sz)i2 * pos_stride;

        float cx3 = (read_f32(bin, b0) + read_f32(bin, b1) + read_f32(bin, b2)) / 3.0f - center_x;
        float cy3 = (read_f32(bin, b0+4) + read_f32(bin, b1+4) + read_f32(bin, b2+4)) / 3.0f - center_y;
        float cz3 = (read_f32(bin, b0+8) + read_f32(bin, b1+8) + read_f32(bin, b2+8)) / 3.0f - center_z;

        int gx = (int)(cx3 + 0.5f) - gx0;
        int gy = (int)(cy3 + 0.5f) - gy0;
        int gz = (int)(cz3 + 0.5f) - gz0;

        if (gx < 0 || gx >= gdx || gy < 0 || gy >= gdy || gz < 0 || gz >= gdz) continue;
        sz gidx = (sz)(gx + gy * gdx + gz * gdx * gdy);

        char cr = (char)180; char cg = (char)180; char cb = (char)200;
        if (has_uv) {
            float u = read_f32(bin, uv_base + (sz)i0 * uv_stride);
            int pal_idx = (int)(u * 255.0f + 0.5f);
            if (pal_idx < 0) pal_idx = 0;
            if (pal_idx > 255) pal_idx = 255;
            // map palette index to a hue — R2D2 is mostly white/blue/silver
            // without PNG decode we use the U value to shift hue
            float t = (float)pal_idx / 255.0f;
            cr = (char)(180.0f + t * 50.0f);
            cg = (char)(180.0f + t * 20.0f);
            cb = (char)(200.0f + t * 30.0f);
        }

        occupied[gidx] = true;
        colors[gidx * 3]     = cr;
        colors[gidx * 3 + 1] = cg;
        colors[gidx * 3 + 2] = cb;
    }

    // 6 face directions in grid space (x, y, z = grid axes; y=depth, z=up in grid)
    // After axis remap (wy=gz, wz=gy): neighbour checks still use grid coords
    int[6] nox = {  0,  0,  0,  0,  1, -1 }; // ±X
    int[6] noy = {  0,  0,  1, -1,  0,  0 }; // ±Y (grid) = ±depth
    int[6] noz = {  1, -1,  0,  0,  0,  0 }; // ±Z (grid) = ±up
    // face normals in renderer space (after Y/Z swap)
    float[6] fnx = {  0,  0,  0,  0,  1, -1 };
    float[6] fny = {  1, -1,  0,  0,  0,  0 }; // grid Z → renderer Y
    float[6] fnz = {  0,  0,  1, -1,  0,  0 }; // grid Y → renderer Z
    // tangent half-extents in renderer space
    float[6] tux = { 0.5f, 0.5f, 0.5f, 0.5f,    0,    0 };
    float[6] tuy = {    0,    0,    0,    0, 0.5f, 0.5f };
    float[6] tuz = {    0,    0,    0,    0,    0,    0 };
    float[6] tvx = {    0,    0,    0,    0,    0,    0 };
    float[6] tvy = { 0.5f, 0.5f,    0,    0,    0,    0 };
    float[6] tvz = {    0,    0, 0.5f, 0.5f, 0.5f, 0.5f };
    // face center offsets in renderer space
    float[6] fox = {    0,    0,    0,    0, 0.5f,-0.5f };
    float[6] foy = { 0.5f,-0.5f,    0,    0,    0,    0 }; // ±Z grid → ±Y renderer
    float[6] foz = {    0,    0, 0.5f,-0.5f,    0,    0 }; // ±Y grid → ±Z renderer

    // Normalize model so its longest axis spans ~10 units (fits comfortably in view)
    float span_x = max_x - min_x;
    float span_y = max_y - min_y;
    float span_z = max_z - min_z;
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

                // scale and remap axes: GLB has Z-up, renderer uses Y-up
                // swap Y and Z so R2D2 stands upright
                float wx = (float)(igx + gx0) * scale;
                float wy = (float)(igz + gz0) * scale;   // Z becomes screen Y (up)
                float wz = (float)(igy + gy0) * scale;   // Y becomes depth
                char cr  = colors[gidx * 3];
                char cg2 = colors[gidx * 3 + 1];
                char cb  = colors[gidx * 3 + 2];

                for (int f = 0; f < 6; f++) {
                    int nx3 = igx + nox[f];
                    int ny3 = igy + noy[f];
                    int nz3 = igz + noz[f];
                    bool neighbour = false;
                    if (nx3 >= 0 && nx3 < gdx && ny3 >= 0 && ny3 < gdy && nz3 >= 0 && nz3 < gdz) {
                        neighbour = occupied[(sz)(nx3 + ny3 * gdx + nz3 * gdx * gdy)];
                    }
                    if (neighbour) continue;
                    if (model.voxel_count >= MAX_VOXELS) break;
                    model.voxels[model.voxel_count++] = {
                        .pos    = vec3(wx + fox[f] * scale, wy + foy[f] * scale, wz + foz[f] * scale),
                        .normal = vec3(fnx[f], fny[f], fnz[f]),
                        .tan_u  = vec3(tux[f] * scale, tuy[f] * scale, tuz[f] * scale),
                        .tan_v  = vec3(tvx[f] * scale, tvy[f] * scale, tvz[f] * scale),
                        .r      = cr,
                        .g      = cg2,
                        .b      = cb,
                    };
                }
            }
        }
    }

    // Allocate render buffers
    model.width       = 80;
    model.height      = 24;
    model.cells       = mem::new_array(xray::Cell, (sz)(model.width * model.height));
    model.pixels      = mem::new_array(Pixel, (sz)(model.width * model.height * 2));
    model.depth       = mem::new_array(float, (sz)(model.width * model.height * 2));

    return model;
}

// ── Tea model callbacks ───────────────────────────────────────────────────────

GlbModel* g_model = null;

fn tea::Cmd GlbModel.init(GlbModel* self) @dynamic {
    tea::Cmd[] cmds = { tea::tick() };
    return tea::batch(cmds);
}

fn tea::Cmd GlbModel.update(GlbModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width  = msg.window_size.width;
        self.height = msg.window_size.height;
        mem::free(self.cells.ptr);
        mem::free(self.pixels.ptr);
        mem::free(self.depth.ptr);
        self.cells       = mem::new_array(xray::Cell, (sz)(self.width * self.height));
        self.pixels      = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
        self.depth       = mem::new_array(float, (sz)(self.width * self.height * 2));
        return null;
    }

    return null;
}

// Edge function: positive on one side of the line A→B, negative on the other.
fn float edge_fn(float ax, float ay, float bx, float by, float px, float py) {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

// Rasterize a triangle using top-left fill convention so coplanar adjacent
// triangles tile exactly without double-shading shared edges. Uses constant
// per-face depth (flat z) — sufficient for voxel faces since corner z's of a
// single small quad are nearly equal.
fn void rasterize_tri(GlbModel* self, int w, int ph,
                      float ax, float ay,
                      float bx, float by,
                      float cx, float cy,
                      float depth_z, Pixel col) {
    // Determine winding via the triangle's signed area.
    float area = edge_fn(ax, ay, bx, by, cx, cy);
    if (area == 0.0f) return;

    // Make winding positive so the inside is where all edge functions are >= 0.
    if (area < 0.0f) {
        float tx = bx; float ty = by;
        bx = cx; by = cy;
        cx = tx; cy = ty;
        area = -area;
    }

    // Bounding box in pixel space, clipped to viewport.
    float min_x = ax; if (bx < min_x) min_x = bx; if (cx < min_x) min_x = cx;
    float max_x = ax; if (bx > max_x) max_x = bx; if (cx > max_x) max_x = cx;
    float min_y = ay; if (by < min_y) min_y = by; if (cy < min_y) min_y = cy;
    float max_y = ay; if (by > max_y) max_y = by; if (cy > max_y) max_y = cy;

    int x0 = (int)math::floor(min_x); if (x0 < 0) x0 = 0;
    int x1 = (int)math::ceil(max_x);  if (x1 >= w) x1 = w - 1;
    int y0 = (int)math::floor(min_y); if (y0 < 0) y0 = 0;
    int y1 = (int)math::ceil(max_y);  if (y1 >= ph) y1 = ph - 1;
    if (x0 > x1 || y0 > y1) return;

    // Top-left fill rule: for each edge, decide whether points exactly on it count.
    // An edge counts if it's a "top" edge (horizontal, going right) or a "left"
    // edge (going down). This guarantees each pixel-center is owned by exactly
    // one triangle when triangles share an edge.
    bool tl_ab = (ay == by && bx > ax) || (by < ay);
    bool tl_bc = (by == cy && cx > bx) || (cy < by);
    bool tl_ca = (cy == ay && ax > cx) || (ay < cy);
    float bias_ab = tl_ab ? 0.0f : -0.0001f;
    float bias_bc = tl_bc ? 0.0f : -0.0001f;
    float bias_ca = tl_ca ? 0.0f : -0.0001f;

    for (int py = y0; py <= y1; py++) {
        float pcy = (float)py + 0.5f;
        for (int px = x0; px <= x1; px++) {
            float pcx = (float)px + 0.5f;
            float e0 = edge_fn(ax, ay, bx, by, pcx, pcy) + bias_ab;
            float e1 = edge_fn(bx, by, cx, cy, pcx, pcy) + bias_bc;
            float e2 = edge_fn(cx, cy, ax, ay, pcx, pcy) + bias_ca;
            if (e0 < 0.0f || e1 < 0.0f || e2 < 0.0f) continue;
            sz idx = (sz)(py * w + px);
            if (depth_z < self.depth[idx]) {
                self.depth[idx] = depth_z;
                self.pixels[idx] = col;
            }
        }
    }
}

fn void rasterize_quad(GlbModel* self, int w, int ph,
                       float[4] csx, float[4] csy, float[4] cz, Pixel col) {
    // Quad corners in (u, v) order: 0=(-,-), 1=(-,+), 2=(+,-), 3=(+,+).
    // Split along the 1↔2 diagonal into triangles (0,1,3) and (0,3,2).
    float face_z = (cz[0] + cz[1] + cz[2] + cz[3]) * 0.25f;
    rasterize_tri(self, w, ph, csx[0], csy[0], csx[1], csy[1], csx[3], csy[3], face_z, col);
    rasterize_tri(self, w, ph, csx[0], csy[0], csx[3], csy[3], csx[2], csy[2], face_z, col);
}

fn tea::View GlbModel.view(GlbModel* self) @dynamic {
    int w  = self.width;
    int h  = self.height;
    int ph = h * 2;
    sz ptotal = (sz)(w * ph);

    for (sz i = 0; i < ptotal; i++) {
        self.pixels[i] = (Pixel){ 0, 0, 0 };
        self.depth[i]  = 1000.0f;
    }

    float fov = 30.0f;
    float cx  = (float)w  / 2.0f;
    float cy  = (float)ph / 2.0f;

    float cos_yaw   = (float)math::cos(self.cam_yaw);
    float sin_yaw   = (float)math::sin(self.cam_yaw);
    float cos_pitch = (float)math::cos(self.cam_pitch);
    float sin_pitch = (float)math::sin(self.cam_pitch);

    float light_x =  0.4f;
    float light_y =  0.8f;
    float light_z = -0.5f;
    float light_len = (float)math::sqrt(light_x*light_x + light_y*light_y + light_z*light_z);
    light_x /= light_len; light_y /= light_len; light_z /= light_len;

    for (int v = 0; v < self.voxel_count; v++) {
        Vec3 p = self.voxels[v].pos;
        Vec3 n_world = self.voxels[v].normal;

        // translate into camera space, then rotate by inverse camera orientation
        float rx = p.x - self.cam_px;
        float ry = p.y - self.cam_py;
        float rz = p.z - self.cam_pz;

        // rotate by -cam_yaw (around Y): R_y(-yaw)
        float ax =  cos_yaw * rx - sin_yaw * rz;
        float ay =  ry;
        float az =  sin_yaw * rx + cos_yaw * rz;

        // rotate by -cam_pitch (around X): R_x(-pitch)
        p.x = ax;
        p.y =  cos_pitch * ay + sin_pitch * az;
        p.z = -sin_pitch * ay + cos_pitch * az;

        // rotate normal for back-face cull (yaw then pitch, same as point)
        float nax =  cos_yaw * n_world.x - sin_yaw * n_world.z;
        float nay =  n_world.y;
        float naz =  sin_yaw * n_world.x + cos_yaw * n_world.z;
        float ncx = nax;
        float ncy =  cos_pitch * nay + sin_pitch * naz;
        float ncz = -sin_pitch * nay + cos_pitch * naz;

        // strict back-face cull: skip faces pointing away from the camera
        if (ncz > 0.0f) continue;

        if (p.z < 0.5f) continue;

        Vec3 tu = self.voxels[v].tan_u;
        Vec3 tv = self.voxels[v].tan_v;

        // yaw
        float taux =  cos_yaw * tu.x - sin_yaw * tu.z;
        float tauz =  sin_yaw * tu.x + cos_yaw * tu.z;
        tu.x = taux; tu.z = tauz;
        float tvux =  cos_yaw * tv.x - sin_yaw * tv.z;
        float tvuz =  sin_yaw * tv.x + cos_yaw * tv.z;
        tv.x = tvux; tv.z = tvuz;

        // pitch
        float tauy2 =  cos_pitch * tu.y + sin_pitch * tu.z;
        float tauz2 = -sin_pitch * tu.y + cos_pitch * tu.z;
        tu.y = tauy2; tu.z = tauz2;
        float tvuy2 =  cos_pitch * tv.y + sin_pitch * tv.z;
        float tvuz2 = -sin_pitch * tv.y + cos_pitch * tv.z;
        tv.y = tvuy2; tv.z = tvuz2;

        // Project all 4 face-quad corners. Order: (-,-), (-,+), (+,-), (+,+).
        float[4] csx_arr;
        float[4] csy_arr;
        float[4] cz_arr;
        bool near_clipped = false;
        float[4] cu = { -1, -1,  1,  1 };
        float[4] cv = { -1,  1, -1,  1 };
        for (int ci = 0; ci < 4; ci++) {
            float cx3 = p.x + cu[ci] * tu.x + cv[ci] * tv.x;
            float cy3 = p.y + cu[ci] * tu.y + cv[ci] * tv.y;
            float cz3 = p.z + cu[ci] * tu.z + cv[ci] * tv.z;
            if (cz3 < 0.1f) { near_clipped = true; break; }
            float sc  = fov / cz3;
            csx_arr[ci] = cx3 * sc * 2.0f + cx;
            csy_arr[ci] = -cy3 * sc * 2.0f + cy;
            cz_arr[ci]  = cz3;
        }
        if (near_clipped) continue;

        // world-space lighting — consistent shading regardless of camera orientation
        float diff = n_world.x * light_x + n_world.y * light_y + n_world.z * light_z;
        if (diff < 0.0f) diff = 0.0f;
        float brightness = 0.30f + 0.70f * diff;

        Pixel col = {
            (char)((float)self.voxels[v].r * brightness),
            (char)((float)self.voxels[v].g * brightness),
            (char)((float)self.voxels[v].b * brightness),
        };

        // Rasterize the quad as two triangles using edge-function coverage.
        // Splitting into (0,1,3) and (0,3,2) so adjacent face-quads tile exactly
        // along their shared edge with no slivers (no bbox bleed).
        rasterize_quad(self, w, ph, csx_arr, csy_arr, cz_arr, col);
    }

    // Combine into half-block cells
    for (sz i = 0; i < (sz)(w * h); i++) self.cells[i] = xray::empty_cell();
    for (int ty = 0; ty < h; ty++) {
        for (int tx = 0; tx < w; tx++) {
            sz top_idx = (sz)((ty * 2)     * w + tx);
            sz bot_idx = (sz)((ty * 2 + 1) * w + tx);
            bool top_filled = self.depth[top_idx] < 999.0f;
            bool bot_filled = self.depth[bot_idx] < 999.0f;
            if (!top_filled && !bot_filled) continue;
            Pixel top = self.pixels[top_idx];
            Pixel bot = self.pixels[bot_idx];
            sz cidx = (sz)(ty * w + tx);
            xray::Color fg_col = top_filled ? xray::color_rgb(top.r, top.g, top.b) : xray::color_rgb(0, 0, 0);
            xray::Color bg_col = bot_filled ? xray::color_rgb(bot.r, bot.g, bot.b) : xray::color_rgb(0, 0, 0);
            xray::Style style = xray::default_style().set_fg(fg_col).set_bg(bg_col);
            self.cells[cidx] = xray::new_cell("\xe2\x96\x80", 1, style); // ▀
        }
    }

    return tea::new_alt_cell_view(self.cells, (sz)w, (sz)h);
}

// ── File picker ───────────────────────────────────────────────────────────────

const int MAX_FILES = 256;

enum AppMode { PICKING, VIEWING }

struct App {
    AppMode   mode;
    // picker state
    String[MAX_FILES] files;
    int       file_count;
    int       cursor;
    int       scroll;
    int       width;
    int       height;
    String    error_msg;
    // viewer
    GlbModel* model;
    // free-fly camera
    float     cam_px;
    float     cam_py;
    float     cam_pz;
    float     cam_yaw;
    float     cam_pitch;
    float     vel_fwd;
    float     vel_up;
    float     vel_yaw;
    float     vel_pitch;
    float     vel_pan;
    bool      auto_rotate;
    // last frame each key was seen (key repeat simulates held state)
    int       key_w;
    int       key_s;
    int       key_a;
    int       key_d;
    int       key_q;
    int       key_e;
    int       key_left;
    int       key_right;
    int       key_up;
    int       key_down;
    int       tick_count;
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
    self.model.width  = self.width;
    self.model.height = self.height;
    mem::free(self.model.cells.ptr);
    mem::free(self.model.pixels.ptr);
    mem::free(self.model.depth.ptr);
    self.model.cells       = mem::new_array(xray::Cell, (sz)(self.width * self.height));
    self.model.pixels      = mem::new_array(Pixel, (sz)(self.width * self.height * 2));
    self.model.depth       = mem::new_array(float, (sz)(self.width * self.height * 2));
    self.model.frame = 0;
    self.cam_px = 0.0f; self.cam_py = 0.0f; self.cam_pz = -20.0f;
    self.cam_yaw = 0.0f; self.cam_pitch = 0.0f;
    self.vel_fwd = 0.0f; self.vel_up = 0.0f; self.vel_yaw = 0.0f; self.vel_pan = 0.0f;
    self.auto_rotate = true;
    self.mode = VIEWING;
}

fn void scan_glb_files(App* self, String dir) {
    self.file_count = 0;
    Path? dp = path::new(tmem, dir);
    if (catch dp) return;
    Path d = (Path)dp;
    PathList? files = path::ls(tmem, d, no_dirs: true, mask: "*.glb");
    if (catch files) return;
    foreach (p : (PathList)files) {
        if (self.file_count >= MAX_FILES) break;
        String name = (String)p;
        if (!name.ends_with(".glb")) continue;
        self.files[self.file_count++] = name.copy(mem);
    }
}

fn tea::Cmd App.init(App* self) @dynamic {
    self.width  = 80;
    self.height = 24;
    self.mode   = PICKING;
    self.cursor = 0;
    self.scroll = 0;
    self.model  = null;
    self.error_msg = "";
    self.cam_px = 0.0f; self.cam_py = 0.0f; self.cam_pz = -20.0f;
    self.cam_yaw = 0.0f; self.cam_pitch = 0.0f;
    self.vel_fwd = 0.0f; self.vel_up = 0.0f; self.vel_yaw = 0.0f; self.vel_pan = 0.0f;
    self.auto_rotate = true;
    scan_glb_files(self, ".");
    return null;
}

fn tea::Cmd App.update(App* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width  = msg.window_size.width;
        self.height = msg.window_size.height;
        if (self.model != null) {
            // forward resize to model
            tea::Msg resize = msg;
            self.model.update(resize);
        }
        return null;
    }

    if (self.mode == VIEWING) {
        if (msg.kind == tea::MsgKind.KEY) {
            tea::KeyMsg k = msg.key;
            if (k.code == tea::KeyCode.ESC ||
                (k.code == tea::KeyCode.RUNE && k.rune == 'b')) {
                self.mode = PICKING;
                return null;
            }
            if (k.code == tea::KeyCode.CTRL_C ||
                (k.code == tea::KeyCode.RUNE && k.rune == 'q')) {
                return tea::quit();
            }
            if (k.code == tea::KeyCode.RUNE) {
                switch (k.rune) {
                    case 'w': self.key_w = self.tick_count; self.auto_rotate = false;
                    case 's': self.key_s = self.tick_count; self.auto_rotate = false;
                    case 'a': self.key_a = self.tick_count; self.auto_rotate = false;
                    case 'd': self.key_d = self.tick_count; self.auto_rotate = false;
                    default:
                }
            }
            if (k.code == tea::KeyCode.UP)    { self.key_up    = self.tick_count; self.auto_rotate = false; }
            if (k.code == tea::KeyCode.DOWN)   { self.key_down  = self.tick_count; self.auto_rotate = false; }
            if (k.code == tea::KeyCode.LEFT)   { self.key_left  = self.tick_count; self.auto_rotate = false; }
            if (k.code == tea::KeyCode.RIGHT)  { self.key_right = self.tick_count; self.auto_rotate = false; }
        }
        if (msg.kind == tea::MsgKind.TICK) {
            self.tick_count++;
            int held_thresh = self.tick_count - 2;
            bool held_w     = self.key_w     >= held_thresh;
            bool held_s     = self.key_s     >= held_thresh;
            bool held_a     = self.key_a     >= held_thresh;
            bool held_d     = self.key_d     >= held_thresh;
            bool held_q     = self.key_q     >= held_thresh;
            bool held_e     = self.key_e     >= held_thresh;
            bool held_left  = self.key_left  >= held_thresh;
            bool held_right = self.key_right >= held_thresh;
            bool held_up    = self.key_up    >= held_thresh;
            bool held_down  = self.key_down  >= held_thresh;

            if (self.model != null) {
                self.model.frame++;
                if (self.auto_rotate) {
                    // orbit camera around origin: position = -forward * dist
                    // forward = (sin(yaw)*cos(pitch), -sin(pitch), cos(yaw)*cos(pitch))
                    float orbit_dist  = 20.0f;
                    float orbit_yaw   = (float)self.model.frame * 0.01f;
                    float orbit_pitch = (float)math::sin((float)self.model.frame * 0.003) * 0.15f;
                    self.cam_yaw   = orbit_yaw;
                    self.cam_pitch = orbit_pitch;
                    float fwd_x = (float)math::sin(orbit_yaw) * (float)math::cos(orbit_pitch);
                    float fwd_y = -(float)math::sin(orbit_pitch);
                    float fwd_z = (float)math::cos(orbit_yaw) * (float)math::cos(orbit_pitch);
                    self.cam_px = -fwd_x * orbit_dist;
                    self.cam_py = -fwd_y * orbit_dist;
                    self.cam_pz = -fwd_z * orbit_dist;
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

                if (held_w)     { self.vel_fwd   += accel_fwd;   if (self.vel_fwd   >  max_fwd)   self.vel_fwd   =  max_fwd;   }
                if (held_s)     { self.vel_fwd   -= accel_fwd;   if (self.vel_fwd   < -max_fwd)   self.vel_fwd   = -max_fwd;   }
                if (held_a)     { self.vel_yaw   -= accel_yaw;   if (self.vel_yaw   < -max_yaw)   self.vel_yaw   = -max_yaw;   }
                if (held_d)     { self.vel_yaw   += accel_yaw;   if (self.vel_yaw   >  max_yaw)   self.vel_yaw   =  max_yaw;   }
                if (held_q)     { self.vel_pitch -= accel_pitch; if (self.vel_pitch < -max_pitch) self.vel_pitch = -max_pitch; }
                if (held_e)     { self.vel_pitch += accel_pitch; if (self.vel_pitch >  max_pitch) self.vel_pitch =  max_pitch; }
                if (held_left)  { self.vel_pan   -= accel_pan;   if (self.vel_pan   < -max_pan)   self.vel_pan   = -max_pan;   }
                if (held_right) { self.vel_pan   += accel_pan;   if (self.vel_pan   >  max_pan)   self.vel_pan   =  max_pan;   }
                if (held_up)    { self.vel_up    += accel_up;    if (self.vel_up    >  max_up)    self.vel_up    =  max_up;    }
                if (held_down)  { self.vel_up    -= accel_up;    if (self.vel_up    < -max_up)    self.vel_up    = -max_up;    }

                if (!held_w && !held_s)           self.vel_fwd   *= friction;
                if (!held_a && !held_d)           self.vel_yaw   *= friction;
                if (!held_q && !held_e)           self.vel_pitch *= friction;
                if (!held_left && !held_right)    self.vel_pan   *= friction;
                if (!held_up && !held_down)       self.vel_up    *= friction;

                float cos_yaw   = (float)math::cos(self.cam_yaw);
                float sin_yaw   = (float)math::sin(self.cam_yaw);
                float cos_pitch = (float)math::cos(self.cam_pitch);
                // forward in world: (sin_yaw*cos_pitch, -sin_pitch, cos_yaw*cos_pitch)
                // right in world:   (cos_yaw, 0, -sin_yaw)
                self.cam_px    += sin_yaw * cos_pitch * self.vel_fwd + cos_yaw * self.vel_pan;
                self.cam_py    += -self.vel_fwd * (float)math::sin(self.cam_pitch) + self.vel_up;
                self.cam_pz    += cos_yaw * cos_pitch * self.vel_fwd - sin_yaw * self.vel_pan;
                self.cam_yaw   += self.vel_yaw;
                self.cam_pitch += self.vel_pitch;
                // clamp pitch to avoid flipping
                if (self.cam_pitch >  1.4f) self.cam_pitch =  1.4f;
                if (self.cam_pitch < -1.4f) self.cam_pitch = -1.4f;
            }
            return tea::tick();
        }
        return null;
    }

    // PICKING mode
    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;
    int visible = self.height - 3;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
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
        case tea::KeyCode.DOWN:
            if (self.cursor < self.file_count - 1) {
                self.cursor++;
                if (self.cursor >= self.scroll + visible) self.scroll++;
            }
        case tea::KeyCode.UP:
            if (self.cursor > 0) {
                self.cursor--;
                if (self.cursor < self.scroll) self.scroll--;
            }
        case tea::KeyCode.ENTER:
            if (self.file_count > 0) {
                self.load_file(self.files[self.cursor]);
                if (self.mode == VIEWING) return tea::tick();
            }
        default:
    }
    return null;
}

fn tea::View App.view(App* self) @dynamic {
    if (self.mode == VIEWING && self.model != null) {
        self.model.cam_px    = self.cam_px;
        self.model.cam_py    = self.cam_py;
        self.model.cam_pz    = self.cam_pz;
        self.model.cam_yaw   = self.cam_yaw;
        self.model.cam_pitch = self.cam_pitch;
        return self.model.view();
    }

    // Picker view using lipgloss
    DString out = dstring::temp();

    lipgloss::Style title_style  = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
    lipgloss::Style cursor_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ffffff")).set_bold(true).background(lipgloss::color_hex("#444444"));
    lipgloss::Style normal_style = lipgloss::new_style().foreground(lipgloss::color_hex("#aaaaaa"));
    lipgloss::Style error_style  = lipgloss::new_style().foreground(lipgloss::color_hex("#ff5555"));
    lipgloss::Style hint_style   = lipgloss::new_style().foreground(lipgloss::color_hex("#555555"));

    out.append_string(title_style.render("GLB Viewer — select a file"));
    out.append_char('\n');

    if (self.file_count == 0) {
        out.append_string(normal_style.render("  No .glb files found in current directory."));
        out.append_char('\n');
    } else {
        int visible = self.height - 3;
        int end = self.scroll + visible;
        if (end > self.file_count) end = self.file_count;
        for (int i = self.scroll; i < end; i++) {
            String name = path::new(tmem, self.files[i])!!.basename();
            bool is_cursor = (i == self.cursor);
            String line = is_cursor
                ? cursor_style.render(string::tformat(" ▶ %s", name))
                : normal_style.render(string::tformat("   %s", name));
            out.append_string(line);
            out.append_char('\n');
        }
    }

    if (self.error_msg.len > 0) {
        out.append_string(error_style.render(self.error_msg));
        out.append_char('\n');
    }

    out.append_string(hint_style.render("↑/↓ or j/k to navigate · enter to open · q to quit"));

    return tea::new_alt_screen_view(out.str_view());
}

// ── main ─────────────────────────────────────────────────────────────────────

fn int main(String[] args) {
    App* app = mem::new(App);

    if (args.len > 1) {
        // direct path given — skip picker, go straight to viewer
        app.width  = 80;
        app.height = 24;
        app.load_file(args[1]);
        if (app.mode != VIEWING) {
            io::printfn("%s", app.error_msg);
            return 1;
        }
    }

    if (catch err = tea::@run_program(app)) {
        io::printfn("Error: %s", err);
        return 1;
    }
    return 0;
}
