module nineslice;

// Nine-slice rounded boxes: rasterize the WHOLE box once into an RGBA surface,
// then cut it on the cell grid and transmit only the distinct tiles.
//
// The rounded/ example draws each corner cell separately, so every glyph has
// to reconstruct where the box edge is from its own cell-local frame -- which
// is why it carries two different arc-center conventions and a per-cell
// opacity override to keep neighbouring cells flush. Here the corner arc is
// one continuous curve in surface space that happens to get cut into cells,
// so seams are structural rather than maintained by hand, and the radius is
// bounded by the BOX rather than by a single cell.
//
// The slice grid is 3x3 cells for a radius up to one cell, (2k+1)^2 for a
// radius spanning k cells. Only the border ring is transmitted -- the centre
// tile is flat background that plain text cells paint for free. So a box of
// any size costs 4k^2 + 2 distinct tiles:
//
//     +----+----+----+     corners: the k*k arc blocks (4k^2 tiles)
//     | TL | T  | TR |     T/B/L/R: ONE tile each, tiled along the run
//     +----+----+----+     centre:  never transmitted
//     | L  |    | R  |
//     +----+----+----+
//     | BL | B  | BR |
//     +----+----+----+
//
// Geometry is a single signed-distance function for a rounded rectangle, so
// the three visual modes (plain fill, stroked border, 1px outline) are
// parameters over one rasterizer instead of three hand-derived ones.

import std::math;
import std::core::mem;

const int GX = 16; // cell width in px
const int GY = 34; // cell height in px -- matches rounded/, see its note on
                   // terminals rendering cells slightly taller than 2:1.
const sz TILE_BYTES = (sz)(GX * GY * 4);

// Radius index -> pixels. With a whole-box surface the arc may span more than
// one cell, so this is NOT clamped to the cell: the top half of the range
// needs a 2x2 block of corner tiles. That is the payoff of slicing a surface
// rather than authoring each corner cell -- a per-cell renderer caps the
// radius at one cell, because a larger arc would leave the cell entirely.
const int RADII = 8;
fn int radius_px(int idx) => (idx + 1) * 4;

// Largest corner block over the whole radius range, and the tile count at
// that size. Every radius reserves MAX_TILES frames so a radius indexes the
// frame axis at a fixed stride, regardless of how many tiles it actually
// uses.
const int MAX_KX = 2;
const int MAX_KY = 1;
const int MAX_TILES = 4 * MAX_KX * MAX_KY + 4;
// Frames reserved per radius: the largest corner blocks, both h-runs, and
// L/C/R for every body row. Fixed so a radius indexes at a constant stride.
const int MAX_BODY = 3;
const int FRAMES_PER_RADIUS = 4 * MAX_KX * MAX_KY + 2 * MAX_KY + 3 * MAX_BODY;

// Cells a radius spans, per axis. A cell is 16x34px -- roughly 1:2 -- so a
// corner arc that needs two cells across still fits in one cell down. Deriving
// both from the width would make a wide radius eat box rows it does not
// actually need.
fn int radius_cells_x(int r) => (r + GX - 1) / GX;
fn int radius_cells_y(int r) => (r + GY - 1) / GY;

// Tile slots in the 3x3 ring, in transmission order. Corner blocks with k > 1
// occupy k*k tiles each starting at the corner's slot base.
const int SLOT_TL = 0;
const int SLOT_TR = 1;
const int SLOT_BL = 2;
const int SLOT_BR = 3;
const int SLOT_T  = 4;
const int SLOT_B  = 5;
const int SLOT_L  = 6;
const int SLOT_R  = 7;
const int SLOT_COUNT = 8;

// Border placement relative to the box edge.
const int STROKE_NONE   = 0; // plain fill, no border drawn
const int STROKE_INSET  = 1; // stroke sits inset px inside the box edge

