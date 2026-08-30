module xray;

import std::core::mem;
import std::math;

// ============================================================
// PixelBuffer — color grid where one pixel maps 1:1 to one
// terminal cell. The color-grid sibling of ScreenBuffer: use it
// when you want to draw pixel art or game sprites without
// managing Cell contents yourself. to_cells turns the grid into
// cells for a milktea cell view (space glyph, pixel color as the
// cell background).
// ============================================================

struct PixelBuffer {
	Color[] pixels; // flat grid: width * height
	sz width;
	sz height;
}

// new_pixel_buffer allocates a buffer of the given dimensions and
// clears every pixel to the default (none) color.
fn PixelBuffer* new_pixel_buffer(sz width, sz height) {
	PixelBuffer* pb = mem::new(PixelBuffer);
	pb.width = width;
	pb.height = height;
	pb.pixels = mem::new_array(Color, width * height);
	pb.clear(color_none());
	return pb;
}

// destroy frees the pixel array.
fn void PixelBuffer.destroy(&self) {
	mem::free(self.pixels.ptr);
}

// in_bounds reports whether (col, row) lies inside the grid.
fn bool PixelBuffer.in_bounds(&self, sz col, sz row) {
	return col < self.width && row < self.height;
}

// clear sets every pixel to the given color.
fn void PixelBuffer.clear(&self, Color c) {
	sz total = self.width * self.height;
	for (sz i = 0; i < total; i++) {
		self.pixels[i] = c;
	}
}

// set_pixel writes a pixel, ignoring out-of-bounds coordinates.
fn void PixelBuffer.set_pixel(&self, int col, int row, Color c) {
	if (col < 0 || row < 0 || (sz)col >= self.width || (sz)row >= self.height) return;
	self.pixels[(sz)row * self.width + (sz)col] = c;
}

// get_pixel returns the pixel at (col, row), or none if out of bounds.
fn Color PixelBuffer.get_pixel(&self, int col, int row) {
	if (col < 0 || row < 0 || (sz)col >= self.width || (sz)row >= self.height) return color_none();
	return self.pixels[(sz)row * self.width + (sz)col];
}

// blend_pixel alpha-blends `c` over the pixel already at (col, row).
fn void PixelBuffer.blend_pixel(&self, int col, int row, Color c) {
	if (col < 0 || row < 0 || (sz)col >= self.width || (sz)row >= self.height) return;
	sz idx = (sz)row * self.width + (sz)col;
	self.pixels[idx] = c.blend_over(self.pixels[idx]);
}

// _gradient_color resolves the fill color at step t of max_t: the flat
// color c when `to` is unset, otherwise a gradient interpolated toward
// `to` in the chosen space.
fn Color _gradient_color(Color c, Color to, BlendSpace space, int t, int max_t) @local {
	if (to.is_none() || max_t <= 0) return c;
	return blend_gradient(c, to, space, (double)t / (double)max_t);
}

// fill_rect fills the given rect with c, or with a gradient from c (top)
// to `to` (bottom) when `to` is set. Clips to the grid.
fn void PixelBuffer.fill_rect(&self, Rect r, Color c, Color to = { }, BlendSpace space = BlendSpace.LUV) {
	if (r.w <= 0 || r.h <= 0) return;
	int max_t = r.h > 1 ? r.h - 1 : 1;
	for (int row = 0; row < r.h; row++) {
		int abs_row = r.y + row;
		if (abs_row < 0 || (sz)abs_row >= self.height) continue;
		Color col = _gradient_color(c, to, space, row, max_t);
		sz base = (sz)abs_row * self.width;
		for (int col_i = 0; col_i < r.w; col_i++) {
			int abs_col = r.x + col_i;
			if (abs_col < 0 || (sz)abs_col >= self.width) continue;
			self.pixels[base + (sz)abs_col] = col;
		}
	}
}

// fill_ellipse fills a solid ellipse centred at (cx, cy) with the given
// radii, or with a gradient from c at the centre toward `to` at the rim
// when `to` is set. Clips to the grid.
fn void PixelBuffer.fill_ellipse(&self, int cx, int cy, int rx, int ry, Color c, Color to = { }, BlendSpace space = BlendSpace.LUV) {
	if (rx <= 0 || ry <= 0) return;
	bool grad = !to.is_none();
	int x0 = cx - rx;
	if (x0 < 0) x0 = 0;
	int y0 = cy - ry;
	if (y0 < 0) y0 = 0;
	int x1 = cx + rx;
	if (x1 >= (int)self.width) x1 = (int)self.width - 1;
	int y1 = cy + ry;
	if (y1 >= (int)self.height) y1 = (int)self.height - 1;
	for (int y = y0; y <= y1; y++) {
		float fdy = ((float)y - (float)cy) / (float)ry;
		sz base = (sz)y * self.width;
		for (int x = x0; x <= x1; x++) {
			float fdx = ((float)x - (float)cx) / (float)rx;
			float t = math::sqrt(fdx * fdx + fdy * fdy);
			if (!grad && t > 1.0f) continue;
			if (t > 1.0f) t = 1.0f;
			if (grad) {
				self.pixels[base + (sz)x] = blend_gradient(c, to, space, (double)t);
			} else {
				self.pixels[base + (sz)x] = c;
			}
		}
	}
}

// draw_line walks a line from (x0, y0) to (x1, y1), writing one pixel
// per step; with `to` set the color interpolates from c at the start to
// `to` at the end.
fn void PixelBuffer.draw_line(&self, int x0, int y0, int x1, int y1, Color c, Color to = { }, BlendSpace space = BlendSpace.LUV) {
	int dx = x1 - x0;
	int dy = y1 - y0;
	int steps = dx < 0 ? -dx : dx;
	int dy_abs = dy < 0 ? -dy : dy;
	if (steps < dy_abs) steps = dy_abs;
	if (steps < 1) steps = 1;
	for (int i = 0; i <= steps; i++) {
		Color col = _gradient_color(c, to, space, i, steps);
		self.set_pixel(x0 + (dx * i) / steps, y0 + (dy * i) / steps, col);
	}
}

// to_cells writes the grid into a flat cell array 1:1: each pixel
// becomes one cell whose background is the pixel color and whose
// content is a space. `grid_width` is the cell grid's row stride;
// rows beyond the buffer or the array are skipped.
fn void PixelBuffer.to_cells(&self, Cell[] cells, sz grid_width, Style base_style) {
	if (grid_width == 0 || cells.len == 0) return;
	sz w = self.width < grid_width ? self.width : grid_width;
	sz h = self.height;
	sz rows_fit = cells.len / grid_width;
	if (h > rows_fit) h = rows_fit;

	for (sz row = 0; row < h; row++) {
		sz src_base = row * self.width;
		sz dst_base = row * grid_width;
		for (sz col = 0; col < w; col++) {
			Cell c = empty_cell();
			c.style = base_style.set_bg(self.pixels[src_base + col]);
			cells[dst_base + col] = c;
		}
	}
}
