module xray;

// Recorded before cell compositing, so transparent backgrounds keep the
// vector surface beneath them instead of inheriting a flattened cell colour.
enum PaintKind : char { CELL, DECORATION, TINT }

struct PaintOp {
	PaintKind kind;
	int col, row;
	bool pixels;
	int bg_w, bg_h;
	Cell cell;
	Decoration decoration;
	Color tint;
}

fn void ScreenBuffer.record_cell(&self, sz col, sz row, Cell cell) {
	if (!self.record_paint) return;
	if (self.decorated_content) cell.style.bg = color_transparent();
	int w = self.paint_metrics.unit_w();
	int h = self.paint_metrics.unit_h();
	int x = (int)col * w + self.paint_dx;
	int y = (int)row * h + self.paint_dy;
	int bg_w = w;
	int bg_h = h;
	// The last whole text cell carries the background into the unused pixel strip.
	if (self.paint_metrics.pixels) {
		if (x + w <= self.paint_extent.right() && x + w * 2 > self.paint_extent.right()) {
			bg_w = self.paint_extent.right() - x;
		}
		if (y + h <= self.paint_extent.bottom() && y + h * 2 > self.paint_extent.bottom()) {
			bg_h = self.paint_extent.bottom() - y;
		}
	}
	if (self.paint_metrics.pixels) {
		int glyph_w = cell.width > 1 ? w * (int)cell.width : w;
		int visible_w = glyph_w > bg_w ? glyph_w : bg_w;
		if (x + visible_w <= 0 || y + bg_h <= 0
			|| x >= self.width * w || y >= self.height * h) return;
	}
	self.paint_ops.push({ .kind = PaintKind.CELL, .col = x,
		.row = y, .cell = cell, .pixels = self.paint_metrics.pixels,
		.bg_w = bg_w, .bg_h = bg_h });
}

fn void ScreenBuffer.record_tint(&self, int col, int row, Color tint) {
	if (!self.record_paint) return;
	self.paint_ops.push({ .kind = PaintKind.TINT, .col = col * self.paint_metrics.unit_w() + self.paint_dx,
		.row = row * self.paint_metrics.unit_h() + self.paint_dy, .tint = tint,
		.pixels = self.paint_metrics.pixels });
}