struct BoxStyle {
	uint bg;
	// Second fill colour. When grad is true the fill ramps bg -> bg2 down the
	// box; the ramp is evaluated in surface space, so it stays continuous
	// across cell boundaries -- a per-cell renderer would have to be told
	// which slice of the ramp each cell owns.
	uint bg2;
	bool grad;
	uint line;
	float line_w;
	// Distance from the box edge to the OUTER face of the stroke. 0 puts the
	// stroke flush against the edge; a few px reproduces what a box-drawing
	// character looks like over a colored background, where the glyph's own
	// side bearing leaves a margin of background outside the line.
	float inset;
	int stroke;
	// Draw only the backdrop and the shadow, not the box itself. Used for the
	// separate shadow pass, whose tiles sit outside the box and must not
	// carry any of its fill.
	bool shadow_only;
	// Backdrop composited under the box. Pixels outside the rounded corner
	// would otherwise be transparent, and a placeholder cell composites
	// against BLACK rather than the cell's text background -- so the corners
	// read as dark notches on a light screen. Painting the backdrop into the
	// surface makes every tile opaque and matching.
	uint backdrop;
	// Drop shadow, in px. Offset down/right by shadow_dy/dx, softened over
	// shadow_blur px. The shadow is the same distance field shifted, so it
	// follows the rounded corner exactly.
	float shadow_dx;
	float shadow_dy;
	float shadow_blur;
	char shadow_alpha;
}

fn float fclamp(float x, float lo, float hi) => x < lo ? lo : (x > hi ? hi : x);
fn float fabsf_(float x) => x < 0.0f ? -x : x;

// sd_round_rect is the signed distance from (px, py) to the boundary of a
// rounded rectangle spanning (0,0)-(w,h) with corner radius r. Negative
// inside, positive outside. Both the fill and the stroke fall out of this one
// value, which is what collapses rounded/'s three rasterizers into one.
fn float sd_round_rect(float px, float py, float w, float h, float r) {
	// Fold into the first quadrant: distance to the rounded corner is the
	// distance to the arc centre minus the radius, and the straight edges
	// fall out of the same expression once the offset is clamped at 0.
	float cx = w * 0.5f;
	float cy = h * 0.5f;
	float qx = fabsf_(px - cx) - (cx - r);
	float qy = fabsf_(py - cy) - (cy - r);
	float mx = math::max(qx, 0.0f);
	float my = math::max(qy, 0.0f);
	float outside = math::sqrt(mx * mx + my * my);
	float inside = math::min(math::max(qx, qy), 0.0f);
	return outside + inside - r;
}

// put alpha-composites one coverage sample into an RGBA8 surface.
fn void put(char* buf, int stride_px, int x, int y, float r, float g, float b, float a) {
	if (a <= 0) return;
	int i = (y * stride_px + x) * 4;
	float da = (float)((int)buf[i + 3] & 0xff) / 255.0f;
	float oa = a + da * (1.0f - a);
	if (oa <= 0) return;
	float dr = (float)((int)buf[i] & 0xff) / 255.0f;
	float dg = (float)((int)buf[i + 1] & 0xff) / 255.0f;
	float db = (float)((int)buf[i + 2] & 0xff) / 255.0f;
	float w = da * (1.0f - a) / oa;
	float wa = a / oa;
	buf[i]     = (char)(int)(255.0f * fclamp(r * wa + dr * w, 0, 1));
	buf[i + 1] = (char)(int)(255.0f * fclamp(g * wa + dg * w, 0, 1));
	buf[i + 2] = (char)(int)(255.0f * fclamp(b * wa + db * w, 0, 1));
	buf[i + 3] = (char)(int)(oa * 255.0f);
}

