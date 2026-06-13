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

struct LayerStyle {
	Shadow shadow;
}

// Distance from point (col, row) to the edge of rect (rx, ry, rw, rh).
// Returns 0 if inside, positive distance if outside.
fn int shadow_edge_dist(int col, int row, int rx, int ry, int rw, int rh) {
	int dx = 0;
	if (col < rx) { dx = rx - col; }
	else if (col >= rx + rw) { dx = col - (rx + rw) + 1; }

	int dy = 0;
	if (row < ry) { dy = ry - row; }
	else if (row >= ry + rh) { dy = row - (ry + rh) + 1; }

	return dx > dy ? dx : dy;
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
	int ext_top = sy - blur;
	int ext_bottom = sy + h + blur;
	int ext_left = sx - blur;
	int ext_right = sx + w + blur;

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
				// Quadratic falloff: darker near core, fades faster at edges
				int t = (blur - dist + 1);
				int range = blur + 1;
				alpha = (int)s.opacity * t * t / (range * range);
			} else {
				continue;
			}

			if (alpha <= 0) continue;

			Cell* dst = &self.cells[(sz)row * self.width + (sz)col];
			Color c = s.color;
			c.a = (char)alpha;
			dst.style.bg = c.blend_over(dst.style.bg);
			dst.style.fg = c.blend_over(dst.style.fg);
			self.dirty_lines[(sz)row] = true;
		}
	}
}
