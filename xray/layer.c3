module xray;

struct Shadow {
	int offset_x;
	int offset_y;
	char opacity;
	Color color;
	bool enabled;
	int blur; // blur radius in cells (0 = hard edge)
}

fn Shadow shadow(int offset_x = 1, int offset_y = 1, char opacity = 128, int blur = 0) {
	return {
		.offset_x = offset_x,
		.offset_y = offset_y,
		.opacity = opacity,
		.color = color_rgb(0, 0, 0),
		.enabled = true,
		.blur = blur,
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

	int sx = x + s.offset_x;
	int sy = y + s.offset_y;

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

	// Extended region: core shadow + blur margin on all sides
	int ext_top    = sy - blur;
	int ext_bottom = sy + h + blur;
	int ext_left   = sx - blur;
	int ext_right  = sx + w + blur;

	for (int row = ext_top; row < ext_bottom; row++) {
		if (row < 0 || row >= (int)self.height) continue;
		for (int col = ext_left; col < ext_right; col++) {
			if (col < 0 || col >= (int)self.width) continue;
			// Skip cells inside the content overlay region
			if (col >= x && col < x + w && row >= y && row < y + h) continue;

			// Distance from core shadow rect (0 = inside core, >0 = in blur fringe)
			int dist = shadow_edge_dist(col, row, sx, sy, w, h);

			int alpha;
			if (dist <= 0) {
				alpha = (int)s.opacity;
			} else if (dist <= blur) {
				// Linear falloff. blend_over is linear in alpha, so an evenly
				// spaced alpha ramp is what produces evenly spaced luminance —
				// which is what the eye reads as smooth. The quadratic this
				// replaced dropped 44% of the opacity in the first step and
				// spent its last step nearly invisible, so the fringe banded at
				// the core edge and wasted its far end.
				int t     = blur - dist + 1;
				int range = blur + 1;
				alpha = (int)s.opacity * t / range;
			} else {
				continue;
			}

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