// render_surface rasterizes the whole rounded box into an RGBA8 surface of
// (cols*GX) x (rows*GY) px. This is the single source of geometric truth: the
// arc is drawn once, continuous across what will become cell boundaries.
//
// pad_x/pad_y extend the surface to the RIGHT and BELOW the box, leaving room
// for a drop shadow to fall outside it without being clipped. The box stays at
// the surface origin: a drop shadow offsets down-right, so padding the other
// two sides would only waste tiles.
fn void render_surface(char[] surf, int cols, int rows, int r, BoxStyle st, int pad_x = 0, int pad_y = 0) {
	for (sz i = 0; i < surf.len; i++) surf[i] = 0;

	int w = cols * GX;
	int h = rows * GY;
	char* buf = &surf[0];

	float br = (float)((st.bg >> 16) & 0xff) / 255.0f;
	float bgc = (float)((st.bg >> 8) & 0xff) / 255.0f;
	float bb = (float)(st.bg & 0xff) / 255.0f;
	float lr = (float)((st.line >> 16) & 0xff) / 255.0f;
	float lg = (float)((st.line >> 8) & 0xff) / 255.0f;
	float lb = (float)(st.line & 0xff) / 255.0f;

	// The box sits at the origin; the padding is skirt to its right and below.
	float bx = 0.0f;
	float by = 0.0f;
	float fw = (float)(w - pad_x);
	float fh = (float)(h - pad_y);
	// The radius cannot exceed half the shorter side, or the arcs overlap.
	float fr = fclamp((float)r, 0.0f, math::min(fw, fh) * 0.5f);
	float half_w = st.line_w * 0.5f;
	// The stroke's centre line sits inset + half_w inside the box edge, so
	// its outer face lands exactly `inset` px in. The fill still runs to the
	// edge, leaving that margin of background outside the line.
	float shift = st.inset + half_w;

	float g2r = (float)((st.bg2 >> 16) & 0xff) / 255.0f;
	float g2g = (float)((st.bg2 >> 8) & 0xff) / 255.0f;
	float g2b = (float)(st.bg2 & 0xff) / 255.0f;
	bool has_shadow = st.shadow_alpha > 0;
	float sh_a_max = (float)((int)st.shadow_alpha & 0xff) / 255.0f;

	// Opaque backdrop first: everything else composites over it.
	float kr = (float)((st.backdrop >> 16) & 0xff) / 255.0f;
	float kg = (float)((st.backdrop >> 8) & 0xff) / 255.0f;
	float kb = (float)(st.backdrop & 0xff) / 255.0f;
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) put(buf, w, x, y, kr, kg, kb, 1.0f);
	}

	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			// Box-local coordinates: the box sits inset by the shadow padding.
			float fx = (float)x + 0.5f - bx;
			float fy = (float)y + 0.5f - by;
			float d = sd_round_rect(fx, fy, fw, fh, fr);

			// Drop shadow first, so the box paints over it. Sampling the same
			// distance field at an offset makes the shadow share the box's
			// exact silhouette, rounded corners included.
			if (has_shadow) {
				float sd = sd_round_rect(fx - st.shadow_dx, fy - st.shadow_dy, fw, fh, fr);
				float soft = st.shadow_blur > 0.0f ? st.shadow_blur : 0.5f;
				float sa = fclamp(0.5f - sd / soft, 0.0f, 1.0f) * sh_a_max;
				if (sa > 0) put(buf, w, x, y, 0.0f, 0.0f, 0.0f, sa);
			}

			// Fill: inside the rounded rect, antialiased across the boundary.
			float bg_a = st.shadow_only ? 0.0f : fclamp(0.5f - d, 0.0f, 1.0f);
			if (bg_a > 0) {
				float t = st.grad ? fclamp(fy / fh, 0.0f, 1.0f) : 0.0f;
				put(buf, w, x, y,
					br + (g2r - br) * t,
					bgc + (g2g - bgc) * t,
					bb + (g2b - bb) * t,
					bg_a);
			}

			if (st.stroke != STROKE_NONE) {
				// The stroke is the band where |d + shift| < line_w/2, which
				// follows the arc and the straight edges alike -- no separate
				// case for the corner quadrant or the edge stubs. Because it
				// rides the same distance field, the inset border stays
				// concentric with the rounded corner at every radius.
				float la = fclamp(0.5f + half_w - fabsf_(d + shift), 0.0f, 1.0f);
				if (la > 0) put(buf, w, x, y, lr, lg, lb, la);
			}
		}
	}
}

// Height in px of the gradient strip used for a scaled interior placement.
// A vertical ramp has no horizontal variation, so one pixel column is enough
// and the terminal stretches it to any box width; the height sets how finely
// the ramp is sampled before the terminal resamples it.
const int STRIP_W = 1;
const int STRIP_H = 256;
const sz STRIP_BYTES = (sz)(STRIP_W * STRIP_H * 4);

