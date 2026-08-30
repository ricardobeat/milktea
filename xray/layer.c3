module xray;

struct Shadow {
	// Offsets are in square units, not cells. A terminal cell is about twice as
	// tall as it is wide, so offset_x counts double columns and offset_y counts
	// rows: shadow(1, 1) puts the shadow two columns right and one row down,
	// the same physical distance on each axis.
	int offset_x;
	// Vertical offset, counted in half-rows: 2 is one row, 1 half of one.
	// shadow() takes the same offset in whole rows and converts.
	// 
	// Only the half-block path can place a shadow on a half-row boundary; with
	// half_blocks off, shadow() rounds an odd value out to a whole row.
	int offset_y;
	char opacity;
	Color color;
	bool enabled;
	int blur; // blur radius in cells (0 = hard edge)
	// Draw the fringe with half blocks, doubling its vertical resolution and
	// allowing half-row offsets. Safe only over blank space; see shadow().
	bool half_blocks;
}

// shadow builds a drop shadow. offset_x is in double columns and offset_y in
// rows, so the two cover the same physical distance (see Shadow).
// 
// half_blocks draws each blank fringe cell as ▀, one colour above and another
// below, which doubles the vertical resolution of the gradient and lets
// offset_y take halves:
// 
//     shadow(1, 1)                               // two columns right, one row down
//     shadow(1, 0.5, 128, 3, half_blocks: true)  // half a row down
// 
// A half block claims the cell's foreground, and a space painted by content is
// indistinguishable from a blank cell, so a shadow with this on will replace
// the spaces in text that an earlier node drew underneath it. Use it where the
// shadow falls on empty background. With it off the fringe tints backgrounds
// only, and text under the shadow darkens.
fn Shadow shadow(int offset_x = 1, double offset_y = 1.0, char opacity = 128, int blur = 0, bool half_blocks = false) {
	// Round to the nearest half-row, so 0.5 lands on a half-step and 0.7 on the
	// nearer one.
	double halves = offset_y * 2.0;
	int half_off  = (int)(halves < 0.0 ? halves - 0.5 : halves + 0.5);
	// Only the half-block path can draw a half-step, so without it round out to
	// a whole row.
	if (!half_blocks && (half_off & 1) != 0) half_off += half_off < 0 ? -1 : 1;
	return {
		.offset_x = offset_x,
		.offset_y = half_off,
		.opacity = opacity,
		.color = color_rgb(0, 0, 0),
		.enabled = true,
		.blur = blur,
		.half_blocks = half_blocks,
	};
}

fn Shadow Shadow.with_color(self, Color c) {
	Shadow s = self;
	s.color = c;
	return s;
}

struct InnerShadow {
	int top;
	int right;
	int bottom;
	int left;
	char opacity;
	Color color;
	bool enabled;
}

fn InnerShadow inner_shadow(int top = 0, int right = 0, int bottom = 0, int left = 0, char opacity = 60) {
	return {
		.top = top,
		.right = right,
		.bottom = bottom,
		.left = left,
		.opacity = opacity,
		.color = color_rgb(0, 0, 0),
		.enabled = true,
	};
}

fn InnerShadow InnerShadow.with_color(self, Color c) {
	InnerShadow s = self;
	s.color = c;
	return s;
}

struct LayerStyle {
	Shadow shadow;
	InnerShadow inner_shadow;
}

// Distance from point (col, row) to the edge of rect (rx, ry, rw, rh).
// Returns 0 if inside, positive distance if outside.
fn int shadow_edge_dist(int col, int row, int rx, int ry, int rw, int rh) {
	int dx = 0;
	if (col < rx) {
		dx = rx - col;
	} else if (col >= rx + rw) {
		dx = col - (rx + rw) + 1;
	}

	int dy = 0;
	if (row < ry) {
		dy = ry - row;
	} else if (row >= ry + rh) {
		dy = row - (ry + rh) + 1;
	}

	return dx > dy ? dx : dy;
}

// Upper half block. Its foreground paints the top half of the cell and its
// background the bottom, giving a shadow two vertical samples per cell.
const String HALF_BLOCK_UPPER = "▀";

