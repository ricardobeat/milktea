module squiggle;

// Procedural squiggle-border frames. Each frame renders a wave offset along a
// rounded-rectangle centreline at full-box pixel resolution, then slices the
// border ring into cell-sized tiles. Identical tiles within a frame are
// deduplicated (straight runs repeat every two cells), so each frame reuses a
// small set of transmitted images.

import std::core::mem;
import std::math;

const int BOX_W = 42;
const int BOX_H = 9;
const int CELL_PX_W = 10;
const int CELL_PX_H = 20;
const int PX_W = BOX_W * CELL_PX_W;
const int PX_H = BOX_H * CELL_PX_H;
const int TILE_BYTES = CELL_PX_W * CELL_PX_H * 4;
const int GFX_FRAMES = 8;
const int MAX_TILES_PER_FRAME = 64;
// Frames reserved per animation frame. Fixed so a (frame, tile) pair indexes
// the glyph's frame axis at a constant stride; the whole buffer is allocated
// up front, so this is the real cost per animation frame.
const int FRAME_STRIDE = MAX_TILES_PER_FRAME;

// Quarter-arc radius chosen so the closed centreline length is an exact
// multiple of the 20px wave period, making the squiggle close seamlessly
// where the path loops back on itself.
const double ARC_R = 10.0 / (4.0 - math::PI);
const double WAVE_AMP = 2.4;
const double WAVE_LEN = 20.0;
const double GLOW_R = 2.6;
const double CORE_R = 1.6;

struct PathSample {
	double x;
	double y;
	double nx;
	double ny;
	double s;
}

fn void hsv_rgb(double h, char* r, char* g, char* b) {
	double f = h * 6.0;
	int i = (int)f;
	double t = f - i;
	double p = 0.0;
	double q = 1.0 - t;
	double v = 1.0;
	switch (i % 6) {
		case 0: *r = (char)(v * 255); *g = (char)(t * 255); *b = (char)(p * 255);
		case 1: *r = (char)(q * 255); *g = (char)(v * 255); *b = (char)(p * 255);
		case 2: *r = (char)(p * 255); *g = (char)(v * 255); *b = (char)(t * 255);
		case 3: *r = (char)(p * 255); *g = (char)(q * 255); *b = (char)(v * 255);
		case 4: *r = (char)(t * 255); *g = (char)(p * 255); *b = (char)(v * 255);
		case 5: *r = (char)(v * 255); *g = (char)(p * 255); *b = (char)(q * 255);
		default:
	}
}

fn void blend_px(char[] buf, sz idx, char cr, char cg, char cb, double a) {
	double a0 = (double)buf[idx + 3] / 255.0;
	double oa = a + a0 * (1.0 - a);
	if (oa <= 0.0) return;
	buf[idx + 0] = (char)((cr * a + buf[idx + 0] * a0 * (1.0 - a)) / oa);
	buf[idx + 1] = (char)((cg * a + buf[idx + 1] * a0 * (1.0 - a)) / oa);
	buf[idx + 2] = (char)((cb * a + buf[idx + 2] * a0 * (1.0 - a)) / oa);
	buf[idx + 3] = (char)(oa * 255.0);
}

fn void stamp_disc(char[] buf, double cx, double cy, double radius, char cr, char cg, char cb, double a) {
	int x0 = (int)(cx - radius - 1.0);
	int x1 = (int)(cx + radius + 1.0);
	int y0 = (int)(cy - radius - 1.0);
	int y1 = (int)(cy + radius + 1.0);
	if (x0 < 0) x0 = 0;
	if (y0 < 0) y0 = 0;
	if (x1 >= PX_W) x1 = PX_W - 1;
	if (y1 >= PX_H) y1 = PX_H - 1;
	for (int py = y0; py <= y1; py++) {
		for (int px = x0; px <= x1; px++) {
			double dx = px + 0.5 - cx;
			double dy = py + 0.5 - cy;
			double cov = radius - math::sqrt(dx * dx + dy * dy) + 0.5;
			if (cov <= 0.0) continue;
			if (cov > 1.0) cov = 1.0;
			blend_px(buf, (sz)((py * PX_W + px) * 4), cr, cg, cb, a * cov);
		}
	}
}

fn double emit_line(PathSample* pts, sz cap, sz* n, double s, double x0, double y0, double x1, double y1, double nx, double ny) {
	double len = math::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
	int steps = (int)(len / 0.4) + 1;
	for (int i = 0; i < steps && *n < cap; i++) {
		double t = len * (double)i / (double)steps;
		pts[*n].x = x0 + (x1 - x0) * t / len;
		pts[*n].y = y0 + (y1 - y0) * t / len;
		pts[*n].nx = nx;
		pts[*n].ny = ny;
		pts[*n].s = s + t;
		*n = *n + 1;
	}
	return s + len;
}

fn double emit_arc(PathSample* pts, sz cap, sz* n, double s, double cx, double cy, double t0, double t1) {
	double len = ARC_R * (t1 - t0);
	int steps = (int)(len / 0.4) + 1;
	for (int i = 0; i < steps && *n < cap; i++) {
		double t = t0 + (t1 - t0) * (double)i / (double)steps;
		double c = math::cos(t);
		double sn = math::sin(t);
		pts[*n].x = cx + ARC_R * c;
		pts[*n].y = cy + ARC_R * sn;
		pts[*n].nx = c;
		pts[*n].ny = sn;
		pts[*n].s = s + len * (double)i / (double)steps;
		*n = *n + 1;
	}
	return s + len;
}