// render_gradient_strip draws the box's fill ramp into a STRIP_W x STRIP_H
// RGBA image. Placed with c/r it stretches to fill a box of any size, and
// because it is a linear ramp it resamples cleanly at any aspect ratio --
// so a resize is a replacement placement, never a retransmission.
fn void render_gradient_strip(char[] out, BoxStyle st) {
	float r0 = (float)((st.bg >> 16) & 0xff) / 255.0f;
	float g0 = (float)((st.bg >> 8) & 0xff) / 255.0f;
	float b0 = (float)(st.bg & 0xff) / 255.0f;
	float r1 = (float)((st.bg2 >> 16) & 0xff) / 255.0f;
	float g1 = (float)((st.bg2 >> 8) & 0xff) / 255.0f;
	float b1 = (float)(st.bg2 & 0xff) / 255.0f;
	if (!st.grad) { r1 = r0; g1 = g0; b1 = b0; }

	for (int y = 0; y < STRIP_H; y++) {
		float t = (float)y / (float)(STRIP_H - 1);
		for (int x = 0; x < STRIP_W; x++) {
			sz i = (sz)((y * STRIP_W + x) * 4);
			out[i]     = (char)(int)(255.0f * (r0 + (r1 - r0) * t));
			out[i + 1] = (char)(int)(255.0f * (g0 + (g1 - g0) * t));
			out[i + 2] = (char)(int)(255.0f * (b0 + (b1 - b0) * t));
			out[i + 3] = (char)255;
		}
	}
}

// gradient_at samples the box fill at vertical position t (0..1), returning a
// packed RGB. A label cell has to paint an opaque background -- a terminal
// text cell has no "transparent" that shows an image through it -- so the
// label uses the ramp colour at its own row and the seam disappears.
fn uint gradient_at(BoxStyle st, float t) {
	if (!st.grad) return st.bg;
	if (t < 0.0f) t = 0.0f;
	if (t > 1.0f) t = 1.0f;
	uint r0 = (st.bg >> 16) & 0xff;
	uint g0 = (st.bg >> 8) & 0xff;
	uint b0 = st.bg & 0xff;
	uint r1 = (st.bg2 >> 16) & 0xff;
	uint g1 = (st.bg2 >> 8) & 0xff;
	uint b1 = st.bg2 & 0xff;
	uint r = (uint)((float)r0 + ((float)r1 - (float)r0) * t);
	uint g = (uint)((float)g0 + ((float)g1 - (float)g0) * t);
	uint b = (uint)((float)b0 + ((float)b1 - (float)b0) * t);
	return (r << 16) | (g << 8) | b;
}

// blit_tile copies one GX x GY cell out of the surface at cell (cx, cy).
fn void blit_tile(char[] dst, char[] surf, int cols, int cx, int cy) {
	int stride = cols * GX;
	for (int y = 0; y < GY; y++) {
		int sy = cy * GY + y;
		for (int x = 0; x < GX; x++) {
			int sx = cx * GX + x;
			sz si = (sz)((sy * stride + sx) * 4);
			sz di = (sz)((y * GX + x) * 4);
			for (int c = 0; c < 4; c++) dst[di + (sz)c] = surf[si + (sz)c];
		}
	}
}

// A vertical gradient breaks the translation-invariance nine-slice relies on:
// the left/right runs and the interior are no longer the same at every row, so
// one tile cannot be tiled down the box. The slice therefore keeps its 3x3
// structure horizontally but expands vertically to the box's real height --
// every body row gets its own L, C and R tile, cut from a surface rasterized
// at full height so the ramp is continuous.
//
// Horizontal invariance still holds (the ramp is a function of y alone), so
// the top/bottom runs and each row's centre are still ONE tile tiled across.
// Cost is 4k^2 + 2 + 3*body tiles instead of 4k^2 + 4.
fn int tile_count(int k) => 4 * k * k + 4;

// tile_count_rows is the tile budget for a box with `body` interior rows: the
// corner blocks, k top-run and k bottom-run tiles, and L/C/R per body row.
//
// The horizontal runs need one tile PER corner row, not one total: with a
// multi-cell corner block the top edge spans k surface rows, and reusing a
// single tile down all of them repeats that row's pixels -- which draws an
// inset border k times as parallel lines.
fn int tile_count_rows(int kx, int ky, int body) => 4 * kx * ky + 2 * ky + 3 * body;

