module xray;

// Recorded before cell compositing, so transparent backgrounds keep the
// vector surface beneath them instead of inheriting a flattened cell colour.
enum PaintKind : char { CELL, DECORATION, TINT }

struct PaintOp {
	PaintKind kind;
	sz col, row;
	bool pixels;
	sz bg_w, bg_h;
	Cell cell;
	Decoration decoration;
	Color tint;
}

fn void ScreenBuffer.record_cell(&self, sz col, sz row, Cell cell) {
	if (!self.record_paint) return;
	if (self.decorated_content) cell.style.bg = color_transparent();
	sz w = self.paint_metrics.unit_w();
	sz h = self.paint_metrics.unit_h();
	sz x = (sz)col * w + self.paint_dx;
	sz y = (sz)row * h + self.paint_dy;
	sz bg_w = w;
	sz bg_h = h;
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
		sz glyph_w = cell.width > 1 ? w * (sz)cell.width : w;
		sz visible_w = glyph_w > bg_w ? glyph_w : bg_w;
		if (x + visible_w <= 0 || y + bg_h <= 0
			|| x >= self.width * w || y >= self.height * h) return;
	}
	self.paint_ops.push({ .kind = PaintKind.CELL, .col = x,
		.row = y, .cell = cell, .pixels = self.paint_metrics.pixels,
		.bg_w = bg_w, .bg_h = bg_h });
}

fn void ScreenBuffer.record_tint(&self, sz col, sz row, Color tint) {
	if (!self.record_paint) return;
	self.paint_ops.push({ .kind = PaintKind.TINT, .col = col * self.paint_metrics.unit_w() + self.paint_dx,
		.row = row * self.paint_metrics.unit_h() + self.paint_dy, .tint = tint,
		.pixels = self.paint_metrics.pixels });
}