// shadow_edge_dist_half is shadow_edge_dist measured in half-rows vertically.
// `half_row` counts half-cells from the top of the buffer (row*2, row*2+1), and
// the rect's vertical bounds are doubled to match, so a vertical distance of 1
// means half a cell rather than a whole one.
// 
// Horizontal distance is in whole cells, doubled so both axes are in half-cell
// units. That also makes the blur radius physically round rather than an
// ellipse stretched down the screen: `blur` cells sideways covers the same
// distance as `blur` rows, which are twice as tall.
fn int shadow_edge_dist_half(int col, int half_row, int rx, int ry, int rw, int rh) {
	int dx = 0;
	if (col < rx) {
		dx = rx - col;
	} else if (col >= rx + rw) {
		dx = col - (rx + rw) + 1;
	}

	int top    = ry * 2;
	int bottom = (ry + rh) * 2;
	int dy     = 0;
	if (half_row < top) {
		dy = top - half_row;
	} else if (half_row >= bottom) {
		dy = half_row - bottom + 1;
	}

	dx *= 2;
	return dx > dy ? dx : dy;
}

// shadow_alpha_at is the fringe falloff, in half-cell units. blend_over is
// linear in alpha, so an evenly spaced alpha ramp gives evenly spaced
// luminance.
fn int shadow_alpha_at(int dist_half, int blur, int opacity) {
	if (dist_half <= 0) return opacity;
	int span = blur * 2;
	if (dist_half > span) return 0;
	return opacity * (span - dist_half + 1) / (span + 1);
}

// shadow_half blends one half of a half-block cell over what is under it.
// 
// A zero alpha means the fringe has run out, and the surface underneath is
// returned untouched: blend_over reads Color.a == 0 as opaque (see
// effective_alpha), so blending would paint the shadow at full strength.
fn Color shadow_half(Color shade, int alpha, Color under) {
	if (alpha <= 0) return under;
	Color c = shade;
	c.a = (char)alpha;
	return c.blend_over(under);
}

// can_half_block reports whether a cell may be replaced by a half block. Only a
// blank, unstyled cell qualifies: the half block occupies the foreground, so
// writing one into a cell that holds a character erases it. Every other cell
// gets its background tinted instead, and the text in it darkens.
fn bool Cell.can_half_block(&self) {
	if (self.content_len != 1 || self.content[0] != ' ') return false;
	// A wide cell's second half is a zero-width continuation; splitting it
	// would desynchronise the pair.
	if (self.width != 1) return false;
	// A space with a foreground of its own was written by content — the gap
	// between two words in a rendered string, say — and the run may style it
	// (underline, a background it shares with its neighbours). Taking the cell
	// for a half block would put a ▀ in the middle of that text, so only an
	// untouched cell qualifies.
	if (!self.style.fg.is_none()) return false;
	Attrs none;
	return self.style.attrs == none;
}

fn void ScreenBuffer.render_inner_shadow(&self, int x, int y, int w, int h, InnerShadow s) {
	if (!s.enabled || s.opacity == 0) return;

	for (int row = y; row < y + h; row++) {
		if (row < 0 || row >= (int)self.height) continue;
		for (int col = x; col < x + w; col++) {
			if (col < 0 || col >= (int)self.width) continue;

			int min_dist = w > h ? w : h;

			if (s.top > 0) {
				int d = row - y;
				if (d < s.top && d < min_dist) min_dist = d;
			}
			if (s.bottom > 0) {
				int d = (y + h - 1) - row;
				if (d < s.bottom && d < min_dist) min_dist = d;
			}
			if (s.left > 0) {
				int d = col - x;
				if (d < s.left && d < min_dist) min_dist = d;
			}
			if (s.right > 0) {
				int d = (x + w - 1) - col;
				if (d < s.right && d < min_dist) min_dist = d;
			}

			int max_edge = s.top;
			if (s.right > max_edge) max_edge = s.right;
			if (s.bottom > max_edge) max_edge = s.bottom;
			if (s.left > max_edge) max_edge = s.left;

			if (min_dist >= max_edge) continue;

			int t     = max_edge - min_dist;
			int alpha = (int)s.opacity * t * t / (max_edge * max_edge);
			if (alpha <= 0) continue;

			Cell* dst = &self.cells[(sz)row * self.width + (sz)col];
			Color c   = s.color;
			c.a = (char)alpha;
			dst.style.bg = c.blend_over(dst.style.bg);
			dst.style.fg = c.blend_over(dst.style.fg);
			self.dirty_lines[(sz)row] = true;
		}
	}
}