// Slot indices within one radius's tile block. Corner blocks come first
// (kx*ky each), then the two horizontal-run bands (ky tiles each, one per
// corner row), then L/C/R for every body row.
fn int tile_index(int kx, int ky, int slot, int ox, int oy) {
	if (slot <= SLOT_BR) return slot * kx * ky + oy * kx + ox;
	int base = 4 * kx * ky;
	switch (slot) {
		case SLOT_T: return base;
		case SLOT_B: return base + ky;
		case SLOT_L: return base + 2 * ky;
		default: return base + 2 * ky + 1;
	}
}

// Top/bottom run tile for corner row oy. The runs need one tile PER corner
// row: with a multi-row corner block the edge spans ky surface rows, and
// reusing a single tile down all of them repeats that row's pixels.
fn int hrun_tile_index(int kx, int ky, int oy, bool bottom) {
	return 4 * kx * ky + (bottom ? ky : 0) + oy;
}

// Per-body-row slots (0 = left, 1 = centre, 2 = right), after the corners
// and the two h-run bands.
fn int row_tile_index(int kx, int ky, int row, int which) {
	return 4 * kx * ky + 2 * ky + row * 3 + which;
}


// ---- Drop shadow: a separate draw pass ----
//
// The shadow falls OUTSIDE the box, so it cannot live in the box's own tiles
// -- those are clipped at the ring's edge, which is why the shadow was
// invisible. Drawing it as its own pass keeps the two independent: the shadow
// is rasterized on a surface one cell larger right and below, sliced into a
// frame of tiles, and painted before the box goes over the top.
//
// Tiles are laid out as a (w+1) x (h+1) grid minus the interior the box
// covers: the right column, the bottom row, and their corner.
const int SHADOW_COLS = 1; // extra cells right of the box
const int SHADOW_ROWS = 1; // extra cells below the box

// The shadow follows the box's silhouette, so it is rounded at the corners
// too and cannot be three straight tiles. It is sliced like the box: kx x ky
// corner blocks at the ends of each run, with a straight tile tiled between
// them. Only the parts falling OUTSIDE the box are kept -- the right column,
// the bottom row, and the corner where they meet.
//
//   right run:  ky corner tiles (top-right curve), then a straight tile
//               tiled down, then ky more (bottom-right curve)
//   bottom run: kx corner tiles (bottom-left curve), a straight tile tiled
//               across, then kx more (bottom-right curve)
fn int shadow_tile_count(int kx, int ky) => 2 * ky + 1 + 2 * kx + 1 + 1;

// Right column: ky top tiles, one straight, ky bottom tiles.
fn int shadow_right_top(int oy) => oy;
fn int shadow_right_mid(int ky) => ky;
fn int shadow_right_bot(int ky, int oy) => ky + 1 + oy;
// Bottom row follows.
fn int shadow_bottom_left(int kx, int ky, int ox) => 2 * ky + 1 + ox;
fn int shadow_bottom_mid(int kx, int ky) => 2 * ky + 1 + kx;
fn int shadow_bottom_right(int kx, int ky, int ox) => 2 * ky + 1 + kx + 1 + ox;
// The outer corner where the two runs meet.
fn int shadow_corner(int kx, int ky) => 2 * ky + 1 + 2 * kx + 1;

