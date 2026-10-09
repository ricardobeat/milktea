module rounded;

// Corner- and edge-glyph rendering for the rounded-box demo. Each cell whose
// corner or border is drawn becomes a kitty-graphics image 16x34 px, matching
// the terminal cell's ~1:2 aspect at its natural size (some terminals render
// cells 2px taller than a strict 2:1 grid; the extra rows keep the box
// background flush with neighboring cells).
//
// Three rendering modes, one per box:
//   0. plain:  the box is just a background region; the corner glyph paints
//              bg everywhere except a corner sliver beyond a quarter-circle
//              arc of radius r (the rounded corner). The arc is the rounded
//              rect's corner arc, r px in from both box edges.
//   1. border: single-line border made of ─ │ text strokes, which sit at the
//              cell mid-lines; the corner arc of radius r is centered at
//              (GX/2 + r, GY/2 + r) and joins the strokes tangentially, with
//              straight stubs carrying the line out to the cell edges.
//   2. div:    a 1px outline around the whole box, all drawn as glyphs; the
//              bg is fully contained inside the outline. Corner glyphs draw
//              the band along the arc and the straight outline edges; edge
//              glyphs paint a 1px line along the cell's outer edge.
//
// One glyph holds all radii as frames (frame i = radius 2*(i+1) px, up to a
// full cell width for the roundest corner); the view picks a frame by
// referencing base_id + radius index directly. A border corner's arc starts
// half a cell in, so past half a cell it runs into the ─ beside it, which gets
// a glyph of its own (the shoulder).

import std::math;

const sz GX = 16;
const sz GY = 34;
const sz CORNER_BYTES = (sz)(GX * GY * 4);
const sz RADII = 8;
const float LINE_W = 2.0f; // matches the weight of box-drawing strokes
const float DIV_W = 1.0f;  // the div outline is exactly 1px

// Declared radius is doubled for drawing (retina cells read small at 1x).
fn sz radius_px(sz idx) => (idx + 1) * 2;

fn float fclamp(float x, float lo, float hi) => x < lo ? lo : (x > hi ? hi : x);
fn float fabsf_(float x) => x < 0.0f ? -x : x;

// put alpha-composites one coverage sample over the frame buffer.
fn void put(char* buf, sz x, sz y, float r, float g, float b, float a) {
	if (x < 0 || x >= GX || y < 0 || y >= GY || a <= 0) return;
	sz i = (y * GX + x) * 4;
	float da = (float)((sz)buf[i + 3] & 0xff) / 255.0f;
	float oa = a + da * (1.0f - a);
	if (oa <= 0) return;
	float dr = (float)((sz)buf[i] & 0xff) / 255.0f;
	float dg = (float)((sz)buf[i + 1] & 0xff) / 255.0f;
	float db = (float)((sz)buf[i + 2] & 0xff) / 255.0f;
	float w = da * (1.0f - a) / oa;
	float wa = a / oa;
	buf[i]     = (char)(sz)(255.0f * fclamp(r * wa + dr * w, 0, 1));
	buf[i + 1] = (char)(sz)(255.0f * fclamp(g * wa + dg * w, 0, 1));
	buf[i + 2] = (char)(sz)(255.0f * fclamp(b * wa + db * w, 0, 1));
	buf[i + 3] = (char)(sz)(oa * 255.0f);
}

// render_corner draws one frame for the plain (mode 0) and div (mode 2)
// corners. Geometry is always computed as top-left, then mirrored per corner.
// When line != bg, a border band lw px wide is drawn along the arc and the
// straight outline edges, wrapping the background inside the corner.
fn void render_corner(char* buf, sz corner, sz r, uint bg, uint line, float lw) {
	for (sz i = 0; i < CORNER_BYTES; i++) buf[i] = 0;

	float br = (float)((bg >> 16) & 0xff) / 255.0f;
	float bgc = (float)((bg >> 8) & 0xff) / 255.0f;
	float bb = (float)(bg & 0xff) / 255.0f;
	float lr = (float)((line >> 16) & 0xff) / 255.0f;
	float lg = (float)((line >> 8) & 0xff) / 255.0f;
	float lb = (float)(line & 0xff) / 255.0f;

	// The rounded rect's corner arc sits r px in from both box edges, so in
	// the top-left frame its center is at (r, r) from the cell's outer corner.
	float fr = (float)(r > GX ? GX : r);
	float half_w = lw / 2.0f;
	bool has_line = line != bg;

	for (sz y = 0; y < GY; y++) {
		for (sz x = 0; x < GX; x++) {
			sz px = (corner == 1 || corner == 3) ? GX - 1 - x : x;
			sz py = (corner == 2 || corner == 3) ? GY - 1 - y : y;
			float fx = (float)px + 0.5f;
			float fy = (float)py + 0.5f;
			float dx = fx - fr;
			float dy = fy - fr;
			float d = math::sqrt(dx * dx + dy * dy);

			// Background: everything except the corner sliver beyond the arc
			// (fx < r and fy < r and outside the circle). The circle interior
			// is background, anti-aliased across the arc; the straight box
			// edges (fx >= r, fy >= r) are always background, so the glyph is
			// opaque wherever it borders neighboring cells.
			float bg_a = fclamp(0.5f + (fr - d), 0.0f, 1.0f);
			if (fx >= fr || fy >= fr) bg_a = 1.0f;
			if (bg_a > 0) put(buf, x, y, br, bgc, bb, bg_a);
			if (has_line) {
				// The border follows the outline: the arc in the corner
				// quadrant, then straight bands along the top and left edges
				// from the arc ends to the cell edges.
				float la = 0.0f;
				if (fx < fr && fy < fr) la = fclamp(0.5f + half_w - fabsf_(d - fr), 0.0f, 1.0f);
				if (fx >= fr) la = math::max(la, fclamp(0.5f + lw - fy, 0.0f, 1.0f));
				if (fy >= fr) la = math::max(la, fclamp(0.5f + lw - fx, 0.0f, 1.0f));
				if (la > 0) put(buf, x, y, lr, lg, lb, la);
			}
		}
	}
}

