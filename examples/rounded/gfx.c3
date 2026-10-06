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
// referencing base_id + radius index directly.

import std::math;

const sz GX = 16;
const sz GY = 34;
const sz CORNER_BYTES = (sz)(GX * GY * 4);
const sz RADII = 8;
const float LINE_W = 2.0f; // matches the weight of box-drawing strokes
const float DIV_W = 1.0f;  // the div outline is exactly 1px

// Declared radius is doubled for drawing (retina cells read small at 1x),
// saturating at a full cell width: a larger arc would leave the cell and the
// box edges would vanish.
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
// (mode 1): the ─ and │ strokes of the neighboring cells sit at the cell
// mid-lines, so the corner arc of radius r is centered at (GX/2 + r, GY/2 + r)
// and joins the strokes tangentially; straight stubs carry the line from the
// arc out to the cell edges. The box is a filled rounded rectangle, so the
// background fills to the cell edge except a rounded outer sliver (matching
// the full-cell background of the neighbouring ─ │ cells); the radius
// saturates at GX/2, where the arc spans the whole cell.
fn void render_corner_bordered(char* buf, sz corner, sz r, uint bg, uint line) {
	for (sz i = 0; i < CORNER_BYTES; i++) buf[i] = 0;

	float br = (float)((bg >> 16) & 0xff) / 255.0f;
	float bgc = (float)((bg >> 8) & 0xff) / 255.0f;
	float bb = (float)(bg & 0xff) / 255.0f;
	float lr = (float)((line >> 16) & 0xff) / 255.0f;
	float lg = (float)((line >> 8) & 0xff) / 255.0f;
	float lb = (float)(line & 0xff) / 255.0f;

	float fr = (float)(r > GX / 2 ? GX / 2 : r);
	float cx = (float)(GX / 2) + fr;
	float cy = (float)(GY / 2) + fr;
	float mid_x = (float)(GX / 2);
	float mid_y = (float)(GY / 2);
	float half_w = LINE_W / 2.0f;

	for (sz y = 0; y < GY; y++) {
		for (sz x = 0; x < GX; x++) {
			sz px = (corner == 1 || corner == 3) ? GX - 1 - x : x;
			sz py = (corner == 2 || corner == 3) ? GY - 1 - y : y;
			float fx = (float)px + 0.5f;
			float fy = (float)py + 0.5f;
			float dx = fx - cx;
			float dy = fy - cy;
			float d = math::sqrt(dx * dx + dy * dy);

			// Background: the box is a filled rounded rectangle, so the corner
			// cell is opaque to the cell edge except the outer rounded sliver.
			// This matches the full-cell background of the neighbouring ─ │ text
			// cells, so the fill is seamless and only the border line shows the
			// rounded corner. The sliver is beyond a quarter-circle of radius
			// fr centered fr px in from the cell's outer corner.
			float odx = fx - fr;
			float ody = fy - fr;
			float bg_a = fclamp(0.5f + (fr - math::sqrt(odx * odx + ody * ody)), 0.0f, 1.0f);
			if (fx >= fr || fy >= fr) bg_a = 1.0f;

			// The single-line border: the corner arc joins the ─ │ strokes at
			// the cell mid-lines. The arc ring follows the arc centered at
			// (cx, cy); the stubs carry the line out to the cell edges.
			float la = 0.0f;
			if (fx >= cx) {
				// Right of the vertical stroke: full box, the horizontal
				// stub carrying the line out to the right edge at mid height.
				la = fclamp(0.5f + half_w - fabsf_(fy - mid_y), 0.0f, 1.0f);
			} else {
				if (fy >= cy) {
					// Below the horizontal stroke: full box, the vertical stub
					// carrying the line down to the bottom edge at mid width.
					la = fclamp(0.5f + half_w - fabsf_(fx - mid_x), 0.0f, 1.0f);
				} else {
					// Corner quadrant: the ring around the arc is the line.
					la = fclamp(0.5f + half_w - fabsf_(d - fr), 0.0f, 1.0f);
				}
			}

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
// outline.
fn void render_corner_set(char[] out, sz mode, sz corner, uint bg, uint line) {
	for (sz f = 0; f < RADII; f++) {
		char[] fbuf = out[(sz)f * CORNER_BYTES:CORNER_BYTES];
		if (mode == 1) {
			render_corner_bordered(fbuf, corner, radius_px(f), bg, line);
		} else if (mode == 2) {
			render_corner(fbuf, corner, radius_px(f), bg, line, DIV_W);
		} else {
			// Plain box: a solid rounded background; no border band. Passing bg
			// as the line color keeps has_line false so nothing is drawn.
			render_corner(fbuf, corner, radius_px(f), bg, bg, LINE_W);
		}
	}
}