// slice_shadow rasterizes just the shadow of a box_w x box_h cell box and
// cuts the parts that fall outside it. The box itself is not drawn: these
// tiles are shadow over backdrop only.
fn void slice_shadow(char[] out, int box_w, int box_h, int kx, int ky, int r, BoxStyle st) {
	int cells_w = box_w + SHADOW_COLS;
	int rows = box_h + SHADOW_ROWS;
	if (box_w < 3 || box_h < 3) return;
	char[] surf = mem::new_array(char, (sz)(cells_w * GX) * (sz)(rows * GY) * 4);
	defer mem::free(&surf[0]);

	// Shadow only: no fill, no stroke, so the box's own pixels stay out of
	// these tiles and only the part spilling past its edge is captured.
	BoxStyle sh = st;
	sh.stroke = STROKE_NONE;
	sh.grad = false;
	sh.shadow_only = true;
	render_surface(surf, cells_w, rows, r, sh, GX * SHADOW_COLS, GY * SHADOW_ROWS);

	// Right column: the curve at each end, a straight tile between.
	for (int oy = 0; oy < ky; oy++) {
		blit_tile(out[(sz)shadow_right_top(oy) * TILE_BYTES:TILE_BYTES],
			surf, cells_w, box_w, oy);
		blit_tile(out[(sz)shadow_right_bot(ky, oy) * TILE_BYTES:TILE_BYTES],
			surf, cells_w, box_w, box_h - ky + oy);
	}
	blit_tile(out[(sz)shadow_right_mid(ky) * TILE_BYTES:TILE_BYTES],
		surf, cells_w, box_w, box_h / 2);

	// Bottom row: same, horizontally.
	for (int ox = 0; ox < kx; ox++) {
		blit_tile(out[(sz)shadow_bottom_left(kx, ky, ox) * TILE_BYTES:TILE_BYTES],
			surf, cells_w, ox, box_h);
		blit_tile(out[(sz)shadow_bottom_right(kx, ky, ox) * TILE_BYTES:TILE_BYTES],
			surf, cells_w, box_w - kx + ox, box_h);
	}
	blit_tile(out[(sz)shadow_bottom_mid(kx, ky) * TILE_BYTES:TILE_BYTES],
		surf, cells_w, box_w / 2, box_h);

	blit_tile(out[(sz)shadow_corner(kx, ky) * TILE_BYTES:TILE_BYTES],
		surf, cells_w, box_w, box_h);
}

fn void slice_box_rows(char[] out, int kx, int ky, int body, int r, BoxStyle st) {
	int cells_w = 2 * kx + 1;
	int box_w = cells_w;
	int rows = 2 * ky + body;
	int box_rows = rows;
	char[] surf = mem::new_array(char, (sz)(cells_w * GX) * (sz)(rows * GY) * 4);
	defer mem::free(&surf[0]);

	render_surface(surf, cells_w, rows, r, st);

	// Corner blocks: kx wide by ky tall.
	for (int oy = 0; oy < ky; oy++) {
		for (int ox = 0; ox < kx; ox++) {
			int fx = box_w - kx;
			int fy = box_rows - ky;
			blit_tile(out[(sz)tile_index(kx, ky, SLOT_TL, ox, oy) * TILE_BYTES:TILE_BYTES], surf, cells_w, ox, oy);
			blit_tile(out[(sz)tile_index(kx, ky, SLOT_TR, ox, oy) * TILE_BYTES:TILE_BYTES], surf, cells_w, fx + ox, oy);
			blit_tile(out[(sz)tile_index(kx, ky, SLOT_BL, ox, oy) * TILE_BYTES:TILE_BYTES], surf, cells_w, ox, fy + oy);
			blit_tile(out[(sz)tile_index(kx, ky, SLOT_BR, ox, oy) * TILE_BYTES:TILE_BYTES], surf, cells_w, fx + ox, fy + oy);
		}
	}

	// Top and bottom runs: one tile per corner row, each tiled horizontally.
	int mid = kx;
	for (int oy = 0; oy < ky; oy++) {
		blit_tile(out[(sz)hrun_tile_index(kx, ky, oy, false) * TILE_BYTES:TILE_BYTES],
			surf, cells_w, mid, oy);
		blit_tile(out[(sz)hrun_tile_index(kx, ky, oy, true) * TILE_BYTES:TILE_BYTES],
			surf, cells_w, mid, box_rows - ky + oy);
	}

	// Body rows: left edge, interior, right edge -- each from its own surface
	// row, which is what makes the gradient continuous.
	for (int i = 0; i < body; i++) {
		int sy = ky + i;
		blit_tile(out[(sz)row_tile_index(kx, ky, i, 0) * TILE_BYTES:TILE_BYTES], surf, cells_w, 0, sy);
		blit_tile(out[(sz)row_tile_index(kx, ky, i, 1) * TILE_BYTES:TILE_BYTES], surf, cells_w, mid, sy);
		blit_tile(out[(sz)row_tile_index(kx, ky, i, 2) * TILE_BYTES:TILE_BYTES], surf, cells_w, box_w - 1, sy);
	}

}