// render_corner_bordered draws one frame of the single-line-border corner
// (mode 1), and of its shoulder: the ─ cell beside it. The ─ and │ strokes of
// the neighboring cells sit at the cell mid-lines, so the corner arc of
// radius r is centered at (GX/2 + r, GY/2 + r) and joins the strokes
// tangentially; straight stubs carry the line from the arc out to the cell
// edges. An arc wider than half a cell runs on into the shoulder, which is
// why the corner is drawn across two cells: geometry is computed for the
// pair laid out top-left, corner then shoulder, and mirrored per corner.
// The background sits the same distance outside the line everywhere: the
// │ stroke is half a cell from the box's side, so the background starts half
// a cell's width above the ─ stroke, and rounds concentric with the arc.
fn void render_corner_bordered(char* buf, char* shoulder, sz corner, sz r, uint bg, uint line) {
	for (sz i = 0; i < CORNER_BYTES; i++) {
		buf[i] = 0;
		shoulder[i] = 0;
	}

	float br = (float)((bg >> 16) & 0xff) / 255.0f;
	float bgc = (float)((bg >> 8) & 0xff) / 255.0f;
	float bb = (float)(bg & 0xff) / 255.0f;
	float lr = (float)((line >> 16) & 0xff) / 255.0f;
	float lg = (float)((line >> 8) & 0xff) / 255.0f;
	float lb = (float)(line & 0xff) / 255.0f;

	float mid_x = (float)(GX / 2);
	float mid_y = (float)(GY / 2);
	// The arc must turn down before the corner cell's bottom edge, where the
	// │ stroke below takes over.
	float max_r = (float)GY - mid_y;
	float fr = (float)r > max_r ? max_r : (float)r;
	float cx = mid_x + fr;
	float cy = mid_y + fr;
	float half_w = LINE_W / 2.0f;
	bool right = corner == 1 || corner == 3;
	bool bottom = corner == 2 || corner == 3;

	for (sz cell = 0; cell < 2; cell++) {
		char* out = cell == 0 ? buf : shoulder;
		for (sz y = 0; y < GY; y++) {
			for (sz x = 0; x < GX; x++) {
				// Pair coordinates: the corner cell is 0..GX, the shoulder
				// GX..2GX, mirrored so the corner is always on the outside.
				sz px = cell * GX + (right ? GX - 1 - x : x);
				sz py = bottom ? GY - 1 - y : y;
				float fx = (float)px + 0.5f;
				float fy = (float)py + 0.5f;
				float dx = fx - cx;
				float dy = fy - cy;
				float d = math::sqrt(dx * dx + dy * dy);

				// Background: the line's arc grown by the gap between the │
				// stroke and the box's side edge, so the background keeps the
				// same distance outside the line all the way round. Along the
				// top it starts that far above the ─ stroke, as the border row
				// cells do.
				float bg_a;
				if (fx < cx && fy < cy) {
					bg_a = fclamp(0.5f + (fr + mid_x - d), 0.0f, 1.0f);
				} else if (fx >= cx) {
					bg_a = fclamp(0.5f + fy - (mid_y - mid_x), 0.0f, 1.0f);
				} else {
					bg_a = 1.0f;
				}

				// The line: the ring around the arc in the corner quadrant,
				// and stubs out to the edges where the strokes continue.
				float la = 0.0f;
				if (fx >= cx) {
					la = fclamp(0.5f + half_w - fabsf_(fy - mid_y), 0.0f, 1.0f);
				} else if (fy >= cy) {
					la = fclamp(0.5f + half_w - fabsf_(fx - mid_x), 0.0f, 1.0f);
				} else {
					la = fclamp(0.5f + half_w - fabsf_(d - fr), 0.0f, 1.0f);
				}

				if (bg_a > 0) put(out, x, y, br, bgc, bb, bg_a);
				if (la > 0) put(out, x, y, lr, lg, lb, la);
			}
		}
	}
}