fn void ScreenBuffer.render_shadow(&self, int x, int y, int w, int h, Shadow s) {
	if (!s.enabled || s.opacity == 0) return;

	// offset_x is in double columns (see Shadow): one unit right is two cells,
	// which is the same physical distance as one row down.
	int sx         = x + s.offset_x * 2;
	// The vertical offset is in half-rows. Whole rows move the shadow's rect; a

	// leftover half-row is carried into the sampling below, the only place that

	// can express it.

	int sy         = y + s.offset_y / 2;
	int extra_half = s.offset_y - (s.offset_y / 2) * 2;

	if (s.blur == 0) {
		Color blend_color = s.color;
		blend_color.a = s.opacity;

		for (int row = sy; row < sy + h; row++) {
			for (int col = sx; col < sx + w; col++) {
				if (col >= x && col < x + w && row >= y && row < y + h) continue;
				if (col < 0 || row < 0 || col >= (int)self.width || row >= (int)self.height) continue;

				Cell* dst = &self.cells[(sz)row * self.width + (sz)col];
				dst.style.bg = blend_color.blend_over(dst.style.bg);
				dst.style.fg = blend_color.blend_over(dst.style.fg);
				self.dirty_lines[(sz)row] = true;
			}
		}
		return;
	}

	// Blurred shadow: the core shadow area gets full opacity, then opacity
	// falls off over `blur` cells beyond the core edges.
	int blur = s.blur;

	// Core shadow plus the blur margin on all sides, and one more row at the
	// bottom when a half-row offset pushes the fringe into it.
	int ext_top    = sy - blur;
	int ext_bottom = sy + h + blur + extra_half;
	int ext_left   = sx - blur;
	int ext_right  = sx + w + blur;

	for (int row = ext_top; row < ext_bottom; row++) {
		if (row < 0 || row >= (int)self.height) continue;
		for (int col = ext_left; col < ext_right; col++) {
			if (col < 0 || col >= (int)self.width) continue;
			// Skip cells inside the content overlay region
			if (col >= x && col < x + w && row >= y && row < y + h) continue;

			// Sample the falloff at both halves of the cell. A cell is about
			// twice as tall as it is wide, so the vertical fringe is the one
			// that bands, and a half block gives it twice the resolution.
			// 
			// A leftover half-row shifts the sample point up half a cell, which
			// slides the shadow down by the same amount.
			int top_a = shadow_alpha_at(
				shadow_edge_dist_half(col, row * 2 - extra_half, sx, sy, w, h),
				blur,
				(int)s.opacity
			);
			int bot_a = shadow_alpha_at(
				shadow_edge_dist_half(col, row * 2 + 1 - extra_half, sx, sy, w, h),
				blur,
				(int)s.opacity
			);

			if (top_a <= 0 && bot_a <= 0) continue;

			Cell* dst = &self.cells[(sz)row * self.width + (sz)col];

			// Two different halves and a cell with nothing to lose: draw the
			// gradient inside it. A half block's foreground is its top half and
			// its background the bottom.
			if (s.half_blocks && top_a != bot_a && dst.can_half_block()) {
				Color under = dst.style.bg;
				dst.content[0] = HALF_BLOCK_UPPER[0];
				dst.content[1] = HALF_BLOCK_UPPER[1];
				dst.content[2] = HALF_BLOCK_UPPER[2];
				dst.content_len = 3;
				dst.width = 1;
				// shadow_half returns the surface untouched where the fringe
				// has run out, rather than blending a zero alpha.
				dst.style.fg = shadow_half(s.color, top_a, under);
				dst.style.bg = shadow_half(s.color, bot_a, under);
				self.dirty_lines[(sz)row] = true;
				continue;
			}

			// Otherwise tint the whole cell. A cell holding a glyph takes this
			// path, so the character survives with a darker background.
			int flat = top_a > bot_a ? top_a : bot_a;
			if (top_a > 0 && bot_a > 0) flat = (top_a + bot_a) / 2;
			if (flat <= 0) continue;

			Color c = s.color;
			c.a = (char)flat;
			dst.style.bg = c.blend_over(dst.style.bg);
			dst.style.fg = c.blend_over(dst.style.fg);
			self.dirty_lines[(sz)row] = true;
		}
	}
}