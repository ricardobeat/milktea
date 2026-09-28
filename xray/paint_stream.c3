module xray;

// Recorded before cell compositing, so transparent backgrounds keep the
// vector surface beneath them instead of inheriting a flattened cell colour.
enum PaintKind : char { CELL, DECORATION, TINT }

struct PaintOp {
	PaintKind kind;
	int col, row;
	Cell cell;
	Decoration decoration;
	Color tint;
}

fn void ScreenBuffer.record_cell(&self, sz col, sz row, Cell cell) {
	if (!self.record_paint) return;
	if (self.decorated_content) cell.style.bg = color_transparent();
	self.paint_ops.push({ .kind = PaintKind.CELL, .col = (int)col,
		.row = (int)row, .cell = cell });
}

fn void ScreenBuffer.record_tint(&self, int col, int row, Color tint) {
	if (!self.record_paint) return;
	self.paint_ops.push({ .kind = PaintKind.TINT, .col = col,
		.row = row, .tint = tint });
}