fn sz build_path(PathSample* pts, sz cap) {
	double xl = CELL_PX_W * 0.5;
	double xr = PX_W - xl;
	double yt = CELL_PX_H * 0.5;
	double yb = PX_H - yt;
	sz n = 0;
	double s = 0.0;
	s = emit_line(pts, cap, &n, s, xl + ARC_R, yt, xr - ARC_R, yt, 0.0, -1.0);
	s = emit_arc(pts, cap, &n, s, xr - ARC_R, yt + ARC_R, -math::PI * 0.5, 0.0);
	s = emit_line(pts, cap, &n, s, xr, yt + ARC_R, xr, yb - ARC_R, 1.0, 0.0);
	s = emit_arc(pts, cap, &n, s, xr - ARC_R, yb - ARC_R, 0.0, math::PI * 0.5);
	s = emit_line(pts, cap, &n, s, xr - ARC_R, yb, xl + ARC_R, yb, 0.0, 1.0);
	s = emit_arc(pts, cap, &n, s, xl + ARC_R, yb - ARC_R, math::PI * 0.5, math::PI);
	s = emit_line(pts, cap, &n, s, xl, yb - ARC_R, xl, yt + ARC_R, -1.0, 0.0);
	s = emit_arc(pts, cap, &n, s, xl + ARC_R, yt + ARC_R, math::PI, math::PI * 1.5);
	return n;
}

fn void render_frame(char[] buf, int frame) {
	for (sz i = 0; i < buf.len; i++) buf[i] = 0;

	PathSample* pts = mem::talloc_array(PathSample, 4096);
	sz n = build_path(pts, 4096);
	double total = pts[n - 1].s;

	for (int pass = 0; pass < 2; pass++) {
		double radius = pass == 0 ? GLOW_R : CORE_R;
		double a = pass == 0 ? 60.0 / 255.0 : 1.0;
		for (sz i = 0; i < n; i++) {
			double off = WAVE_AMP * math::sin(
				2.0 * math::PI * pts[i].s / WAVE_LEN - 2.0 * math::PI * (double)frame / (double)GFX_FRAMES);
			char cr, cg, cb;
			double band = math::floor(pts[i].s / total * 8.0);
			hsv_rgb((band + 0.5) / 8.0, &cr, &cg, &cb);
			stamp_disc(buf, pts[i].x + pts[i].nx * off, pts[i].y + pts[i].ny * off, radius, cr, cg, cb, a);
		}
	}
}

fn void copy_tile(char[] frame, int cx, int cy, char* out) {
	for (int y = 0; y < CELL_PX_H; y++) {
		sz src = (sz)((cy * CELL_PX_H + y) * PX_W + cx * CELL_PX_W) * 4;
		sz dst = (sz)(y * CELL_PX_W) * 4;
		mem::copy(out + dst, &frame[src], (sz)CELL_PX_W * 4);
	}
}

// Tolerance compare: blend rounding jitters by +/-1 between otherwise
// identical tiles, so exact byte equality would never merge them.
fn bool tiles_close(char* a, char* b, sz n) {
	for (sz i = 0; i < n; i++) {
		int d = (int)a[i] - (int)b[i];
		if (d < -2 || d > 2) return false;
	}
	return true;
}

fn void border_cell(int k, int* cx, int* cy) {
	if (k < BOX_W) {
		*cx = k;
		*cy = 0;
	} else if (k < BOX_W + BOX_H - 2) {
		*cx = BOX_W - 1;
		*cy = 1 + (k - BOX_W);
	} else if (k < 2 * BOX_W + BOX_H - 2) {
		*cx = BOX_W - 1 - (k - (BOX_W + BOX_H - 2));
		*cy = BOX_H - 1;
	} else {
		*cx = 0;
		*cy = BOX_H - 2 - (k - (2 * BOX_W + BOX_H - 2));
	}
}

// build_tiles renders every animation frame, dedupes the border tiles within
// each frame, and packs the unique ones into out at a fixed FRAME_STRIDE so a
// (frame, tile) pair indexes the glyph's frame axis directly. cell_tile gets
// the per-cell tile index and tile_counts the unique count per frame.
//
// The dedupe matters: a squiggle's border repeats a lot of identical cells, so
// a frame typically needs far fewer tiles than it has border cells.
fn void build_tiles(char[] out, int[] cell_tile, int[] tile_counts) {
	char* frame = mem::new_array(char, PX_W * PX_H * 4);
	defer mem::free(frame);
	char* tile = mem::talloc_array(char, TILE_BYTES);

	int border_cells = 2 * BOX_W + 2 * (BOX_H - 2);
	for (int f = 0; f < GFX_FRAMES; f++) {
		render_frame(frame[:PX_W * PX_H * 4], f);
		char* tiles = &out[(sz)(f * FRAME_STRIDE) * TILE_BYTES];
		int uniq = 0;
		for (int k = 0; k < border_cells; k++) {
			int cx, cy;
			border_cell(k, &cx, &cy);
			copy_tile(frame[:PX_W * PX_H * 4], cx, cy, tile[:TILE_BYTES]);
			int found = -1;
			for (int j = 0; j < uniq; j++) {
				if (tiles_close(tile, tiles + (sz)j * TILE_BYTES, (sz)TILE_BYTES)) {
					found = j;
					break;
				}
			}
			if (found < 0) {
				found = uniq;
				mem::copy(tiles + (sz)uniq * TILE_BYTES, tile, (sz)TILE_BYTES);
				uniq++;
			}
			cell_tile[(f * BOX_H + cy) * BOX_W + cx] = found;
		}
		tile_counts[f] = uniq;
	}
}