// render_border_row draws the ─ cell of the bordered box's top (or, flipped,
// bottom) row. The stroke sits at the cell's mid-line, where the corner's arc
// meets it, and the background starts as far above it as the │ stroke is from
// the box's side, so the gap outside the line is even on every edge. A text
// ─ cannot do this: its background always fills the whole cell.
fn void render_border_row(char* buf, bool bottom, uint bg, uint line) {
	for (sz i = 0; i < CORNER_BYTES; i++) buf[i] = 0;

	float br = (float)((bg >> 16) & 0xff) / 255.0f;
	float bgc = (float)((bg >> 8) & 0xff) / 255.0f;
	float bb = (float)(bg & 0xff) / 255.0f;
	float lr = (float)((line >> 16) & 0xff) / 255.0f;
	float lg = (float)((line >> 8) & 0xff) / 255.0f;
	float lb = (float)(line & 0xff) / 255.0f;

	float mid_x = (float)(GX / 2);
	float mid_y = (float)(GY / 2);
	for (sz y = 0; y < GY; y++) {
		float fy = (float)(bottom ? GY - 1 - y : y) + 0.5f;
		float bg_a = fclamp(0.5f + fy - (mid_y - mid_x), 0.0f, 1.0f);
		float la = fclamp(0.5f + LINE_W / 2.0f - fabsf_(fy - mid_y), 0.0f, 1.0f);
		for (sz x = 0; x < GX; x++) {
			if (bg_a > 0) put(buf, x, y, br, bgc, bb, bg_a);
			if (la > 0) put(buf, x, y, lr, lg, lb, la);
		}
	}
}

// render_edge draws one frame of a div-outline edge cell (mode 2): the box
// background fills the whole cell and a 1px line of the border color runs
// along the cell's outer edge (0=top 1=right 2=bottom 3=left), so the
// background is fully contained inside the outline.
fn void render_edge(char* buf, sz edge, uint bg, uint line) {
	for (sz i = 0; i < CORNER_BYTES; i++) buf[i] = 0;

	float br = (float)((bg >> 16) & 0xff) / 255.0f;
	float bgc = (float)((bg >> 8) & 0xff) / 255.0f;
	float bb = (float)(bg & 0xff) / 255.0f;
	float lr = (float)((line >> 16) & 0xff) / 255.0f;
	float lg = (float)((line >> 8) & 0xff) / 255.0f;
	float lb = (float)(line & 0xff) / 255.0f;

	for (sz y = 0; y < GY; y++) {
		for (sz x = 0; x < GX; x++) {
			sz px = (edge == 1) ? GX - 1 - x : x;
			sz py = (edge == 2) ? GY - 1 - y : y;
			float fx = (float)px + 0.5f;
			float fy = (float)py + 0.5f;

			put(buf, x, y, br, bgc, bb, 1.0f);
			// Distance from the cell's outer edge; the line hugs it.
			float la = fclamp(0.5f + DIV_W - (edge == 1 || edge == 3 ? fx : fy), 0.0f, 1.0f);
			if (la > 0) put(buf, x, y, lr, lg, lb, la);
		}
	}
}

// render_corner_set renders all radius frames for one corner into out
// (RADII * CORNER_BYTES bytes). mode: 0 plain, 1 single-line border, 2 div
// outline. Mode 1 also fills shoulder, the same size, with the frames of the
// ─ cell beside the corner; the other modes leave it alone.
fn void render_corner_set(char[] out, char[] shoulder, sz mode, sz corner, uint bg, uint line) {
	for (sz f = 0; f < RADII; f++) {
		char[] fbuf = out[(sz)f * CORNER_BYTES:CORNER_BYTES];
		if (mode == 1) {
			char[] sbuf = shoulder[(sz)f * CORNER_BYTES:CORNER_BYTES];
			render_corner_bordered(fbuf, sbuf, corner, radius_px(f), bg, line);
		} else if (mode == 2) {
			render_corner(fbuf, corner, radius_px(f), bg, line, DIV_W);
		} else {
			// Plain box: a solid rounded background; no border band. Passing bg
			// as the line color keeps has_line false so nothing is drawn.
			render_corner(fbuf, corner, radius_px(f), bg, bg, LINE_W);
		}
	}
}